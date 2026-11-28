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

    func testRemakingWithAChangeReusesPhotoNotesAndDiscardUnusedProtectsSavedPhotos() async throws {
        let gallery = CarouselGallery(directory: folder.appendingPathComponent("studio-revise"))
        let names = try gallery.addPhotos(photos())
        let extra = try XCTUnwrap(try gallery.addPhotos(Array(photos().prefix(1))).first)
        let model = ScriptedCarouselModel([
            """
            1. Your phone can do this | No internet, no cloud, just your iPhone.
            2. Models that fit | Pick one and it runs right here.
            3. Apps for real work | Docs, sheets and slides with offline viewers.
            4. Try it tonight | Join the TestFlight and see for yourself.
            """,
            """
            1. Offline AI in your pocket | Everything runs right on this iPhone.
            2. Models sized to fit | Download once and use without signal.
            3. Built-in offline apps | Preview docs, tables and slides anywhere.
            4. Get the beta | Install Keel on TestFlight today.
            """,
        ])
        let chat = LocalChat(transcript: folder.appendingPathComponent("chat-revise/chat.json"), generator: model)
        let looks = CarouselLookCounter()
        let maker = CarouselMaker(look: { urls in
            looks.count += 1
            return urls.map { _ in "screenshot" }
        })
        let textModel = try XCTUnwrap(LocalModel.catalog.first { $0.visionFile == nil })
        maker.make(description: "Keel on your phone", photos: names, chat: chat, model: textModel,
                   modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)
        let first = try XCTUnwrap(gallery.items.first)
        XCTAssertEqual(first.notes, ["screenshot", "screenshot"])
        XCTAssertEqual(looks.count, 1)

        // Removing an unused photo deletes its file; a photo used by a saved carousel stays.
        gallery.discardUnused(extra)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gallery.url(extra).path))
        gallery.discardUnused(names[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: gallery.url(names[0]).path))

        // Asking for a change reuses photo notes and sends the previous slides + change.
        maker.make(description: first.description, photos: first.photos, from: first, change: "Make the cover punchier",
                   chat: chat, model: textModel, modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)
        XCTAssertEqual(looks.count, 1, "same photos reuse their cached notes")
        let prompts = await model.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("The slides so far:\n1. Your phone can do this | No internet, no cloud, just your iPhone."))
        XCTAssertTrue(prompts[1].contains("Change: Make the cover punchier"))
        XCTAssertEqual(gallery.items.count, 2)
        XCTAssertEqual(gallery.items.first?.slides.first?.headline, "Offline AI in your pocket")
        for made in gallery.items { gallery.delete(made) }
    }
}

private final class CarouselLookCounter: @unchecked Sendable { var count = 0 }

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
