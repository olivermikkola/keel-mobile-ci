import XCTest
import SwiftUI
@testable import KeelMobile

/// Shares from other apps reach the chat: a link opens a new chat with it in
/// the message box, a file is attached, and each share opens once.
@MainActor
final class SharedInboxChatTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func chat() -> LocalChat {
        let chat = LocalChat(transcript: folder.appendingPathComponent("chat").appendingPathComponent("chat.json"))
        chat.sharedInboxRoot = folder.appendingPathComponent("Share")
        return chat
    }

    func testALinkSharedFromSafariOpensOnceThroughItsLink() throws {
        let chat = chat()
        let root = try XCTUnwrap(chat.sharedInboxRoot)
        let item = SharedItem(action: .chat, url: "https://example.com/story")
        try SharedInbox.save(item, in: root)
        XCTAssertTrue(chat.receiveIncomingURL(SharedInbox.link(item.id)))
        XCTAssertEqual(chat.incomingShare, item)
        chat.incomingShare = nil
        chat.checkSharedInbox()
        XCTAssertNil(chat.incomingShare, "an opened share is not offered again")

        chat.openShareInChat(item)
        XCTAssertEqual(chat.incomingDraftPrompt, "Read and summarize https://example.com/story")
        XCTAssertNil(chat.incomingSharedFileURL)
    }

    func testAShareIOSDidNotOpenKeelForIsFoundWhenKeelComesBack() throws {
        let chat = chat()
        let root = try XCTUnwrap(chat.sharedInboxRoot)
        let older = SharedItem(action: .chat, text: "older", createdAt: Date().addingTimeInterval(-60))
        var newer = SharedItem(action: .chat, text: "What does this say?")
        let files = try SharedInbox.prepare(newer.id, in: root)
        try Data("Meeting at 10".utf8).write(to: files.appendingPathComponent("notes.txt"))
        newer.files = ["notes.txt"]
        try SharedInbox.save(older, in: root)
        try SharedInbox.save(newer, in: root)

        chat.sceneDidChange(.active)
        XCTAssertEqual(chat.incomingShare, newer)
        XCTAssertTrue(SharedInbox.pending(in: root).isEmpty, "the older one is dropped, not offered later")

        chat.openShareInChat(newer)
        XCTAssertEqual(chat.incomingDraftPrompt, "What does this say?")
        let attached = try XCTUnwrap(chat.incomingSharedFileURL)
        XCTAssertEqual(try String(contentsOf: attached, encoding: .utf8), "Meeting at 10")
    }
}
