import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ToolCallTextTests: XCTestCase {
    let call = "<tool_call>\n<function=read_file>\n<parameter=path>README.md</parameter>\n</function>\n</tool_call>"

    /// The app's strict pattern, read from Harness/RepositoryCall.swift so this test
    /// fails if the app's parser changes shape.
    func strictPattern() throws -> NSRegularExpression {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Harness/RepositoryCall.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let marker = try XCTUnwrap(text.range(of: "let pattern = #\""))
        let end = try XCTUnwrap(text.range(of: "\"#", range: marker.upperBound..<text.endIndex))
        return try NSRegularExpression(pattern: String(text[marker.upperBound..<end.lowerBound]))
    }

    func assertStrictAccepts(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = try strictPattern().firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        XCTAssertNotNil(match, "strict parser would reject: \(text)", file: file, line: line)
    }

    func testCleanCallIsUnchanged() throws {
        let result = ToolCallText.normalize(call)
        XCTAssertFalse(result.repaired)
        XCTAssertEqual(result.text, call)
        try assertStrictAccepts(result.text)
    }

    func testReasoningLeakedBeforeTheCallIsDropped() throws {
        // Verbatim shape from LFM3 1.7B in the agent eval: every one of its
        // 9 rejected calls was a well-formed call after leaked reasoning.
        let leaked = "Let me read the file `todo.md` to see its current content. I'll use the correct function syntax.</think>" + call
        XCTAssertNil(try strictPattern().firstMatch(in: leaked, range: NSRange(leaked.startIndex..., in: leaked)), "precondition: rejected today")
        let result = ToolCallText.normalize(leaked)
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.text, call)
        try assertStrictAccepts(result.text)
        // With an opening tag and a fence too.
        XCTAssertEqual(ToolCallText.normalize("<think>\nplan\n</think>\n\n```xml\n\(call)\n```").text, call)
        // A </think> inside an argument, with no call after it, is left alone.
        let inside = "<tool_call>\n<function=create_file>\n<parameter=path>a.md</parameter>\n<parameter=new_text>Tags: </think></parameter>\n</function>\n</tool_call>"
        XCTAssertEqual(ToolCallText.normalize(inside).text, inside)
        // A plain answer after reasoning is not a call and is not changed here.
        XCTAssertFalse(ToolCallText.normalize("hmm</think>The answer is 4.").repaired)
    }

    func testThinkMarkerCannotHideAnEarlierCallOrPromoteArgumentText() throws {
        let ambiguous = call + "\n</think>\n" + call
        XCTAssertEqual(ToolCallText.normalize(ambiguous).text, ambiguous)
        XCTAssertFalse(ToolCallText.normalize(ambiguous).repaired)
        let nested = "<tool_call><function=create_file><parameter=path>example.md</parameter><parameter=new_text>Example: </think>" + call + "</parameter></function></tool_call>"
        XCTAssertEqual(ToolCallText.normalize(nested).text, nested)
        XCTAssertFalse(ToolCallText.normalize(nested).repaired)
    }

    func testCodeFenceIsRemoved() throws {
        let strictRejects = try strictPattern().firstMatch(in: "```xml\n\(call)\n```", range: NSRange(location: 0, length: ("```xml\n\(call)\n```" as NSString).length))
        XCTAssertNil(strictRejects, "precondition: fenced call fails today")
        let result = ToolCallText.normalize("```xml\n\(call)\n```")
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.text, call)
        try assertStrictAccepts(result.text)
    }

    func testTrailingProseIsDroppedAndReported() throws {
        let result = ToolCallText.normalize("I will read it.\n\(call)\nThen I will summarize.")
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.droppedTrailing, "Then I will summarize.")
        XCTAssertTrue(result.text.hasPrefix("I will read it.\n<tool_call>"))
        try assertStrictAccepts(result.text)
    }

    func testMissingCloseTagIsRepaired() throws {
        let unclosed = "<tool_call>\n<function=list_files>\n<parameter=path>Sources</parameter>\n</function>"
        let result = ToolCallText.normalize(unclosed)
        XCTAssertTrue(result.repaired)
        XCTAssertTrue(result.text.hasSuffix("</tool_call>"))
        try assertStrictAccepts(result.text)
    }

    func testTwoCallsAreLeftForTheStrictParserToReject() {
        let two = call + "\n" + call
        XCTAssertEqual(ToolCallText.normalize(two).text, two)
        XCTAssertFalse(ToolCallText.normalize(two).repaired)
    }

    func testTextBetweenFunctionAndCloseIsNotTouched() {
        let odd = "<tool_call>\n<function=read_file>\n<parameter=path>a</parameter>\n</function>\nextra\n</tool_call>"
        XCTAssertEqual(ToolCallText.normalize(odd).text, odd)
    }

    func testArgumentsAreNeverChanged() {
        let fenced = "```\n<tool_call>\n<function=search_file>\n<parameter=path>a.swift</parameter>\n<parameter=query>  x &lt; y  </parameter>\n</function>\n</tool_call>\n```"
        let result = ToolCallText.normalize(fenced)
        XCTAssertTrue(result.text.contains("<parameter=query>  x &lt; y  </parameter>"))
    }

    func testPlainAnswerIsUnchanged() {
        let answer = "The README says Keel Mobile runs on the phone."
        XCTAssertEqual(ToolCallText.normalize(answer), .init(text: answer, repaired: false, droppedTrailing: ""))
    }

    func testBareFunctionCallIsWrappedAndAfterReasoningToo() throws {
        let bare = "<function=read_file>\n<parameter=path>README.md</parameter>\n</function>"
        let plain = ToolCallText.normalize(bare)
        XCTAssertEqual(plain.text, "<tool_call>\n" + bare + "\n</tool_call>")
        XCTAssertTrue(plain.repaired)
        let leaked = ToolCallText.normalize("I should read it.</think>\n" + bare + "\nDone.")
        XCTAssertEqual(leaked.text, "<tool_call>\n" + bare + "\n</tool_call>")
        XCTAssertEqual(leaked.droppedTrailing, "Done.")
        // Two bare calls are ambiguous and stay as they are.
        XCTAssertFalse(ToolCallText.normalize(bare + bare).repaired)
    }

    /// The reply an imported Qwen3 GLB fine-tune left in the chat.
    func testBrokenToolTextIsRemovedFromTheAnswer() {
        let reply = "I need to build the page.\n<function>run_html</function>\n</think>\nHere is your scene."
        XCTAssertEqual(ToolCallText.cleanReply(reply).text, "Here is your scene.")
        XCTAssertTrue(ToolCallText.cleanReply(reply).removed)

        let onlyBroken = "<function=run_html>\n<parameter=code>&amp;count&amp;limit"
        XCTAssertEqual(ToolCallText.cleanReply(onlyBroken).text, ToolCallText.brokenOnly)

        let stray = "The answer is 4.</tool_call>"
        XCTAssertEqual(ToolCallText.cleanReply(stray).text, "The answer is 4.")
    }

    func testCleanAnswersAndCodeFencesAreUntouched() {
        for reply in ["Plain answer.", "Use `a < b` here.", "```xml\n<function=x>\n</function>\n```\nThat is the format."] {
            XCTAssertEqual(ToolCallText.cleanReply(reply).text, reply)
            XCTAssertFalse(ToolCallText.cleanReply(reply).removed, reply)
        }
        XCTAssertEqual(ToolCallText.cleanReply("<think>\nhmm\n</think>\n\nHi!").text, "Hi!")
        XCTAssertFalse(ToolCallText.cleanReply("<think>\nhmm\n</think>\n\nHi!").removed)

        // Trailing stray </think> without following text must not leak into visibleReply.
        XCTAssertEqual(ToolCallText.visibleReply("The sky is blue.</think>"), "The sky is blue.")
        XCTAssertEqual(ToolCallText.afterThink("The sky is blue.</think>"), "")
        XCTAssertEqual(ToolCallText.afterThink("Draft.</think>\nFinal answer."), "Final answer.")
        XCTAssertEqual(ToolCallText.visibleReply("Draft.</think>\nFinal answer."), "Final answer.")
        XCTAssertEqual(ToolCallText.visibleReply("\n  <think>\nStill thinking"), "Still thinking")
    }
}
