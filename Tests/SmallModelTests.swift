import XCTest
import CryptoKit
import UIKit
import ImageIO
@testable import KeelMobile

final class SmallModelTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    @MainActor
    func testVisionInstallationNeedsBothVerifiedAssetsAndResumesMissingProjector() async throws {
        let weights = Data("language weights".utf8), vision = Data("vision weights".utf8)
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        let asset = ModelAsset(fileName: "vision.gguf", repository: "owner/model", revision: "pinned", bytes: Int64(vision.count), sha256: hash(vision))
        let model = LocalModel(id: "test-vision", name: "Test vision", bytes: Int64(weights.count), revision: "pinned", sha256: hash(weights),
            detail: "", repository: "owner/model", fileName: "language.gguf", family: .lfm3, visionFile: asset)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try weights.write(to: folder.appendingPathComponent(model.fileName))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let library = ModelLibrary(directory: folder, defaults: defaults, catalog: [model], transferConfiguration: { configuration })
        XCTAssertFalse(library.installed.contains(model.id), "Language weights alone do not make vision ready")
        var fetched = [String]()
        StubProtocol.handler = { request in
            fetched.append(request.url!.lastPathComponent)
            return (200, vision)
        }
        library.install(model)
        for _ in 0..<500 where library.downloading != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.downloading); XCTAssertNil(library.error)
        XCTAssertEqual(fetched, [asset.fileName], "The verified language model must not download again")
        XCTAssertTrue(library.installed.contains(model.id))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(library.visionPath(model))), vision)
        let reopened = ModelLibrary(directory: folder, defaults: defaults, catalog: [model])
        XCTAssertTrue(reopened.installed.contains(model.id))
    }

    @MainActor
    func testPhotoIsBoundedAndStoredSeparatelyFromSavedConversation() throws {
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }.pngData()!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try PhotoAttachment.make(raw, directory: folder)
        let pixels = try XCTUnwrap(PhotoAttachment.load(photo, directory: folder))
        XCTAssertLessThanOrEqual(pixels.count, AttachmentLimits.maxImageBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(pixels as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 768); XCTAssertLessThanOrEqual(image.height, 768)
        let saved = try JSONEncoder().encode(photo)
        XCTAssertLessThan(saved.count, 1024, "Streaming checkpoints retain a photo ID rather than a base64 bitmap")
        let restored = try JSONDecoder().decode(Attachment.self, from: saved)
        XCTAssertEqual(try PhotoAttachment.load(restored, directory: folder), pixels)
        PhotoAttachment.discard([photo], retaining: [try XCTUnwrap(photo.imageID)], directory: folder)
        XCTAssertEqual(try PhotoAttachment.load(photo, directory: folder), pixels, "A photo referenced by another chat must survive")
        PhotoAttachment.discard([photo], directory: folder)
        XCTAssertThrowsError(try PhotoAttachment.load(photo, directory: folder))
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","filename":"note.txt","mimeType":"text/plain","extractedText":"hello","byteSize":5,"source":"file"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Attachment.self, from: legacy).imageID)
    }

    @MainActor
    func testTextModelRefusesPhotoBeforeSavingOrStartingInference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let chat = LocalChat(transcript: file)
        let photo = Attachment(filename: "photo.jpg", mimeType: "image/jpeg", extractedText: "", byteSize: 10, source: .photo, imageID: UUID())
        let model = try XCTUnwrap(LocalModel.catalog.first { $0.id == "minicpm5" })
        chat.send("What is in this photo?", attachments: [photo], model: model, path: URL(fileURLWithPath: "/not-loaded"))
        XCTAssertFalse(chat.running); XCTAssertNotNil(chat.error); XCTAssertTrue(chat.messages.isEmpty)
    }
}
