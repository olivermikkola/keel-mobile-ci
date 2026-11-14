import XCTest

final class NavigationUITests: XCTestCase {
    func testDefaultNavigationWorksWithoutAHost() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.buttons["New chat"].tap()
        XCTAssertFalse(app.buttons["attachRepository"].exists, "A fresh chat starts with the assistant, without a repository prompt")
        capture(app, "General assistant home")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Chat is the only screen; everything else opens from the menu")
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["menu-models"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu-connections"].exists)
        XCTAssertFalse(app.buttons["menu-hostWorkspace"].exists)
        XCTAssertFalse(app.buttons["menu-hostApprovals"].exists)
        capture(app, "On-device default menu")
        app.buttons["menu-connections"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose a local model"].exists)
        XCTAssertTrue(app.buttons["openGitHubRepository"].exists)
        capture(app, "Local model and repository connections")
        app.buttons["Choose a local model"].tap()
        XCTAssertTrue(app.buttons["Download Bonsai 2 · 4B"].waitForExistence(timeout: 10))
    }

    func testHostControlsAppearOnlyWhileConnectedAndDisconnectReturnsToConnections() {
        let app = XCUIApplication(); app.launchArguments = ["--connected-host-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["menu-hostWorkspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["menu-hostApprovals"].exists)
        app.buttons["menu-hostWorkspace"].tap()
        XCTAssertTrue(app.staticTexts["Commands execute on the connected host."].waitForExistence(timeout: 5))
        capture(app, "Connected host workspace - UI fixture")
        app.navigationBars.buttons["Disconnect"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["menu-connections"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["menu-hostWorkspace"].exists)
        XCTAssertFalse(app.buttons["menu-hostApprovals"].exists)
        capture(app, "Disconnected host returns to connections")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
