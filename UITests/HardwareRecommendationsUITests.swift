import XCTest

final class HardwareRecommendationsUITests: XCTestCase {
    func testRecommendationsShelfShowsPlainSummaryAndTrendingScreenOpens() {
        let app = XCUIApplication()
        app.launch()
        app.openFromMenu("models")

        let headline = app.staticTexts["recommendationHeadline-4B"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertTrue(headline.label.contains("Fits your"), headline.label)
        for jargon in ["GGUF", "Q2_0", "Q4_K_M", "quantized", "KV cache", "context length"] {
            XCTAssertFalse(headline.label.localizedCaseInsensitiveContains(jargon), "Unexpected jargon \(jargon) in \(headline.label)")
        }

        let trending = app.buttons["openHardwareTrending"]
        for _ in 0..<10 where !trending.exists || !trending.isHittable { app.swipeUp() }
        XCTAssertTrue(trending.exists && trending.isHittable)
        let modelsShot = XCTAttachment(screenshot: app.screenshot())
        modelsShot.name = "Models recommendations shelf"
        modelsShot.lifetime = .keepAlways
        add(modelsShot)

        trending.tap()
        XCTAssertTrue(app.navigationBars["Trending for hardware"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["onlyFittingTrendingToggle"].waitForExistence(timeout: 5))
        let trendingShot = XCTAttachment(screenshot: app.screenshot())
        trendingShot.name = "Hardware-aware Hugging Face trending"
        trendingShot.lifetime = .keepAlways
        add(trendingShot)
    }
}
