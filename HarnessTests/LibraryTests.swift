import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class LibraryTests: XCTestCase {
    private let older = UUID(), newer = UUID()

    private var chats: [Library.Chat] {
        [Library.Chat(taskID: older, title: "Café site", updatedAt: Date(timeIntervalSince1970: 100), operations: [
            .write(path: "index.html", text: "<html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body>Nordic Bean</body></html>"),
            .write(path: "style.css", text: "body{color:red}"),
            .write(path: "draft.md", text: "# Draft"),
            .delete(path: "draft.md"),
        ]),
         Library.Chat(taskID: newer, title: "Budget", updatedAt: Date(timeIntervalSince1970: 200), operations: [
            .write(path: "budget.csv", text: "item,amount\nrent,800\n"),
            .write(path: "notes.md", text: "# Notes v1"),
            .write(path: "notes.md", text: "# Notes v2"),
         ]),
         Library.Chat(taskID: UUID(), title: "Just talk", updatedAt: Date(timeIntervalSince1970: 300), operations: [])]
    }

    func testListsTheFinalFilesNewestChatFirst() {
        let items = Library.items(chats)
        XCTAssertEqual(items.map(\.path), ["budget.csv", "notes.md", "index.html", "style.css"])
        XCTAssertEqual(items.first { $0.path == "notes.md" }?.text, "# Notes v2", "Later changes win")
        XCTAssertFalse(items.contains { $0.path == "draft.md" }, "Deleted files are gone")
        XCTAssertEqual(items.first?.chatTitle, "Budget")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testFiltersAndSearch() {
        let items = Library.items(chats)
        XCTAssertEqual(Library.filter(items, .pages).map(\.path), ["index.html"])
        XCTAssertEqual(Library.filter(items, .tables).map(\.path), ["budget.csv"])
        XCTAssertEqual(Library.filter(items, .documents).map(\.path), ["notes.md"])
        XCTAssertEqual(Library.filter(items, .all, query: "café").count, 2, "Search matches the chat title")
        XCTAssertEqual(Library.filter(items, .all, query: "BUDGET.CSV").map(\.path), ["budget.csv"])
        XCTAssertTrue(Library.filter(items, .cards).isEmpty)
    }

    func testAPageOpensWithItsOwnChatsStylesheet() throws {
        let items = Library.items(chats)
        let page = try XCTUnwrap(items.first { $0.path == "index.html" })
        let document = try XCTUnwrap(Library.document(for: page, in: items))
        XCTAssertTrue(document.contains("body{color:red}"))
        XCTAssertTrue(document.contains("Content-Security-Policy"))
        XCTAssertNil(Library.document(for: try XCTUnwrap(items.first { $0.path == "style.css" }), in: items), "No viewer for CSS")
    }
}
