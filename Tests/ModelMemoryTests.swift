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
}
