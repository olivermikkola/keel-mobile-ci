import AVFoundation
import XCTest
@testable import KeelMobile

/// An HTML page with renderFrame(t) becomes a video whose frames follow t.
@MainActor
final class HTMLMotionCaptureTests: XCTestCase {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testAMotionPageBecomesAVideoWhoseFramesFollowTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("html-motion-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        // Half size keeps CI quick; the phone benchmark uses 1080×1920.
        let stats = try await HTMLMotionCapture().render(html: HTMLMotionCapture.benchmarkPage(seconds: 1), seconds: 1,
                                                         width: 540, height: 960, to: url)
        XCTAssertEqual(stats.frames, 30)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 540, height: 960))

        let frames = AVAssetImageGenerator(asset: asset)
        frames.requestedTimeToleranceBefore = .zero
        frames.requestedTimeToleranceAfter = .zero
        let early = try await frames.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let late = try await frames.image(at: CMTime(seconds: 0.85, preferredTimescale: 600)).image
        // The top-left marker is red before t = 0.5 s and blue after.
        let before = pixel(early, x: 10, y: 10), after = pixel(late, x: 10, y: 10)
        XCTAssertGreaterThan(before.r, 180, "\(before)"); XCTAssertLessThan(before.b, 90, "\(before)")
        XCTAssertGreaterThan(after.b, 180, "\(after)"); XCTAssertLessThan(after.r, 90, "\(after)")
        // And the page is not blank: the title is white in the middle once it has flown in.
        let title = (0..<20).map { pixel(late, x: 120 + $0 * 15, y: Int(Double(late.height) * 0.40)) }
        XCTAssertTrue(title.contains { $0.r > 200 && $0.g > 200 && $0.b > 200 }, "white title text in the frame")
        print("HTML motion proof (simulator, 540x960): \(stats.summary)")
    }

    func testAPageWithoutRenderFrameIsRefused() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("html-motion-\(UUID().uuidString).mp4")
        do {
            _ = try await HTMLMotionCapture().render(html: "<p>static</p>", seconds: 1, width: 270, height: 480, to: url)
            XCTFail("needs renderFrame")
        } catch HTMLMotionCapture.Failure.noRenderFrame {
        } catch {
            XCTFail("\(error)")
        }
    }
}
