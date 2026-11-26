import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ContextWindowCapTests: XCTestCase {
    func testAutoUsesModelDefaultUnchanged() {
        XCTAssertEqual(ContextWindowCap.auto.effectiveContextSize(modelDefault: 4_096), 4_096)
        XCTAssertEqual(ContextWindowCap.auto.effectiveContextSize(modelDefault: 16_384), 16_384)
        XCTAssertEqual(ContextWindowCap.auto.effectiveContextSize(modelDefault: 32_768), 32_768)
        XCTAssertNil(ContextWindowCap.auto.activeBadge(forModelDefault: 16_384))
    }

    func testCapNeverExceedsModelDefault() {
        XCTAssertEqual(ContextWindowCap.k16.effectiveContextSize(modelDefault: 4_096), 4_096)
        XCTAssertEqual(ContextWindowCap.k16.effectiveContextSize(modelDefault: 8_192), 8_192)
        XCTAssertEqual(ContextWindowCap.k8.effectiveContextSize(modelDefault: 4_096), 4_096)
        XCTAssertNil(ContextWindowCap.k16.activeBadge(forModelDefault: 8_192))
    }

    func testCapTrimsLargerModelDefaultsAndReportsBadge() {
        XCTAssertEqual(ContextWindowCap.k4.effectiveContextSize(modelDefault: 32_768), 4_096)
        XCTAssertEqual(ContextWindowCap.k8.effectiveContextSize(modelDefault: 16_384), 8_192)
        XCTAssertEqual(ContextWindowCap.k16.effectiveContextSize(modelDefault: 32_768), 16_384)
        XCTAssertEqual(ContextWindowCap.k4.activeBadge(forModelDefault: 16_384), "4K cap")
        XCTAssertEqual(ContextWindowCap.k8.activeBadge(forModelDefault: 32_768), "8K cap")
    }

    func testSelectableOptionsOnlyIncludeSmallerCaps() {
        XCTAssertEqual(ContextWindowCap.selectableOptions(forModelDefault: 4_096), [.auto])
        XCTAssertEqual(ContextWindowCap.selectableOptions(forModelDefault: 8_192), [.auto, .k4])
        XCTAssertEqual(ContextWindowCap.selectableOptions(forModelDefault: 16_384), [.auto, .k4, .k8])
        XCTAssertEqual(ContextWindowCap.selectableOptions(forModelDefault: 32_768), [.auto, .k4, .k8, .k16])
    }
}
