import XCTest

final class NavigationUITests: XCTestCase {
    func testDefaultNavigationWorksWithoutAHost() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Models"].exists)
        XCTAssertTrue(app.tabBars.buttons["Connect"].exists)
        XCTAssertFalse(app.tabBars.buttons["Workspace"].exists)
        XCTAssertFalse(app.tabBars.buttons["Approvals"].exists)
        capture(app, "On-device default navigation")
        app.tabBars.buttons["Connect"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose a local model"].exists)
        XCTAssertTrue(app.buttons["openGitHubRepository"].exists)
        capture(app, "Local model and repository connections")
        app.buttons["Choose a local model"].tap()
        XCTAssertTrue(app.buttons["Download Bonsai 2 · 4B"].waitForExistence(timeout: 5))
    }

    func testHostControlsAppearOnlyWhileConnectedAndDisconnectReturnsToConnections() {
        let app = XCUIApplication(); app.launchArguments = ["--connected-host-fixture"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Approvals"].exists)
        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.staticTexts["Commands execute on the connected host."].waitForExistence(timeout: 5))
        capture(app, "Connected host workspace - UI fixture")
        app.navigationBars.buttons["Disconnect"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Workspace"].exists)
        XCTAssertFalse(app.tabBars.buttons["Approvals"].exists)
        capture(app, "Disconnected host returns to connections")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
