import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortVideoManifestTests: XCTestCase {
    func testAManifestKeepsTheRenderedPlanAndItsStoryboard() throws {
        let arguments = try ShortVideoRequest.arguments([
            "path": "storm.mp4", "title": "Storm", "voice": "am_adam",
            "scenes": "image: a.png\nsay: Still standing.\noverlay: STILL STANDING\nmotion: slow_zoom\n\nimage: b.png\nsay: Waves.",
        ])
        let rendered = ShortVideoRequest.plan(arguments).retimed(narrationSeconds: [2.0, nil])
        let manifest = ShortVideoManifest(plan: rendered)
        let decoded = try JSONDecoder().decode(ShortVideoManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.plan, rendered, "the draft screen sees the lengths it was rendered at")
        XCTAssertEqual(decoded.storyboard, "image: a.png\nsay: Still standing.\noverlay: STILL STANDING\nmotion: slow_zoom\n\nimage: b.png\nsay: Waves.")
        // The storyboard parses back into the same scenes, so the model can edit and re-send it.
        let again = try ShortVideoRequest.arguments(["path": "storm.mp4", "scenes": decoded.storyboard])
        XCTAssertEqual(again.scenes, arguments.scenes)
    }
}
