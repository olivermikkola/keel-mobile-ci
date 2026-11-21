import XCTest

final class DecideUITests: XCTestCase {
    func testDecideTakesDocumentsAndQuestionsAndAsksForTheModel() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("decide")
        // The simulator has no decision model.
        XCTAssertTrue(app.buttons["decideDownloadModel"].waitForExistence(timeout: 5))

        // Questions are remembered between runs, so the examples may already be there.
        if app.buttons["decideExamples"].exists { app.buttons["decideExamples"].tap() }
        XCTAssertTrue(app.buttons.matching(identifier: "decideQuestion").firstMatch.waitForExistence(timeout: 5))
        let questions = app.buttons.matching(identifier: "decideQuestion").count
        XCTAssertGreaterThanOrEqual(questions, 3)

        app.buttons["decideAddQuestion"].tap()
        let text = app.textFields["decideQuestionText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Does it mention a late fee?")
        app.buttons["decideQuestionSave"].tap()
        XCTAssertTrue(app.staticTexts["Does it mention a late fee?"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "decideQuestion").count, questions + 1)

        app.buttons["decidePaste"].tap()
        let paste = app.textViews["decidePasteText"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap(); paste.typeText("Invoice 1043. Amount due 68.40 EUR. Overdue: a late fee of 5 EUR was added.")
        app.buttons["decidePasteAdd"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "decideDocument").firstMatch.waitForExistence(timeout: 5))

        // Without the model Decide cannot run, and says why.
        let run = app.buttons["decideRun"]
        for _ in 0..<4 where !run.isHittable { app.swipeUp() }
        XCTAssertTrue(run.exists)
        XCTAssertFalse(run.isEnabled)
        XCTAssertTrue(app.staticTexts["Download the decision model first."].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Decide with a document and questions"; shot.lifetime = .keepAlways; add(shot)
    }
}
