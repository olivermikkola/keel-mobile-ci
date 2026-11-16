import XCTest
@testable import KeelMobile

@MainActor
final class KeepGoingChatTests: XCTestCase {
    private actor Scripted: LocalGenerating {
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            onText(replies.isEmpty ? "Done." : replies.removeFirst())
            return 12
        }
    }

    private func list(_ n: Int) -> String {
        "<tool_call>\n<function=list_files>\n<parameter=path>\n.\n</parameter>\n<parameter=offset>\n\(n)\n</parameter>\n</function>\n</tool_call>"
    }

    /// Runs the chat, answering the check-in with `answer`; returns how often it asked.
    private func run(_ chat: LocalChat, answer: Bool) async throws -> Int {
        var asked = 0
        for _ in 0..<1500 {
            if chat.pendingContinue != nil { asked += 1; chat.decideContinue(answer) }
            if !chat.running { return asked }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Chat did not finish")
        return asked
    }

    private func transcript() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
    }

    func testTheReplyPausesAtTheCheckInAndContinuesOnYes() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let calls = (0..<30).map(list)
        let chat = LocalChat(transcript: path, generator: Scripted(calls + ["All 30 listings done."]))
        chat.send("List the files thirty times", model: LocalModel.catalog[0], path: path)
        let asked = try await run(chat, answer: true)
        XCTAssertEqual(asked, 1, "One check-in at 25 calls; a yes allows 25 more")
        XCTAssertEqual(chat.messages.filter { $0.role == "tool" }.count, 30)
        XCTAssertEqual(chat.messages.last?.text, "All 30 listings done.")
        XCTAssertNil(chat.error)
    }

    func testStopHereEndsTheReplyWithoutRunningMoreTools() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path, generator: Scripted((0..<30).map(list)))
        chat.send("List the files thirty times", model: LocalModel.catalog[0], path: path)
        let asked = try await run(chat, answer: false)
        XCTAssertEqual(asked, 1)
        let tools = chat.messages.filter { $0.role == "tool" }
        XCTAssertEqual(tools.filter { $0.note != "Stopped" }.count, ChatMode.work.toolCheckIn, "Exactly 25 calls ran")
        XCTAssertTrue(tools.last?.text.contains("the user stopped here after 25 tool calls") == true)
        XCTAssertNotNil(chat.error)
    }
}
