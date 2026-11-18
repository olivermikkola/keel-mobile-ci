import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class StepNoteTests: XCTestCase {
    private let call = "<tool_call>\n<function=list_files>\n<parameter=path>\n.\n</parameter>\n</function>\n</tool_call>"

    func testNarrationIsTheTextBeforeTheCall() {
        XCTAssertEqual(StepNote.narration("Let me check your files.\n" + call), "Let me check your files.")
        XCTAssertEqual(StepNote.narration(call), "")
        XCTAssertEqual(StepNote.narration("<think>secret</think>\nSearching now.\n" + call), "Searching now.")
        XCTAssertEqual(StepNote.narration("Searching now.\n<tool_c"), "Searching now.", "A call still being written is not shown")
        XCTAssertEqual(StepNote.narration("Plain answer, no call."), "Plain answer, no call.")
    }

    func testSummaryIsOneShortSentence() {
        let plan = """
        I need to understand what the user wants: an interactive HTML analysis page about small language models. This likely involves search.

        Tools relevant:
        - `mcp_huggingface_hub_repo_search` - search
        """ + "\n" + call
        XCTAssertEqual(StepNote.summary(plan), "I need to understand what the user wants.")
        XCTAssertEqual(StepNote.summary("**Searching** Hugging Face for small models. Then I'll build the page.\n" + call),
                       "Searching Hugging Face for small models.")
        XCTAssertNil(StepNote.summary(call))
        XCTAssertNil(StepNote.summary("   \n" + call))
        let long = String(repeating: "word ", count: 40) + "\n" + call
        let summary = StepNote.summary(long)
        XCTAssertEqual(summary?.count, StepNote.maxSummaryCharacters)
        XCTAssertTrue(summary?.hasSuffix("…") == true)
        XCTAssertEqual(StepNote.summary("## Plan\nFirst, I'll create the file:\n" + call), "First, I'll create the file.")
    }
}
