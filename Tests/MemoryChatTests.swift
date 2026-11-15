import XCTest
@testable import KeelMobile

@MainActor
final class MemoryChatTests: XCTestCase {
    private actor Scripted: LocalGenerating {
        var requests: [LocalGenerationRequest] = []
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            requests.append(request)
            onText(replies.isEmpty ? "Done." : replies.removeFirst())
            return 12
        }
    }

    private func tempTranscript() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-memory-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private let remember = "<tool_call>\n<function=remember>\n<parameter=fact>\nThe user is vegetarian.\n</parameter>\n</function>\n</tool_call>"

    /// Waits for the approval question, answers it, then waits for the reply.
    private func run(_ chat: LocalChat, answer: Bool?) async throws {
        for _ in 0..<300 {
            if let answer, chat.pendingMemory != nil { chat.decideMemory(answer) }
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Chat did not finish")
    }

    func testAFactIsSavedOnlyWithApprovalAndReachesTheNextChat() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted([remember, "I won't save that.", remember, "Noted.", "Lentil curry."])
        let chat = LocalChat(transcript: path, generator: model)

        chat.send("Remember that I'm vegetarian", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: false)
        XCTAssertTrue(chat.memory.facts.isEmpty, "Declined: nothing saved")
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.hasPrefix("Not saved") })

        chat.send("Please do remember it", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: true)
        XCTAssertEqual(chat.memory.facts.map(\.text), ["The user is vegetarian."])

        XCTAssertTrue(chat.newChat())
        chat.send("Suggest a dinner", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: nil)
        let requests = await model.requests
        let last = try XCTUnwrap(requests.last)
        XCTAssertTrue(last.prompt.contains("What you remember about the user"))
        XCTAssertTrue(last.prompt.contains("- The user is vegetarian."))

        let reopened = LocalChat(transcript: path, generator: model)
        XCTAssertEqual(reopened.memory.facts.count, 1, "Memory persists")
        XCTAssertTrue(reopened.setMemoryEnabled(false))
        XCTAssertTrue(reopened.forget(reopened.memory.facts[0].id))
        XCTAssertTrue(reopened.memory.facts.isEmpty)
        XCTAssertFalse(LocalChat(transcript: path, generator: model).memory.enabled)
    }

    func testAppsDoNotGetMemory() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted(["Here is a page."])
        let chat = LocalChat(transcript: path, generator: model)
        XCTAssertTrue(chat.newChat(app: .websites))
        chat.send("Make a page", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: nil)
        let requests = await model.requests
        let first = try XCTUnwrap(requests.first)
        XCTAssertFalse(first.prompt.contains(#""name":"remember""#))
    }
}
