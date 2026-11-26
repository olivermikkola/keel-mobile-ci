import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class RepetitionGuardTests: XCTestCase {
    private func feed(_ text: String, pieceSize: Int = 3) -> RepetitionGuard {
        var guardian = RepetitionGuard()
        var rest = Substring(text)
        while !rest.isEmpty {
            guardian.feed(String(rest.prefix(pieceSize)))
            rest = rest.dropFirst(pieceSize)
        }
        return guardian
    }

    /// The loop from the GLB fine-tune's screenshot.
    func testEntityLoopStopsWithinTheSpan() {
        var guardian = RepetitionGuard()
        let start = "<function=run_html>\n<parameter=code>\n"
        XCTAssertFalse(guardian.feed(start))
        var written = start
        while !guardian.isLooping, written.count < 5000 {
            written += "&amp;count&amp;limit"
            guardian.feed("&amp;count&amp;limit")
        }
        XCTAssertTrue(guardian.isLooping)
        XCTAssertEqual(guardian.period, "&amp;count&amp;limit".count)
        XCTAssertLessThan(written.count, start.count + RepetitionGuard.span + 2 * guardian.period)
        XCTAssertEqual(RepetitionGuard.collapse(written, period: guardian.period), start + "&amp;count&amp;limit")
    }

    func testRepeatedLinesAndSingleCharactersAreLoops() {
        XCTAssertTrue(feed(String(repeating: "\n", count: 450)).isLooping)
        let line = "The scene uses a cube mesh with a basic material.\n"
        let looped = feed("Intro.\n" + String(repeating: line, count: 12))
        XCTAssertTrue(looped.isLooping)
        XCTAssertEqual(looped.period, line.count)
    }

    func testOrdinaryProseCodeAndTablesAreNotLoops() {
        let prose = (1...60).map { "Sentence number \($0) says something a little different. " }.joined()
        XCTAssertFalse(feed(prose).isLooping)
        let code = (0..<40).map { "  let value\($0) = vertices[\($0)] * scale\n" }.joined()
        XCTAssertFalse(feed(code).isLooping)
        let table = "| a | b |\n|---|---|\n" + (0..<30).map { "| \($0) | \($0 * 2) |\n" }.joined()
        XCTAssertFalse(feed(table).isLooping)
        // A short repeat, under the span, is fine.
        XCTAssertFalse(feed("Intro " + String(repeating: "ha", count: 150)).isLooping)
    }

    func testCollapseLeavesTextWithoutALoopAlone() {
        XCTAssertEqual(RepetitionGuard.collapse("abcdef", period: 2), "abcdef")
        XCTAssertEqual(RepetitionGuard.collapse("xyzabcabcabc", period: 3), "xyzabc")
    }
}
