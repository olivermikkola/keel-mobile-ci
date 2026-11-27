import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShellToolTests: XCTestCase {
    private func reply(_ stdout: String, _ stderr: String = "", exit: Int = 0, problems: [String] = []) -> ScriptOutcome {
        let object: [String: Any] = ["stdout": stdout, "stderr": stderr, "exitCode": exit, "problems": problems]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return .finished(value: String(decoding: data, as: UTF8.self))
    }

    func testTheCommandIsCheckedAndUnwrapped() throws {
        XCTAssertEqual(try ShellTool.command(["command": "ls -la"]), "ls -la")
        // Some small models wrap the argument in JSON.
        XCTAssertEqual(try ShellTool.command(["command": #"{"command": "grep -rn TODO ."}"#]), "grep -rn TODO .")
        XCTAssertThrowsError(try ShellTool.command(["cmd": "ls"]))
        XCTAssertThrowsError(try ShellTool.command(["command": "  \n"]))
        XCTAssertThrowsError(try ShellTool.command(["command": "ls\u{0}"]))
        XCTAssertThrowsError(try ShellTool.command(["command": String(repeating: "a", count: ShellTool.maxCommandBytes + 1)]))
    }

    /// The command reaches JavaScript as one string literal, whatever quotes,
    /// backslashes or line breaks it holds.
    func testInvocationKeepsTheCommandAsOneStringLiteral() throws {
        let command = #"echo "a\"b" 'c' $(x) `y` </script>  "# + "\nline2"
        let code = ShellTool.invocation(command)
        XCTAssertTrue(code.hasPrefix("return await globalThis.__keelShell(\""))
        XCTAssertTrue(code.hasSuffix("\");"))
        let literal = String(code.dropFirst("return await globalThis.__keelShell(".count).dropLast(2))
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String
        XCTAssertEqual(decoded, command)
    }

    func testOutputReadsLikeATerminal() {
        XCTAssertEqual(ShellTool.format(reply("a.txt\nb.txt\n"), changedFiles: []), "a.txt\nb.txt")
        XCTAssertEqual(ShellTool.format(reply(""), changedFiles: []), "(no output)")
        XCTAssertEqual(ShellTool.format(reply("", "cat: x: No such file or directory\n", exit: 1), changedFiles: []),
                       "stderr:\ncat: x: No such file or directory\nexit code 1")
        XCTAssertEqual(ShellTool.format(reply("done\n"), changedFiles: ["notes.md", "src/app.js"]),
                       "done\nSaved for review: notes.md, src/app.js")
        XCTAssertEqual(ShellTool.format(reply("", problems: ["big.txt: over budget"]), changedFiles: []),
                       "Not saved:\nbig.txt: over budget")
    }

    func testLongOutputIsCutWithAHint() {
        let text = ShellTool.format(reply(String(repeating: "x", count: ShellTool.maxStdoutBytes + 500)), changedFiles: [])
        XCTAssertTrue(text.hasSuffix("[output cut: 500 more bytes. Use head, tail or grep to see less at once.]"), text)
        // Cutting never splits a character.
        let emoji = ShellTool.clip(String(repeating: "é", count: 10), to: 5)
        XCTAssertTrue(emoji.hasPrefix("éé\n"), emoji)
    }

    func testFailuresSayNothingChanged() {
        XCTAssertTrue(ShellTool.format(.timedOut(seconds: 10), changedFiles: ["a"]).contains("Nothing was changed"))
        XCTAssertEqual(ShellTool.format(.failed(message: "boom"), changedFiles: []), "shell error: boom\nNothing was changed.")
        XCTAssertTrue(ShellTool.format(.finished(value: "not json"), changedFiles: []).hasPrefix("shell error"))
    }

    func testRegistryKnowsTheShellAndItsAliases() {
        XCTAssertTrue(ToolRegistry.isAllowedToolName("shell"))
        XCTAssertEqual(ToolRegistry.safety(for: "shell"), .localProposal)
        XCTAssertEqual(ToolRegistry.category(for: "shell"), .compute)
        for alias in ["bash", "sh", "terminal", "run_command", "exec"] {
            XCTAssertEqual(ToolRegistry.commonAliases[alias], "shell", alias)
        }
        let call = DirectorCall(name: "shell", arguments: ["command": "grep -rn TODO .\necho done"])
        XCTAssertEqual(call.label, "Shell · grep -rn TODO .")
    }

    /// The shell reads the chat's own files: private data, not outside text.
    func testShellResultsArePrivateData() {
        XCTAssertEqual(TurnTaint.effect(ofTool: "shell"), TurnTaint(privateOrigins: [TurnTaint.phone]))
    }

    /// Chat mode never changes files, so it has no shell.
    func testOnlyWorkChatsOfferTheShell() {
        let names = { (lines: [String]) in Set(lines.map(AgentPrompt.toolName)) }
        XCTAssertTrue(names(AgentPrompt.localCatalog(mode: .work)).contains("shell"))
        XCTAssertFalse(names(AgentPrompt.localCatalog(mode: .chat)).contains("shell"))
        XCTAssertTrue(names(AgentPrompt.localCatalog(mode: .chat)).contains("list_files"))
        for app in AppPreset.allCases {
            XCTAssertFalse(names(AgentPrompt.localCatalog(app: app)).contains("shell"), app.title)
        }
    }
}
