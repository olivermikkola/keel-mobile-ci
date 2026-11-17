import XCTest

extension XCUIApplication {
    /// Opens the menu over the chat and taps one of its destinations
    /// ("models", "connections", "hostWorkspace", "hostApprovals").
    func openFromMenu(_ destination: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(buttons["Menu"].waitForExistence(timeout: 10), file: file, line: line)
        buttons["Menu"].tap()
        let row = buttons["menu-\(destination)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        // At the largest text sizes the rows can sit under the New chat bar.
        for _ in 0..<6 where !(row.isHittable && row.frame.maxY < frame.maxY - 110) {
            swipeUp()
        }
        row.tap()
    }
}
