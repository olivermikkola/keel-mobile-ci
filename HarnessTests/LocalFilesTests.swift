import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class LocalFilesTests: XCTestCase {
    private func call(_ name: String, _ parameters: [(String, String)]) throws -> DirectorCall {
        let body = parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>" }.joined(separator: "\n")
        return try XCTUnwrap(DirectorCall.parse("<tool_call>\n<function=\(name)>\n\(body)\n</function>\n</tool_call>"))
    }

    func testFilesAreAttachmentsThenAppliedChanges() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try LocalFiles.prepare(workspace, key: "a", operations: [])
        XCTAssertEqual(workspace.identity, LocalFiles.identity)
        XCTAssertFalse(workspace.directoryExists("site"))

        // An applied change to an attached file wins over the attachment.
        let operations = LocalFiles.operations(attachments: [(path: "notes.txt", text: "draft\n")],
                                               changes: [.write(path: "notes.txt", text: "final\n"),
                                                         .write(path: "site/index.html", text: "<h1>Hi</h1>\n")])
        try LocalFiles.prepare(workspace, key: "b", operations: operations)
        XCTAssertEqual(try workspace.read("notes.txt").text, "final\n")
        XCTAssertEqual(try workspace.read("site/index.html").text, "<h1>Hi</h1>\n")
        let listing = try WorkspaceTools(workspace: workspace).execute(try call("list_files", [("path", ".")]).readCall()).text
        XCTAssertTrue(listing.contains("notes.txt") && listing.contains("site"), listing)
    }

    func testReplacesARepositoryWorkspace() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(.init(repository: "owner/repo", commit: String(repeating: "a", count: 40), tree: String(repeating: "b", count: 40)),
                              entries: [.init(path: "README.md", mode: "100644", type: "blob", sha: String(repeating: "c", count: 40), size: 3)])
        try LocalFiles.prepare(workspace, key: "x", operations: [.write(path: "a.txt", text: "a\n")])
        XCTAssertEqual(workspace.identity, LocalFiles.identity)
        XCTAssertThrowsError(try workspace.read("README.md"))
        XCTAssertEqual(try workspace.read("a.txt").text, "a\n")
    }

    func testNewFileMayStartAFolderOnlyWhenAllowed() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try LocalFiles.prepare(workspace, key: "a", operations: [])
        let create = try call("create_file", [("path", "site/index.html"), ("new_text", "<h1>Hi</h1>")])
        XCTAssertThrowsError(try EditPlanner.plan(create, workspace: workspace)) {
            XCTAssertEqual($0 as? EditPlanError, .missingFolder)
        }
        let planned = try EditPlanner.plan(create, workspace: workspace, newFolders: true)
        XCTAssertEqual(planned.kind, .create)
        XCTAssertEqual(planned.after, "<h1>Hi</h1>\n")
        let scripted = try EditPlanner.planChanges([(path: "data/out.csv", after: "a,b\n")], workspace: workspace, newFolders: true)
        XCTAssertEqual(scripted.map(\.path), ["data/out.csv"])
        XCTAssertThrowsError(try EditPlanner.planChanges([(path: "data/out.csv", after: "a,b\n")], workspace: workspace))
    }

    func testStillAppliesOnlyToTheContentItWasMadeAgainst() throws {
        let workspace = try TaskWorkspace(path: ":memory:")
        try LocalFiles.prepare(workspace, key: "a", operations: [.write(path: "a.txt", text: "one\n")])
        XCTAssertTrue(LocalFiles.stillApplies(.create, path: "b.txt", destinationPath: nil, before: "", in: workspace))
        XCTAssertFalse(LocalFiles.stillApplies(.create, path: "a.txt", destinationPath: nil, before: "", in: workspace))
        XCTAssertTrue(LocalFiles.stillApplies(.replace, path: "a.txt", destinationPath: nil, before: "one\n", in: workspace))
        XCTAssertFalse(LocalFiles.stillApplies(.replace, path: "a.txt", destinationPath: nil, before: "two\n", in: workspace))
        XCTAssertFalse(LocalFiles.stillApplies(.delete, path: "gone.txt", destinationPath: nil, before: "", in: workspace))
        XCTAssertTrue(LocalFiles.stillApplies(.rename, path: "a.txt", destinationPath: "c.txt", before: "one\n", in: workspace))
        XCTAssertFalse(LocalFiles.stillApplies(.rename, path: "a.txt", destinationPath: "a.txt", before: "one\n", in: workspace))
    }

    func testLocalPromptIsStableAndSpeaksAboutTheChatsFiles() throws {
        let prompt = AgentPrompt.local()
        XCTAssertEqual(prompt, AgentPrompt.local(), "The prompt must not change between turns, or prefill is redone")
        XCTAssertFalse(prompt.contains("repository"), prompt)
        XCTAssertTrue(prompt.contains("Folders are created as needed."))
        for name in ["search_repo", "read_file", "list_files", "propose_edit", "create_file", "delete_file", "rename_file", "run_sql", "run_js"] {
            XCTAssertTrue(prompt.contains("\"name\":\"\(name)\""), name)
        }
        // Every tool line is still valid JSON after the wording changes.
        let tools = prompt.components(separatedBy: "<tools>\n")[1].components(separatedBy: "\n</tools>")[0]
        for line in tools.split(separator: "\n") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)), String(line))
        }
    }
}
