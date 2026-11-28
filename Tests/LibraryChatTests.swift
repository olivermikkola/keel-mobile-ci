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

    func testVideoGalleryDiscardUnusedProtectsSavedMusicAndDraftUsesReadableVoiceLabel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-gallery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gallery = VideoGallery(directory: dir)
        let songSource = dir.appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: songSource)

        let keptMusic = try gallery.addMusic(from: songSource)
        let unusedMusic = try gallery.addMusic(from: songSource)

        try ShortVideoStore.prepareDirectory()
        let videoName = ShortVideoStore.newName()
        let videoURL = ShortVideoStore.url(videoName)
        let manifestURL = ShortVideoStore.manifestURL(videoName)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: manifestURL)
        }
        try Data("mp4".utf8).write(to: videoURL)
        let arguments = VideoScript.arguments(lines: [VideoScript.Line(narration: "Hello")], photoNames: ["p1.jpg"],
                                              voice: "apple:com.apple.voice.enhanced.en-US.Samantha", title: "Demo")
        let plan = ShortVideoRequest.plan(arguments)
        try ShortVideoStore.save(ShortVideoManifest(plan: plan), for: videoName)

        let saved = StudioVideo(video: videoName, photos: ["p1.jpg"], description: "Demo video",
                                lines: [VideoScript.Line(narration: "Hello")],
                                voice: "apple:com.apple.voice.enhanced.en-US.Samantha",
                                createdAt: Date(), music: keptMusic)
        gallery.add(saved)

        gallery.discardUnused(unusedMusic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gallery.photoURL(unusedMusic).path))
        gallery.discardUnused(keptMusic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gallery.photoURL(keptMusic).path))

        let draft = try XCTUnwrap(gallery.draft(saved))
        XCTAssertEqual(draft.voiceLabel, "Apple · Samantha")
        XCTAssertFalse(draft.voiceLabel.contains("Kokoro"))
        gallery.delete(saved)
    }
}
