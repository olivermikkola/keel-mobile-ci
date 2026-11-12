import XCTest
import CryptoKit
@testable import KeelMobile

final class ModelTransferTests: XCTestCase {
    private let bytes = Data((0..<131_072).map { UInt8($0 % 251) })
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private var model: LocalModel {
        LocalModel(id: "fixture", name: "Fixture", bytes: Int64(bytes.count), revision: "pinned",
                   sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), detail: "")
    }
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("model.download")
    }
    private func configuration(_ type: AnyClass = StubProtocol.self) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [type]; return configuration
    }

    func testResumesExactRangeAndVerifiesTheAssembledModel() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let prefix = bytes.count / 2; try bytes.prefix(prefix).write(to: file)
        StubProtocol.responseHeaders = ["Content-Range": "bytes \(prefix)-\(bytes.count - 1)/\(bytes.count)"]
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(prefix)-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            return (206, self.bytes.suffix(from: prefix))
        }
        try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try ModelLibrary.verify(file, model: model)
        print("Resume proof: preserved prefix + exact HTTP Range -> full pinned SHA-256 verified.")
    }

    func testIgnoredRangeRestartsInsteadOfAppendingAndInvalidRangePreservesPrefix() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let prefix = bytes.prefix(1024)
        try prefix.write(to: file)
        StubProtocol.responseHeaders = ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"]
        StubProtocol.handler = { _ in (206, self.bytes) }
        do { try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }; XCTFail("Wrong range must fail") }
        catch LocalModelError.http { }
        XCTAssertEqual(try Data(contentsOf: file), prefix)
        StubProtocol.responseHeaders = nil
        StubProtocol.handler = { _ in (200, self.bytes) }
        do { try await ModelTransfer.fetch(model, to: file, configuration: configuration(), allowRestart: false) { _, _ in }; XCTFail("Strict resume must reject a full restart") }
        catch LocalModelError.http { }
        XCTAssertEqual(try Data(contentsOf: file), prefix)
        try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try ModelLibrary.verify(file, model: model)
    }

    func testOversizedAndCorruptedResponsesCannotBecomeVerifiedModels() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        StubProtocol.handler = { _ in (200, self.bytes + Data([0])) }
        do { try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }; XCTFail("Must bound disk output") }
        catch LocalModelError.integrity { }
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, bytes.count)
        StubProtocol.handler = { _ in (200, Data(repeating: 0, count: self.bytes.count)) }
        try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }
        XCTAssertThrowsError(try ModelLibrary.verify(file, model: model))
    }

    func testCancellationKeepsWrittenBytesAndNextTransferResumesThem() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        StreamingModelProtocol.body = bytes
        let cancellation = TransferTaskBox()
        let transfer = Task {
            try await ModelTransfer.fetch(model, to: file, configuration: configuration(StreamingModelProtocol.self)) { received, total in
                if received > 0 && received < total { cancellation.cancel() }
            }
        }
        cancellation.set(transfer)
        do { try await transfer.value; XCTFail("Must stop during transfer") }
        catch is CancellationError { }
        let saved = try Data(contentsOf: file)
        XCTAssertGreaterThan(saved.count, 0); XCTAssertLessThan(saved.count, bytes.count)
        XCTAssertEqual(saved, bytes.prefix(saved.count))
        StubProtocol.responseHeaders = ["Content-Range": "bytes \(saved.count)-\(bytes.count - 1)/\(bytes.count)"]
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(saved.count)-")
            return (206, self.bytes.suffix(from: saved.count))
        }
        try await ModelTransfer.fetch(model, to: file, configuration: configuration()) { _, _ in }
        try ModelLibrary.verify(file, model: model)
        print("Pause proof: cancelled a live URLSession stream after \(saved.count) bytes, reopened its file, resumed and verified the model. HTTP transport is a fixture.")
    }

    @MainActor
    func testCompleteDownloadIsInstalledOnlyAfterHashVerification() async throws {
        for valid in [false, true] {
            let file = try file(); let folder = file.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = self.model
            let staging = folder.appendingPathComponent(model.fileName + ".download")
            try (valid ? bytes : Data(repeating: 0, count: bytes.count)).write(to: staging)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            StubProtocol.handler = { _ in (200, Data(repeating: 0, count: self.bytes.count)) }
            let library = ModelLibrary(directory: folder, defaults: defaults, transferConfiguration: { self.configuration() })
            library.install(model)
            for _ in 0..<500 {
                if library.downloading == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(library.downloading)
            XCTAssertEqual(FileManager.default.fileExists(atPath: library.path(model).path), valid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            if valid { XCTAssertNil(library.error); try ModelLibrary.verify(library.path(model), model: model) }
            else { XCTAssertNotNil(library.error); XCTAssertNotEqual(library.selected, model.id) }
        }
    }

    @MainActor
    func testRelaunchFindsPartialAndDiscardTouchesOnlyThatModel() throws {
        let file = try file(); let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LocalModel.catalog[0]
        let partial = folder.appendingPathComponent(model.fileName + ".download")
        let unrelated = folder.appendingPathComponent("keep.download")
        let data = Data(repeating: 7, count: 4096)
        try data.write(to: partial); try data.write(to: unrelated)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let library = ModelLibrary(directory: folder, defaults: defaults)
        XCTAssertEqual(library.partialBytes[model.id], 4096)
        XCTAssertFalse(library.installed.contains(model.id))
        library.discardPartial(model)
        XCTAssertNil(ModelLibrary(directory: folder, defaults: defaults).partialBytes[model.id])
        XCTAssertEqual(try Data(contentsOf: unrelated), data)
    }

    @MainActor
    func testCorruptedSavedPrefixRestartsOnceAndInstallsOnlyVerifiedBytes() async throws {
        let file = try file(); let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = self.model
        let staging = folder.appendingPathComponent(model.fileName + ".download")
        try Data(repeating: 0, count: bytes.count / 2).write(to: staging)
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            if calls == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(self.bytes.count / 2)-")
                StubProtocol.responseHeaders = ["Content-Range": "bytes \(self.bytes.count / 2)-\(self.bytes.count - 1)/\(self.bytes.count)"]
                return (206, self.bytes.suffix(from: self.bytes.count / 2))
            }
            XCTAssertEqual(calls, 2); XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            StubProtocol.responseHeaders = nil
            return (200, self.bytes)
        }
        let library = ModelLibrary(directory: folder, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                   transferConfiguration: { self.configuration() })
        library.install(model)
        for _ in 0..<500 { if library.downloading == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.downloading)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(library.error)
        XCTAssertEqual(try Data(contentsOf: library.path(model)), bytes)
        try ModelLibrary.verify(library.path(model), model: model)
        XCTAssertNil(library.failedModel)
        print("Recovery proof: resumed a corrupt saved prefix, rejected its assembled checksum, fetched one clean copy and installed only its verified bytes. HTTP payloads are fixtures.")
    }

    @MainActor
    func testFreshCorruptionDoesNotLoopAndOffersRetryDiagnostics() async throws {
        let file = try file(); let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = self.model
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (200, Data(repeating: 0, count: self.bytes.count)) }
        let library = ModelLibrary(directory: folder, defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                   transferConfiguration: { self.configuration() })
        library.install(model)
        for _ in 0..<500 { if library.downloading == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.downloading); XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path(model).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.partialPath(model).path))
        XCTAssertEqual(library.failedModel?.id, model.id)
        XCTAssertTrue(library.failureDetail?.contains("SHA-256 mismatch") == true)
        XCTAssertTrue(library.failureDetail?.contains(model.sha256) == true)
        StubProtocol.handler = { _ in calls += 1; return (200, self.bytes) }
        library.install(model)
        for _ in 0..<500 { if library.downloading == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.error); XCTAssertNil(library.failureDetail); XCTAssertNil(library.failedModel)
        XCTAssertEqual(calls, 2); try ModelLibrary.verify(library.path(model), model: model)
    }

    func testNativeComplete9BDownloadAndVerification() async throws {
        guard Bundle(for: Self.self).url(forResource: "live-model-complete", withExtension: "txt", subdirectory: "fixtures") != nil else {
            throw XCTSkip("Full 2.56 GB native CDN verification is an explicit opt-in workflow.")
        }
        let model = LocalModel.catalog[1]
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let started = Date()
        do {
            try await ModelTransfer.fetch(model, to: file) { _, _ in }
            try ModelLibrary.verify(file, model: model)
        } catch {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            XCTFail("Full native 9B transfer/verification failed: \(String(describing: error)); stored bytes \(size), expected \(model.bytes).")
            throw error
        }
        XCTAssertEqual(Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!), model.bytes)
        print("Full native CDN proof: pinned 9B, \(model.bytes) bytes streamed by production URLSession transfer, SHA256 \(model.sha256) verified by production ModelLibrary.verify, \(Int(Date().timeIntervalSince(started))) seconds. macOS-hosted iOS simulator; physical cellular download remains unverified.")
    }

    func testNativeResumeAgainstPinnedModelCDN() async throws {
        guard Bundle(for: Self.self).url(forResource: "live-model-range", withExtension: "txt", subdirectory: "fixtures") != nil else {
            throw XCTSkip("Live CDN range probe is enabled by the model-download workflow only.")
        }
        let model = LocalModel.catalog[1]
        let file = try file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        let offset = model.bytes - 16
        try handle.truncate(atOffset: UInt64(offset)); try handle.close()
        // Strict resume rejects a full response before accepting its body, so
        // this probe cannot restart a multi-gigabyte transfer.
        do { try await ModelTransfer.fetch(model, to: file, allowRestart: false) { _, _ in } }
        catch {
            let code = (error as? URLError)?.code.rawValue
            XCTFail("Native CDN resume failed: \(type(of: error)), network code \(code.map { String($0) } ?? "none"). No full model download was requested.")
            return
        }
        let result = try FileHandle(forReadingFrom: file)
        defer { try? result.close() }
        try result.seek(toOffset: UInt64(offset))
        let tail = try XCTUnwrap(result.read(upToCount: 16))
        XCTAssertEqual(tail.count, 16)
        XCTAssertEqual(try result.seekToEnd(), UInt64(model.bytes))
        print("Native CDN resume proof: pinned 9B, offset \(offset), \(tail.count) bytes received through URLSession after redirects. Prefix is a sparse test fixture; this does not verify the full model.")
    }
}

private final class TransferTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var cancelled = false
    func set(_ task: Task<Void, Error>) {
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel()
    }
}

private final class StreamingModelProtocol: URLProtocol, @unchecked Sendable {
    static var body = Data()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        send(0)
    }
    private func send(_ offset: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.03) { [self] in
            lock.lock(); let stop = stopped; lock.unlock(); guard !stop else { return }
            let end = min(offset + 16_384, Self.body.count)
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset..<end))
            if end == Self.body.count { client?.urlProtocolDidFinishLoading(self) }
            else { send(end) }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
