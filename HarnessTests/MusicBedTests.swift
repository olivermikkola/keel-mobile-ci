import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class MusicBedTests: XCTestCase {
    private let lines: [(start: TimeInterval, seconds: TimeInterval)] = [(0.0, 2.4), (2.75, 2.0), (6.0, 1.5)]

    func testCloseLinesShareOneDipAndFarOnesDoNot() {
        // 2.4 → 2.75 is 0.35 s apart (less than two ramps): one dip. 4.75 → 6.0 is not.
        XCTAssertEqual(MusicBed.speech(lines), [0.0...4.75, 6.0...7.5])
    }

    func testFadesInDucksUnderSpeechAndFadesOut() {
        let spoken = MusicBed.speech(lines), total = 10.0
        XCTAssertEqual(MusicBed.volume(at: 0, speech: spoken, total: total), 0, "starts silent")
        XCTAssertEqual(MusicBed.volume(at: 1.0, speech: spoken, total: total), MusicBed.duckedVolume, "ducked under the first line")
        XCTAssertEqual(MusicBed.volume(at: 5.4, speech: spoken, total: total), MusicBed.baseVolume, "back up between lines")
        XCTAssertEqual(MusicBed.volume(at: 6.5, speech: spoken, total: total), MusicBed.duckedVolume)
        XCTAssertEqual(MusicBed.volume(at: 8.0, speech: spoken, total: total), MusicBed.baseVolume)
        XCTAssertEqual(MusicBed.volume(at: 10, speech: spoken, total: total), 0, "ends silent")
        let halfwayOut = MusicBed.volume(at: 10 - MusicBed.fadeOut / 2, speech: spoken, total: total)
        XCTAssertEqual(halfwayOut, MusicBed.baseVolume / 2, accuracy: 0.001)
        let rising = MusicBed.volume(at: 4.75 + MusicBed.duckRamp / 2, speech: spoken, total: total)
        XCTAssertEqual(rising, (MusicBed.duckedVolume + MusicBed.baseVolume) / 2, accuracy: 0.001, "comes back up over the ramp")
    }

    func testRampsCoverTheWholeVideoBackToBack() {
        let ramps = MusicBed.ramps(lines: lines, total: 10)
        XCTAssertEqual(ramps.first?.start, 0)
        XCTAssertEqual(ramps.last?.end, 10)
        for (a, b) in zip(ramps, ramps.dropFirst()) {
            XCTAssertEqual(a.end, b.start, accuracy: 1e-9, "no gaps")
            XCTAssertEqual(a.to, b.from, accuracy: 1e-6, "no jumps")
        }
        XCTAssertTrue(ramps.allSatisfy { $0.from <= MusicBed.baseVolume && $0.to <= MusicBed.baseVolume })
        XCTAssertTrue(MusicBed.ramps(lines: [], total: 0).isEmpty)
    }
}
