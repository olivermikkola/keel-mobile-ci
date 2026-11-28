import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortVideoDraftTests: XCTestCase {
    private func plan() throws -> ShortVideoRequest.RenderPlan {
        // Estimated lengths: 14 characters per second, at least 1.5 s.
        ShortVideoRequest.plan(try ShortVideoRequest.arguments([
            "path": "a.mp4",
            "scenes": "image: a.png\nsay: Short.\n\nimage: b.png\nsay: A line that is a good deal longer than the first one.\n\nimage: c.png\nsay: End.",
        ]))
    }

    func testTheSceneAtATime() throws {
        let plan = try plan()
        let starts = plan.clips.map(\.start)
        XCTAssertEqual(plan.clipIndex(at: 0), 0)
        XCTAssertEqual(plan.clipIndex(at: starts[1] - 0.01), 0)
        XCTAssertEqual(plan.clipIndex(at: starts[1]), 1)
        XCTAssertEqual(plan.clipIndex(at: plan.totalSeconds + 5), 2)
    }

    func testPreviousAndNextJumpLikeAMusicPlayer() throws {
        let plan = try plan()
        let starts = plan.clips.map(\.start)
        XCTAssertEqual(plan.previousStart(from: starts[1] + 2), starts[1], "well into a scene: back to its start")
        XCTAssertEqual(plan.previousStart(from: starts[1] + 0.5), starts[0], "just started: the scene before")
        XCTAssertEqual(plan.previousStart(from: 0.2), 0)
        XCTAssertEqual(plan.nextStart(from: 0.2), starts[1])
        XCTAssertNil(plan.nextStart(from: starts[2] + 0.1))
    }

    func testClipWidthsAddUpToTheTimeline() throws {
        let fractions = try plan().clipFractions
        XCTAssertEqual(fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(fractions[1], fractions[0], "the long line gets the wide clip")
    }

    func testWaveformBarsArePeaksScaledToTheLoudest() {
        let samples: [Float] = [0, 0.1, -0.5, 0.2, 0, 0, 0.05, -0.25]
        XCTAssertEqual(ShortVideoWaveform.bars(samples, count: 4), [0.2, 1, 0, 0.5])
        XCTAssertEqual(ShortVideoWaveform.bars([], count: 3), [0, 0, 0])
        XCTAssertEqual(ShortVideoWaveform.bars([0, 0.0001], count: 2), [0, 0], "silence is flat")
        XCTAssertEqual(ShortVideoWaveform.bars(samples, count: 0).count, 1)
    }
}
