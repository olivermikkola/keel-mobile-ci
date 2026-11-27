import XCTest
@testable import KeelMobile

@MainActor
final class ModelChatTitleTests: XCTestCase {
    /// Answers the chat, then the title question.
    private actor Model: LocalGenerating {
        var requests: [LocalGenerationRequest] = []
        let title: String
        init(title: String) { self.title = title }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            requests.append(request)
            onText(request.prompt.contains(ChatTitle.ask) ? title : "Ruben sounds like a fun dog.")
            return 8
        }
    }

    private func transcript() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-title-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private func waitForTitle(_ chat: LocalChat, _ model: Model, requests: Int) async throws {
        for _ in 0..<300 {
            let count = await model.requests.count
            if !chat.running, count >= requests { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No title request")
    }

    func testFirstReplyIsFollowedByATitleOnTheSamePrompt() async throws {
        let path = transcript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Model(title: "\"Ruben the funny dog\"")
        let chat = LocalChat(transcript: path, generator: model)
        chat.writesModelTitles = true
        chat.send("can you tell me something about my dog ruben who is a little funny", model: LocalModel.catalog[0], path: path)
        try await waitForTitle(chat, model, requests: 2)
        try await Task.sleep(nanoseconds: 50_000_000)

        let requests = await model.requests
        XCTAssertEqual(requests.count, 2)
        let chatPrompt = requests[0].prompt
        let titlePrompt = requests[1].prompt
        // The whole chat prompt up to its reply is reused: only one turn is new.
        let opening = String(chatPrompt.prefix(chatPrompt.count - 40))
        XCTAssertTrue(titlePrompt.hasPrefix(opening))
        XCTAssertTrue(titlePrompt.contains("Ruben sounds like a fun dog."))
        XCTAssertTrue(titlePrompt.contains(ChatTitle.ask))
        XCTAssertTrue(requests[1].keepCheckpoint)
        XCTAssertTrue(requests[1].greedy)
        XCTAssertEqual(requests[1].limit, ChatTitle.replyTokens)
        XCTAssertFalse(requests[0].keepCheckpoint)

        let saved = try XCTUnwrap(chat.tasks.first { $0.id == chat.activeTaskID })
        XCTAssertEqual(saved.title, "Ruben the funny dog")
        XCTAssertEqual(saved.titledByModel, true)

        // A second turn keeps the model title and asks for no new one.
        chat.send("What should I feed him?", model: LocalModel.catalog[0], path: path)
        try await waitForTitle(chat, model, requests: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await model.requests.count
        XCTAssertEqual(after, 3)
        XCTAssertEqual(chat.tasks.first { $0.id == chat.activeTaskID }?.title, "Ruben the funny dog")

        // It survives a relaunch.
        let reopened = LocalChat(transcript: path, generator: model)
        XCTAssertEqual(reopened.tasks.first { $0.id == chat.activeTaskID }?.title, "Ruben the funny dog")
    }

    func testAnUnusableTitleKeepsTheTidiedFirstMessage() async throws {
        let path = transcript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Model(title: "<tool_call>{}</tool_call>")
        let chat = LocalChat(transcript: path, generator: model)
        chat.writesModelTitles = true
        chat.send("Can you plan a weekend in Turku", model: LocalModel.catalog[0], path: path)
        try await waitForTitle(chat, model, requests: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let saved = try XCTUnwrap(chat.tasks.first { $0.id == chat.activeTaskID })
        XCTAssertEqual(saved.title, "Plan a weekend in Turku")
        XCTAssertNotEqual(saved.titledByModel, true)
    }

    func testARenamedChatIsNotRetitled() async throws {
        let path = transcript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Model(title: "Something else")
        let chat = LocalChat(transcript: path, generator: model)
        chat.writesModelTitles = true
        let id = chat.activeTaskID
        XCTAssertTrue(chat.renameTask(id, title: "My own name"))
        chat.send("Hello there", model: LocalModel.catalog[0], path: path)
        for _ in 0..<200 where chat.running { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await model.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(chat.tasks.first { $0.id == id }?.title, "My own name")
    }
}
