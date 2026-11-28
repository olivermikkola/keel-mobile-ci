import XCTest

final class SmallModelUITests: XCTestCase {
    func testSmallModelChoicesAndVisionDownloadAreReachable() {
        let app = XCUIApplication(); app.launch(); app.openFromMenu("models")
        for name in ["LFM3 · 1.7B", "LFM3 VL · 2B", "MiniCPM5 · 2B"] {
            let download = app.buttons["Download \(name)"]
            for _ in 0..<10 where !download.exists || !download.isHittable { app.swipeUp() }
            XCTAssertTrue(download.exists && download.isHittable, name)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Small model choice \(name)"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }
}
