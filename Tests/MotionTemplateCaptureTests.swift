import AVFoundation
import XCTest
@testable import KeelMobile

/// The motion templates in real WebKit: each style's words animate in.
@MainActor
final class MotionTemplateCaptureTests: XCTestCase {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func whiteSamples(_ image: CGImage) -> Int {
        var count = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let p = pixel(image, x: x, y: y)
                if p.r > 220, p.g > 220, p.b > 220 { count += 1 }
            }
        }
        return count
    }

    func testEveryStyleAnimatesItsWordsIn() async throws {
        for style in MotionTemplate.Style.allCases {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-\(style.rawValue)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let scene = MotionTemplate.Scene(style: style, headline: "Runs on your phone", caption: "No internet needed", seconds: 1)
            let stats = try await HTMLMotionCapture().render(html: MotionTemplate.html(scene, photo: nil, index: 0, count: 1),
                                                             seconds: 1, width: 270, height: 480, to: url)
            XCTAssertEqual(stats.frames, 30, style.rawValue)
            let frames = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            frames.requestedTimeToleranceBefore = .zero
            frames.requestedTimeToleranceAfter = .zero
            let first = try await frames.image(at: .zero).image
            let later = try await frames.image(at: CMTime(seconds: 0.9, preferredTimescale: 600)).image
            let before = whiteSamples(first), after = whiteSamples(later)
            XCTAssertGreaterThan(after, 40, "\(style.rawValue): the words are on screen")
            XCTAssertGreaterThan(after, before * 3 + 10, "\(style.rawValue): and they animated in (\(before) → \(after))")
            print("Motion template proof: \(style.rawValue) white samples \(before) → \(after), \(stats.summary)")
        }
    }
}
