import XCTest
@testable import KeelHarness

final class ToolCallTextTests: XCTestCase {
    let call = "<tool_call>\n<function=read_file>\n<parameter=path>README.md</parameter>\n</function>\n</tool_call>"

    /// The app's strict pattern, read from Sources/RepositoryAgent.swift so this test
    /// fails if the app's parser changes shape.
    func strictPattern() throws -> NSRegularExpression {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RepositoryAgent.swift")
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
}
