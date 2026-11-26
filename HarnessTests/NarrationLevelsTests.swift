import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class NarrationLevelsTests: XCTestCase {
    private let rate = 24_000.0

    /// Half a second of silence, one second of quiet "speech", half a second of silence.
    private func quietLine(amplitude: Float = 0.05) -> [Float] {
        let pad = [Float](repeating: 0.001, count: Int(rate * 0.5))
        let tone = (0..<Int(rate)).map { amplitude * Float(sin(Double($0) * 0.05)) }
        return pad + tone + pad
    }

    func testTrimsTheSilenceAtBothEndsButKeepsAMargin() {
        let samples = quietLine()
        let plan = NarrationLevels.plan(samples: samples, sampleRate: rate)
        let kept = Double(plan.end - plan.start) / rate
        XCTAssertEqual(kept, 1 + NarrationLevels.leadSeconds + NarrationLevels.tailSeconds, accuracy: 0.01)
        XCTAssertEqual(Double(plan.start) / rate, 0.5 - NarrationLevels.leadSeconds, accuracy: 0.01)
    }

    func testRaisesQuietSpeechWithoutLettingPeaksClip() {
        let samples = quietLine(amplitude: 0.05)
        let plan = NarrationLevels.plan(samples: samples, sampleRate: rate)
        XCTAssertGreaterThan(plan.gain, 2)
        let peak = samples[plan.start..<plan.end].map { abs($0) * plan.gain }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, NarrationLevels.peakLimit + 0.001)
    }

    func testLoudSpeechIsTurnedDownAndNeverClips() {
        let plan = NarrationLevels.plan(samples: quietLine(amplitude: 0.95), sampleRate: rate)
        XCTAssertLessThan(plan.gain, 1)
        XCTAssertLessThanOrEqual(0.95 * plan.gain, NarrationLevels.peakLimit)
    }

    func testSilenceIsLeftAlone() {
        let silent = [Float](repeating: 0, count: 1000)
        XCTAssertEqual(NarrationLevels.plan(samples: silent, sampleRate: rate), .init(start: 0, end: 1000, gain: 1))
    }
}
