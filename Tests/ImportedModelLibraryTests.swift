import XCTest
import CryptoKit
@testable import KeelMobile

/// Importing a .gguf through the real library: header check, pinned copy,
/// saved list, selection and removal. Synthetic headers; no model is run.
@MainActor
final class ImportedModelLibraryTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A header followed by filler, standing in for weights.
    private func gguf(_ architecture: String, in folder: URL, name: String = "Tiny-Qwen3-Q4_K_M.gguf") throws -> URL {
        var b = GGUFBuilder(metadataCount: 6)
        b.addString("general.architecture", architecture)
        b.addUInt32("\(architecture).block_count", 28)
        b.addUInt32("\(architecture).attention.head_count_kv", 8)
        b.addUInt32("\(architecture).attention.key_length", 128)
        b.addUInt32("\(architecture).attention.value_length", 128)
        b.addUInt32("\(architecture).context_length", 40_960)
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (b.data + Data(repeating: 7, count: 5_000_000)).write(to: url)
        return url
    }

    private func library(_ directory: URL, stubbed: Bool = false) -> ModelLibrary {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return ModelLibrary(directory: directory, defaults: defaults, transferConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            if stubbed { configuration.protocolClasses = [StubProtocol.self] }
            return configuration
        })
    }

    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private func serve(_ file: Data, sha256: String, requests: @escaping (String) -> Void = { _ in }, status: Int = 302) {
        StubProtocol.responseHeaders = ["X-Linked-Size": String(file.count), "X-Linked-Etag": "\"\(sha256)\""]
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "huggingface.co")
            if request.httpMethod == "HEAD" { requests("HEAD"); return (status, Data()) }
            if let range = request.value(forHTTPHeaderField: "Range") { requests(range); return (206, file.prefix(262_144)) }
            requests("GET"); return (200, file)
        }
    }

    private func settle(_ models: ModelLibrary) async throws {
        for _ in 0..<500 where models.importing != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(models.importing)
    }

    func testAQwenFileIsCopiedPinnedSavedAndSelected() async throws {
        let source = try gguf("qwen3", in: folder()), directory = folder()
        let models = library(directory)
        models.importModel(from: source)
        try await settle(models)
        XCTAssertNil(models.error)
        let record = try XCTUnwrap(models.imported.first)
        XCTAssertEqual(record.name, "Tiny-Qwen3-Q4_K_M")
        XCTAssertEqual(record.family, .bonsai)
        let original = try Data(contentsOf: source)
        XCTAssertEqual(record.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(record.fileName)), original)
        XCTAssertEqual(models.selected, record.id)
        XCTAssertTrue(models.installed.contains(record.id))
        XCTAssertEqual(models.current.quantization, "GGUF")
        XCTAssertEqual(models.current.contextSize, record.contextSize)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // A relaunch finds it; removing it deletes the copy and falls back to a catalog model.
        let relaunched = library(directory)
        XCTAssertEqual(relaunched.imported, [record])
        relaunched.removeImported(record.id)
        XCTAssertTrue(relaunched.imported.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(record.fileName).path))
        XCTAssertTrue(library(directory).imported.isEmpty)
    }

    func testAnImportBlocksAnotherDownloadAndCancellationDoesNotInstallIt() async throws {
        let directory = folder(), models = library(directory)
        models.importModel(from: try gguf("qwen3", in: folder()))
        XCTAssertTrue(models.isTransferring)
        models.install(LocalModel.catalog[0])
        XCTAssertNil(models.downloading, "A second transfer must not replace the import's cancellation handle")
        models.cancel()
        try await settle(models)
        XCTAssertTrue(models.imported.isEmpty)
        XCTAssertFalse(models.isTransferring)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasPrefix("custom-") }, "Cancelled import left \(files)")
    }

    func testCancellationAtTheLastBlockRemovesTheStagingFile() async throws {
        let source = try gguf("qwen3", in: folder()), directory = folder()
        let job = Task.detached {
            try ModelLibrary.copyChecked(source, into: directory, physicalMemoryBytes: 8_000_000_000) { done, total in
                if done == total { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await job.value; XCTFail("Cancelled import was installed") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasPrefix("custom-") }, "Cancelled import left \(files)")
    }

    func testFailedManifestWriteKeepsTheImportedModelAndSelection() async throws {
        let directory = folder(), models = library(directory)
        models.importModel(from: try gguf("qwen3", in: folder()))
        try await settle(models)
        let model = try XCTUnwrap(models.imported.first)
        let manifest = directory.appendingPathComponent("imported-models.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        try Data("block replacement".utf8).write(to: manifest.appendingPathComponent("keep"))
        models.removeImported(model.id)
        XCTAssertEqual(models.imported, [model])
        XCTAssertEqual(models.selected, model.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: models.path(models.current).path))
        XCTAssertNotNil(models.error)
    }

    func testHeaderChangeBetweenInspectionAndCopyIsRejected() async throws {
        let source = try gguf("qwen3", in: folder()), directory = folder()
        let job = Task.detached {
            try ModelLibrary.copyChecked(source, into: directory, physicalMemoryBytes: 8_000_000_000) { done, _ in
                if done == 0 {
                    do {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        try writer.write(contentsOf: Data("NOPE".utf8))
                    } catch { XCTFail("Could not alter fixture: \(error)") }
                }
            }
        }
        do { _ = try await job.value; XCTFail("Changed header was imported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed"), "\(error)") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("custom-") })
    }

    func testGrowingSourceCannotWriteBeyondItsDeclaredSize() async throws {
        let source = try gguf("qwen3", in: folder()), directory = folder()
        let job = Task.detached {
            try ModelLibrary.copyChecked(source, into: directory, physicalMemoryBytes: 8_000_000_000) { done, total in
                XCTAssertLessThanOrEqual(done, total, "The copy must be bounded before writing or reporting progress")
                if done > 0 && done < total {
                    do {
                        let writer = try FileHandle(forWritingTo: source)
                        defer { try? writer.close() }
                        try writer.seekToEnd()
                        try writer.write(contentsOf: Data(repeating: 0, count: 65_536))
                    } catch { XCTFail("Could not grow fixture: \(error)") }
                }
            }
        }
        do { _ = try await job.value; XCTFail("Growing file was imported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed"), "\(error)") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("custom-") })
    }

    func testAPastedLinkIsCheckedPinnedDownloadedAndVerified() async throws {
        let file = try Data(contentsOf: try gguf("qwen3", in: folder()))
        let sha = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        var seen = [String]()
        serve(file, sha256: sha) { seen.append($0) }
        let directory = folder()
        let models = library(directory, stubbed: true)
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/blob/main/Tiny-Qwen3-Q4_K_M.gguf?download=true")
        try await settle(models)
        XCTAssertNil(models.error)
        XCTAssertEqual(seen, ["HEAD", "bytes=0-262143", "GET"], "Header first, then the pinned download")
        let record = try XCTUnwrap(models.imported.first)
        XCTAssertEqual(record.sha256, sha)
        XCTAssertEqual(record.name, "Tiny-Qwen3-Q4_K_M")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(record.fileName)), file)
        XCTAssertEqual(models.selected, record.id)
    }

    func testDownloadedHeaderMustMatchTheInspectedFileEvenWithAValidChecksum() async throws {
        let inspected = try Data(contentsOf: try gguf("qwen3", in: folder()))
        let downloaded = try Data(contentsOf: try gguf("qwen2", in: folder()))
        XCTAssertEqual(inspected.count, downloaded.count)
        let sha = SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()
        StubProtocol.responseHeaders = ["X-Linked-Size": String(downloaded.count), "X-Linked-Etag": sha]
        StubProtocol.handler = { request in
            if request.httpMethod == "HEAD" { return (302, Data()) }
            if request.value(forHTTPHeaderField: "Range") != nil { return (206, inspected.prefix(GGUFHeader.maxHeaderBytes)) }
            return (200, downloaded)
        }
        let directory = folder(), models = library(directory, stubbed: true)
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/tiny.gguf")
        try await settle(models)
        XCTAssertTrue(models.error?.contains("verification failed") == true, models.error ?? "no error")
        XCTAssertTrue(models.imported.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("custom-") })
    }

    func testCancellingALinkImportBeforeItStartsMakesNoRequest() async throws {
        var requests = 0
        StubProtocol.handler = { _ in requests += 1; return (500, Data()) }
        let models = library(folder(), stubbed: true)
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/tiny.gguf")
        XCTAssertTrue(models.isTransferring)
        models.install(LocalModel.catalog[0])
        XCTAssertNil(models.downloading)
        models.cancel()
        try await settle(models)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(models.imported.isEmpty)
    }

    func testALinkThatFailsAnyCheckLeavesNothingBehind() async throws {
        let file = try Data(contentsOf: try gguf("qwen3", in: folder()))
        let directory = folder()
        let models = library(directory, stubbed: true)
        // Hugging Face's checksum disagrees with the bytes: verification removes the download.
        serve(file, sha256: String(repeating: "0", count: 64))
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/tiny.gguf")
        try await settle(models)
        XCTAssertTrue(models.error?.contains("verification failed") == true, models.error ?? "no error")
        // A gated model, a page that is not a .gguf, and a llama model whose format Keel cannot tell.
        serve(file, sha256: String(repeating: "0", count: 64), status: 401)
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/tiny.gguf")
        try await settle(models)
        XCTAssertTrue(models.error?.contains("sign-in") == true, models.error ?? "no error")
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/README.md")
        XCTAssertNotNil(models.error)
        let llama = try Data(contentsOf: try gguf("llama", in: folder()))
        var downloads = 0
        serve(llama, sha256: SHA256.hash(data: llama).map { String(format: "%02x", $0) }.joined()) { if $0 == "GET" { downloads += 1 } }
        models.importModel(link: "https://huggingface.co/acme/Tiny-GGUF/resolve/main/llama.gguf")
        try await settle(models)
        XCTAssertTrue(models.error?.contains("cannot tell which chat format") == true, models.error ?? "no error")
        XCTAssertEqual(downloads, 0, "Refused from the header, before downloading the weights")
        XCTAssertTrue(models.imported.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix("custom-") }, "\(left)")
    }

    func testAFileKeelCannotPromptIsRefusedBeforeAnythingIsCopied() async throws {
        let directory = folder()
        let models = library(directory)
        models.importModel(from: try gguf("llama", in: folder(), name: "Some-Llama.gguf"))
        try await settle(models)
        XCTAssertTrue(models.error?.contains("cannot tell which chat format") == true, models.error ?? "no error")
        XCTAssertTrue(models.imported.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix("custom-") }, "\(left)")

        let text = folder().appendingPathComponent("notes.gguf")
        try FileManager.default.createDirectory(at: text.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: text)
        models.importModel(from: text)
        try await settle(models)
        XCTAssertTrue(models.error?.contains("not a model Keel can read") == true, models.error ?? "no error")
    }
}
