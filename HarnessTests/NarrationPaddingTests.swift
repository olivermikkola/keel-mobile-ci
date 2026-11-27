import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

/// The burst before every Kokoro line lives in its padding frames.
final class NarrationPaddingTests: XCTestCase {
    func testTheStartAndEndPaddingAreMutedExceptOneFrameBySpeech() {
        // Durations as the v3 chain gave them on a Mac for "Ruben is a little funny, and he knows it."
        let ids: [Int32] = [0, 123, 156, 63, 0]
        let durations: [Int32] = [20, 2, 3, 3, 7]
        let total = durations.reduce(0) { $0 + Int($1) } * 600
        let ranges = NarrationLevels.paddingRanges(inputIds: ids, durations: durations, sampleCount: total)
        XCTAssertEqual(ranges, [0..<(19 * 600), (29 * 600)..<total])

        var samples = [Float](repeating: 0.3, count: total)
        NarrationLevels.mute(&samples, ranges)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[19 * 600 - 1], 0, "the burst is gone")
        XCTAssertEqual(samples[19 * 600], 0.3, "the frame before the first sound stays")
        XCTAssertEqual(samples[29 * 600 - 1], 0.3)
        XCTAssertEqual(samples[total - 1], 0)

        // After muting, the silence trim starts just before speech, not at the burst.
        let plan = NarrationLevels.plan(samples: samples, sampleRate: 24_000)
        XCTAssertEqual(plan.start, 19 * 600 - Int(NarrationLevels.leadSeconds * 24_000))
    }

    func testEachPassOfALongLineHasItsPaddingMuted() {
        let ids: [Int32] = [0, 50, 0, 0, 60, 0]
        let durations: [Int32] = [4, 2, 3, 5, 2, 3]
        let total = 19 * 600
        let ranges = NarrationLevels.paddingRanges(inputIds: ids, durations: durations, sampleCount: total)
        // Frames 4,2,3,5,2,3 start at samples 0, 2400, 3600, 5400, 8400, 9600 and end at 11400.
        // Each padding run keeps one frame next to the speech on either side of it.
        XCTAssertEqual(ranges, [0..<(2400 - 600), (3600 + 600)..<5400, 5400..<(8400 - 600), (9600 + 600)..<total])
    }

    func testMismatchedDurationsChangeNothing() {
        XCTAssertEqual(NarrationLevels.paddingRanges(inputIds: [0, 5, 0], durations: [3, 2, 1], sampleCount: 1000), [])
        XCTAssertEqual(NarrationLevels.paddingRanges(inputIds: [0, 5], durations: [3, 2, 1], sampleCount: 3600), [])
    }
}
