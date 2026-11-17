import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class AppleToolPlanTests: XCTestCase {
    private func plan() throws -> AppleToolPlan {
        try XCTUnwrap(AppleToolPlan.make(prompt: AgentPrompt.chatML(system: AgentPrompt.local(), messages: [("user", "Hi")])))
    }

    func testEveryOfferedToolBecomesAChoiceWithItsArguments() throws {
        let plan = try plan()
        let expected = AgentPrompt.toolLines(for: .local).compactMap(ToolSchema.init).map(\.name)
        XCTAssertEqual(plan.tools.map(\.name), expected)
        let read = try XCTUnwrap(plan.tools.first { $0.name == "read_file" })
        XCTAssertEqual(read.parameters.first, .init(name: "path", isInteger: false, required: true))
        XCTAssertTrue(read.description.hasPrefix("Read lines of one text file"), read.description)
        XCTAssertTrue(read.parameters.contains(.init(name: "start_line", isInteger: true, required: false)))
        XCTAssertNil(AppleToolPlan.make(prompt: "no tools here"))
    }

    /// The model filled in read_file: Keel's own call text, accepted by the strict parser.
    func testAChosenToolBecomesKeelsCallText() throws {
        let plan = try plan()
        let text = try XCTUnwrap(plan.callText(choice: "read_file", arguments: ["path": "index.html", "start_line": "1", "stray": "x"]))
        let call = try XCTUnwrap(try DirectorCall.parse(text))
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.arguments, ["path": "index.html", "start_line": "1"], "Only the tool's own parameters")
        let code = try XCTUnwrap(plan.callText(choice: "run_js", arguments: ["code": "console.log(1 < 2 && true)"]))
        XCTAssertEqual(try DirectorCall.parse(code)?.arguments["code"], "console.log(1 < 2 && true)")
    }

    func testAnswersUnknownToolsAndMissingArgumentsAreNotCalls() throws {
        let plan = try plan()
        XCTAssertNil(plan.callText(choice: "answer", arguments: ["text": "Hello"]))
        XCTAssertNil(plan.callText(choice: "run_shell", arguments: ["command": "ls"]))
        XCTAssertNil(plan.callText(choice: "read_file", arguments: [:]), "path is required")
    }

    /// Apple's framework lists the registered tools; the JSON list and XML format only cost its 4K context.
    func testTheToolBlockIsReplacedByShortInstructions() {
        let system = AgentPrompt.local()
        let swapped = AppleToolPlan.instructions(from: system)
        XCTAssertFalse(swapped.contains(AgentPrompt.callFormat))
        XCTAssertFalse(swapped.contains("<tools>"))
        XCTAssertTrue(swapped.contains("Never say you created, changed, moved or read anything"))
        XCTAssertTrue(swapped.contains("You are Keel"), "The rest of the system prompt stays")
        XCTAssertLessThan(swapped.utf8.count, system.utf8.count / 2)
    }
}
