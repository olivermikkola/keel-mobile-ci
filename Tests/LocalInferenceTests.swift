import XCTest
import CryptoKit
@testable import KeelMobile

final class LocalInferenceTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stories15M-q4_0", withExtension: "gguf", subdirectory: "fixtures"))
    }

    func testNativeRuntimeActuallyGeneratesText() async throws {
        let runtime = LocalInference()
        let text = CollectedText()
        let count = try await runtime.generate(path: fixture().path, prompt: "Once upon a time", limit: 24,
                                               cancellation: InferenceCancellation()) { text.append($0) }
        XCTAssertGreaterThan(count, 0)
        XCTAssertFalse(text.value.isEmpty)
        print("Native CPU fixture: \(count) tokens, \(text.value.utf8.count) UTF-8 bytes. No server involved.")
        await runtime.unload()
    }

    func testStopInterruptsRealGenerationAndRuntimeCanBeReused() async throws {
        let runtime = LocalInference()
        let cancellation = InferenceCancellation()
        do {
            _ = try await runtime.generate(path: fixture().path, prompt: "Once upon a time", limit: 128,
                                           cancellation: cancellation) { _ in cancellation.cancel() }
            XCTFail("Generation must stop after the first text chunk")
        } catch is CancellationError { }
        let count = try await runtime.generate(path: fixture().path, prompt: "Once upon a time", limit: 4,
                                               cancellation: InferenceCancellation()) { _ in }
        XCTAssertGreaterThan(count, 0)
        await runtime.unload()
    }

    func testPrefillProgressReportsBoundedTokenCounts() async throws {
        let runtime = LocalInference()
        let progress = PrefillBox()
        _ = try await runtime.generate(path: fixture().path, prompt: "Once upon a time", limit: 4,
                                       contextSize: 4096, cancellation: InferenceCancellation(),
                                       onPrefill: { progress.append($0, $1) }) { _ in }
        let values = progress.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(Set(values.map(\.total)).count, 1)
        XCTAssertEqual(values.last?.done, values.last?.total)
        var previous = -1
        for value in values {
            XCTAssertGreaterThanOrEqual(value.done, previous)
            previous = value.done
        }
        await runtime.unload()
    }

    func testOversizedContextFailsWithoutDecoding() async throws {
        let runtime = LocalInference()
        do {
            _ = try await runtime.generate(path: fixture().path, prompt: String(repeating: "hello ", count: 5000),
                                           cancellation: InferenceCancellation()) { _ in XCTFail("Must not emit text") }
            XCTFail("Oversized prompts must fail")
        } catch LocalModelError.tooLong { }
        await runtime.unload()
    }

    func testMissingModelFailsWithoutFallback() async throws {
        do {
            _ = try await LocalInference().generate(path: "/does-not-exist.gguf", prompt: "Hello",
                                                    cancellation: InferenceCancellation()) { _ in XCTFail("No model") }
            XCTFail("Missing model must fail")
        } catch LocalModelError.load { }
    }

    func testVerificationRejectsSameSizeCorruption() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("GGUF-test-fixture".utf8)
        try data.write(to: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = LocalModel(id: "test", name: "Test", bytes: Int64(data.count), revision: "test", sha256: hash, detail: "")
        XCTAssertNoThrow(try ModelLibrary.verify(file, model: model))
        try Data(repeating: 0, count: data.count).write(to: file)
        XCTAssertThrowsError(try ModelLibrary.verify(file, model: model))
    }

    @MainActor
    func testLibraryReclaimsOnlyInterruptedDownloadFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = LocalModel.catalog[0]
        let installed = folder.appendingPathComponent(model.fileName)
        let staging = folder.appendingPathComponent(model.fileName + ".partial")
        let other = folder.appendingPathComponent("unrelated.partial")
        let content = Data("retained data".utf8)
        for file in [installed, staging, other] { try content.write(to: file) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let library = ModelLibrary(directory: folder, defaults: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: installed), content)
        XCTAssertEqual(try Data(contentsOf: other), content)
        XCTAssertFalse(library.installed.contains(model.id), "A short file must not be offered as an installed model")
    }

    func testModelCatalogContextSizes() {
        let fourB = LocalModel.catalog.first(where: { $0.id == "4B" })
        XCTAssertEqual(fourB?.contextSize, 16_384)
        let nineB = LocalModel.catalog.first(where: { $0.id == "9B" })
        XCTAssertEqual(nineB?.contextSize, 32_768)
    }

    func testExpandedContextSizeAllowsLargerPrompts() async throws {
        let runtime = LocalInference()
        // Default 4096 context fails at 5000 tokens
        do {
            _ = try await runtime.generate(path: try fixture().path, prompt: String(repeating: "hello ", count: 5000),
                                           limit: 24, contextSize: 4096, cancellation: InferenceCancellation()) { _ in }
            XCTFail("Should fail with 4096 context")
        } catch LocalModelError.tooLong { }

        // With expanded 8192 context size, 5000 tokens fits within context
        // (will either generate or cancel promptly)
        let cancel = InferenceCancellation()
        cancel.cancel()
        do {
            _ = try await runtime.generate(path: try fixture().path, prompt: String(repeating: "hello ", count: 5000),
                                           limit: 4, contextSize: 8192, cancellation: cancel) { _ in }
        } catch is CancellationError { }
        await runtime.unload()
    }
}

private final class PrefillBox: @unchecked Sendable {
    struct Value { let done: Int; let total: Int }
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ done: Int, _ total: Int) { lock.lock(); stored.append(Value(done: done, total: total)); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class CollectedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
