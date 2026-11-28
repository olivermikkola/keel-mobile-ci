import XCTest
#if canImport(KeelHarness)
import KeelHarness
#endif
@testable import KeelMobile

private struct StubProjectOCR: TextRecognizer {
    let text: String
    func recognizeText(from imageData: Data, options: TextRecognitionOptions) async throws -> String {
        text
    }
}

@MainActor
final class ProjectChatTests: XCTestCase {
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
            .appendingPathComponent("keel-project-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private func wait(_ chat: LocalChat) async throws {
        for _ in 0..<300 {
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Chat did not finish")
    }

    private func call(_ name: String, _ arguments: [(String, String)]) -> String {
        "<tool_call>\n<function=\(name)>\n" + arguments.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined() + "</function>\n</tool_call>"
    }

    func testChatsInAProjectShareInstructionsAndReadOnlyFiles() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted([
            call("read_file", [("path", "project/prices.csv")]),
            call("create_file", [("path", "project/new.md"), ("new_text", "x")]),
            "Tea costs 3."
        ])
        let chat = LocalChat(transcript: path, generator: model)
        let project = try XCTUnwrap(chat.createProject(name: "Café"))
        XCTAssertEqual(chat.activeProject?.id, project.id, "Creating a project opens a chat in it")
        let prices = Attachment(filename: "prices.csv", mimeType: "text/csv", extractedText: "item,price\ntea,3\n", byteSize: 17)
        XCTAssertTrue(chat.updateProject(project.id) { try $0.add(prices); $0.setInstructions("Answer in one line.") })

        chat.send("How much is tea?", model: LocalModel.catalog[0], path: path)
        try await wait(chat)

        let requests = await model.requests
        let first = try XCTUnwrap(requests.first)
        XCTAssertTrue(first.prompt.contains("part of the project \"Café\""))
        XCTAssertTrue(first.prompt.contains("Project instructions:\nAnswer in one line."))
        let tools = chat.messages.filter { $0.role == "tool" }.map(\.text)
        XCTAssertTrue(tools.first?.contains("tea,3") == true, "The project file is readable: \(tools)")
        XCTAssertTrue(tools.dropFirst().first?.contains("is a project file") == true, "Writing into project/ is refused: \(tools)")
        XCTAssertTrue(chat.messages.compactMap(\.edit).isEmpty)
        XCTAssertEqual(chat.messages.last?.text, "Tea costs 3.")

        let reopened = LocalChat(transcript: path, generator: model)
        XCTAssertEqual(reopened.projects.map(\.name), ["Café"])
        XCTAssertEqual(reopened.activeProject?.files.count, 1)
        XCTAssertEqual(reopened.chats(in: project).count, 1)

        XCTAssertTrue(reopened.newChat())
        XCTAssertNil(reopened.activeProject, "A plain new chat is not in the project")
        XCTAssertTrue(reopened.moveTask(reopened.activeTaskID, to: project))
        XCTAssertEqual(reopened.chats(in: project).count, 2)
        let before = reopened.tasks.count
        XCTAssertTrue(reopened.deleteProject(project.id))
        XCTAssertTrue(reopened.projects.isEmpty)
        XCTAssertEqual(reopened.tasks.count, before, "Deleting a project keeps its chats")
        XCTAssertTrue(reopened.tasks.allSatisfy { $0.projectID == nil })
    }

    func testProjectFileLoaderReadsPlainLocalFilesAndRecognizesImageText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-project-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noteURL = dir.appendingPathComponent("notes.md")
        try "# Budget\nTea: 3 EUR\n".write(to: noteURL, atomically: true, encoding: .utf8)
        let loaded = try await ProjectView.loadProjectFile(from: noteURL)
        XCTAssertEqual(loaded.filename, "notes.md")
        XCTAssertEqual(loaded.source, .file)
        XCTAssertTrue(loaded.extractedText.contains("Tea: 3 EUR"))

        let photoURL = dir.appendingPathComponent("receipt.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: photoURL)
        let ocrFile = try await ProjectView.loadProjectFile(from: photoURL, ocr: StubProjectOCR(text: "Receipt total\r\n12.50 EUR"))
        XCTAssertEqual(ocrFile.filename, "receipt.png")
        XCTAssertEqual(ocrFile.source, .photoOCR)
        XCTAssertEqual(ocrFile.mimeType, "text/plain")
        XCTAssertEqual(ocrFile.extractedText, "Receipt total\n12.50 EUR")
    }
}
