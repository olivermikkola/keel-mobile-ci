import XCTest
@testable import KeelMobile

final class ModelMemoryTests: XCTestCase {
    func testHybridMetadataComputesOnlyFullAttentionLayers() {
        let architecture = ModelArchitecture.bonsai2
        XCTAssertEqual(architecture.layerCount, 32)
        XCTAssertEqual(architecture.fullAttentionLayerCount, 8)
        XCTAssertEqual(architecture.linearAttentionLayerCount, 24)
        // 8 layers × 4 KV heads × (256 + 256) values × 18/32 bytes for Q4_0.
        XCTAssertEqual(architecture.kvBytesPerToken, 9_216)
    }

    func testNineBillionBudgetMatchesPinnedGGUFInsteadOfFlatGuess() {
        let model = LocalModel.catalog.first { $0.id == "9B" }!
        let required = model.architecture.requiredBytes(weights: UInt64(model.bytes), contextSize: 32_768)
        XCTAssertEqual(required, 3_294_534_528)
        let oldFlatGuard = UInt64(model.bytes) + UInt64(32_768) * 40_000 + 384_000_000
        XCTAssertEqual(oldFlatGuard, 4_251_360_128)
        XCTAssertLessThan(required, oldFlatGuard)
        XCTAssertGreaterThan(required, UInt64(model.bytes) + 300_000_000)
    }

    func testFourBillionBudgetUsesItsSixteenKContext() {
        let model = LocalModel.catalog.first { $0.id == "4B" }!
        let required = model.architecture.requiredBytes(weights: UInt64(model.bytes), contextSize: 16_384)
        XCTAssertEqual(required, 1_799_002_976)
        let oldFlatGuard = UInt64(model.bytes) + UInt64(16_384) * 40_000 + 384_000_000
        XCTAssertEqual(oldFlatGuard, 2_251_463_520)
        XCTAssertLessThan(required, oldFlatGuard)
    }

    func testBudgetScalesWithContextAndWeights() {
        let architecture = ModelArchitecture.bonsai2
        let short = architecture.requiredBytes(weights: 1_000_000_000, contextSize: 4_096)
        let long = architecture.requiredBytes(weights: 1_000_000_000, contextSize: 32_768)
        XCTAssertEqual(long - short, UInt64(32_768 - 4_096) * architecture.kvBytesPerToken)
        XCTAssertEqual(long - short, 264_241_152)
        XCTAssertEqual(architecture.requiredBytes(weights: 1, contextSize: 1, appHeadroom: 0),
                       1 + UInt64(architecture.kvBytesPerToken)
                       + UInt64(architecture.linearAttentionLayerCount) * 2_162_688)
    }

    func testSmallModelsUseQ8KVCacheToCutMemoryNearlyInHalf() {
        // LFM3: 11 attention layers × 4 KV heads × (128 + 128) values × 34/32 bytes = 11,968 B/tok
        // vs 22,528 B/tok at F16 (~47% saved).
        XCTAssertEqual(LocalModel.lfmArchitecture.kvBlockBytes, 34)
        XCTAssertEqual(LocalModel.lfmArchitecture.kvBlockElements, 32)
        XCTAssertEqual(LocalModel.lfmArchitecture.kvBytesPerToken, 11_968)
        XCTAssertLessThan(LocalModel.lfmArchitecture.kvBytesPerToken, 22_528 * 55 / 100)

        // MiniCPM5: 42 layers × 2 KV heads × (128 + 128) values × 34/32 bytes = 22,848 B/tok
        // vs 43,008 B/tok at F16 (~165 MB saved at 8K context).
        XCTAssertEqual(LocalModel.miniArchitecture.kvBlockBytes, 34)
        XCTAssertEqual(LocalModel.miniArchitecture.kvBlockElements, 32)
        XCTAssertEqual(LocalModel.miniArchitecture.kvBytesPerToken, 22_848)
        XCTAssertLessThan(LocalModel.miniArchitecture.kvBytesPerToken, 43_008 * 55 / 100)
    }
}
