import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortVideoMediaTests: XCTestCase {
    func testStoryboardRoundTrip() throws {
        let args = try ShortVideoRequest.arguments([
            "path": "storm.mp4",
            "scenes": """
                image: lighthouse.png
                say: Still standing through the storm.
                overlay: STILL STANDING
                motion: slow_zoom

                image: waves.jpg
                say: The sea keeps coming in.
                """,
            "voice": "af_heart",
            "aspect_ratio": "9:16",
            "title": "Storm",
        ])
        let text = ShortVideoRequest.storyboard(args)
        XCTAssertTrue(text.contains("title: Storm"))
        XCTAssertTrue(text.contains("voice: af_heart"))
        XCTAssertTrue(text.contains("image: lighthouse.png"))
        XCTAssertTrue(text.contains("motion: slow_zoom"))

        let again = try ShortVideoRequest.arguments(storyboard: text, path: "storm.mp4")
        XCTAssertEqual(again.title, "Storm")
        XCTAssertEqual(again.voice.id, "af_heart")
        XCTAssertEqual(again.aspectRatio, .vertical)
        XCTAssertEqual(again.scenes, args.scenes)
    }

    func testStoryboardRoundTripWithoutTitlePreservesVoiceAndAspectRatio() throws {
        let args = try ShortVideoRequest.arguments([
            "path": "wide.mp4",
            "scenes": "image: lighthouse.png\nsay: Wide frame without a title.",
            "voice": "bf_emma",
            "aspect_ratio": "16:9",
        ])
        let text = ShortVideoRequest.storyboard(args)
        XCTAssertFalse(text.contains("title:"))
        XCTAssertTrue(text.contains("voice: bf_emma"))
        XCTAssertTrue(text.contains("aspect_ratio: 16:9"))

        let again = try ShortVideoRequest.arguments(storyboard: text, path: "wide.mp4")
        XCTAssertNil(again.title)
        XCTAssertEqual(again.voice.id, "bf_emma")
        XCTAssertEqual(again.aspectRatio, .landscape)
        XCTAssertEqual(again.scenes, args.scenes)
    }

    func testMediaIndexResolvesAndReportsMissing() throws {
        var index = ShortVideoMediaIndex()
        index.register(path: "Lighthouse.PNG", fileURL: URL(fileURLWithPath: "/tmp/lighthouse.png"), bytes: 12)
        index.register(path: "waves.jpg")

        let hit = try index.resolve("lighthouse.png")
        XCTAssertEqual(hit.path, "Lighthouse.PNG")
        XCTAssertEqual(hit.bytes, 12)

        let args = try ShortVideoRequest.arguments([
            "path": "out.mp4",
            "scenes": """
                image: lighthouse.png
                say: One.

                image: missing.png
                say: Two.
                """,
        ])
        XCTAssertEqual(index.missing(in: args.scenes), ["missing.png"])
        XCTAssertThrowsError(try index.requireAll(in: args)) {
            XCTAssertEqual($0 as? ShortVideoRequest.Problem, .missingImage("missing.png"))
        }

        index.register(path: "missing.png")
        try index.requireAll(in: args)
    }

    func testAttachmentAndGeneratedPathHelpers() {
        XCTAssertEqual(
            ShortVideoMediaIndex.storyboardPath(fromAttachmentFilename: "IMG_0042.HEIC"),
            "img_0042.heic"
        )
        XCTAssertEqual(
            ShortVideoMediaIndex.storyboardPath(fromAttachmentFilename: "My Photo!!.PNG"),
            "my-photo.png"
        )
        XCTAssertNil(ShortVideoMediaIndex.storyboardPath(fromAttachmentFilename: "notes.txt"))

        XCTAssertEqual(
            ShortVideoMediaIndex.storyboardPath(fromGeneratedPath: "art/fox.png", unique: "abcdefgh"),
            "art/fox.png"
        )
        XCTAssertEqual(
            ShortVideoMediaIndex.storyboardPath(fromGeneratedPath: "../bad.png", unique: "abcdefgh"),
            "image-abcdefgh.png"
        )
    }
}
