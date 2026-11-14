import XCTest

final class GitHubConnectionUITests: XCTestCase {
    func testConnectedAccountSearchAndRepositorySelection() throws { try exercise(largeText: false) }
    func testConnectedAccountAtLargestText() throws { try exercise(largeText: true) }
    private func exercise(largeText: Bool) throws {
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-recording", withExtension: "json"))
        let data = try Data(contentsOf: fixture)
        var responses = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        responses["/user"] = ["id":7,"login":"fixture-owner"]
        responses["/user/repos"] = [
            ["id":42,"full_name":"octocat/Hello-World","default_branch":"master","private":false],
            ["id":43,"full_name":"fixture-owner/Private-project","default_branch":"develop","private":true]]
        responses["/config"] = ["configured":true,"install_url":"https://github.com/apps/keel-fixture/installations/new"]
        app.launchArguments += ["--recorded-repository", "--recorded-github-account"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["KEEL_RECORDED_REPOSITORY"] = String(decoding: try JSONSerialization.data(withJSONObject: responses), as: UTF8.self)
        app.launch()
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 10)); app.buttons["New chat"].tap()
        app.openFromMenu("connections")
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        let open = app.buttons["openGitHubRepository"]
        // At the largest text size the introduction fills the first page.
        // Form builds the connection rows as they scroll into view.
        for _ in 0..<4 where !open.exists || !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        // The first URLSession + Keychain-adjacent account load can take well
        // over 10 seconds on a cold CI simulator. SwiftUI may expose this Label
        // as a button/other rather than StaticText, so match any element.
        let account = app.descendants(matching: .any).matching(identifier: "githubConnectedAccount").firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 30))
        // At accessibility sizes the account header fills the screen and the
        // lazy Form has not built the repository rows yet.
        app.swipeUp()
        let repo = app.buttons["githubRepositoryChoice-42"]
        XCTAssertTrue(repo.waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = largeText ? "GitHub account picker largest text" : "GitHub account picker"
        attachment.lifetime = .keepAlways; add(attachment)
        let search = app.textFields["githubRepositorySearch"]
        if !search.isHittable { app.swipeUp() }
        search.tap(); search.typeText("Hello-World\n")
        XCTAssertFalse(app.buttons["githubRepositoryChoice-43"].exists)
        if !repo.isHittable { app.swipeUp() }
        repo.tap()
        let browse = app.buttons["browseRepositoryFiles"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        print("Recorded GitHub account UI: loaded authenticated repository choices, filtered them, and opened a pinned snapshot. Browser OAuth and real GitHub authorization remain separate checks.")
    }
}
