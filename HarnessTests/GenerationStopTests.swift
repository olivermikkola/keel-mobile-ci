import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class GenerationStopTests: XCTestCase {
    let call = "<tool_call>\n<function=read_file>\n<parameter=path>README.md</parameter>\n</function>\n</tool_call>"

    /// Feeds pieces in order and returns the index of the piece that asked to stop, or nil.
    func run(_ pieces: [String], detector: inout ToolCallStopDetector) -> Int? {
        for (index, piece) in pieces.enumerated() where detector.feed(piece) { return index }
        return nil
    }

    func testStopsAtClosingTagAndTrimsTrailingText() {
        var detector = ToolCallStopDetector()
        XCTAssertNil(run(["Let me read it.\n"], detector: &detector))
        XCTAssertTrue(detector.feed(call + "\nNow I will wait for the result and then"))
        XCTAssertEqual(detector.text, "Let me read it.\n" + call)
        XCTAssertTrue(detector.isStopped)
    }

    func testFiresOnTheLastCharacterOfTheClosingTag() {
        var detector = ToolCallStopDetector()
        let characters = call.map(String.init)
        var stoppedAt: Int?
        for (index, character) in characters.enumerated() where detector.feed(character) {
            stoppedAt = index
            break
        }
        XCTAssertEqual(stoppedAt, characters.count - 1)
        XCTAssertEqual(detector.text, call)
    }

    func testClosingTagSplitAcrossPiecesStillStops() {
        var detector = ToolCallStopDetector()
        let pieces = ["<tool_call>\n<function=read_file>", "\n<parameter=path>README.md</parameter>\n</function>\n</tool", "_call", ">", " extra"]
        XCTAssertEqual(run(pieces, detector: &detector), 3)
        XCTAssertTrue(detector.text.hasSuffix("</tool_call>"))
    }

    func testOpeningTagSplitAcrossPiecesIsRecognised() {
        var detector = ToolCallStopDetector()
        let pieces = ["<tool", "_call>\n<function=list_files>\n</function>\n</tool_call>"]
        XCTAssertEqual(run(pieces, detector: &detector), 1)
    }

    func testClosingTagInsideThinkBlockDoesNotStop() {
        var detector = ToolCallStopDetector()
        let pieces = ["<think>\nMaybe a </tool_call> would look like this", "\n</think>\n", call]
        XCTAssertEqual(run(pieces, detector: &detector), 2)
        XCTAssertEqual(detector.text, "<think>\nMaybe a </tool_call> would look like this\n</think>\n" + call)
    }

    func testSplitThinkTagsAreRecognised() {
        var detector = ToolCallStopDetector()
        // A `</tool_call>` after a split `</think>` is outside think, so it counts.
        let pieces = ["<th", "ink>a</think", ">", "<tool_call>x", "</tool_call>"]
        XCTAssertEqual(run(pieces, detector: &detector), 4)
    }

    func testToolCallOpenedInsideThinkDoesNotArmTheStop() {
        var detector = ToolCallStopDetector()
        let pieces = ["<think><tool_call>planning</think>", "The answer is 4. </tool_call>"]
        XCTAssertNil(run(pieces, detector: &detector))
    }

    func testClosingTagBeforeAnyOpeningTagDoesNotStop() {
        var detector = ToolCallStopDetector()
        XCTAssertNil(run(["Stray </tool_call> in prose, then no call at all."], detector: &detector))
        XCTAssertFalse(detector.isStopped)
    }

    func testClosingTagBeforeTheOpeningTagDoesNotStopTheRealCall() {
        var detector = ToolCallStopDetector()
        XCTAssertEqual(run(["</tool_call>\n" + call], detector: &detector), 0)
        XCTAssertEqual(detector.text, "</tool_call>\n" + call)
    }

    func testUnclosedThinkBlockNeverStops() {
        var detector = ToolCallStopDetector()
        let pieces = ["<think>", "<tool_call>", "</function>", "</tool_call>"]
        XCTAssertNil(run(pieces, detector: &detector))
    }

    func testFeedingAfterStopIsIgnored() {
        var detector = ToolCallStopDetector()
        XCTAssertTrue(detector.feed(call + "tail"))
        XCTAssertTrue(detector.feed("more"))
        XCTAssertEqual(detector.text, call)
    }

    func testPlainAnswerNeverStops() {
        var detector = ToolCallStopDetector()
        XCTAssertNil(run(["The file ", "has three ", "functions."], detector: &detector))
        XCTAssertEqual(detector.text, "The file has three functions.")
    }
}
