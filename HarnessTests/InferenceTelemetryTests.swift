import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class InferenceTelemetryTests: XCTestCase {
    func testSummaryFormatsPrefillDecodeAndGigabyteFootprint() {
        let telemetry = InferenceTelemetry(
            prefillTokens: 480,
            reusedTokens: 0,
            prefillDuration: 2.0,
            decodedTokens: 142,
            decodeDuration: 5.0,
            footprintBytes: 2_350_000_000
        )

        XCTAssertEqual(telemetry.prefillTokensPerSecond, 240.0)
        XCTAssertEqual(telemetry.decodeTokensPerSecond, 28.4)
        XCTAssertEqual(telemetry.summary, "prefill 240 tok/s · decode 28.4 tok/s · 2.4 GB")
    }

    func testSummaryShowsCacheHitAndMegabyteFootprintWhenAllPromptTokensReused() {
        let telemetry = InferenceTelemetry(
            prefillTokens: 0,
            reusedTokens: 320,
            prefillDuration: 0,
            decodedTokens: 48,
            decodeDuration: 1.5,
            footprintBytes: 640_000_000
        )

        XCTAssertNil(telemetry.prefillTokensPerSecond)
        XCTAssertEqual(telemetry.summary, "cache hit · decode 32.0 tok/s · 640 MB")
    }

    func testZeroWorkReturnsNilSummary() {
        let telemetry = InferenceTelemetry(
            prefillTokens: 0,
            reusedTokens: 0,
            prefillDuration: 0,
            decodedTokens: 0,
            decodeDuration: 0,
            footprintBytes: nil
        )

        XCTAssertNil(telemetry.summary)
    }

    func testCombinedAccumulatesCountsAndKeepsPeakMemory() {
        let first = InferenceTelemetry(
            prefillTokens: 100,
            reusedTokens: 0,
            prefillDuration: 0.5,
            decodedTokens: 20,
            decodeDuration: 1.0,
            footprintBytes: 1_200_000_000
        )
        let second = InferenceTelemetry(
            prefillTokens: 50,
            reusedTokens: 120,
            prefillDuration: 0.5,
            decodedTokens: 40,
            decodeDuration: 1.0,
            footprintBytes: 1_800_000_000
        )

        let combined = first.combined(with: second)
        XCTAssertEqual(combined.prefillTokens, 150)
        XCTAssertEqual(combined.reusedTokens, 120)
        XCTAssertEqual(combined.prefillDuration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(combined.decodedTokens, 60)
        XCTAssertEqual(combined.decodeDuration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(combined.footprintBytes, 1_800_000_000)
        XCTAssertEqual(combined.summary, "prefill 150 tok/s · decode 30.0 tok/s · 1.8 GB")
    }
}
