import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class SyntaxCheckTests: XCTestCase {
    func testValidAndInvalidJSON() {
        let ok = SyntaxCheck.inspect(path: "config/settings.json", text: #"{"port": 8080, "items": ["a", "b"]}"#)
        XCTAssertEqual(ok, SyntaxCheckResult(isValid: true, message: "JSON syntax valid"))

        let bad = SyntaxCheck.inspect(path: "data.json", text: #"{"port": 8080,"#)
        XCTAssertEqual(bad?.isValid, false)
        XCTAssertEqual(bad?.message.contains("JSON syntax error"), true)
    }

    func testValidAndBrokenCSSBracesStringsAndComments() {
        let ok = SyntaxCheck.inspect(path: "styles/site.css", text: """
        /* comment with } unmatched brace inside */
        body { color: #111; content: "hello } world"; }
        @media (min-width: 600px) { .card { padding: 12px; } }
        """)
        XCTAssertEqual(ok, SyntaxCheckResult(isValid: true, message: "CSS braces and strings balanced"))

        let missingBrace = SyntaxCheck.inspect(path: "styles/site.css", text: "body { color: #111;")
        XCTAssertEqual(missingBrace?.isValid, false)
        XCTAssertEqual(missingBrace?.message, "CSS syntax error: missing 1 closing '}'.")

        let extraBrace = SyntaxCheck.inspect(path: "styles/site.css", text: "body { color: #111; }}")
        XCTAssertEqual(extraBrace?.isValid, false)
        XCTAssertEqual(extraBrace?.message, "CSS syntax error: unexpected closing '}'.")

        let unclosedString = SyntaxCheck.inspect(path: "styles/site.css", text: "body { content: \"oops; }")
        XCTAssertEqual(unclosedString?.isValid, false)
    }

    func testUnsupportedFormatsReturnNil() {
        XCTAssertNil(SyntaxCheck.inspect(path: "README.md", text: "# Hello"))
        XCTAssertNil(SyntaxCheck.inspect(path: "index.html", text: "<br><img src='a.png'>"))
        XCTAssertNil(SyntaxCheck.inspect(path: "App.swift", text: "struct A {}"))
    }
}
