import XCTest
@testable import KeelMobile

final class ChatBlockTests: XCTestCase {
    func testCodeCopyPreservesIndentationBlankLinesAndFinalNewline() {
        let source = "Before\n\n```swift\nfunc greet() {\n    print(\"hello\")\n\n}\n```\nAfter"
        XCTAssertEqual(ChatBlock.parse(source), [
            .text("Before\n\n"),
            .code(language: "swift", content: "func greet() {\n    print(\"hello\")\n\n}\n"),
            .text("After")
        ])
    }

    func testCRLFIsKeptInCopiedCode() {
        XCTAssertEqual(ChatBlock.parse("```text\r\nfirst\r\n  second\r\n```\r\n"), [
            .code(language: "text", content: "first\r\n  second\r\n")
        ])
    }

    func testLongFenceCanContainShorterFenceWithoutDroppingCode() {
        XCTAssertEqual(ChatBlock.parse("````markdown\n```swift\nlet n = 1\n```\n````"), [
            .code(language: "markdown", content: "```swift\nlet n = 1\n```\n")
        ])
    }

    func testStreamingPartialBlockKeepsItsLastUnfinishedLine() {
        XCTAssertEqual(ChatBlock.parse("```swift\nlet value = optional.ma"), [
            .code(language: "swift", content: "let value = optional.ma")
        ])
    }

    func testDifferentFenceAndClosingFenceWithTextAreCode() {
        XCTAssertEqual(ChatBlock.parse("~~~sh\necho hello\n```\n~~~ not closing\n~~~"), [
            .code(language: "sh", content: "echo hello\n```\n~~~ not closing\n")
        ])
    }

    func testOrdinaryTextAndIndentedFenceRemainLiteral() {
        let source = "Use `value` and [the docs](https://example.com).\n    ```not a fence"
        XCTAssertEqual(ChatBlock.parse(source), [.text(source)])
    }
}
