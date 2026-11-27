import XCTest
@testable import KeelMobile

@MainActor
final class CustomInstructionsChatTests: XCTestCase {
    private actor Recorder: LocalGenerating {
        var requests: [LocalGenerationRequest] = []
        let reply: String
        init(reply: String = "Short answer.") { self.reply = reply }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            requests.append(request)
            onText(reply)
            return 12
        }
    }

    private func tempTranscript() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-customize-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private func wait(_ chat: LocalChat) async throws {
        for _ in 0..<200 {
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Chat did not finish")
    }

    func testStandingInstructionsAndThinkingPersistAndRenderIntoPrompt() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let recorder = Recorder(reply: "Reasoning step first.\n</think>\n\nFinal concise answer.")
        let chat = LocalChat(transcript: path, generator: recorder)
        XCTAssertTrue(chat.saveCustomInstructions("Always use metric units."))
        XCTAssertTrue(chat.setThinkingEnabled(true))
        XCTAssertEqual(chat.customInstructions, "Always use metric units.")
        XCTAssertTrue(chat.thinkingEnabled)

        chat.send("How far is 1000m?", model: LocalModel.catalog[0], path: path)
        try await wait(chat)

        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.prompt.contains("Standing instructions from the user for every chat:\nAlways use metric units."))
        XCTAssertTrue(request.prompt.hasSuffix("<|im_start|>assistant\n<think>\n"))
        XCTAssertEqual(request.limit, AgentPrompt.writingReplyTokens + AgentPrompt.thinkingBudgetTokens)
        XCTAssertEqual(chat.messages.last?.text, "Final concise answer.")

        let reopened = LocalChat(transcript: path, generator: recorder)
        XCTAssertEqual(reopened.customInstructions, "Always use metric units.")
        XCTAssertTrue(reopened.thinkingEnabled)
        XCTAssertTrue(reopened.saveCustomInstructions(""))
        XCTAssertEqual(reopened.customInstructions, "")
    }
}
