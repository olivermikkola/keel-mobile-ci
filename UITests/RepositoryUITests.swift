import XCTest

final class RepositoryUITests: XCTestCase {
    func testOpenPublicRepositoryAndReadRealFile() throws {
        try exerciseRepository(recorded: false)
    }

    func testRecordedRepositoryAttachmentAndRelaunch() throws {
        try exerciseRepository(recorded: true)
    }

    private func exerciseRepository(recorded: Bool) throws {
        let app = XCUIApplication()
        if recorded {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-recording", withExtension: "json"))
            app.launchArguments += ["--recorded-repository"]
            app.launchEnvironment["KEEL_RECORDED_REPOSITORY"] = try String(contentsOf: fixture, encoding: .utf8)
        }
        app.launch()
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 10))
        app.buttons["New chat"].tap()
        let open = app.buttons["attachRepository"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["githubSignIn"].waitForExistence(timeout: 5))
        capture(app, "GitHub sign-in entry")
        app.buttons["githubManualRepository"].tap()
        XCTAssertTrue(app.textFields["githubRepository"].waitForExistence(timeout: 5))
        for name in ["githubRepository", "githubBranch"] {
            let field = app.textFields[name]
            if let text = field.value as? String, !text.isEmpty, text != field.placeholderValue {
                field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
            }
        }
        capture(app, "GitHub repository setup")

        app.buttons["connectGitHubRepository"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Enter owner/repository")).firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["githubRepository"]
        field.tap()
        field.typeText("octocat/Hello-World\n")
        let browse = app.buttons["browseRepositoryFiles"]
        XCTAssertTrue(browse.waitForExistence(timeout: 40))
        capture(app, "GitHub immutable repository version")
        browse.tap()
        let readme = app.buttons["README"]
        XCTAssertTrue(readme.waitForExistence(timeout: 40))
        readme.tap()
        let content = app.staticTexts["repositoryFileContent"]
        XCTAssertTrue(content.waitForExistence(timeout: 40))
        XCTAssertTrue(content.label.contains("Hello World!"))
        print("\(recorded ? "Recorded" : "Live") GitHub UI: opened octocat/Hello-World at a pinned commit and read its verified README; no gateway involved.")
        capture(app, "\(recorded ? "Recorded" : "Live") GitHub README")
        // The chat's menu button sits behind this sheet, so pick each back button by its label.
        for previous in ["Hello-World", "GitHub"] {
            app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", [previous, "Back"])).firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["useChatRepository"].waitForExistence(timeout: 5))
        app.buttons["useChatRepository"].tap()
        let attached = app.buttons["attachRepository"]
        XCTAssertTrue(attached.waitForExistence(timeout: 5))
        XCTAssertTrue(attached.label.contains("octocat/Hello-World"))
        capture(app, "Repository attached to on-device chat")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["attachRepository"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["attachRepository"].label.contains("octocat/Hello-World"))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
