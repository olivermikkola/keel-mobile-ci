import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ContextMeterTests: XCTestCase {
    func testFormatsContextUsageAndThermalPill() {
        let meter = ContextMeter(usedTokens: 2_400, contextSize: 8_192, thermal: .nominal)
        XCTAssertEqual(meter.percentUsed, 29)
        XCTAssertFalse(meter.isHigh)
        XCTAssertEqual(meter.contextLabel, "2.4K / 8.2K (29%)")
        XCTAssertEqual(meter.pillText, "2.4K / 8.2K (29%)")
    }

    func testFlagsHighContextAndAppendsWarmThermalBadge() {
        let meter = ContextMeter(usedTokens: 6_500, contextSize: 8_000, thermal: .fair)
        XCTAssertTrue(meter.isHigh)
        XCTAssertEqual(meter.percentUsed, 81)
        XCTAssertEqual(meter.pillText, "6.5K / 8K (81%) · Warm")
    }

    func testEmptyContextStillShowsElevatedThermalBadge() {
        let quiet = ContextMeter(usedTokens: 0, contextSize: 8_192, thermal: .nominal)
        XCTAssertNil(quiet.pillText)

        let hot = ContextMeter(usedTokens: 0, contextSize: 8_192, thermal: .serious)
        XCTAssertEqual(hot.pillText, "Hot")
    }

    func testClampsOverflowingTokensToOneHundredPercent() {
        let over = ContextMeter(usedTokens: 12_000, contextSize: 8_000, thermal: .critical)
        XCTAssertEqual(over.percentUsed, 100)
        XCTAssertEqual(over.thermal.badge, "Overheated")
    }
}
