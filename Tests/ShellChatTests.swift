import XCTest
@testable import KeelMobile

/// The shell tool with the real bundled just-bash in WebKit: a runner-level
/// check, then a scripted chat that writes a file and reads it back.
@MainActor
final class ShellChatTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)

    private func workspace(_ files: [String: String]) throws -> TaskWorkspace {
        let ws = try TaskWorkspace(path: ":memory:")
        let entries = files.map {
            TaskWorkspace.TreeEntry(path: $0.key, mode: "100644", type: "blob", sha: GitBlob.sha($0.value), size: $0.value.utf8.count)
        }
        try ws.setBase(TaskWorkspace.Identity(repository: "owner/fixture", commit: commit, tree: tree), entries: entries)
        for (path, text) in files { try ws.store(path: path, data: Data(text.utf8)) }
        return ws
    }

    private func shell(_ command: String, in ws: TaskWorkspace) async throws -> (text: String, execution: ScriptExecution) {
        let execution = try await ScriptRunner.run(
            code: ShellTool.invocation(command), workspace: ws, allowWrites: true,
            approvedKey: "", approvedOperations: [], budget: ShellTool.budget,
            timeout: ShellTool.timeout, library: try XCTUnwrap(KeelShellLibrary.source)
        )
        return (ShellTool.format(execution.outcome, changedFiles: execution.changedFiles), execution)
    }

    func testRealBashRunsOverTheTaskFilesInWebKit() async throws {
        XCTAssertGreaterThan(KeelShellLibrary.source?.utf8.count ?? 0, 500_000, "KeelShell.js ships in the app bundle")
        let ws = try workspace([
            "src/app.js": "function add(a, b) {\n  return a + b; // TODO tests\n}\n",
            "src/util.js": "// TODO: remove\nexport const x = 1;\n",
            "data.json": #"{"users":[{"age":3},{"age":5}]}"#,
        ])

        let grep = try await shell("grep -rn TODO . | sort", in: ws)
        XCTAssertEqual(grep.text, "src/app.js:2:  return a + b; // TODO tests\nsrc/util.js:1:// TODO: remove")
        XCTAssertTrue(grep.execution.changedFiles.isEmpty)

        let jq = try await shell("jq '.users | map(.age) | add' data.json", in: ws)
        XCTAssertEqual(jq.text, "8")

        let sed = try await shell("sed -i 's/a + b/Number(a) + Number(b)/' src/app.js && echo hi > /tmp/scratch", in: ws)
        XCTAssertEqual(sed.execution.changedFiles, ["src/app.js"], "/tmp is scratch")
        XCTAssertEqual(sed.execution.netChanges.first?.after, "function add(a, b) {\n  return Number(a) + Number(b); // TODO tests\n}\n")
        XCTAssertTrue(sed.text.hasSuffix("Saved for review: src/app.js"), sed.text)

        let missing = try await shell("cat nope.txt", in: ws)
        XCTAssertEqual(missing.text, "stderr:\ncat: nope.txt: No such file or directory\nexit code 1")

        let network = try await shell("curl https://example.com", in: ws)
        XCTAssertTrue(network.text.contains("command not found"), network.text)
        print("Shell proof: just-bash in WKWebView over a TaskWorkspace: grep/jq/sed -i, /tmp not kept, bash-style errors, no curl.")
    }

    func testAShellSessionWritesAFileAndTheNextCommandSeesIt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ShellScriptedModel([
            call("mkdir -p site && echo '<h1>Hi from the shell</h1>' > site/index.html"),
            call("cat site/index.html && ls site"),
            call("rm site/index.html"),
            "Made site/index.html.",
        ])
        let chat = LocalChat(transcript: path, generator: model)
        chat.send("Make a page with a shell", model: LocalModel.catalog[0], path: path)
        try await finish(chat)

        let prompts = await model.prompts
        XCTAssertTrue(prompts[0].contains(#""name":"shell""#))
        XCTAssertFalse(prompts[0].contains(#""name":"list_files""#), "shell stands in for list_files")
        let results = chat.messages.filter { $0.role == "tool" && ($0.activity ?? "").hasPrefix("Shell") }.map(\.text)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results[0].contains("Saved for review: site/index.html"), results[0])
        // The write was applied before the next command, which reads it back.
        XCTAssertTrue(results[1].hasPrefix("<h1>Hi from the shell</h1>\nindex.html"), results[1])
        // The note the model reads does not tell it to stop.
        XCTAssertFalse(chat.messages.contains { $0.role == "tool" && $0.text.contains("summarize your proposal and stop") })

        // A delete is never applied without the user.
        XCTAssertEqual(chat.fileEdits.map(\.proposal.kind.rawValue), ["create", "delete"])
        XCTAssertEqual(chat.fileEdits.map(\.decision), [.applied, .pending])
        XCTAssertEqual(chat.messages.last?.text, "Made site/index.html.")
        print("Shell chat proof: write, auto-apply before the next command, read back; delete stays pending.")
    }

    private func call(_ command: String) -> String {
        "<tool_call>\n<function=shell>\n<parameter=command>\n\(command)\n</parameter>\n</function>\n</tool_call>"
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<3000 {
            if !chat.running { XCTAssertNil(chat.error); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Chat did not stop")
    }
}

private actor ShellScriptedModel: LocalGenerating {
    private var outputs: [String]
    private(set) var prompts = [String]()
    init(_ outputs: [String]) { self.outputs = outputs }
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try Task.checkCancellation()
        prompts.append(prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }
}
