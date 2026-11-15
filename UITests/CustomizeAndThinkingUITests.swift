import XCTest

final class CustomizeAndThinkingUITests: XCTestCase {
    func testCustomizeStandingInstructionsAndThinkingTogglePersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()

        app.openFromMenu("customize")
        XCTAssertTrue(app.navigationBars["Customize"].waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any).matching(identifier: "customInstructionsField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Use metric units and concise bullet points.")
        let sheetShot = XCTAttachment(screenshot: app.screenshot())
        sheetShot.name = "Customize standing instructions sheet"
        sheetShot.lifetime = .keepAlways
        add(sheetShot)
        app.buttons["saveCustomInstructions"].tap()
        XCTAssertFalse(app.navigationBars["Customize"].waitForExistence(timeout: 2))

        let addMenu = app.buttons["composerAddMenu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let toggle = app.buttons["thinkingToggleMenuOption"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Thinking off")
        toggle.tap()

        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Thinking on")
        let menuShot = XCTAttachment(screenshot: app.screenshot())
        menuShot.name = "Thinking toggle enabled in composer menu"
        menuShot.lifetime = .keepAlways
        add(menuShot)
    }
}
