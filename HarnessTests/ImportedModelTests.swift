import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ImportedModelTests: XCTestCase {
    private let iPhone15Pro: UInt64 = 8_000_000_000

    private func qwen(_ architecture: String = "qwen3", layers: UInt32 = 36, template: String? = nil) throws -> GGUFHeader {
        var b = GGUFBuilder(metadataCount: template == nil ? 6 : 7)
        b.addString("general.architecture", architecture)
        b.addUInt32("\(architecture).block_count", layers)
        b.addUInt32("\(architecture).attention.head_count_kv", 8)
        b.addUInt32("\(architecture).attention.key_length", 128)
        b.addUInt32("\(architecture).attention.value_length", 128)
        b.addUInt32("\(architecture).context_length", 40_960)
        if let template { b.addString("tokenizer.chat_template", template) }
        return try GGUFHeader.parse(b.data)
    }

    private func lfm3() throws -> GGUFHeader {
        var b = GGUFBuilder(metadataCount: 8)
        b.addString("general.architecture", "lfm3")
        b.addUInt32("lfm3.block_count", 24)
        b.addUInt32("lfm3.context_length", 262_144)
        b.addUInt32("lfm3.embedding_length", 2048)
        b.addUInt32("lfm3.shortconv.l_cache", 7)
        b.addUInt32Array("lfm3.attention.head_count_kv", [4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 0, 0])
        b.addUInt32("lfm3.attention.key_length", 128)
        b.addUInt32("lfm3.attention.value_length", 128)
        return try GGUFHeader.parse(b.data)
    }

    func testQwenAndLFMModelsGetTheirPromptFormatAndAContextThatFits() throws {
        let chatML = try ImportedModel.plan(header: qwen(), bytes: 2_500_000_000, physicalMemoryBytes: iPhone15Pro)
        XCTAssertEqual(chatML.family, .bonsai, "Qwen ChatML, the format Bonsai's prompt renders")
        XCTAssertEqual(chatML.contextSize, 8_192)
        let lfm = try ImportedModel.plan(header: lfm3(), bytes: 1_099_627_808, physicalMemoryBytes: iPhone15Pro)
        XCTAssertEqual(lfm.family, .lfm3)
        XCTAssertEqual(lfm.contextSize, 8_192)
        // A big model on the 8 GB phone keeps running with a shorter context.
        let big = try ImportedModel.plan(header: qwen(layers: 64), bytes: 3_400_000_000, physicalMemoryBytes: iPhone15Pro)
        XCTAssertLessThan(big.contextSize, 8_192)
        XCTAssertGreaterThanOrEqual(big.contextSize, DeviceMemoryGate.minimumAgentContext)
    }

    func testFormatsKeelCannotPromptAreRefusedWithAReason() throws {
        // A llama model whose template was not in the first 256 KB: ChatML would be a guess.
        XCTAssertThrowsError(try ImportedModel.plan(header: qwen("llama"), bytes: 1_000_000_000, physicalMemoryBytes: iPhone15Pro)) {
            XCTAssertTrue(($0 as? ImportedModel.Problem)?.errorDescription?.contains("cannot tell which chat format") == true, "\($0)")
        }
        let llama3 = try qwen("llama", template: "<|start_header_id|>user<|end_header_id|>")
        XCTAssertThrowsError(try ImportedModel.plan(header: llama3, bytes: 1_000_000_000, physicalMemoryBytes: iPhone15Pro)) {
            XCTAssertTrue($0.localizedDescription.contains("Llama 3"), "\($0)")
        }
        let gemma = try qwen("gemma3", template: "<start_of_turn>user")
        XCTAssertThrowsError(try ImportedModel.plan(header: gemma, bytes: 1_000_000_000, physicalMemoryBytes: iPhone15Pro)) {
            XCTAssertTrue($0.localizedDescription.contains("Gemma"), "\($0)")
        }
    }

    func testAModelThatCannotFitIsRefusedWithBothSizes() throws {
        XCTAssertThrowsError(try ImportedModel.plan(header: qwen(layers: 64), bytes: 7_600_000_000, physicalMemoryBytes: iPhone15Pro)) {
            let text = $0.localizedDescription
            XCTAssertTrue(text.contains("needs about") && text.contains("4.5 GB"), text)
        }
    }

    func testSavedListKeepsOnlyValidDistinctRecords() throws {
        let header = try qwen()
        func record(_ id: String = ImportedModel.newID(), sha: String = String(repeating: "a", count: 64), context: UInt32 = 8_192) -> ImportedModel {
            ImportedModel(id: id, name: "Qwen3-4B-Q4_K_M.gguf", bytes: 2_500_000_000, sha256: sha, header: header, family: .bonsai, contextSize: context)
        }
        let good = record()
        XCTAssertEqual(good.name, "Qwen3-4B-Q4_K_M")
        XCTAssertEqual(good.fileName, good.id + ".gguf")
        XCTAssertTrue(good.isValid)
        let data = try JSONEncoder().encode([good, good, record("custom-../../etc"), record(sha: "XYZ"), record(context: 512)])
        XCTAssertEqual(ImportedModel.load(data), [good])
        XCTAssertEqual(ImportedModel.load(Data("not json".utf8)), [])
        let many = (0..<20).map { _ in record() }
        XCTAssertEqual(ImportedModel.load(try JSONEncoder().encode(many)).count, ImportedModel.limit)
    }

    func testSavedRecordsRejectInvalidMemoryDimensionsAndControls() throws {
        let model = ImportedModel(name: "Qwen", bytes: 2_500_000_000, sha256: String(repeating: "a", count: 64),
                                  header: try qwen(), family: .bonsai, contextSize: 8_192)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        for (field, value) in [("ssmInnerSize", -1), ("ssmStateSize", -1), ("ssmConvKernel", -1),
                               ("ssmInnerSize", Int.max), ("layerCount", 0)] {
            var record = original; record[field] = value
            XCTAssertTrue(ImportedModel.load(try JSONSerialization.data(withJSONObject: [record])).isEmpty, field)
        }
        var record = original; record["name"] = "Qwen\nspoofed row"
        XCTAssertTrue(ImportedModel.load(try JSONSerialization.data(withJSONObject: [record])).isEmpty)
    }

    func testNamesAreOneShortLine() {
        XCTAssertEqual(ImportedModel.cleanName("  my\nmodel\u{0007}.gguf"), "mymodel")
        XCTAssertEqual(ImportedModel.cleanName(".gguf"), "Imported model")
        XCTAssertEqual(ImportedModel.cleanName(String(repeating: "x", count: 100)).count, 60)
    }
}
