import XCTest
import UIKit
@testable import KeelMobile

/// Opt-in: makes a real picture with the pinned Core ML image model. Ordinary
/// CI skips it (a 1.1 GB download). It runs on the simulator's CPU with a few
/// steps, so it proves the whole path (tokenizer, text encoder, U-Net,
/// scheduler, decoder, PNG), never phone speed, heat or the Neural Engine.
final class ImageSmokeTests: XCTestCase {
    private func installedFixture() throws -> (pack: ImageModelPack, folder: URL) {
        guard let fixtures = Bundle(for: Self.self).url(forResource: "fixtures", withExtension: nil) else {
            throw XCTSkip("Opt-in image model fixture is absent")
        }
        for pack in ImageModelPack.allPacks {
            let folder = fixtures.appendingPathComponent("image").appendingPathComponent(pack.id)
            if pack.missing(in: folder).isEmpty {
                return (pack, folder)
            }
        }
        throw XCTSkip("Opt-in image model fixture is absent")
    }

    func testARealPictureComesOutOfThePinnedModel() async throws {
        let (pack, folder) = try installedFixture()
        let runtime = ImageRuntime()
        let request = try ImageRequest.arguments(["prompt": "a red fox in the snow, watercolour", "path": "fox.png"], seed: 7)
        let steps = StepLog()
        let started = Date()
        let first = try await runtime.png(for: request, modelFolder: folder, pack: pack, computeUnits: .cpuOnly, steps: 4) { step, count in
            steps.add(step, count); return true
        }
        let seconds = Date().timeIntervalSince(started)
        let data = try XCTUnwrap(first)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(steps.values.map(\.0), [0, 1, 2, 3, 4], "Called before each step and once before decoding")
        XCTAssertTrue(steps.values.allSatisfy { $0.1 == 4 })

        // A picture, not a flat or broken frame: the pixels vary and are not all black or white.
        let stats = try Self.brightness(of: image)
        XCTAssertGreaterThan(stats.spread, 12, "\(stats)")
        XCTAssertGreaterThan(stats.mean, 15, "\(stats)")
        XCTAssertLessThan(stats.mean, 240, "\(stats)")

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "Generated image - 4 steps on the simulator CPU"; attachment.lifetime = .keepAlways
        add(attachment)

        // Stopping before the first step gives nothing, and no error.
        let stopped = try await runtime.png(for: request, modelFolder: folder, pack: pack, computeUnits: .cpuOnly, steps: 4) { _, _ in false }
        XCTAssertNil(stopped)

        // A smaller size is the same picture scaled down.
        let small = try ImageRuntime.png(image, side: 256)
        XCTAssertEqual(UIImage(data: small)?.cgImage?.width, 256)
        print("Image smoke: 512x512 PNG, \(data.count) bytes, 4 steps in \(Int(seconds)) s on the simulator CPU; mean brightness \(Int(stats.mean)), spread \(Int(stats.spread)).")
    }

    /// Mean and standard deviation of the picture's brightness, 0…255.
    private static func brightness(of image: CGImage) throws -> (mean: Double, spread: Double) {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int, Int)] = []
    func add(_ step: Int, _ count: Int) { lock.lock(); stored.append((step, count)); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return stored }
}
