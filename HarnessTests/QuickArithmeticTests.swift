import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class QuickArithmeticTests: XCTestCase {
    func testBasicRequestsAreEvaluatedWithoutModelOutput() {
        XCTAssertEqual(QuickArithmetic.answer("What is 17 times 23? Reply with just the number."), "391")
        XCTAssertEqual(QuickArithmetic.answer("What is 17*23? Reply with just the number"), "391")
        XCTAssertEqual(QuickArithmetic.answer("0.1 + 0.2"), "0.3")
        XCTAssertEqual(QuickArithmetic.answer("Calculate -4 − -6"), "2")
        XCTAssertEqual(QuickArithmetic.answer("what’s 15 divided by 4?"), "3.75")
        XCTAssertEqual(QuickArithmetic.answer("17 x 23="), "391")
        XCTAssertEqual(QuickArithmetic.answer("1 / 3"), "≈ 0.3333333333")
        XCTAssertEqual(QuickArithmetic.answer("2 ÷ 0"), "Cannot divide by zero.")
    }

    func testRequestsWithOtherWorkFallThroughToTheModel() {
        for input in ["Explain how to calculate 17 × 23", "Use 17*23 to write a note", "17*23 plus 42",
                      "19*4 and write result to my file", "1234567890 + 1", "17*23\nplease explain"] {
            XCTAssertNil(QuickArithmetic.answer(input), input)
        }
    }
}
