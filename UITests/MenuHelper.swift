import XCTest

extension XCUIApplication {
    /// Opens the menu over the chat and taps one of its destinations
    /// ("models", "connections", "hostWorkspace", "hostApprovals").
    func openFromMenu(_ destination: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(buttons["Menu"].waitForExistence(timeout: 10), file: file, line: line)
        buttons["Menu"].tap()
        let row = buttons["menu-\(destination)"]
        // The menu is a List: a row below the screen is not created until it is
        // scrolled to, which happens to lower rows at the largest text sizes.
        for _ in 0..<6 where !row.waitForExistence(timeout: 2) { swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3), file: file, line: line)
        // At the largest text sizes the rows can sit under the New chat bar.
        for _ in 0..<6 where !(row.isHittable && row.frame.maxY < frame.maxY - 110) {
            swipeUp()
        }
        row.tap()
    }
}
