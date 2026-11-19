import XCTest

final class ProjectUITests: XCTestCase {
    func testCreateAProjectGiveItInstructionsAndChatInIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()

        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.openFromMenu("projects")
        let create = app.buttons["createProject"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        // SwiftUI alerts do not pass identifiers to their fields, so find them in the alert.
        let alert = app.alerts["New project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let nameField = alert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Trip to Lapland")
        alert.buttons["Create"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Trip to Lapland"].waitForExistence(timeout: 5), "The new project opens")
        let instructions = app.descendants(matching: .any).matching(identifier: "projectInstructionsField").firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.tap()
        instructions.typeText("We travel in March with two kids.")
        app.buttons["saveProjectInstructions"].tap()
        XCTAssertTrue(app.buttons["addProjectFile"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Project page with instructions"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["projectNewChat"].tap()
        XCTAssertFalse(app.navigationBars["Trip to Lapland"].waitForExistence(timeout: 2), "Starting a chat closes the project")
        XCTAssertFalse(app.navigationBars["Projects"].exists, "Starting a chat closes the project list too")
        app.openFromMenu("projects")
        let row = app.buttons["project-Trip to Lapland"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("2 chats"), row.label)
    }
}
