import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ImportedImagePackTests: XCTestCase {
    private let phone8GB: UInt64 = 8_000_000_000

    private func sampleEntries(prefix: String = "", chunked: Bool = false, weightBytes: Int64 = 600_000_000) -> [(path: String, bytes: Int64, sha256: String?)] {
        let p = prefix.isEmpty ? "" : prefix + "/"
        var list: [(String, Int64, String?)] = [
            ("\(p)TextEncoder.mlmodelc/coremldata.bin", 1_024, nil),
            ("\(p)TextEncoder.mlmodelc/metadata.json", 3_000, nil),
            ("\(p)TextEncoder.mlmodelc/weights/weight.bin", 240_000_000, nil),
            ("\(p)VAEDecoder.mlmodelc/coremldata.bin", 1_024, nil),
            ("\(p)VAEDecoder.mlmodelc/weights/weight.bin", 98_000_000, nil),
            ("\(p)vocab.json", 900_000, nil),
            ("\(p)merges.txt", 524_000, nil),
        ]
        if chunked {
            list += [
                ("\(p)UnetChunk1.mlmodelc/coremldata.bin", 1_024, nil),
                ("\(p)UnetChunk1.mlmodelc/weights/weight.bin", weightBytes / 2, nil),
                ("\(p)UnetChunk2.mlmodelc/coremldata.bin", 1_024, nil),
                ("\(p)UnetChunk2.mlmodelc/weights/weight.bin", weightBytes / 2, nil),
            ]
        } else {
            list += [
                ("\(p)Unet.mlmodelc/coremldata.bin", 1_024, nil),
                ("\(p)Unet.mlmodelc/weights/weight.bin", weightBytes, nil),
            ]
        }
        return list
    }

    func testLayoutPrefersSplitEinsumV2CompiledAndStripsUnusedBundles() throws {
        var entries = sampleEntries(prefix: "original/compiled", weightBytes: 700_000_000)
        entries += sampleEntries(prefix: "split_einsum_v2/compiled", weightBytes: 600_000_000)
        entries += [
            ("split_einsum_v2/compiled/SafetyChecker.mlmodelc/coremldata.bin", 1_024, nil),
            ("split_einsum_v2/compiled/SafetyChecker.mlmodelc/weights/weight.bin", 300_000_000, nil),
            ("split_einsum_v2/compiled/VAEEncoder.mlmodelc/coremldata.bin", 1_024, nil),
            ("__MACOSX/split_einsum_v2/compiled/._vocab.json", 200, nil),
            ("split_einsum_v2/compiled/.DS_Store", 6_148, nil),
        ]

        let plan = try CoreMLImagePackLayout.plan(entries: entries, physicalMemoryBytes: phone8GB)
        XCTAssertEqual(plan.rootPrefix, "split_einsum_v2/compiled")
        XCTAssertFalse(plan.chunkedUnet)
        XCTAssertFalse(plan.files.contains { $0.relativePath.contains("SafetyChecker") })
        XCTAssertFalse(plan.files.contains { $0.relativePath.contains("VAEEncoder") })
        XCTAssertFalse(plan.files.contains { $0.relativePath.contains(".DS_Store") })
        XCTAssertEqual(plan.files.count, 9)
        XCTAssertTrue(plan.files.contains { $0.relativePath == "Unet.mlmodelc/weights/weight.bin" && $0.bytes == 600_000_000 })
    }

    func testLayoutSupportsChunkedUnetAndNestedZipFolder() throws {
        let entries = sampleEntries(prefix: "dreamshaper-8-lcm/compiled", chunked: true, weightBytes: 640_000_000)
        let plan = try CoreMLImagePackLayout.plan(entries: entries, physicalMemoryBytes: phone8GB)
        XCTAssertEqual(plan.rootPrefix, "dreamshaper-8-lcm/compiled")
        XCTAssertTrue(plan.chunkedUnet)
        XCTAssertTrue(plan.files.contains { $0.relativePath == "UnetChunk1.mlmodelc/coremldata.bin" })
        XCTAssertTrue(plan.files.contains { $0.relativePath == "UnetChunk2.mlmodelc/coremldata.bin" })
    }

    func testLayoutRejectsUncompiledSDXLMissingAndOversizedPacks() {
        // Uncompiled .mlpackage only
        let uncompiled: [(String, Int64, String?)] = [
            ("TextEncoder.mlpackage/Manifest.json", 512, nil),
            ("Unet.mlpackage/Manifest.json", 512, nil),
            ("VAEDecoder.mlpackage/Manifest.json", 512, nil),
        ]
        XCTAssertThrowsError(try CoreMLImagePackLayout.plan(entries: uncompiled, physicalMemoryBytes: phone8GB)) { error in
            XCTAssertEqual(error as? CoreMLImagePackLayout.Problem, .uncompiledOnly)
        }

        // SDXL pack with TextEncoder2.mlmodelc
        var sdxl = sampleEntries()
        sdxl.append(("TextEncoder2.mlmodelc/coremldata.bin", 1_024, nil))
        XCTAssertThrowsError(try CoreMLImagePackLayout.plan(entries: sdxl, physicalMemoryBytes: phone8GB)) { error in
            guard case CoreMLImagePackLayout.Problem.unsupportedArchitecture = error else {
                XCTFail("Expected unsupportedArchitecture, got \(error)")
                return
            }
        }

        // Missing VAEDecoder and merges.txt
        let incomplete = sampleEntries().filter { !$0.path.hasPrefix("VAEDecoder") && $0.path != "merges.txt" }
        XCTAssertThrowsError(try CoreMLImagePackLayout.plan(entries: incomplete, physicalMemoryBytes: phone8GB)) { error in
            XCTAssertEqual(error as? CoreMLImagePackLayout.Problem, .missingFiles(["VAEDecoder.mlmodelc", "merges.txt"]))
        }

        // Too large for a 4 GB phone
        let smallPhone: UInt64 = 4_000_000_000
        let heavy = sampleEntries(weightBytes: 1_500_000_000)
        XCTAssertThrowsError(try CoreMLImagePackLayout.plan(entries: heavy, physicalMemoryBytes: smallPhone)) { error in
            guard case CoreMLImagePackLayout.Problem.tooLarge = error else {
                XCTFail("Expected tooLarge, got \(error)")
                return
            }
        }
    }

    func testEnginePadTokenAndSDXLMetadataDetection() throws {
        XCTAssertEqual(ImportedImagePack.inferEngine(from: "coreml-dreamshaper-8-lcm-6bit"), .lcm)
        XCTAssertEqual(ImportedImagePack.inferEngine(from: "sd15_LCM_v2.zip"), .lcm)
        XCTAssertEqual(ImportedImagePack.inferEngine(from: "realistic-vision-v5"), .standard)
        XCTAssertEqual(ImportedImagePack.inferEngine(from: "welcome-pack"), .standard)

        XCTAssertEqual(ImportedImagePack.detectPadToken(textEncoderMetadata: "\"shape\": \"[1, 77, 1024]\""), "!")
        XCTAssertEqual(ImportedImagePack.detectPadToken(textEncoderMetadata: "\"shape\": \"[1, 77, 768]\""), "<|endoftext|>")
        XCTAssertEqual(ImportedImagePack.detectPadToken(textEncoderMetadata: nil), "<|endoftext|>")

        XCTAssertNotNil(ImportedImagePack.unsupportedMetadataReason(unetMetadata: "{\"inputs\": [\"sample\", \"time_ids\"]}"))
        XCTAssertNil(ImportedImagePack.unsupportedMetadataReason(unetMetadata: "{\"inputs\": [\"sample\", \"timestep\"]}"))

        try CoreMLImagePackLayout.validateTokenizer(
            vocabData: Data("{\"a\": 0}".utf8),
            mergesData: Data("#version: 0.2\na b\n".utf8)
        )
        XCTAssertThrowsError(try CoreMLImagePackLayout.validateTokenizer(vocabData: Data("not-json".utf8), mergesData: Data("a b\n".utf8)))
        XCTAssertThrowsError(try CoreMLImagePackLayout.validateTokenizer(vocabData: Data("{\"a\":0}".utf8), mergesData: Data("single-line".utf8)))
    }

    func testHuggingFaceCoreMLPackLinkValidation() throws {
        let root = try HuggingFaceCoreMLPackLink.parse("https://huggingface.co/LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2")
        XCTAssertEqual(root.repository, "LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2")
        XCTAssertEqual(root.revision, "main")
        XCTAssertEqual(root.subpath, "")
        XCTAssertEqual(root.treeAPIURL.absoluteString, "https://huggingface.co/api/models/LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2/tree/main?recursive=true&limit=1000")

        let sub = try HuggingFaceCoreMLPackLink.parse("https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/tree/main/split_einsum_v2/compiled")
        XCTAssertEqual(sub.repository, "apple/coreml-stable-diffusion-2-1-base-palettized")
        XCTAssertEqual(sub.subpath, "split_einsum_v2/compiled")
        XCTAssertEqual(
            sub.resolveURL(forRepoPath: "split_einsum_v2/compiled/vocab.json")?.absoluteString,
            "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/split_einsum_v2/compiled/vocab.json"
        )

        for bad in [
            "http://huggingface.co/a/b",
            "https://example.com/a/b",
            "https://user:pass@huggingface.co/a/b",
            "https://huggingface.co/a/b?token=secret",
            "https://huggingface.co/a/b/blob/main/vocab.json",
            "https://huggingface.co/a/b/tree/main/../escape",
            "https://huggingface.co/only-owner",
        ] {
            XCTAssertThrowsError(try HuggingFaceCoreMLPackLink.parse(bad), bad)
        }
    }

    func testImportedImagePackRecordValidationAndConversion() throws {
        let sha = String(repeating: "a", count: 64)
        let record = ImportedImagePack(
            name: "  My Custom LCM.zip \n",
            bytes: 950_000_000,
            fileCount: 17,
            sha256: sha,
            engine: .lcm,
            padToken: "<|endoftext|>",
            chunkedUnet: false,
            sourceLabel: "Files"
        )
        XCTAssertTrue(record.isValid)
        XCTAssertEqual(record.name, "My Custom LCM")
        XCTAssertEqual(record.defaultSteps, 8)
        XCTAssertEqual(record.defaultGuidance, 2.0)

        let pack = record.asImageModelPack()
        XCTAssertEqual(pack.id, record.id)
        XCTAssertEqual(pack.totalBytes, 950_000_000)
        XCTAssertEqual(pack.engine, .lcm)
        XCTAssertEqual(pack.padToken, "<|endoftext|>")

        // Persistence round-trip drops tampered records.
        let tampered = ImportedImagePack(
            id: "../escape",
            name: "Evil",
            bytes: 100,
            fileCount: 1,
            sha256: sha,
            engine: .standard,
            padToken: "!",
            chunkedUnet: false,
            sourceLabel: "Files"
        )
        XCTAssertFalse(tampered.isValid)
        let encoded = try JSONEncoder().encode([record, tampered, record])
        XCTAssertEqual(ImportedImagePack.load(encoded), [record])
    }
}
