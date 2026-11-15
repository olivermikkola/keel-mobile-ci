import XCTest
@testable import KeelMobile

@MainActor
final class ChatModeChatTests: XCTestCase {
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
            .appendingPathComponent("keel-mode-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private func wait(_ chat: LocalChat) async throws {
        for _ in 0..<300 {
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Chat did not finish")
    }

    func testChatModeSendsTheShortPromptAndPersists() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted(["Paris."])
        let chat = LocalChat(transcript: path, generator: model)
        XCTAssertEqual(chat.chatMode, .work, "Existing and new chats start in Work until the user picks Chat")
        XCTAssertTrue(chat.setChatMode(.chat))
        chat.send("Capital of France?", model: LocalModel.catalog[0], path: path)
        try await wait(chat)

        let requests = await model.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.prompt.contains("in Chat mode"))
        XCTAssertFalse(request.prompt.contains(#""name":"create_file""#))
        XCTAssertEqual(request.limit, AgentPrompt.readingReplyTokens)
        XCTAssertEqual(chat.messages.last?.text, "Paris.")

        XCTAssertEqual(LocalChat(transcript: path, generator: model).chatMode, .chat, "The mode is saved with the chat")
        XCTAssertTrue(chat.newChat())
        XCTAssertEqual(chat.chatMode, .chat, "A new chat starts in the last mode chosen")
        XCTAssertTrue(chat.newChat(app: .docs))
        XCTAssertEqual(chat.chatMode, .work, "Apps are always Work")
        XCTAssertFalse(chat.canSwitchMode)
        XCTAssertFalse(chat.setChatMode(.chat))
    }

    func testChatModeRefusesAWriteToolEvenIfTheModelCallsIt() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let call = "<tool_call>\n<function=create_file>\n<parameter=path>\nnote.md\n</parameter>\n<parameter=new_text>\nhi\n</parameter>\n</function>\n</tool_call>"
        let model = Scripted([call, "Work mode can make that file."])
        let chat = LocalChat(transcript: path, generator: model)
        XCTAssertTrue(chat.setChatMode(.chat))
        chat.send("Make a note file", model: LocalModel.catalog[0], path: path)
        try await wait(chat)

        XCTAssertTrue(chat.messages.compactMap(\.edit).isEmpty, "No proposal may be made in Chat mode")
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.contains("Chat mode does not offer create_file") })
        XCTAssertEqual(chat.messages.last?.text, "Work mode can make that file.")
    }
}
