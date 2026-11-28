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

    private func notesAttachment() -> Attachment {
        let text = (1...40).map { "line-\($0)" }.joined(separator: "\n")
        return Attachment(filename: "notes.txt", mimeType: "text/plain", extractedText: text, byteSize: text.utf8.count, source: .file)
    }

    private func readLine(_ n: Int) -> String {
        "<tool_call>\n<function=read_file>\n<parameter=path>\nattachments/notes.txt\n</parameter>\n<parameter=start_line>\n\(n + 1)\n</parameter>\n<parameter=count>\n1\n</parameter>\n</function>\n</tool_call>"
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
        let calls = (0..<30).map(readLine)
        let chat = LocalChat(transcript: path, generator: Scripted(calls + ["All 30 lines read."]))
        chat.send("Read thirty lines", attachments: [notesAttachment()], model: LocalModel.catalog[0], path: path)
        let asked = try await run(chat, answer: true)
        XCTAssertEqual(asked, 1, "One check-in at 25 calls; a yes allows 25 more")
        XCTAssertEqual(chat.messages.filter { $0.role == "tool" }.count, 30)
        XCTAssertEqual(chat.messages.last?.text, "All 30 lines read.")
        XCTAssertNil(chat.error)
    }

    func testStopHereEndsTheReplyWithoutRunningMoreTools() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path, generator: Scripted((0..<30).map(readLine)))
        chat.send("Read thirty lines", attachments: [notesAttachment()], model: LocalModel.catalog[0], path: path)
        let asked = try await run(chat, answer: false)
        XCTAssertEqual(asked, 1)
        let tools = chat.messages.filter { $0.role == "tool" }
        XCTAssertEqual(tools.filter { $0.note != "Stopped" }.count, ChatMode.work.toolCheckIn, "Exactly 25 calls ran")
        XCTAssertTrue(tools.last?.text.contains("the user stopped here after 25 tool calls") == true)
        XCTAssertNotNil(chat.error)
    }
}
