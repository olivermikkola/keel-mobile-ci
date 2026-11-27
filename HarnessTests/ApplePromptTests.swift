import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ApplePromptTests: XCTestCase {
    func testASingleQuestionIsSentAsIs() throws {
        let rendered = AgentPrompt.chatML(system: "You are Keel.", messages: [("user", "What is the capital of Finland?")])
        let parts = try XCTUnwrap(ApplePrompt.split(chatML: rendered))
        XCTAssertEqual(parts.instructions, "You are Keel.")
        XCTAssertEqual(parts.prompt, "What is the capital of Finland?")
    }

    func testToolStepsBecomeATranscriptEndingAtTheLastResult() throws {
        let call = "<tool_call>\n<function=read_file>\n<parameter=path>\nnotes.txt\n</parameter>\n</function>\n</tool_call>"
        let rendered = AgentPrompt.chatML(system: AgentPrompt.local(), messages: [
            ("user", "Summarise my notes"), ("assistant", call), ("tool", "{\"content\":\"buy milk\"}"),
        ])
        let parts = try XCTUnwrap(ApplePrompt.split(chatML: rendered))
        XCTAssertTrue(parts.instructions.contains("<tools>"), "The tool list stays in the instructions")
        XCTAssertFalse(parts.instructions.contains("<|im_"))
        XCTAssertEqual(parts.prompt, """
            Conversation so far:

            User:
            Summarise my notes

            You:
            \(call)

            Tool result:
            {"content":"buy milk"}

            Continue from the last tool result: call the next tool or answer the user.
            """)
    }

    func testAFollowUpQuestionAsksForAReply() throws {
        let rendered = AgentPrompt.chatML(system: "S", messages: [("user", "Hi"), ("assistant", "Hello!"), ("user", "And Sweden?")])
        let parts = try XCTUnwrap(ApplePrompt.split(chatML: rendered))
        XCTAssertTrue(parts.prompt.hasSuffix("User:\nAnd Sweden?\n\nWrite your reply to the user's last message."))
        XCTAssertFalse(parts.prompt.contains("<think>"))
    }

    func testOtherTemplatesAreRefused() {
        XCTAssertNil(ApplePrompt.split(chatML: "plain text"))
        let lfm = ModelPrompt.render(family: .lfm3, system: "S", messages: [("user", "Hi")])
        XCTAssertNil(ApplePrompt.split(chatML: lfm))
    }

    func testTokenEstimate() {
        XCTAssertEqual(ApplePrompt.estimatedTokens(""), 1)
        XCTAssertEqual(ApplePrompt.estimatedTokens("abcdefgh"), 2)
    }
}
