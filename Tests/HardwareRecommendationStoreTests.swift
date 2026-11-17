import XCTest
@testable import KeelMobile

@MainActor
final class HardwareRecommendationStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hw-rec-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.responseHeaders = nil
        super.tearDown()
    }

    func testCatalogRecommendationsHaveZeroHFJargonAndUpdateAfterMeasuredRun() {
        let dir = tempDir()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let models = ModelLibrary(directory: dir, defaults: defaults, includeSystemModel: false)
        let store = HardwareRecommendationStore(
            modelsDirectory: dir,
            defaults: defaults,
            currentDevice: .iphone15ProA17
        )

        let initial = store.recommendations(for: models, mode: .work)
        XCTAssertEqual(initial.first?.id, "4B")
        XCTAssertTrue(initial.first?.fits == true)
        XCTAssertFalse(initial.first?.calibratedSpeed.isMeasured ?? true)

        for rec in initial {
            let text = (rec.plainHeadline + " " + rec.plainBadges.joined(separator: " ")).lowercased()
            for term in ModelRecommendationEngine.forbiddenJargon {
                XCTAssertFalse(text.contains(term), "Forbidden jargon '\(term)' in \(text)")
            }
        }

        // Record a real measured run on 4B and verify it persists and updates the recommendation headline.
        let bonsai4B = models.catalog.first { $0.id == "4B" }!
        store.recordObservation(
            model: bonsai4B,
            runtime: .llamaCpp,
            telemetry: InferenceTelemetry(
                prefillTokens: 200,
                reusedTokens: 0,
                prefillDuration: 0.8,
                decodedTokens: 80,
                decodeDuration: 2.0,
                footprintBytes: 1_950_000_000
            ),
            thermal: .nominal
        )

        let reloaded = HardwareRecommendationStore(
            modelsDirectory: dir,
            defaults: defaults,
            currentDevice: .iphone15ProA17
        )
        let updated = reloaded.recommendations(for: models, mode: .work)
        let card4B = updated.first { $0.id == "4B" }
        XCTAssertTrue(card4B?.calibratedSpeed.isMeasured == true)
        XCTAssertTrue(card4B?.plainHeadline.contains("measured") == true)
        XCTAssertEqual(card4B?.calibratedSpeed.tokensPerSecond ?? 0, 40.0, accuracy: 0.5)
    }

    func testSwitchingDevicePresetsChangesEstimatedSpeedAndTrendingFilter() async {
        let dir = tempDir()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = HardwareRecommendationStore(
            modelsDirectory: dir,
            defaults: defaults,
            currentDevice: .iphone15ProA17,
            configuration: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubProtocol.self]
                return config
            }
        )

        StubProtocol.handler = { request in
            let query = request.url?.query ?? ""
            let json: String
            if query.contains("filter=mlx") {
                json = """
                [
                  {
                    "id": "LiquidAI/LFM3-1.7B-MLX-4bit",
                    "likes": 80,
                    "downloads": 2000,
                    "trendingScore": 45.0,
                    "pipeline_tag": "text-generation",
                    "tags": ["mlx"],
                    "safetensors": { "total": 973000000 }
                  }
                ]
                """
            } else {
                json = """
                [
                  {
                    "id": "Qwen/Qwen3-8B-GGUF",
                    "likes": 400,
                    "downloads": 50000,
                    "trendingScore": 90.0,
                    "pipeline_tag": "text-generation",
                    "tags": ["gguf", "qwen3"],
                    "siblings": [
                      { "rfilename": "Qwen3-8B-Q4_K_M.gguf", "size": 4900000000 },
                      { "rfilename": "Qwen3-8B-Q2_K.gguf", "size": 2950000000 }
                    ]
                  }
                ]
                """
            }
            return (200, Data(json.utf8))
        }

        await store.refreshTrending()
        XCTAssertNil(store.trendingError)
        XCTAssertEqual(store.trending.first?.selectedFileName, "Qwen3-8B-Q2_K.gguf")
        let a17Speed = store.trending.first?.calibratedSpeed.tokensPerSecond ?? 0

        // Switching to 16GB iPad Pro (M4) automatically upgrades to Q4_K_M and boosts speed.
        store.selectedProfileID = HardwareProfile.ipadProM416GB.id
        XCTAssertEqual(store.trending.first?.selectedFileName, "Qwen3-8B-Q4_K_M.gguf")
        XCTAssertGreaterThan(store.trending.first?.calibratedSpeed.tokensPerSecond ?? 0, a17Speed)

        // Switching to Xbox Series S filters out MLX-only models because supportsMLX == false.
        store.selectedProfileID = HardwareProfile.xboxSeriesS.id
        XCTAssertFalse(store.trending.contains { $0.fit.recommendedRuntime == .mlx })
    }
}
