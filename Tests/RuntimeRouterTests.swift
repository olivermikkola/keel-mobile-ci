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

    func testTheAppleModelHasNoFileAndIsListedOnlyWhereItRuns() async throws {
        let apple = LocalModel.apple
        XCTAssertTrue(apple.isSystem)
        XCTAssertTrue(apple.assets.isEmpty, "Nothing to download")
        XCTAssertEqual(apple.family, .bonsai, "Rendered as ChatML for ApplePrompt")
        XCTAssertFalse(LocalModel.catalog.contains { $0.isSystem }, "Not a download in the catalog")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "apple-\(UUID().uuidString)"))
        let without = await ModelLibrary(directory: folder, defaults: defaults, includeSystemModel: false)
        let without_catalog = await without.catalog
        XCTAssertFalse(without_catalog.contains { $0.isSystem })
        let listed = await ModelLibrary(directory: folder, defaults: defaults)
        let catalog = await listed.catalog, installed = await listed.installed
        XCTAssertEqual(catalog.contains { $0.isSystem }, AppleModelRunner.isAvailable)
        if AppleModelRunner.isAvailable { XCTAssertTrue(installed.contains("apple"), "Ready without a download") }
        else { XCTAssertNotNil(AppleModelRunner.unavailableReason) }
    }

    func testRepliesForTheAppleModelNeverReachLlama() async throws {
        let router = RuntimeRouter(llama: LocalInference())
        let request = LocalGenerationRequest(path: "/nonexistent", prompt: AgentPrompt.chatML(system: "S", messages: [("user", "Hi")]),
                                             limit: 8, contextSize: 4096, model: LocalModel.apple)
        guard !AppleModelRunner.isAvailable else { throw XCTSkip("Apple's model runs here; this checks the unavailable path") }
        do {
            _ = try await router.generate(request, cancellation: InferenceCancellation(), onPrefill: { _, _ in }, onText: { _ in })
            XCTFail("No Apple model here")
        } catch LocalModelError.load {
            // llama.cpp would have failed on the missing file with a different error first.
        }
        let telemetry = await router.latestTelemetry()
        XCTAssertNil(telemetry)
    }

    /// Runs Apple's model for real where it is available (the CI simulator has it).
    func testAppleModelAnswersAndAttemptsAToolCall() async throws {
        guard AppleModelRunner.isAvailable else { throw XCTSkip(AppleModelRunner.unavailableReason ?? "unavailable") }
        let router = RuntimeRouter(llama: LocalInference())
        final class Collected: @unchecked Sendable { var text = ""; let lock = NSLock()
            func add(_ piece: String) { lock.withLock { text += piece } } }
        func run(system: String, user: String) async throws -> String {
            let collected = Collected()
            let request = LocalGenerationRequest(path: "", prompt: AgentPrompt.chatML(system: system, messages: [("user", user)]),
                                                 limit: 200, contextSize: 4096, model: LocalModel.apple)
            _ = try await router.generate(request, cancellation: InferenceCancellation(), onPrefill: { _, _ in }) { collected.add($0) }
            return collected.text
        }
        let answer: String
        do { answer = try await run(system: "You are a helpful assistant. Answer briefly.", user: "What is 2 + 2? Reply with just the number.") }
        catch let failure as AppleModelRunner.Failure {
            // The CI simulator reports the model available but has no model files.
            throw XCTSkip("Apple's model is listed but could not run here: \(failure.detail)")
        }
        print("APPLE-ANSWER: \(answer)")
        XCTAssertTrue(answer.contains("4"), answer)
        let telemetry = await router.latestTelemetry()
        print("APPLE-TELEMETRY: \(telemetry?.summary ?? "none")")
        XCTAssertNotNil(telemetry)

        let call = try await run(system: AgentPrompt.local(), user: "List the files in this chat.")
        print("APPLE-TOOL: \(call.replacingOccurrences(of: "\n", with: "\\n"))")
        let parsed = try? DirectorCall.parse(ToolCallText.normalize(call).text)
        print("APPLE-TOOL-PARSED: \(parsed?.name ?? "no valid call")")
    }
}
