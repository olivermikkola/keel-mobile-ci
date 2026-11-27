import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class SharedInboxTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testASavedShareIsPendingUntilOpenedAndKeepsItsFiles() throws {
        let item = SharedItem(action: .video, text: "Ruben at the beach", photos: ["photo-1.jpg", "photo-2.jpg"])
        let folder = try SharedInbox.prepare(item.id, in: root)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("photo-1.jpg"))
        XCTAssertTrue(SharedInbox.pending(in: root).isEmpty, "not offered before its manifest is written")
        try SharedInbox.save(item, in: root)
        XCTAssertEqual(SharedInbox.pending(in: root).map(\.id), [item.id])
        XCTAssertEqual(SharedInbox.load(item.id, in: root), item)
        SharedInbox.markOpened(item.id, in: root)
        XCTAssertTrue(SharedInbox.pending(in: root).isEmpty)
        XCTAssertNil(SharedInbox.load(item.id, in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("photo-1.jpg").path))
    }

    func testOldSharesAreRemovedAndOrderIsOldestFirst() throws {
        let now = Date()
        let old = SharedItem(action: .chat, text: "old", createdAt: now.addingTimeInterval(-SharedInbox.keepFor - 60))
        let first = SharedItem(action: .chat, text: "first", createdAt: now.addingTimeInterval(-120))
        let second = SharedItem(action: .chat, text: "second", createdAt: now.addingTimeInterval(-60))
        for item in [second, old, first] { try SharedInbox.save(item, in: root) }
        XCTAssertEqual(SharedInbox.pending(in: root, now: now).map(\.text), ["first", "second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedInbox.folder(old.id, in: root).path))
    }

    func testThePromptReadsALinkOrKeepsTheText() {
        XCTAssertEqual(SharedItem(action: .chat, url: "https://example.com/a").prompt, "Read and summarize https://example.com/a")
        XCTAssertEqual(SharedItem(action: .chat, text: " Plan my week ").prompt, "Plan my week")
        XCTAssertEqual(SharedItem(action: .chat, text: "Look at this", url: "https://example.com").prompt, "Look at this\n\nhttps://example.com")
        XCTAssertEqual(SharedItem(action: .chat, text: "See https://example.com", url: "https://example.com").prompt, "See https://example.com")
        XCTAssertNil(SharedItem(action: .chat, files: ["notes.pdf"]).prompt)
    }

    func testTheLinkOpensTheShare() {
        let id = UUID()
        XCTAssertEqual(IncomingLink.parse(SharedInbox.link(id)), .shared(id))
        XCTAssertNil(IncomingLink.parse(URL(string: "keelmobile://share?id=nope")!))
    }
}
