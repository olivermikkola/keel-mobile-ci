import XCTest
@testable import KeelHarness

final class CircuitBreakerTests: XCTestCase {
    func testTripsAtThresholdAndSuccessResets() {
        let breaker = CircuitBreaker()
        XCTAssertNil(breaker.recordFailure(.notFound))
        XCTAssertNil(breaker.recordFailure(.notFound))
        breaker.recordSuccess()
        XCTAssertNil(breaker.recordFailure(.notFound))
        XCTAssertNil(breaker.recordFailure(.notFound))
        let advice = breaker.recordFailure(.rateLimited)
        XCTAssertTrue(advice?.contains("3 tool calls in a row failed") == true)
        XCTAssertTrue(advice?.contains("rate limit") == true)
    }

    func testThresholdIsAtLeastOne() {
        XCTAssertNotNil(CircuitBreaker(tripThreshold: 0).recordFailure(.network))
    }
}
