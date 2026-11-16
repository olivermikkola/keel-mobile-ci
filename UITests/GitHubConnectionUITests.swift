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
        // Form scrolling collapses the large navigation title. Recompute the
        // viewport and tap the visible part of the row, rather than its center
        // (which can be covered even when XCTest reports it as hittable).
        func visibleTarget() -> CGRect {
            guard open.exists else { return .null }
            let bounds = app.frame
            let top = app.navigationBars["Connections"].frame.maxY + 8
            let viewport = CGRect(x: bounds.minX + 16, y: top,
                                  width: bounds.width - 32, height: max(0, bounds.maxY - 80 - top))
            return open.frame.intersection(viewport)
        }
        for _ in 0..<8 {
            let visible = visibleTarget()
            if !visible.isNull, visible.height >= 44 { break }
            let above = open.exists && open.frame.maxY <= app.navigationBars["Connections"].frame.maxY + 8
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.5, dy: above ? 0.85 : 0.35)))
        }
        let visible = visibleTarget()
        guard !visible.isNull, visible.height >= 44 else {
            XCTFail("GitHub connection row has no safe visible tap target")
            return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.midX - app.frame.minX, dy: visible.midY - app.frame.minY)).tap()
        XCTAssertTrue(app.navigationBars["GitHub"].waitForExistence(timeout: 5))
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
