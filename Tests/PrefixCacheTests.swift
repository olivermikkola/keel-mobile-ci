import XCTest
@testable import KeelMobile

final class PrefixCacheTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "stories15M-q4_0", withExtension: "gguf", subdirectory: "fixtures"))
    }

    func testAppendOnlyTurnReusesDecodedPrefix() async throws {
        let runtime = LocalInference()
        let firstText = TextBox()
        let prompt = "Once upon a time"
        _ = try await runtime.generate(path: try fixture().path, prompt: prompt, limit: 12,
                                       cancellation: InferenceCancellation()) { firstText.append($0) }
        let first = await runtime.prefixStats()
        XCTAssertEqual(first.reusedTokens, 0)
        XCTAssertGreaterThan(first.decodedTokens, 0)

        let second = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: prompt + firstText.value, limit: 4,
                                       cancellation: InferenceCancellation()) { second.append($0) }
        let reused = await runtime.prefixStats()
        XCTAssertGreaterThan(reused.reusedTokens, 0)
        XCTAssertLessThan(reused.decodedTokens, first.decodedTokens)
        XCTAssertFalse(second.value.isEmpty)
        await runtime.unload()
    }

    func testDivergentPromptFallsBackToCleanPrefill() async throws {
        let runtime = LocalInference()
        let first = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: "Once upon a time", limit: 8,
                                       cancellation: InferenceCancellation()) { first.append($0) }
        let second = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: "A different opening entirely", limit: 4,
                                       cancellation: InferenceCancellation()) { second.append($0) }
        let stats = await runtime.prefixStats()
        XCTAssertEqual(stats.reusedTokens, 0)
        XCTAssertGreaterThan(stats.decodedTokens, 0)
        await runtime.unload()
    }

    func testCancelledTurnDoesNotLeaveAReusableSuffix() async throws {
        let runtime = LocalInference()
        let cancellation = InferenceCancellation()
        do {
            _ = try await runtime.generate(path: try fixture().path, prompt: "Once upon a time", limit: 128,
                                           cancellation: cancellation) { _ in cancellation.cancel() }
            XCTFail("Must stop after the first chunk")
        } catch is CancellationError { }
        let text = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: "Once upon a time", limit: 4,
                                       cancellation: InferenceCancellation()) { text.append($0) }
        let stats = await runtime.prefixStats()
        XCTAssertEqual(stats.reusedTokens, 0, "Cancelled bytes are unknown and must be re-prefilled, not trusted")
        XCTAssertGreaterThan(stats.decodedTokens, 0)
        await runtime.unload()
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
