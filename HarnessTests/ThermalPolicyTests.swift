import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ThermalPolicyTests: XCTestCase {
    func testNominalAndFairProceedWithoutThrottle() {
        for step in 0..<8 {
            XCTAssertEqual(ThermalPolicy.decision(for: .nominal, step: step), .proceed)
            XCTAssertEqual(ThermalPolicy.decision(for: .fair, step: step), .proceed)
        }
    }

    func testSeriousThrottlesWithoutStopping() {
        XCTAssertEqual(
            ThermalPolicy.decision(for: .serious, step: 0),
            .throttle(pauseNanoseconds: ThermalPolicy.seriousPauseNanoseconds)
        )
        XCTAssertEqual(ThermalPolicy.decision(for: .serious, step: 1), .proceed)
        XCTAssertEqual(
            ThermalPolicy.decision(for: .serious, step: 2),
            .throttle(pauseNanoseconds: ThermalPolicy.seriousPauseNanoseconds)
        )
    }

    func testCriticalStopsGeneration() {
        for step in 0..<4 {
            XCTAssertEqual(ThermalPolicy.decision(for: .critical, step: step), .stop)
        }
    }
}
