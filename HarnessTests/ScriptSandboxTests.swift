import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ScriptSandboxTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)

    /// A workspace whose base holds `files`, each one stored and verified.
    private func workspace(_ files: [String: String], limits: TaskWorkspace.Limits = TaskWorkspace.Limits()) throws -> TaskWorkspace {
        let workspace = try TaskWorkspace(path: ":memory:", limits: limits)
        let entries = files.map {
            TaskWorkspace.TreeEntry(path: $0.key, mode: "100644", type: "blob", sha: GitBlob.sha($0.value), size: $0.value.utf8.count)
        }
        try workspace.setBase(TaskWorkspace.Identity(repository: "owner/fixture", commit: commit, tree: tree), entries: entries)
        for (path, text) in files {
            try workspace.store(path: path, data: Data(text.utf8))
        }
        return workspace
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Calls one host function with JSON arguments and decodes the reply envelope.
    private func call(_ host: ScriptHost, _ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = host.handle(name: name, argumentsJSON: try json(arguments))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], reply)
    }

    private func error(_ reply: [String: Any]) -> String? {
        reply["error"] as? String
    }

    // MARK: - Host functions

    func testWriteThenReadAndListSeeTheChangeAsLocal() throws {
        let workspace = try workspace(["README.md": "base\n"])
        let host = ScriptHost(workspace: workspace)

        XCTAssertNil(error(try call(host, "writeFile", ["path": "Sources/App.swift", "text": "let x = 1\n"])))
        XCTAssertEqual(try call(host, "readFile", ["path": "Sources/App.swift"])["result"] as? String, "let x = 1\n")
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "Sources/"])["result"] as? [String], ["Sources/App.swift"])
        XCTAssertEqual(try call(host, "listFiles")["result"] as? [String], ["README.md", "Sources/App.swift"])

        // The workspace itself reports the change as task-local.
        let file = try workspace.read("Sources/App.swift")
        XCTAssertTrue(file.isLocal)
        XCTAssertEqual(host.changedFiles, ["Sources/App.swift"])
    }

    func testDeleteRemovesABaseFileFromTheTaskAndDeletingAMissingFileIsAnError() throws {
        let workspace = try workspace(["README.md": "base\n", "Old.swift": "old\n"])
        let host = ScriptHost(workspace: workspace)

        XCTAssertNil(error(try call(host, "deleteFile", ["path": "Old.swift"])))
        XCTAssertEqual(try call(host, "listFiles")["result"] as? [String], ["README.md"])
        XCTAssertEqual(host.changedFiles, ["Old.swift"])
        XCTAssertNotNil(error(try call(host, "readFile", ["path": "Old.swift"])))
        XCTAssertNotNil(error(try call(host, "deleteFile", ["path": "Old.swift"])))
        XCTAssertNotNil(error(try call(host, "deleteFile", ["path": "Nope.swift"])))
    }

    func testListFilesFollowsPrefixesAcrossFolders() throws {
        let workspace = try workspace(["Sources/A.swift": "a", "Sources/Models/B.swift": "b", "Tests/C.swift": "c", "Sourcery.txt": "d"])
        let host = ScriptHost(workspace: workspace)

        // "Sourcery.txt" is not under "Sources", and a prefix is bytes, not a folder name.
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "Sources"])["result"] as? [String],
                       ["Sources/A.swift", "Sources/Models/B.swift"])
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "Sourc"])["result"] as? [String],
                       ["Sourcery.txt", "Sources/A.swift", "Sources/Models/B.swift"])
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "Sources/Mo"])["result"] as? [String], ["Sources/Models/B.swift"])
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "Nowhere/"])["result"] as? [String], [])
    }

    func testPrintIsCapturedWithANewlinePerCall() throws {
        let host = ScriptHost(workspace: try workspace([:]))
        XCTAssertNil(error(try call(host, "print", ["text": "first"])))
        XCTAssertNil(error(try call(host, "print", ["text": "second"])))
        XCTAssertEqual(host.output, "first\nsecond\n")
        XCTAssertFalse(host.outputTruncated)
    }

    // MARK: - Path jail

    func testEveryUnsafePathIsRefusedBeforeTheWorkspaceIsTouched() throws {
        let workspace = try workspace(["README.md": "base\n"])
        let host = ScriptHost(workspace: workspace)
        let bad = [
            "", "/etc/passwd", "/chat.json", "../x", "a/../b", "..", "a/..", "a//b", "./a", "a/./b", ".", "a/",
            "a\u{0}b", "a\nb", "a\u{7f}b", "x\u{1}y",
            String(repeating: "a", count: 1025),
            (0..<17).map { _ in "d" }.joined(separator: "/"),
        ]
        for path in bad {
            XCTAssertNotNil(error(try call(host, "readFile", ["path": path])), "readFile \(path.debugDescription)")
            XCTAssertNotNil(error(try call(host, "writeFile", ["path": path, "text": "x"])), "writeFile \(path.debugDescription)")
            XCTAssertNotNil(error(try call(host, "deleteFile", ["path": path])), "deleteFile \(path.debugDescription)")
        }
        XCTAssertNotNil(error(try call(host, "listFiles", ["prefix": "/"])))
        XCTAssertNotNil(error(try call(host, "listFiles", ["prefix": "a/../b"])))
        XCTAssertTrue(host.changedFiles.isEmpty)
        XCTAssertEqual(try workspace.list(""), [TaskWorkspace.Child(name: "README.md", kind: .file)])
    }

    func testAppStorageNamesAreNotReachable() throws {
        // The task's workspace has no such files, so the name is simply missing.
        let host = ScriptHost(workspace: try workspace(["README.md": "base\n"]))
        for name in ["chat.json", "Models/model.gguf", "../Keychain/token"] {
            XCTAssertNotNil(error(try call(host, "readFile", ["path": name])), name)
        }
    }

    func testAPathThatIsBothAFileAndAFolderIsRefusedOnWrite() throws {
        let host = ScriptHost(workspace: try workspace(["Sources/A.swift": "a"]))
        XCTAssertNotNil(error(try call(host, "writeFile", ["path": "Sources", "text": "x"])))
        XCTAssertNotNil(error(try call(host, "writeFile", ["path": "Sources/A.swift/inner", "text": "x"])))
        XCTAssertTrue(host.changedFiles.isEmpty)
    }

    // MARK: - Budgets

    func testHostCallBudgetStopsTheRunButNeverCrashes() throws {
        var budget = ScriptBudget()
        budget.maxHostCalls = 2
        let host = ScriptHost(workspace: try workspace([:]), budget: budget)
        XCTAssertNil(error(try call(host, "print", ["text": "one"])))
        XCTAssertNil(error(try call(host, "print", ["text": "two"])))
        XCTAssertTrue(error(try call(host, "print", ["text": "three"]))?.contains("Host call limit") == true)
        XCTAssertEqual(host.output, "one\ntwo\n")
    }

    func testReadBudgetCountsReturnedBytes() throws {
        var budget = ScriptBudget()
        budget.maxBytesRead = 10
        let host = ScriptHost(workspace: try workspace(["a.txt": "12345", "b.txt": "123456", "c.txt": "x"]), budget: budget)
        XCTAssertEqual(try call(host, "readFile", ["path": "a.txt"])["result"] as? String, "12345")
        XCTAssertNotNil(error(try call(host, "readFile", ["path": "b.txt"])))
        XCTAssertEqual(try call(host, "readFile", ["path": "c.txt"])["result"] as? String, "x")
        XCTAssertEqual(host.bytesRead, 6)
    }

    func testWriteBudgetIsCheckedPerFileAndInTotal() throws {
        var budget = ScriptBudget()
        budget.maxBytesWrittenPerFile = 5
        budget.maxBytesWritten = 8
        let host = ScriptHost(workspace: try workspace([:]), budget: budget)

        XCTAssertNil(error(try call(host, "writeFile", ["path": "a.txt", "text": "abc"])))
        // Cumulative per path: 3 + 3 is over the per-file limit of 5.
        XCTAssertNotNil(error(try call(host, "writeFile", ["path": "a.txt", "text": "def"])))
        XCTAssertNil(error(try call(host, "writeFile", ["path": "b.txt", "text": "abcde"])))
        // Total is now 8, so one more byte anywhere is over the run budget.
        XCTAssertNotNil(error(try call(host, "writeFile", ["path": "c.txt", "text": "x"])))
        XCTAssertEqual(host.bytesWritten, 8)
        XCTAssertEqual(host.changedFiles, ["a.txt", "b.txt"])
        XCTAssertNotNil(error(try call(host, "readFile", ["path": "c.txt"])))
    }

    func testPrintOutputIsCutWithANoteAndKeepsWholeCharacters() throws {
        var budget = ScriptBudget()
        budget.maxPrintBytes = 10
        let host = ScriptHost(workspace: try workspace([:]), budget: budget)
        XCTAssertNil(error(try call(host, "print", ["text": "héllo wörld and more"])))
        XCTAssertNil(error(try call(host, "print", ["text": "ignored"])))
        XCTAssertTrue(host.outputTruncated)
        XCTAssertTrue(host.output.hasPrefix("héllo"))
        XCTAssertTrue(host.output.contains("[output truncated at 10 bytes]"))
        XCTAssertFalse(host.output.contains("ignored"))
        XCTAssertNotNil(host.output.data(using: .utf8))
    }

    func testListFilesRefusesAnAnswerLargerThanTheBudget() throws {
        var budget = ScriptBudget()
        budget.maxListedFiles = 2
        let host = ScriptHost(workspace: try workspace(["a": "1", "b": "2", "c": "3"]), budget: budget)
        XCTAssertNotNil(error(try call(host, "listFiles")))
        XCTAssertEqual(try call(host, "listFiles", ["prefix": "a"])["result"] as? [String], ["a"])
    }

    // MARK: - Malformed calls

    func testUnknownFunctionsAndBadArgumentsReturnErrorsNotCrashes() throws {
        let host = ScriptHost(workspace: try workspace(["a.txt": "a"]))
        XCTAssertEqual(error(try call(host, "fetch", ["url": "https://example.com"])), "Unknown host function: fetch.")
        XCTAssertNotNil(error(try call(host, "readFile")))
        XCTAssertNotNil(error(try call(host, "readFile", ["path": 3])))
        XCTAssertNotNil(error(try call(host, "writeFile", ["path": "a.txt"])))
        XCTAssertNotNil(error(try call(host, "listFiles", ["prefix": false])))

        for raw in ["", "{", "[\"a\"]", "\"text\"", "null", "{\"path\":"] {
            let reply = host.handle(name: "readFile", argumentsJSON: raw)
            XCTAssertEqual(error(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])),
                           "Arguments must be one JSON object.", raw)
        }
    }

    func testEveryReplyIsOneOfTwoEnvelopes() throws {
        let host = ScriptHost(workspace: try workspace(["a.txt": "a"]))
        let replies = [
            host.handle(name: "readFile", argumentsJSON: #"{"path":"a.txt"}"#),
            host.handle(name: "readFile", argumentsJSON: #"{"path":"missing.txt"}"#),
            host.handle(name: "nope", argumentsJSON: "{}"),
        ]
        for reply in replies {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            XCTAssertTrue((object["result"] != nil) != (object["error"] != nil), reply)
        }
    }

    // MARK: - Overlay rebuild

    func testSavedOperationsRebuildTheSameTaskAfterTheWorkspaceReloads() throws {
        let workspace = try workspace(["Keep.swift": "keep", "Gone.swift": "gone"])
        let host = ScriptHost(workspace: workspace)
        _ = try call(host, "writeFile", ["path": "New/File.swift", "text": "new"])
        _ = try call(host, "deleteFile", ["path": "Gone.swift"])

        // The task saves what the script did and rebuilds from that list.
        try workspace.setOverlay(key: "run-1", operations: host.operations)
        XCTAssertEqual(try workspace.read("New/File.swift").text, "new")
        XCTAssertThrowsError(try workspace.read("Gone.swift"))
        XCTAssertEqual(try workspace.read("Keep.swift").text, "keep")

        // A rebuild without the saved list drops the script's changes.
        try workspace.setOverlay(key: "run-2", operations: [])
        XCTAssertThrowsError(try workspace.read("New/File.swift"))
        XCTAssertEqual(try workspace.read("Gone.swift").text, "gone")
    }

    // MARK: - Formatter

    func testFormatterCoversEveryOutcome() {
        XCTAssertEqual(
            ScriptResultFormatter.format(.finished(value: "3"), output: "hi\n", changedFiles: ["a.txt", "b.txt"]),
            "Output:\nhi\nReturned: 3\nFiles changed: a.txt, b.txt")
        XCTAssertEqual(ScriptResultFormatter.format(.finished(value: nil), output: "", changedFiles: []),
                       "Script finished with no output.")
        XCTAssertEqual(ScriptResultFormatter.format(.failed(message: "boom"), output: "before\n", changedFiles: []),
                       "Output:\nbefore\nscript error: boom")
        XCTAssertEqual(ScriptResultFormatter.format(.timedOut(seconds: 5), output: "", changedFiles: ["x.swift"]),
                       "timed out after 5 s\nFiles changed: x.swift")
    }

    func testFormatterClipsLongValuesAndLongFileLists() {
        let long = String(repeating: "é", count: 2_000)
        let value = ScriptResultFormatter.format(.finished(value: long), output: "", changedFiles: [])
        XCTAssertTrue(value.hasSuffix("[value truncated]"))
        XCTAssertLessThanOrEqual(value.utf8.count, ScriptResultFormatter.maxValueBytes + 40)

        let files = (1...25).map { "f\($0).txt" }
        let line = ScriptResultFormatter.format(.finished(value: nil), output: "", changedFiles: files)
        XCTAssertTrue(line.hasSuffix("f20.txt and 5 more"))
        XCTAssertFalse(line.contains("f21.txt"))
    }

    // MARK: - Prelude

#if os(macOS) || os(Linux)
    func testPreludeIsPlausibleJavaScriptUnderNodeWithAStubBridge() throws {
        let stub = """
        globalThis.__calls = [];
        globalThis.__keelHost = (name, args) => {
          __calls.push([name, JSON.parse(args)]);
          return JSON.stringify({ result: name === "readFile" ? "hello" : null });
        };
        """
        let check = """
        const value = keel.readFile("a.txt");
        keel.writeFile("b.txt", "x");
        keel.listFiles();
        keel.deleteFile("c.txt");
        console.log("hi", { n: 1 });
        process.stdout.write(JSON.stringify({
          value: value,
          names: __calls.map((call) => call[0]),
          print: __calls[__calls.length - 1][1].text,
          fetch: typeof fetch, xhr: typeof XMLHttpRequest, ws: typeof WebSocket, imports: typeof importScripts
        }));
        """
        let program = [stub, ScriptPrelude.source(), check].joined(separator: "\n")
        let run = try runNode(program)
        // `env` exits 127 when node is not on the PATH: skip, do not fail.
        if run.status == 127 { throw XCTSkip("node is not installed") }
        XCTAssertEqual(run.status, 0, run.stderr)
        let output = run.stdout

        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], output)
        XCTAssertEqual(result["value"] as? String, "hello")
        XCTAssertEqual(result["names"] as? [String], ["readFile", "writeFile", "listFiles", "deleteFile", "print"])
        XCTAssertEqual(result["print"] as? String, "hi {\"n\":1}")
        XCTAssertEqual(result["fetch"] as? String, "undefined")
        XCTAssertEqual(result["xhr"] as? String, "undefined")
        XCTAssertEqual(result["ws"] as? String, "undefined")
        XCTAssertEqual(result["imports"] as? String, "undefined")
    }

    /// Runs `node -e program` through `env`, returning its exit status and output.
    private func runNode(_ program: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", program]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
#endif
}
