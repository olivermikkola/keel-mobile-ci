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

    func testModelsRejectsUnsupportedCoreMLImagePackLinkWithoutStartingDownload() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("models")
        let field = app.textFields["imagePackLink"]
        for _ in 0..<12 {
            if field.exists, field.isHittable, field.frame.maxY < app.frame.maxY - 80 { break }
            app.swipeUp()
        }
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.buttons["importImagePackFile"].exists)
        let submit = app.buttons["addImagePackLink"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("https://example.test/coreml-sd")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let error = app.staticTexts["imagePackError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("huggingface.co"), error.label)
        XCTAssertEqual(field.value as? String, "https://example.test/coreml-sd")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "BYO Core ML image pack rejects non-Hugging-Face link"; shot.lifetime = .keepAlways; add(shot)
    }
}
