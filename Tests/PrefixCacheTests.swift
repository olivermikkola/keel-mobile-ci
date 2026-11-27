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

    func testAStepStoppedMidReplyKeepsItsPromptForTheNextStep() async throws {
        // Keel stops a step as soon as a complete tool call is written. That
        // stop used to clear the cache, so every tool step read the whole chat
        // again (seen on an iPhone XR, 2026-11-26).
        let runtime = LocalInference()
        let prompt = "Once upon a time there was a little girl named Lily. She liked to play"
        let stop = InferenceCancellation()
        let partial = TextBox()
        do {
            _ = try await runtime.generate(path: try fixture().path, prompt: prompt, limit: 48, cancellation: stop) { text in
                partial.append(text)
                if partial.value.count >= 6 { stop.cancel() }
            }
        } catch is CancellationError {}
        XCTAssertTrue(stop.isCancelled, "The first step must be stopped mid-reply")
        let read = await runtime.prefixStats()
        _ = try await runtime.generate(path: try fixture().path, prompt: prompt + " in the park", limit: 4,
                                       cancellation: InferenceCancellation()) { _ in }
        let next = await runtime.prefixStats()
        XCTAssertEqual(next.reusedTokens, read.decodedTokens, "The whole first prompt is reused")
        XCTAssertGreaterThan(next.decodedTokens, 0)
        await runtime.unload()
    }

    func testDivergentPromptKeepsOnlyTheSharedStartToken() async throws {
        let runtime = LocalInference()
        let first = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: "Once upon a time", limit: 8,
                                       cancellation: InferenceCancellation()) { first.append($0) }
        let second = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: "A different opening entirely", limit: 4,
                                       cancellation: InferenceCancellation()) { second.append($0) }
        let stats = await runtime.prefixStats()
        XCTAssertEqual(stats.reusedTokens, 1, "Only the beginning-of-text token is shared")
        XCTAssertGreaterThan(stats.decodedTokens, 0)
        XCTAssertFalse(second.value.isEmpty)
        await runtime.unload()
    }

    func testDivergenceAfterASharedOpeningTrimsInsteadOfClearing() async throws {
        // Chat history re-tokenizes differently from sampled tokens; the shared
        // system prompt must survive that instead of being read again.
        let runtime = LocalInference()
        let shared = "Once upon a time there was a little girl named Lily. She"
        let first = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: shared + " liked to play", limit: 8,
                                       cancellation: InferenceCancellation()) { first.append($0) }
        let firstStats = await runtime.prefixStats()
        let second = TextBox()
        _ = try await runtime.generate(path: try fixture().path, prompt: shared + " was very sad", limit: 4,
                                       cancellation: InferenceCancellation()) { second.append($0) }
        let stats = await runtime.prefixStats()
        XCTAssertGreaterThan(stats.reusedTokens, 10)
        XCTAssertLessThan(stats.reusedTokens, firstStats.decodedTokens)
        XCTAssertGreaterThan(stats.decodedTokens, 0)
        XCTAssertFalse(second.value.isEmpty)
        await runtime.unload()
    }

    func testCancelledTurnRollsBackToItsPromptAndAnswersLikeAFreshRead() async throws {
        // A stopped step keeps exactly its prompt (`keepReadPrompt`), never the
        // unknown part of its reply. The same prompt then reads only its last
        // token again, and must answer exactly like a runtime that read it all.
        let path = try fixture().path
        func request(_ limit: Int) -> LocalGenerationRequest {
            var made = LocalGenerationRequest(path: path, prompt: "Once upon a time", limit: limit, contextSize: 4096)
            made.greedy = true
            return made
        }
        let runtime = LocalInference()
        let cancellation = InferenceCancellation()
        do {
            _ = try await runtime.generate(request(128), cancellation: cancellation, onPrefill: { _, _ in }) { _ in cancellation.cancel() }
            XCTFail("Must stop after the first chunk")
        } catch is CancellationError { }
        let text = TextBox()
        _ = try await runtime.generate(request(8), cancellation: InferenceCancellation(), onPrefill: { _, _ in }) { text.append($0) }
        let stats = await runtime.prefixStats()
        XCTAssertGreaterThan(stats.reusedTokens, 0, "The prompt read before the stop is kept")
        XCTAssertEqual(stats.decodedTokens, 1, "The last prompt token is read again for fresh output")
        await runtime.unload()

        let fresh = LocalInference()
        let reference = TextBox()
        _ = try await fresh.generate(request(8), cancellation: InferenceCancellation(), onPrefill: { _, _ in }) { reference.append($0) }
        await fresh.unload()
        XCTAssertFalse(reference.value.isEmpty)
        XCTAssertEqual(text.value, reference.value, "The kept prompt answers exactly like a fresh read")
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
