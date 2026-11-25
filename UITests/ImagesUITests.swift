import XCTest

final class ImagesUITests: XCTestCase {
    func testImagesOpensWithStylesAndAskForTheModel() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("images")
        let prompt = app.descendants(matching: .any).matching(identifier: "imagePrompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        // The simulator has neither the image model nor Apple Intelligence.
        XCTAssertTrue(app.buttons["imagesDownloadModel"].exists)
        prompt.tap(); prompt.typeText("A red fox in the snow")
        XCTAssertFalse(app.buttons["makeImage"].isEnabled)
        app.buttons["imageStylePicker"].tap()
        XCTAssertTrue(app.buttons["imageStyle-sketch"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Images with its style menu"; shot.lifetime = .keepAlways; add(shot)
    }
}
