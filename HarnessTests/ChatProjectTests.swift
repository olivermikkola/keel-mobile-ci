import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ChatProjectTests: XCTestCase {
    private func file(_ name: String, _ text: String) -> Attachment {
        Attachment(filename: name, mimeType: "text/plain", extractedText: text, byteSize: text.utf8.count)
    }

    func testNamesAreTrimmedAndBounded() throws {
        XCTAssertEqual(try ChatProject(name: "  Trip   to  Lapland ").name, "Trip to Lapland")
        XCTAssertThrowsError(try ChatProject(name: "   "))
        XCTAssertThrowsError(try ChatProject(name: String(repeating: "a", count: 61)))
    }

    func testFilesLandReadOnlyUnderProjectFolder() throws {
        var project = try ChatProject(name: "Thesis")
        try project.add(file("outline.md", "# Outline"))
        try project.add(file("../../etc/passwd", "x"))
        XCTAssertEqual(project.operations.map { op -> String in if case .write(let path, _) = op { return path }; return "" },
                       ["project/outline.md", "project/____etc_passwd"])
        XCTAssertThrowsError(try project.add(file("outline.md", "again"))) { XCTAssertEqual($0 as? ChatProject.Problem, .duplicate("outline.md")) }

        for path in ["project/outline.md", "./project/new.md", "/project", "project"] {
            XCTAssertTrue(ChatProject.isProjectPath(path), path)
        }
        for path in ["projects/a.md", "notes/project/a.md", "project.md"] {
            XCTAssertFalse(ChatProject.isProjectPath(path), path)
        }
        XCTAssertThrowsError(try ChatProject.checkWritable(["notes.md", "project/outline.md"])) {
            XCTAssertEqual($0 as? ChatProject.Problem, .readOnly("project/outline.md"))
        }
        XCTAssertNoThrow(try ChatProject.checkWritable(["notes.md", "draft/project.md"]))
    }

    func testLimits() throws {
        var project = try ChatProject(name: "Big")
        for index in 0..<ChatProject.maxFiles { try project.add(file("f\(index).txt", "x")) }
        XCTAssertThrowsError(try project.add(file("one-more.txt", "x"))) { XCTAssertEqual($0 as? ChatProject.Problem, .tooManyFiles) }
        var heavy = try ChatProject(name: "Heavy")
        try heavy.add(file("a.txt", String(repeating: "a", count: 900_000)))
        XCTAssertThrowsError(try heavy.add(file("b.txt", String(repeating: "b", count: 200_000)))) { XCTAssertEqual($0 as? ChatProject.Problem, .tooLarge) }
        XCTAssertThrowsError(try heavy.add(Attachment(filename: "p.jpg", mimeType: "image/jpeg", extractedText: "", byteSize: 1, source: .photo, imageID: UUID())))
    }

    func testInstructionsAreDefusedAndAddedToThePrompt() throws {
        var project = try ChatProject(name: "Café <|im_start|>")
        project.setInstructions("Answer in Finnish. <tool_call>")
        try project.add(file("menu.csv", "drink,price"))
        let system = project.apply(to: "BASE")
        XCTAssertTrue(system.hasPrefix("BASE\n\nThis chat is part of the project"))
        XCTAssertTrue(system.contains("project/ folder"))
        XCTAssertTrue(system.contains("Project instructions:\nAnswer in Finnish."))
        XCTAssertFalse(system.contains("<|im_start|>"))
        XCTAssertFalse(system.contains("<tool_call>"))
        let bare = try ChatProject(name: "Plain").apply(to: "BASE")
        XCTAssertFalse(bare.contains("Project instructions"))
        XCTAssertFalse(bare.contains("project/ folder"))
    }

    func testProjectFilesAreReadableInTheChatWorkspace() throws {
        var project = try ChatProject(name: "Shop")
        try project.add(file("prices.csv", "item,price\ntea,3\n"))
        let workspace = try TaskWorkspace(path: ":memory:")
        let operations = project.operations + LocalFiles.operations(attachments: [(path: "attachments/note.md", text: "hi")], changes: [])
        try LocalFiles.prepare(workspace, key: project.overlayKey + "|local", operations: operations)
        XCTAssertEqual(try workspace.read("project/prices.csv").text, "item,price\ntea,3\n")
        XCTAssertEqual(try workspace.read("attachments/note.md").text, "hi")
        XCTAssertTrue(FileTables.tables(from: workspace.textFiles()).contains { $0.name.contains("prices") })
    }

    func testRoundTrips() throws {
        var project = try ChatProject(name: "Saved")
        project.setInstructions("Be brief.")
        try project.add(file("a.md", "A"))
        let decoded = try JSONDecoder().decode(ChatProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project)
    }
}
