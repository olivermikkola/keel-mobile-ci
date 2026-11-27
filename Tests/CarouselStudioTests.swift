import XCTest
import UIKit
@testable import KeelMobile

/// The Carousels screen without its UI: two photos and a sentence go in; a
/// scripted model writes the slides and each is drawn from HTML into a
/// 1080×1350 PNG that the gallery keeps.
@MainActor
final class CarouselStudioTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("carousel-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func photos() -> [Data] {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return [UIColor.systemTeal, UIColor.systemOrange].map { colour in
            UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200), format: format).image { context in
                colour.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
            }.jpegData(compressionQuality: 0.9)!
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testTwoPhotosAndASentenceBecomeFourSlideImages() async throws {
        let gallery = CarouselGallery(directory: folder.appendingPathComponent("studio"))
        let names = try gallery.addPhotos(photos())
        let model = ScriptedCarouselModel(["""
        1. Your phone can do this | No internet, no cloud, just your iPhone.
        2. Models that fit | Pick one and it runs right here.
        3. Apps for real work | Docs, sheets and slides with offline viewers.
        4. Try it tonight | Join the TestFlight and see for yourself.
        """])
        let chat = LocalChat(transcript: folder.appendingPathComponent("chat/chat.json"), generator: model)
        let maker = CarouselMaker(look: { urls in urls.map { _ in "screenshot" } })
        let textModel = try XCTUnwrap(LocalModel.catalog.first { $0.visionFile == nil })
        maker.make(description: "Keel on your phone", photos: names, chat: chat, model: textModel,
                   modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)

        let item = try XCTUnwrap(gallery.items.first)
        XCTAssertEqual(item.slides.map(\.kind), [.cover, .photo, .photo, .closing])
        XCTAssertEqual(item.images.count, 4)
        let prompts = await model.prompts
        XCTAssertTrue(prompts[0].contains("Write exactly 4 lines"))
        XCTAssertTrue(prompts[0].contains("Photo 2: screenshot"))

        let cover = try XCTUnwrap(UIImage(contentsOfFile: gallery.url(item.images[0]).path)?.cgImage)
        XCTAssertEqual(cover.width, 1080)
        XCTAssertEqual(cover.height, 1350)
        // White headline text sits in the lower half, over the darkened photo.
        var white = 0
        for y in stride(from: cover.height / 2, to: cover.height, by: 6) {
            for x in stride(from: 60, to: cover.width - 60, by: 6) {
                let p = pixel(cover, x: x, y: y)
                if p.r > 230, p.g > 230, p.b > 230 { white += 1 }
            }
        }
        XCTAssertGreaterThan(white, 200, "the headline is drawn")
        XCTAssertEqual(CarouselGallery(directory: gallery.directory).items, gallery.items, "kept across launches")
        print("Carousel proof: 2 photos + sentence -> scripted slides -> \(item.images.count) slides drawn from HTML at \(cover.width)x\(cover.height), \(white) white headline samples on the cover")
        gallery.delete(item)
        XCTAssertTrue(gallery.items.isEmpty)
    }
}

private actor ScriptedCarouselModel: LocalGenerating {
    private var outputs: [String]
    private(set) var prompts = [String]()
    init(_ outputs: [String]) { self.outputs = outputs }

    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        prompts.append(request.prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }

    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        prompts.append(prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }
}
