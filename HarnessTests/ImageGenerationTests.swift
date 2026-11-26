import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ImageGenerationTests: XCTestCase {
    /// Records loads and unloads across both models, and fails if both are ever in memory.
    final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        private var loaded: Set<String> = []
        private(set) var overlap = false
        func load(_ name: String) { lock.lock(); events.append("load \(name)"); loaded.insert(name); if loaded.count > 1 { overlap = true }; lock.unlock() }
        func unload(_ name: String) { lock.lock(); events.append("unload \(name)"); loaded.remove(name); lock.unlock() }
    }
    final class Fake: ResidentModel, @unchecked Sendable {
        let name: String, ledger: Ledger, failLoad: Bool
        init(_ name: String, _ ledger: Ledger, failLoad: Bool = false) { self.name = name; self.ledger = ledger; self.failLoad = failLoad }
        func load() async throws { if failLoad { throw ImageRequest.Problem.memory }; ledger.load(name) }
        func unload() async { ledger.unload(name) }
    }
    struct Boom: Error {}

    func testModelsTakeTurnsAndNeverOverlap() async throws {
        let ledger = Ledger()
        let swap = ModelSwap(chat: Fake("chat", ledger), image: Fake("image", ledger))
        try await swap.useChat()
        try await swap.useChat()
        let size = try await swap.withImage { 512 }
        XCTAssertEqual(size, 512)
        let afterImage = await swap.resident
        XCTAssertEqual(afterImage, .none, "The image model leaves memory right after its run")
        try await swap.useChat()
        XCTAssertEqual(ledger.events, ["load chat", "unload chat", "load image", "unload image", "load chat"])
        XCTAssertFalse(ledger.overlap)
    }

    func testAFailedOrCancelledRunStillUnloadsTheImageModel() async throws {
        let ledger = Ledger()
        let swap = ModelSwap(chat: Fake("chat", ledger), image: Fake("image", ledger))
        try await swap.useChat()
        do { _ = try await swap.withImage { () async throws -> Int in throw Boom() }; XCTFail() } catch is Boom {}
        do { _ = try await swap.withImage { () async throws -> Int in throw CancellationError() }; XCTFail() } catch is CancellationError {}
        let resident = await swap.resident
        XCTAssertEqual(resident, .none)
        XCTAssertEqual(ledger.events, ["load chat", "unload chat", "load image", "unload image", "load image", "unload image"])
        XCTAssertFalse(ledger.overlap)
    }

    func testAnImageModelThatCannotLoadLeavesNothingLoaded() async throws {
        let ledger = Ledger()
        let swap = ModelSwap(chat: Fake("chat", ledger), image: Fake("image", ledger, failLoad: true))
        try await swap.useChat()
        do { _ = try await swap.withImage { 1 }; XCTFail() } catch { XCTAssertEqual(error as? ImageRequest.Problem, .memory) }
        let resident = await swap.resident
        XCTAssertEqual(resident, .none)
        try await swap.useChat()
        XCTAssertEqual(ledger.events, ["load chat", "unload chat", "load chat"])
    }

    func testArguments() throws {
        let ok = try ImageRequest.arguments(["prompt": "  a red   fox in snow, watercolour ", "path": "art/fox.png"], seed: 7)
        XCTAssertEqual(ok, ImageRequest.Arguments(prompt: "a red fox in snow, watercolour", path: "art/fox.png", size: 512, seed: 7, style: nil))
        XCTAssertEqual(try ImageRequest.arguments(["prompt": "cat", "path": "cat.PNG", "size": "256"], seed: 1).size, 256)
        let styled = try ImageRequest.arguments(["prompt": "cat", "path": "cat.png", "style": " Illustration "], seed: 3)
        XCTAssertEqual(styled.style, .illustration)
        XCTAssertNil(try ImageRequest.arguments(["prompt": "cat", "path": "cat.png", "style": "  "], seed: 3).style)
        for (raw, problem) in [
            (["prompt": "cat"], ImageRequest.Problem.arguments),
            (["prompt": "cat", "path": "cat.png", "steps": "50"], .arguments),
            (["prompt": " ", "path": "cat.png"], .prompt),
            (["prompt": String(repeating: "a", count: 301), "path": "cat.png"], .prompt),
            (["prompt": "cat", "path": "cat.jpg"], .path),
            (["prompt": "cat", "path": "../cat.png"], .path),
            (["prompt": "cat", "path": "/cat.png"], .path),
            (["prompt": "cat", "path": ".png"], .path),
            (["prompt": "cat", "path": "cat.png", "size": "1024"], .size),
            (["prompt": "cat", "path": "cat.png", "style": "oil-painting"], .style),
        ] as [([String: String], ImageRequest.Problem)] {
            XCTAssertThrowsError(try ImageRequest.arguments(raw, seed: 0), "\(raw)") { XCTAssertEqual($0 as? ImageRequest.Problem, problem) }
        }
    }

    func testMemoryPlanForAnEightGigabytePhone() {
        let phone: UInt64 = 8_000_000_000
        let bonsai9B: UInt64 = 2_556_640_128 + 3_290_000_000 / 2, diffusion: UInt64 = 1_300_000_000
        XCTAssertTrue(ImageRequest.fits(imageModelBytes: diffusion, physicalMemoryBytes: phone), "Alone, the image model fits")
        XCTAssertFalse(ImageRequest.bothFit(chatModelBytes: bonsai9B, imageModelBytes: diffusion, physicalMemoryBytes: phone), "Together they do not")
        XCTAssertFalse(ImageRequest.fits(imageModelBytes: 4_500_000_000, physicalMemoryBytes: phone))
    }

    func testToolCallParsesThroughTheGrammarFormat() throws {
        let line = ImageRequest.tool
        XCTAssertEqual(AgentPrompt.toolName(line), "generate_image")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let fn = try XCTUnwrap(obj["function"] as? [String: Any])
        let params = try XCTUnwrap(fn["parameters"] as? [String: Any])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertNotNil(props["style"])

        let grammar = ToolCallGrammar.make(tools: [line], family: .bonsai)
        XCTAssertTrue(grammar?.text.contains("generate_image") == true)
        let args = try ImageRequest.arguments(["prompt": "cat", "path": "cat.png"], seed: 42)
        XCTAssertEqual(ImageRequest.result(args, seconds: 31.4),
                       "Saved cat.png (512×512, 8 steps, seed 42) in 31 s. The user can open it in the chat.")
        XCTAssertEqual(ImageRequest.result(args, seconds: 4.2, steps: 0, engine: "Apple Image Playground · illustration"),
                       "Saved cat.png (512×512, Apple Image Playground · illustration) in 4 s. The user can open it in the chat.")
    }

    func testDreamShaperLCMPackIsPinnedFileByFile() throws {
        let pack = ImageModelPack.dreamShaper8LCM
        XCTAssertEqual(ImageModelPack.defaultPack, pack)
        XCTAssertEqual(pack.engine, .lcm)
        XCTAssertEqual(pack.defaultSteps, 8)
        XCTAssertEqual(pack.defaultGuidance, 2.0)
        XCTAssertEqual(pack.padToken, "<|endoftext|>")
        XCTAssertEqual(pack.files.count, 17)
        XCTAssertEqual(pack.totalBytes, 995_565_455)
        XCTAssertTrue(pack.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        XCTAssertEqual(Set(pack.files.map(\.path)).count, pack.files.count)
        let weights = try XCTUnwrap(pack.files.first { $0.path == "Unet.mlmodelc/weights/weight.bin" })
        XCTAssertEqual(pack.url(for: weights).absoluteString,
                       "https://huggingface.co/LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2/resolve/145761e40713fa2cb0348a90fc721109f2a98083/Unet.mlmodelc/weights/weight.bin")
        XCTAssertFalse(pack.url(for: weights).absoluteString.contains("//Unet"), "Empty remoteFolder must not produce a double slash")
        XCTAssertTrue(ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: 8_000_000_000))
    }

    func testTheImageModelPackIsPinnedFileByFile() throws {
        let pack = ImageModelPack.stableDiffusion21
        XCTAssertEqual(pack.engine, .standard)
        XCTAssertEqual(pack.defaultSteps, 20)
        XCTAssertEqual(pack.padToken, "!", "SD 2.1 OpenCLIP pads with '!' (token ID 0), not <|endoftext|>")
        XCTAssertEqual(pack.files.count, 17)
        XCTAssertEqual(pack.totalBytes, 1_072_887_285)
        XCTAssertTrue(pack.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        XCTAssertEqual(Set(pack.files.map(\.path)).count, pack.files.count)
        let weights = try XCTUnwrap(pack.files.first { $0.path == "Unet.mlmodelc/weights/weight.bin" })
        XCTAssertEqual(pack.url(for: weights).absoluteString,
                       "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/dca5f2fda9c5143c71aded72bbb4ce39f3c2cc9c/split_einsum_v2/compiled/Unet.mlmodelc/weights/weight.bin")
        XCTAssertTrue(ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: 8_000_000_000))

        // A folder holding only some files reports the rest as missing.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(pack.missing(in: folder).count, 17)
        let small = try XCTUnwrap(pack.files.first { $0.path == "TextEncoder.mlmodelc/analytics/coremldata.bin" })
        let file = folder.appendingPathComponent(small.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Int(small.bytes)).write(to: file)
        XCTAssertEqual(pack.missing(in: folder).count, 16)
        try Data(count: 3).write(to: file)
        XCTAssertEqual(pack.missing(in: folder).count, 17, "A file of the wrong size is missing")
    }

    /// scripts/prepare-image-model.py downloads from this JSON; it must pin the same files as the app.
    func testScriptFixtureMatchesTheAppPack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/image-models.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture not bundled in this test run") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        for pack in ImageModelPack.allPacks {
            let entry = try XCTUnwrap(json[pack.id], "Missing \(pack.id) in image-models.json")
            XCTAssertEqual(entry["repository"] as? String, pack.repository)
            XCTAssertEqual(entry["revision"] as? String, pack.revision)
            XCTAssertEqual(entry["remoteFolder"] as? String, pack.remoteFolder)
            let files = try XCTUnwrap(entry["files"] as? [[String: Any]])
            XCTAssertEqual(files.map { $0["path"] as? String }, pack.files.map(\.path))
            XCTAssertEqual(files.map { ($0["bytes"] as? NSNumber)?.int64Value }, pack.files.map(\.bytes))
            XCTAssertEqual(files.map { $0["sha256"] as? String }, pack.files.map(\.sha256))
        }
    }
}
