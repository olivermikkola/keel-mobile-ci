import XCTest
import UIKit

final class IPadLayoutUITests: XCTestCase {
    func testModelSetupAndConnectionsInLandscapeAndPortrait() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Tablet layout requires an iPad simulator")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["setupLocalModel"].waitForExistence(timeout: 10))
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["setupLocalModel"].isHittable)
        capture(app, "iPad landscape on-device chat")
        app.buttons["setupLocalModel"].tap()
        let download = app.buttons["Download Bonsai 2 · 4B"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isHittable)
        capture(app, "iPad landscape local model library")
        app.buttons["Done"].tap()
        app.openFromMenu("connections")
        XCTAssertTrue(app.buttons["openGitHubRepository"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openGitHubRepository"].isHittable)
        XCTAssertTrue(app.buttons["advancedPairing"].isHittable)
        capture(app, "iPad landscape connections")
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["openGitHubRepository"].isHittable)
        capture(app, "iPad portrait connections")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
