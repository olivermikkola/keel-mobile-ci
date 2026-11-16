import XCTest
@testable import KeelMobile

final class RuntimeRouterTests: XCTestCase {
    func testMLXIsUsedOnlyForLFM3WhenSwitchedOnAndDownloaded() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: models) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "router-\(UUID().uuidString)"))
        let router = RuntimeRouter(llama: LocalInference(), modelsDirectory: models, defaults: defaults)
        let lfm3 = try XCTUnwrap(LocalModel.catalog.first { $0.id == "lfm3" })
        let bonsai = try XCTUnwrap(LocalModel.catalog.first { $0.id == "4B" })

        XCTAssertFalse(router.usesMLX(lfm3), "Off by default")
        defaults.set(true, forKey: RuntimeRouter.useMLXKey)
        XCTAssertFalse(router.usesMLX(lfm3), "On, but the MLX model is not downloaded")

        // Sparse files of the pinned sizes stand in for the download.
        let pack = MLXModelPack.lfm3, folder = pack.directory(in: models)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in pack.files {
            let url = folder.appendingPathComponent(file.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes)); try handle.close()
        }
        XCTAssertTrue(router.usesMLX(lfm3))
        XCTAssertFalse(router.usesMLX(bonsai), "Only the model the MLX pack matches")
        XCTAssertFalse(router.usesMLX(nil))
        defaults.set(false, forKey: RuntimeRouter.useMLXKey)
        XCTAssertFalse(router.usesMLX(lfm3))
        XCTAssertFalse(router.lastReplyUsedMLX)
    }

    @MainActor
    func testTheAppChatUsesTheRouter() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path)
        let mirror = Mirror(reflecting: chat)
        XCTAssertTrue(mirror.children.contains { $0.label == "generator" && $0.value is RuntimeRouter })
    }
}
