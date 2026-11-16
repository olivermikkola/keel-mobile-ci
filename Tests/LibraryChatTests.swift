import XCTest
@testable import KeelMobile

@MainActor
final class LibraryChatTests: XCTestCase {
    private actor Scripted: LocalGenerating {
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            onText(replies.isEmpty ? "Done." : replies.removeFirst())
            return 12
        }
    }

    private func create(_ path: String, _ text: String) -> String {
        "<tool_call>\n<function=create_file>\n<parameter=path>\n\(path)\n</parameter>\n<parameter=new_text>\n\(text)\n</parameter>\n</function>\n</tool_call>"
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<500 where chat.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(chat.running)
    }

    func testLibraryListsAppliedFilesFromEveryChat() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted([create("index.html", "<h1>Nordic Bean</h1>"), "Made the page.",
                              create("budget.csv", "item,amount\nrent,800"), create("unused.md", "# never applied"), "Made two files."])
        let chat = LocalChat(transcript: path, generator: model)
        chat.send("Make a page", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        chat.applyEdit(try XCTUnwrap(chat.fileEdits.first).id)
        try await finish(chat)
        let first = chat.activeTaskID

        XCTAssertTrue(chat.newChat())
        chat.send("Make a budget", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        chat.applyEdit(try XCTUnwrap(chat.fileEdits.first { $0.proposal.path == "budget.csv" }).id)
        try await finish(chat)

        let items = chat.libraryItems
        XCTAssertEqual(items.map(\.path), ["budget.csv", "index.html"], "Applied files only, newest chat first")
        XCTAssertEqual(items.last?.taskID, first)
        XCTAssertEqual(items.first?.kind, .table)
        XCTAssertTrue(Library.document(for: try XCTUnwrap(items.last), in: items)?.contains("Nordic Bean") == true)
        XCTAssertEqual(LocalChat(transcript: path, generator: model).libraryItems.map(\.path), ["budget.csv", "index.html"], "Survives relaunch")
    }
}
