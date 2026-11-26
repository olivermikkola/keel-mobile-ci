import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortVideoTimelineTests: XCTestCase {
    private func plan() throws -> ShortVideoRequest.RenderPlan {
        let args = try ShortVideoRequest.arguments([
            "path": "storm.mp4",
            "scenes": "image: a.png\nsay: Still standing through the storm.\noverlay: STILL STANDING\nmotion: slow_zoom\n\nimage: b.png\nsay: Waves.\n\nimage: c.png\nsay: The sea keeps coming, again and again.",
        ])
        return ShortVideoRequest.plan(args)
    }

    func testClipsFollowTheRealNarration() throws {
        let original = try plan()
        let timed = original.retimed(narrationSeconds: [2.0, 0.4, nil])
        XCTAssertEqual(timed.clips.map(\.duration), [2.35, 1.5, original.clips[2].duration], "pad, minimum, estimate kept")
        XCTAssertEqual(timed.clips.map(\.start), [0, 2.35, 3.85])
        XCTAssertEqual(timed.totalSeconds, 3.85 + original.clips[2].duration, accuracy: 1e-9)
        XCTAssertEqual(timed.clips.map(\.overlay), original.clips.map(\.overlay))
        XCTAssertEqual(timed.width, 1080); XCTAssertEqual(timed.height, 1920)
    }

    func testFrameCounts() {
        XCTAssertEqual(ShortVideoRequest.RenderPlan.frameCount(seconds: 2.35), 71)
        XCTAssertEqual(ShortVideoRequest.RenderPlan.frameCount(seconds: 0), 1)
    }

    /// Every crop has the canvas's shape and stays inside the picture.
    func testCropsFillTheCanvasAndStayInsideThePicture() {
        let pictures: [(Double, Double)] = [(768, 768), (768, 1024), (1024, 512), (512, 2000)]
        for motion in ShortVideoRequest.Motion.allCases {
            for (w, h) in pictures {
                for step in 0...10 {
                    let rect = motion.cropRect(imageWidth: w, imageHeight: h, canvasWidth: 1080, canvasHeight: 1920, progress: Double(step) / 10)
                    XCTAssertEqual(rect.width / rect.height, 1080.0 / 1920.0, accuracy: 1e-9, "\(motion) \(w)x\(h)")
                    XCTAssertGreaterThanOrEqual(rect.minX, -1e-9); XCTAssertGreaterThanOrEqual(rect.minY, -1e-9)
                    XCTAssertLessThanOrEqual(rect.maxX, w + 1e-9); XCTAssertLessThanOrEqual(rect.maxY, h + 1e-9)
                }
            }
        }
    }

    func testCameraMoves() {
        let crop = { (motion: ShortVideoRequest.Motion, progress: Double) in
            motion.cropRect(imageWidth: 1000, imageHeight: 1000, canvasWidth: 1080, canvasHeight: 1920, progress: progress)
        }
        XCTAssertEqual(crop(.none, 0), crop(.none, 1))
        // Zoom closes in by 12 %, centred.
        XCTAssertEqual(crop(.slowZoom, 0).width / crop(.slowZoom, 1).width, 1.12, accuracy: 1e-9)
        XCTAssertEqual(crop(.slowZoom, 1).midX, 500, accuracy: 1e-9)
        // Pans drift opposite ways and are eased (no jump at the start).
        XCTAssertGreaterThan(crop(.panLeft, 0).minX, crop(.panLeft, 1).minX)
        XCTAssertLessThan(crop(.panRight, 0).minX, crop(.panRight, 1).minX)
        XCTAssertEqual(crop(.panLeft, 0.01).minX, crop(.panLeft, 0).minX, accuracy: 0.5)
    }

    func testPhotoNamesAreUniqueAndStable() {
        XCTAssertEqual(ShortVideoMediaIndex.photoNames(["IMG_1.HEIC", "Photo.jpg", "Photo.jpg", "Photo.jpg"]),
                       ["img_1.heic", "photo.jpg", "photo-2.jpg", "photo-3.jpg"])
        XCTAssertEqual(ShortVideoMediaIndex.photoNames(["Photo.jpg"], taken: ["photo.jpg"]), ["photo-2.jpg"])
        XCTAssertEqual(ShortVideoMediaIndex.photoNames(["notes.txt"]), ["photo-1.jpg"])
    }
}
