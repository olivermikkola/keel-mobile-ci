import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class HardwareFitTests: XCTestCase {
    func testWeightsFitAndKVCacheMathMatchFourPartModel() {
        let input = ModelFitInput(
            id: "test-3b",
            name: "Test 3B",
            totalParamBillions: 3.0,
            bitsPerWeight: 4.0,
            layerCount: 32,
            attentionLayerCount: 32,
            kvHeadCount: 4,
            keyLength: 128,
            valueLength: 128,
            maxContextLength: 8_192,
            quantizedKV: false,
            quantLabel: "Q4"
        )

        // 3B at 4-bit = 1.50 GB raw; * 1.1 = 1.65 GB.
        XCTAssertEqual(input.rawWeightBytes, 1_500_000_000)
        XCTAssertEqual(input.weightsWithOverheadBytes, 1_650_000_000)

        // KV cache per token: 2 * 32 * 4 * 128 * 2 = 65,536 bytes/token at fp16.
        XCTAssertEqual(input.kvBytesPerToken, 65_536)
        // At 8K context: 8192 * 65536 = 536,870,912 bytes (~0.54 GB).
        let fit = ModelFitEstimator.evaluate(input, on: .iphone15ProA17, targetContext: 8_192)
        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.selectedContext, 8_192)
        XCTAssertEqual(fit.kvCacheBytes, 8_192 * 65_536)
        XCTAssertEqual(fit.requiredBytes, 1_650_000_000 + 8_192 * 65_536 + ModelFitEstimator.runtimeScratchBytes)
    }

    func testChipNuanceShowsUpBetweenA17ProA18ProA20IPadAndXbox() {
        let model = ModelFitInput(
            id: "qwen-3b",
            name: "Qwen 3B",
            totalParamBillions: 3.0,
            bitsPerWeight: 4.0,
            exactWeightBytes: 1_800_000_000,
            layerCount: 36,
            attentionLayerCount: 36,
            kvHeadCount: 2,
            keyLength: 128,
            valueLength: 128,
            maxContextLength: 8_192,
            quantLabel: "Q4_K_M"
        )

        let a17 = ModelFitEstimator.evaluate(model, on: .iphone15ProA17)
        let a18 = ModelFitEstimator.evaluate(model, on: .iphone16ProA18)
        let a20 = ModelFitEstimator.evaluate(model, on: .iphoneA20)
        let ipad = ModelFitEstimator.evaluate(model, on: .ipadProM416GB)
        let xbox = ModelFitEstimator.evaluate(model, on: .xboxSeriesS)

        XCTAssertTrue(a17.fits && a18.fits && a20.fits && ipad.fits && xbox.fits)
        XCTAssertLessThan(a17.predictedTokensPerSecond, a18.predictedTokensPerSecond)
        XCTAssertLessThan(a18.predictedTokensPerSecond, a20.predictedTokensPerSecond)
        XCTAssertLessThan(a20.predictedTokensPerSecond, ipad.predictedTokensPerSecond)
        XCTAssertLessThan(ipad.predictedTokensPerSecond, xbox.predictedTokensPerSecond)
    }

    func testMoEUsesTotalWeightsForFitAndActiveWeightsForSpeed() {
        let moe = ModelFitInput(
            id: "qwen-30b-a3b",
            name: "Qwen3 30B-A3B",
            totalParamBillions: 30.0,
            activeParamBillions: 3.0,
            bitsPerWeight: 4.0,
            exactWeightBytes: 16_500_000_000,
            maxContextLength: 8_192,
            quantLabel: "Q4_K_M"
        )

        // Does not fit on 16GB iPad Pro (~10.5 GB usable), even though active params are small.
        let fitOnPad = ModelFitEstimator.evaluate(moe, on: .ipadProM416GB)
        XCTAssertFalse(fitOnPad.fits)

        let bigHost = HardwareProfile(
            id: "mac-studio",
            name: "Mac 32GB",
            shortDeviceName: "Mac",
            chipID: "m4-max",
            chipName: "M4 Max",
            physicalMemoryBytes: 32_000_000_000,
            usableMemoryBytes: 24_000_000_000,
            memoryBandwidthGBps: 400.0,
            supportsMLX: true,
            supportsAppleIntelligence: true
        )
        let dense30B = ModelFitInput(
            id: "dense-30b",
            name: "Dense 30B",
            totalParamBillions: 30.0,
            activeParamBillions: 30.0,
            bitsPerWeight: 4.0,
            exactWeightBytes: 16_500_000_000,
            maxContextLength: 8_192,
            quantLabel: "Q4_K_M"
        )
        let moeFit = ModelFitEstimator.evaluate(moe, on: bigHost)
        let denseFit = ModelFitEstimator.evaluate(dense30B, on: bigHost)
        XCTAssertTrue(moeFit.fits && denseFit.fits)
        XCTAssertGreaterThan(moeFit.predictedTokensPerSecond, denseFit.predictedTokensPerSecond * 5.0)
    }

    func testContextStepsDownWhenLargeContextExceedsHeadroom() {
        let heavyKV = ModelFitInput(
            id: "heavy-kv",
            name: "Heavy KV 4B",
            totalParamBillions: 4.0,
            bitsPerWeight: 4.5,
            exactWeightBytes: 2_600_000_000,
            layerCount: 36,
            attentionLayerCount: 36,
            kvHeadCount: 8,
            keyLength: 128,
            valueLength: 128,
            maxContextLength: 32_768,
            quantizedKV: false,
            quantLabel: "Q4_K_M"
        )

        // At 32K FP16 KV (~4.83 GB KV alone), exceeds 4.5 GB A17 Pro budget, so it steps down.
        let fit = ModelFitEstimator.evaluate(heavyKV, on: .iphone15ProA17, targetContext: 32_768)
        XCTAssertTrue(fit.fits)
        XCTAssertLessThan(fit.selectedContext, 32_768)
        XCTAssertGreaterThanOrEqual(fit.selectedContext, 2_048)
    }

    func testThermalPressureScalesSpeedAndStopsAtCritical() {
        let model = ModelFitInput(id: "m", name: "M", totalParamBillions: 2.0, exactWeightBytes: 1_100_000_000)
        let nominal = ModelFitEstimator.predictTokensPerSecond(input: model, on: .iphone16ProA18, runtime: .llamaCpp, thermal: .nominal)
        let fair = ModelFitEstimator.predictTokensPerSecond(input: model, on: .iphone16ProA18, runtime: .llamaCpp, thermal: .fair)
        let serious = ModelFitEstimator.predictTokensPerSecond(input: model, on: .iphone16ProA18, runtime: .llamaCpp, thermal: .serious)
        let critical = ModelFitEstimator.predictTokensPerSecond(input: model, on: .iphone16ProA18, runtime: .llamaCpp, thermal: .critical)

        XCTAssertGreaterThan(nominal, fair)
        XCTAssertGreaterThan(fair, serious)
        XCTAssertEqual(critical, 0.0)
    }

    func testSelfCalibratingSpeedStoreLearnsPerChipRuntimeQuantThermalAndPersists() throws {
        var store = SpeedCalibrationStore()
        // Tiny 2-token noise should be ignored.
        XCTAssertFalse(store.record(SpeedObservation(
            chipID: "a17-pro",
            runtime: .llamaCpp,
            quantBucket: "Q4_K_M",
            thermalLevel: .nominal,
            predictedTokensPerSecond: 20.0,
            actualTokensPerSecond: 40.0,
            decodedTokens: 2,
            decodeDuration: 0.05
        )))
        XCTAssertEqual(store.totalSamples, 0)

        // Real first run: actual is 30 tok/s when predicted was 20 tok/s -> 1.5x multiplier.
        XCTAssertTrue(store.record(SpeedObservation(
            chipID: "a17-pro",
            runtime: .llamaCpp,
            quantBucket: "Q4_K_M",
            thermalLevel: .nominal,
            predictedTokensPerSecond: 20.0,
            actualTokensPerSecond: 30.0,
            decodedTokens: 48,
            decodeDuration: 1.6,
            footprintBytes: 2_100_000_000
        )))

        let exact = store.calibratedSpeed(
            predicted: 20.0,
            chipID: "a17-pro",
            runtime: .llamaCpp,
            quantBucket: "Q4_0", // normalizes to 4bit bucket
            thermalLevel: .nominal
        )
        XCTAssertTrue(exact.isMeasured)
        XCTAssertEqual(exact.sampleCount, 1)
        XCTAssertEqual(exact.tokensPerSecond, 30.0, accuracy: 0.01)

        // Unseen thermal level falls back cleanly to same chip+runtime+quant.
        let thermalFallback = store.calibratedSpeed(
            predicted: 20.0,
            chipID: "a17-pro",
            runtime: .llamaCpp,
            quantBucket: "4bit",
            thermalLevel: .fair
        )
        XCTAssertTrue(thermalFallback.isMeasured)
        XCTAssertEqual(thermalFallback.tokensPerSecond, 30.0, accuracy: 0.01)

        // Different chip remains unmeasured.
        let otherChip = store.calibratedSpeed(
            predicted: 35.0,
            chipID: "a18-pro",
            runtime: .llamaCpp,
            quantBucket: "4bit",
            thermalLevel: .nominal
        )
        XCTAssertFalse(otherChip.isMeasured)
        XCTAssertEqual(otherChip.tokensPerSecond, 35.0, accuracy: 0.01)

        // Round-trip save & load.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("calibration.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(to: file)
        let reloaded = SpeedCalibrationStore.load(from: file)
        XCTAssertEqual(reloaded, store)
    }

    func testRecommendationsHaveZeroHFJargonAndReflectMeasuredSpeed() {
        var calibration = SpeedCalibrationStore()
        calibration.record(SpeedObservation(
            chipID: "m4",
            runtime: .llamaCpp,
            quantBucket: "Q2_0",
            thermalLevel: .nominal,
            predictedTokensPerSecond: 30.0,
            actualTokensPerSecond: 42.0,
            decodedTokens: 60,
            decodeDuration: 1.4
        ))

        let smallFit = ModelFitInput(
            id: "4B",
            name: "Bonsai 2 · 4B",
            totalParamBillions: 4.0,
            bitsPerWeight: 2.5,
            exactWeightBytes: 1_212_103_520,
            maxContextLength: 16_384,
            quantizedKV: true,
            quantLabel: "Q2_0"
        )
        let tooBig = ModelFitInput(
            id: "70B",
            name: "Llama 70B",
            totalParamBillions: 70.0,
            bitsPerWeight: 4.5,
            exactWeightBytes: 40_000_000_000,
            maxContextLength: 8_192,
            quantLabel: "Q4_K_M"
        )

        let recs = ModelRecommendationEngine.recommend(
            candidates: [
                CatalogModelCandidate(id: "70B", name: "Llama 70B", fitInput: tooBig, capabilities: [.code], isRecommendedForMode: false),
                CatalogModelCandidate(id: "4B", name: "Bonsai 2 · 4B", fitInput: smallFit, capabilities: [.code, .tools], isRecommendedForMode: true),
            ],
            hardware: .ipadProM416GB,
            mode: .work,
            calibration: calibration
        )

        XCTAssertEqual(recs.first?.id, "4B")
        XCTAssertTrue(recs.first?.fits == true)
        XCTAssertTrue(recs.first?.calibratedSpeed.isMeasured == true)
        XCTAssertTrue(recs.first?.plainHeadline.contains("measured") == true)
        XCTAssertFalse(recs.last?.fits ?? true)

        for rec in recs {
            let combined = (rec.plainHeadline + " " + rec.plainBadges.joined(separator: " ")).lowercased()
            for term in ModelRecommendationEngine.forbiddenJargon {
                XCTAssertFalse(combined.contains(term), "Forbidden HF jargon '\(term)' leaked into: \(combined)")
            }
        }
    }

    func testHuggingFaceTrendingFiltersByHardwarePicksFittingQuantAndHandlesMLX() throws {
        let json = """
        [
          {
            "id": "Qwen/Qwen3-8B-GGUF",
            "likes": 450,
            "downloads": 120000,
            "trendingScore": 95.0,
            "pipeline_tag": "text-generation",
            "tags": ["gguf", "qwen3", "code"],
            "gguf": { "architecture": "qwen3", "context_length": 32768 },
            "config": { "model_type": "qwen3", "num_hidden_layers": 36, "num_key_value_heads": 8, "num_attention_heads": 32, "head_dim": 128 },
            "siblings": [
              { "rfilename": "Qwen3-8B-Q8_0.gguf", "size": 8500000000 },
              { "rfilename": "Qwen3-8B-Q4_K_M.gguf", "size": 4900000000 },
              { "rfilename": "Qwen3-8B-Q2_K.gguf", "size": 2950000000 }
            ]
          },
          {
            "id": "Qwen/Qwen3-1.7B-GGUF",
            "likes": 310,
            "downloads": 85000,
            "trendingScore": 80.0,
            "pipeline_tag": "text-generation",
            "tags": ["gguf", "qwen3"],
            "gguf": { "architecture": "qwen3", "context_length": 32768 },
            "siblings": [
              { "rfilename": "Qwen3-1.7B-Q4_K_M.gguf", "size": 1100000000 }
            ]
          },
          {
            "id": "LiquidAI/LFM3-1.7B-MLX-4bit",
            "likes": 220,
            "downloads": 30000,
            "trendingScore": 70.0,
            "pipeline_tag": "text-generation",
            "tags": ["mlx", "safetensors"],
            "safetensors": { "total": 980000000 },
            "siblings": [
              { "rfilename": "model.safetensors", "size": 980000000 }
            ]
          },
          {
            "id": "meta-llama/Llama-3.3-70B-GGUF",
            "likes": 900,
            "downloads": 200000,
            "trendingScore": 120.0,
            "pipeline_tag": "text-generation",
            "tags": ["gguf", "llama"],
            "siblings": [
              { "rfilename": "Llama-3.3-70B-Q4_K_M.gguf", "size": 42000000000 }
            ]
          }
        ]
        """
        let data = Data(json.utf8)
        let calibration = SpeedCalibrationStore()

        // On A17 Pro (4.5 GB usable): 8B picks Q2_K (~2.95 GB) because Q4_K_M (4.9 GB) is too large; 70B is filtered out!
        let a17Fitting = try HuggingFaceTrending.parseAndRank(
            data: data,
            hardware: .iphone15ProA17,
            calibration: calibration,
            onlyFitting: true
        )
        XCTAssertEqual(a17Fitting.map(\.repoID), ["Qwen/Qwen3-8B-GGUF", "Qwen/Qwen3-1.7B-GGUF", "LiquidAI/LFM3-1.7B-MLX-4bit"])
        XCTAssertEqual(a17Fitting.first(where: { $0.repoID == "Qwen/Qwen3-8B-GGUF" })?.selectedFileName, "Qwen3-8B-Q2_K.gguf")
        XCTAssertEqual(a17Fitting.first(where: { $0.repoID == "LiquidAI/LFM3-1.7B-MLX-4bit" })?.fit.recommendedRuntime, .mlx)

        // On 16GB iPad Pro (10.5 GB usable): 8B picks higher-quality Q4_K_M (4.9 GB)!
        let ipadFitting = try HuggingFaceTrending.parseAndRank(
            data: data,
            hardware: .ipadProM416GB,
            calibration: calibration,
            onlyFitting: true
        )
        XCTAssertEqual(ipadFitting.first(where: { $0.repoID == "Qwen/Qwen3-8B-GGUF" })?.selectedFileName, "Qwen3-8B-Q4_K_M.gguf")

        // On Xbox Series S (supportsMLX = false): MLX-only repo does not fit.
        let xboxFitting = try HuggingFaceTrending.parseAndRank(
            data: data,
            hardware: .xboxSeriesS,
            calibration: calibration,
            onlyFitting: true
        )
        XCTAssertFalse(xboxFitting.contains(where: { $0.repoID == "LiquidAI/LFM3-1.7B-MLX-4bit" }))
    }

    func testHuggingFaceTrendingFetchMergesGGUFAndMLXThroughTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrendingStubProtocol.self]

        let results = try await HuggingFaceTrending.fetch(
            hardware: .iphone16ProA18,
            calibration: SpeedCalibrationStore(),
            onlyFitting: true,
            configuration: config
        )
        XCTAssertEqual(results.map(\.repoID), ["Qwen/Qwen3-1.7B-GGUF", "LiquidAI/LFM3-1.7B-MLX-4bit"])
        XCTAssertEqual(results.first?.ggufLink?.fileName, "Qwen3-1.7B-Q4_K_M.gguf")
    }

    func testA17ProUsesLPDDR5MemoryBandwidth() {
        XCTAssertEqual(HardwareProfile.iphone15ProA17.memoryBandwidthGBps, 51.2, accuracy: 0.01)
        let detected = HardwareProfile.detectCurrent(machineIdentifier: "iPhone16,1", physicalMemoryBytes: 8_000_000_000)
        XCTAssertEqual(detected.memoryBandwidthGBps, 51.2, accuracy: 0.01)
    }

    func testAppleDevicePresetsExcludeNonAppleAndUnreleasedHardware() {
        let ids = HardwareProfile.appleDevicePresets.map(\.id)
        XCTAssertFalse(ids.contains(HardwareProfile.xboxSeriesS.id))
        XCTAssertFalse(ids.contains(HardwareProfile.iphoneA20.id))
        XCTAssertTrue(HardwareProfile.appleDevicePresets.allSatisfy {
            $0.shortDeviceName.contains("iPhone") || $0.shortDeviceName.contains("iPad")
        })
    }
}

private final class TrendingStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = request.url?.query ?? ""
        let payload: String
        if query.contains("filter=mlx") {
            payload = """
            [
              {
                "id": "LiquidAI/LFM3-1.7B-MLX-4bit",
                "likes": 90,
                "downloads": 5000,
                "trendingScore": 42.0,
                "pipeline_tag": "text-generation",
                "tags": ["mlx"],
                "safetensors": { "total": 973000000 }
              }
            ]
            """
        } else {
            payload = """
            [
              {
                "id": "Qwen/Qwen3-1.7B-GGUF",
                "likes": 120,
                "downloads": 12000,
                "trendingScore": 75.0,
                "pipeline_tag": "text-generation",
                "tags": ["gguf", "qwen3"],
                "siblings": [
                  { "rfilename": "Qwen3-1.7B-Q4_K_M.gguf", "size": 1100000000 }
                ]
              }
            ]
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
