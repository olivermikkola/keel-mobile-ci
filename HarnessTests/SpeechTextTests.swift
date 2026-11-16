import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class SpeechTextTests: XCTestCase {
    func testStripsFencedCodeAndMarkdownFormattingWhileKeepingProse() {
        let reply = """
        # Optional handling

        Keep the **optional** value explicit, then check `user.name` in [Swift](https://swift.org).

        ```swift
        guard let name = user.name else {
            return "Hello, there"
        }
        ```

        - [x] Handle empty names
        - Return a clear greeting
        """
        let spoken = SpeechText.spoken(from: reply)
        XCTAssertEqual(spoken, """
        Optional handling

        Keep the optional value explicit, then check user.name in Swift.

        Handle empty names
        Return a clear greeting
        """)
        XCTAssertFalse(spoken.contains("guard let"))
        XCTAssertFalse(spoken.contains("https://"))
    }

    func testCodeOnlyReplySpeaksShortCodeBlockCue() {
        let reply = """
        ```python
        print("hello")
        ```
        """
        XCTAssertEqual(SpeechText.spoken(from: reply), "Code block.")
    }

    func testStripsLeakedThinkingAndToolCalls() {
        let reply = """
        Let me think first.
        </think>
        Here is your summary.
        <tool_call>
        <function=read_file>
        <parameter=path>README.md</parameter>
        </function>
        </tool_call>
        """
        XCTAssertEqual(SpeechText.spoken(from: reply), "Here is your summary.")
    }

    func testCapsSpokenTextAtMaximumLength() {
        let long = String(repeating: "a", count: SpeechText.maxCharacters + 500)
        let spoken = SpeechText.spoken(from: long)
        XCTAssertEqual(spoken.count, SpeechText.maxCharacters)
    }
}
