import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class NGramSpeculatorTests: XCTestCase {
    func testProposesContinuationFromMostRecentMatchingNGram() {
        let spec = NGramSpeculator(minMatchLength: 3, maxDraftTokens: 4)
        // Earlier occurrence: [10, 20, 30] -> [40, 41, 42, 43]
        // Later occurrence:   [10, 20, 30] -> [90, 91, 92, 93]
        // Trailing needle:    [10, 20, 30]
        let history: [Int32] = [10, 20, 30, 40, 41, 42, 43, 99, 10, 20, 30, 90, 91, 92, 93, 77, 10, 20, 30]
        XCTAssertEqual(spec.propose(from: history), [90, 91, 92, 93])
    }

    func testRespectsMaxTokensAndShortHistory() {
        let spec = NGramSpeculator(minMatchLength: 3, maxDraftTokens: 4)
        XCTAssertEqual(spec.propose(from: [1, 2, 3]), [])
        let history: [Int32] = [1, 2, 3, 4, 5, 6, 7, 1, 2, 3]
        XCTAssertEqual(spec.propose(from: history, maxTokens: 2), [4, 5])
        XCTAssertEqual(spec.propose(from: history, maxTokens: 0), [])
    }

    func testReturnsEmptyWhenNoPriorMatchExists() {
        let spec = NGramSpeculator(minMatchLength: 3, maxDraftTokens: 4)
        XCTAssertEqual(spec.propose(from: [1, 2, 3, 4, 5, 6, 7, 8, 9]), [])
    }

    func testVerifyAcceptsFullDraftPlusBonusToken() {
        let draft: [Int32] = [10, 20, 30]
        let verified: [Int32] = [10, 20, 30, 40]
        let result = NGramSpeculator.verify(draft: draft, verified: verified)
        XCTAssertEqual(result.emitted, [10, 20, 30, 40])
        XCTAssertEqual(result.acceptedDraftCount, 3)
    }

    func testVerifyStopsAtFirstMismatchAndKeepsCorrectionToken() {
        let draft: [Int32] = [10, 20, 30, 40]
        let verified: [Int32] = [10, 99, 30, 40, 50]
        let result = NGramSpeculator.verify(draft: draft, verified: verified)
        XCTAssertEqual(result.emitted, [10, 99])
        XCTAssertEqual(result.acceptedDraftCount, 1)
    }

    func testVerifyZeroMatchStillEmitsExactTargetToken() {
        let draft: [Int32] = [10, 20]
        let verified: [Int32] = [77, 88, 99]
        let result = NGramSpeculator.verify(draft: draft, verified: verified)
        XCTAssertEqual(result.emitted, [77])
        XCTAssertEqual(result.acceptedDraftCount, 0)
    }
}
