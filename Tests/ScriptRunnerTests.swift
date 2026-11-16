import XCTest
@testable import KeelMobile

@MainActor
final class ScriptRunnerTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)

    private func workspace(_ files: [String: String]) throws -> TaskWorkspace {
        let ws = try TaskWorkspace(path: ":memory:")
        let entries = files.map {
            TaskWorkspace.TreeEntry(path: $0.key, mode: "100644", type: "blob", sha: GitBlob.sha($0.value), size: $0.value.utf8.count)
        }
        try ws.setBase(TaskWorkspace.Identity(repository: "owner/fixture", commit: commit, tree: tree), entries: entries)
        for (path, text) in files {
            try ws.store(path: path, data: Data(text.utf8))
        }
        return ws
    }

    func testExecutesWorkspaceReadsLogsWritesAndRestoresWorkspaceOverlay() async throws {
        let ws = try workspace(["README.md": "hello\nworld\n", "Sources/App.swift": "let v = 1\n"])
        try ws.setOverlay(key: "approved-1", operations: [.write(path: "Sources/App.swift", text: "let v = 2\n")])

        let code = """
        const files = await keel.listFiles("Sources/");
        const content = await keel.readFile("README.md");
        await keel.writeFile("Sources/App.swift", "let v = 99\\n");
        await keel.writeFile("Sources/New.swift", "struct New {}\\n");
        console.log("lines", content.trim().split("\\n").length);
        return { files: files, ok: true };
        """
        let execution = try await ScriptRunner.run(
            code: code,
            workspace: ws,
            allowWrites: true,
            approvedKey: "approved-1",
            approvedOperations: [.write(path: "Sources/App.swift", text: "let v = 2\n")]
        )
        XCTAssertEqual(execution.outcome, .finished(value: #"{"files":["Sources/App.swift"],"ok":true}"#))
        XCTAssertEqual(execution.output, "lines 2\n")
        XCTAssertEqual(execution.readPaths, ["README.md"])
        XCTAssertEqual(execution.changedFiles, ["Sources/App.swift", "Sources/New.swift"])
        XCTAssertEqual(execution.netChanges.count, 2)
        XCTAssertEqual(execution.netChanges[0].after, "let v = 99\n")
        XCTAssertEqual(execution.netChanges[1].after, "struct New {}\n")

        // Workspace remains strictly at user-approved overlay until explicit UI review applies changes.
        XCTAssertEqual(ws.overlayKey, "approved-1")
        XCTAssertEqual(try ws.read("Sources/App.swift").text, "let v = 2\n")
        XCTAssertThrowsError(try ws.read("Sources/New.swift"))

        // Script without return yields nil value cleanly.
        let noReturn = try await ScriptRunner.run(
            code: "console.log('just log');",
            workspace: ws,
            allowWrites: false,
            approvedKey: "approved-1",
            approvedOperations: [.write(path: "Sources/App.swift", text: "let v = 2\n")]
        )
        XCTAssertEqual(noReturn.outcome, .finished(value: nil))
        XCTAssertEqual(noReturn.output, "just log\n")
    }

    func testBlocksNetworkAPIsAndDOMRequestsAndReportsRuntimeOrSyntaxErrors() async throws {
        let ws = try workspace(["a.txt": "1"])
        let networkProbe = """
        let blocked = [typeof fetch, typeof XMLHttpRequest, typeof WebSocket, typeof importScripts].every(t => t === "undefined");
        const img = document.createElement("img");
        img.src = "https://127.0.0.1:9/should-not-load.png";
        document.body.appendChild(img);
        return blocked;
        """
        let netResult = try await ScriptRunner.run(
            code: networkProbe,
            workspace: ws,
            allowWrites: false,
            approvedKey: "",
            approvedOperations: []
        )
        XCTAssertEqual(netResult.outcome, .finished(value: "true"))

        let errorResult = try await ScriptRunner.run(
            code: #"console.log("before"); throw new Error("boom");"#,
            workspace: ws,
            allowWrites: false,
            approvedKey: "",
            approvedOperations: []
        )
        if case .failed(let message) = errorResult.outcome {
            XCTAssertTrue(message.contains("boom"), message)
        } else {
            XCTFail("Expected .failed outcome, got \(errorResult.outcome)")
        }
        XCTAssertEqual(errorResult.output, "before\n")

        let syntaxResult = try await ScriptRunner.run(
            code: "if (",
            workspace: ws,
            allowWrites: false,
            approvedKey: "",
            approvedOperations: []
        )
        guard case .failed = syntaxResult.outcome else {
            XCTFail("Expected .failed for syntax error, got \(syntaxResult.outcome)")
            return
        }
    }

    func testInfiniteLoopTimesOutCleanlyWithoutBlocking() async throws {
        let ws = try workspace(["a.txt": "1"])
        let started = Date()
        let result = try await ScriptRunner.run(
            code: "await keel.writeFile('a.txt', 'partial'); while (true) {}",
            workspace: ws,
            allowWrites: true,
            approvedKey: "",
            approvedOperations: [],
            timeout: 0.6
        )
        XCTAssertEqual(result.outcome, .timedOut(seconds: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try ws.read("a.txt").text, "1", "Timed-out script writes must not leak into workspace")
    }
}
