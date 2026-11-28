import XCTest

extension XCUIApplication {
    /// Opens the menu over the chat and taps one of its destinations
    /// ("models", "connections", "hostWorkspace", "hostApprovals").
    func openFromMenu(_ destination: String, file: StaticString = #filePath, line: UInt = #line) {
        // Studios live in Apps and About lives at the end of Customize.
        if ["images", "videos", "carousels", "decide"].contains(destination) {
            openFromMenu("apps", file: file, line: line)
            let tile = buttons["app-\(destination)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5), file: file, line: line)
            tile.tap()
            return
        }
        if destination == "about" {
            openFromMenu("customize", file: file, line: line)
            let about = buttons["openAbout"]
            for _ in 0..<8 where !(about.exists && about.isHittable) { swipeUp() }
            XCTAssertTrue(about.waitForExistence(timeout: 5), file: file, line: line)
            about.tap()
            return
        }
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
