import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class MLXModelPackTests: XCTestCase {
    func testPackIsPinnedAndComplete() {
        let pack = MLXModelPack.lfm3
        XCTAssertEqual(pack.revision.count, 40)
        XCTAssertTrue(pack.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        for needed in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"] {
            XCTAssertTrue(pack.files.contains { $0.name == needed }, needed)
        }
        XCTAssertEqual(Set(pack.files.map(\.name)).count, pack.files.count)
        XCTAssertEqual(pack.totalBytes, 991_059_565)
        XCTAssertEqual(pack.url(for: pack.files[0]).absoluteString,
                       "https://huggingface.co/LiquidAI/LFM3-1.7B-MLX-4bit/resolve/91f34088d6946482cbcae11b85d4657093618c34/config.json")
        XCTAssertEqual(pack.family, .lfm3)
    }

    func testMissingFilesAreFoundBySize() throws {
        let pack = MLXModelPack.lfm3
        let models = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: models) }
        let directory = pack.directory(in: models)
        XCTAssertTrue(directory.path.hasSuffix("mlx/lfm3-1.7b-mlx-4bit"))
        XCTAssertEqual(pack.missing(in: directory).count, pack.files.count)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 92).write(to: directory.appendingPathComponent("special_tokens_map.json"))
        try Data(count: 10).write(to: directory.appendingPathComponent("config.json"))
        let missing = pack.missing(in: directory).map(\.name)
        XCTAssertFalse(missing.contains("special_tokens_map.json"))
        XCTAssertTrue(missing.contains("config.json"), "A file of the wrong size counts as missing")
    }
}

final class MLXModelPackFixtureTests: XCTestCase {
    /// scripts/prepare-mlx-model.py downloads from this JSON; it must pin the same files as the app.
    func testScriptFixtureMatchesTheAppPack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/mlx-models.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Fixture not bundled in this test run") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let pack = MLXModelPack.lfm3
        let entry = try XCTUnwrap(json[pack.id])
        XCTAssertEqual(entry["repository"] as? String, pack.repository)
        XCTAssertEqual(entry["revision"] as? String, pack.revision)
        let files = try XCTUnwrap(entry["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["name"] as? String }, pack.files.map(\.name))
        XCTAssertEqual(files.map { ($0["bytes"] as? NSNumber)?.int64Value }, pack.files.map(\.bytes))
        XCTAssertEqual(files.map { $0["sha256"] as? String }, pack.files.map(\.sha256))
    }
}
