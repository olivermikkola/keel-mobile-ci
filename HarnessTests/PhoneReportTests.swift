import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class PhoneReportTests: XCTestCase {
    private let facts = PhoneFacts(machine: "iPhone16,1", system: "iOS 26.1", memoryBytes: 8 * 1_073_741_824,
                                   freeDiskBytes: 42_000_000_000, thermal: "nominal", lowPower: false, appVersion: "1.0 (120)")

    func testReportGroupsTheLatestMeasurementsNewestFirst() {
        var log = PhoneMeasurementLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(PhoneMeasurement(date: start, kind: .video, text: "Photos 1 s · Lines 9 s · Voice 15 s · Video 38 s"))
        log.append(PhoneMeasurement(date: start.addingTimeInterval(60), kind: .video, text: "Photos 1 s · Lines 8 s · Voice 12 s · Video 20 s"))
        log.append(PhoneMeasurement(date: start, kind: .image, text: "Photo style · 41 s"))
        let report = PhoneReport.text(facts: facts, log: log, made: start)
        XCTAssertTrue(report.contains("Device: iPhone16,1 · iOS 26.1 · 8.0 GB memory"))
        XCTAssertTrue(report.contains("Now: thermal nominal · 42.0 GB free"))
        XCTAssertTrue(report.contains("Videos (latest 2)"))
        XCTAssertTrue(report.contains("Chat replies (none yet)"))
        let newer = report.range(of: "Video 20 s")!, older = report.range(of: "Video 38 s")!
        XCTAssertLessThan(newer.lowerBound, older.lowerBound)
    }

    func testLogIsCappedAndOneLinePerEntry() {
        var log = PhoneMeasurementLog()
        for index in 0..<(PhoneMeasurementLog.limit + 5) {
            log.append(PhoneMeasurement(kind: .chat, text: "reply \(index)\nsecond line"))
        }
        XCTAssertEqual(log.entries.count, PhoneMeasurementLog.limit)
        XCTAssertEqual(log.entries.first?.text, "reply 5 second line")
        log.append(PhoneMeasurement(kind: .chat, text: "   "))
        XCTAssertEqual(log.entries.count, PhoneMeasurementLog.limit)
        let report = PhoneReport.text(facts: facts, log: log)
        XCTAssertEqual(report.components(separatedBy: "\n- ").count - 1, PhoneMeasurementLog.perKind)
    }

    func testLogSurvivesSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = PhoneMeasurementLog()
        log.append(PhoneMeasurement(date: Date(timeIntervalSince1970: 1_800_000_000), kind: .benchmark, text: "HTML video 5 s: 41 ms a frame"))
        try log.save(to: url)
        XCTAssertEqual(PhoneMeasurementLog.load(from: url), log)
        XCTAssertEqual(PhoneMeasurementLog.load(from: url.appendingPathExtension("missing")), PhoneMeasurementLog())
    }

    func testChatLineHasModelSpeedsAndMemory() {
        let telemetry = InferenceTelemetry(prefillTokens: 1690, reusedTokens: 400, prefillDuration: 5,
                                           decodedTokens: 203, decodeDuration: 10, footprintBytes: 379_000_000)
        let line = PhoneReport.chatLine(model: "LFM3 1.7B", runtime: "llama.cpp", telemetry: telemetry, thermal: "fair")
        XCTAssertTrue(line.hasPrefix("LFM3 1.7B · llama.cpp · read 1690 tok at 338 tok/s · 400 reused"), line)
        XCTAssertTrue(line.contains("wrote 203 tok at 20.3 tok/s"), line)
        XCTAssertTrue(line.hasSuffix("thermal fair"), line)
    }
}
