import AVFoundation
import XCTest
@testable import KeelMobile

/// Renders a real `.mp4` from a storyboard: two pictures, a camera move, an
/// overlay and one narrated scene, then reads the file back.
final class ShortVideoRendererTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("short-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A solid picture, the size of a chat photo.
    private func picture(_ name: String, _ colour: UIColor, size: CGSize) throws -> URL {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        let url = folder.appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    /// One second of tone as AAC, as the narration engine will hand over.
    private func narration(seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent("line.m4a")
        let rate = 24_000.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { samples[i] = Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.3) }
        try file.write(from: buffer)
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testRendersPicturesMotionOverlayAndNarrationIntoAnMP4() async throws {
        let red = try picture("red.png", .red, size: CGSize(width: 768, height: 768))
        let blue = try picture("blue.png", .blue, size: CGSize(width: 1024, height: 512))
        let line = try narration(seconds: 2.0)
        let arguments = try ShortVideoRequest.arguments([
            "path": "storm.mp4",
            "scenes": "image: red.png\nsay: Still standing.\noverlay: STILL STANDING THROUGH THE STORM\nmotion: slow_zoom\n\nimage: blue.png\nsay: Waves.\nmotion: pan_left",
        ])
        let output = folder.appendingPathComponent("out/storm.mp4")
        var progressSeen = 0.0
        let began = Date()
        let rendered = try await ShortVideoRenderer.render(
            plan: ShortVideoRequest.plan(arguments),
            picture: { ["red.png": red, "blue.png": blue][$0] },
            narration: [line, nil],
            to: output,
            progress: { progressSeen = $0 })
        let seconds = Date().timeIntervalSince(began)

        // Scene one is as long as its narration plus the pause; scene two keeps its estimate.
        XCTAssertEqual(rendered.clips[0].duration, 2.0 + ShortVideoRequest.RenderPlan.narrationPad, accuracy: 0.05)
        XCTAssertEqual(rendered.clips[1].duration, ShortVideoRequest.RenderPlan.minimumClipSeconds)
        XCTAssertEqual(progressSeen, 1)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, rendered.totalSeconds, accuracy: 0.1)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "narration track")

        // Frames: red with the yellow overlay in scene one, plain blue in scene two.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let top = pixel(first, x: first.width / 2, y: first.height / 6)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 60)
        var yellow = 0
        for y in stride(from: first.height * 52 / 100, to: first.height * 76 / 100, by: 8) {
            for x in stride(from: first.width / 10, to: first.width * 9 / 10, by: 8) {
                let p = pixel(first, x: x, y: y)
                if p.r > 220, p.g > 190, p.b < 90 { yellow += 1 }
            }
        }
        XCTAssertGreaterThan(yellow, 50, "overlay text is drawn in the lower third")
        let second = try await generator.image(at: CMTime(seconds: rendered.clips[1].start + 0.5, preferredTimescale: 600)).image
        let middle = pixel(second, x: second.width / 2, y: second.height / 2)
        XCTAssertGreaterThan(middle.b, 200); XCTAssertLessThan(middle.r, 60)

        let bytes = try XCTUnwrap(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("Short video proof: \(String(format: "%.2f", duration)) s 1080x1920 H.264 + AAC narration, \(bytes) bytes, rendered in \(String(format: "%.1f", seconds)) s (simulator CPU).")
    }

    func testStoppingSavesNothing() async throws {
        let red = try picture("red.png", .red, size: CGSize(width: 64, height: 64))
        let arguments = try ShortVideoRequest.arguments(["path": "x.mp4", "scenes": "image: red.png\nsay: One two three four five six seven."])
        let output = folder.appendingPathComponent("x.mp4")
        do {
            _ = try await ShortVideoRenderer.render(plan: ShortVideoRequest.plan(arguments), picture: { _ in red }, narration: [nil],
                                                    to: output, shouldContinue: { false })
            XCTFail("should stop")
        } catch let failure as ShortVideoRenderer.Failure {
            XCTAssertEqual(failure, .stopped)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testAMissingPictureIsNamed() async throws {
        let arguments = try ShortVideoRequest.arguments(["path": "x.mp4", "scenes": "image: gone.png\nsay: Hello."])
        do {
            _ = try await ShortVideoRenderer.render(plan: ShortVideoRequest.plan(arguments), picture: { _ in nil }, narration: [nil],
                                                    to: folder.appendingPathComponent("x.mp4"))
            XCTFail("should fail")
        } catch let failure as ShortVideoRenderer.Failure {
            XCTAssertEqual(failure, .image("gone.png"))
        }
    }
}
