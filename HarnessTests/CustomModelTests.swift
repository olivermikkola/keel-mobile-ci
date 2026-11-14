import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class CustomModelTests: XCTestCase {
    // MARK: - HuggingFaceGGUFLink tests

    func testBlobLinkEncodedDirectoryAndDownloadQueryNormalizeWithoutDoubleEncoding() throws {
        let link = try HuggingFaceGGUFLink.parse(
            "https://huggingface.co/org/repo/blob/main/folder%20name/model.gguf?download=true"
        )
        XCTAssertEqual(link.repository, "org/repo")
        XCTAssertEqual(link.revision, "main")
        XCTAssertEqual(link.filePath, "folder name/model.gguf")
        XCTAssertEqual(link.fileName, "model.gguf")
        XCTAssertEqual(
            link.resolveURL.absoluteString,
            "https://huggingface.co/org/repo/resolve/main/folder%20name/model.gguf"
        )
    }

    func testRejectsCredentialsTokensTraversalControlCharsAndWrongHost() {
        XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(
            "https://hf_user:hf_secret@huggingface.co/org/repo/resolve/main/model.gguf"
        )) { error in
            XCTAssertEqual(error as? CustomModelError, .credentialsInURL)
        }

        XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(
            "https://huggingface.co/org/repo/resolve/main/model.gguf?token=hf_secret"
        )) { error in
            XCTAssertEqual(error as? CustomModelError, .credentialsInURL)
        }

        XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(
            "http://huggingface.co/org/repo/resolve/main/model.gguf"
        ))

        XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(
            "https://evil.example.com/org/repo/resolve/main/model.gguf"
        )) { error in
            XCTAssertEqual(error as? CustomModelError, .unsupportedHost("evil.example.com"))
        }

        for badPath in [
            "https://huggingface.co/org/repo/resolve/main/%2e%2e/secret.gguf",
            "https://huggingface.co/org/repo/resolve/main/folder%0aname/model.gguf",
            "https://huggingface.co/org/repo/resolve/main/folder%0dname/model.gguf",
            "https://huggingface.co/org/repo/resolve/main/folder%00name/model.gguf",
            "https://huggingface.co/org/repo/resolve/main/folder%7fname/model.gguf",
            "https://huggingface.co/org/repo/resolve/main/folder\nname/model.gguf"
        ] {
            XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(badPath), "Should reject \(badPath)")
        }

        XCTAssertThrowsError(try HuggingFaceGGUFLink.parse(
            "https://huggingface.co/org/repo/resolve/main/weights.safetensors"
        )) { error in
            XCTAssertEqual(error as? CustomModelError, .notGGUFFile("weights.safetensors"))
        }
    }

    // MARK: - GGUFHeader parsing & parity with Bonsai 2 / LFM3 / MiniCPM5

    func testBonsai2HeaderMatchesModelLibraryMemoryFormula() throws {
        var b = GGUFBuilder(metadataCount: 11)
        b.addString("general.architecture", "qwen35")
        b.addString("general.name", "Ternary-Bonsai-2-4B")
        b.addUInt32("qwen35.block_count", 32)
        b.addUInt32("qwen35.full_attention_interval", 4)
        b.addUInt32("qwen35.attention.head_count_kv", 4)
        b.addUInt32("qwen35.attention.key_length", 256)
        b.addUInt32("qwen35.attention.value_length", 256)
        b.addUInt32("qwen35.context_length", 262_144)
        b.addUInt32("qwen35.ssm.inner_size", 4096)
        b.addUInt32("qwen35.ssm.state_size", 128)
        b.addUInt32("qwen35.ssm.conv_kernel", 4)

        let header = try GGUFHeader.parse(b.data)
        XCTAssertEqual(header.architecture, "qwen35")
        XCTAssertEqual(header.modelName, "Ternary-Bonsai-2-4B")
        XCTAssertEqual(header.layerCount, 32)
        XCTAssertEqual(header.attentionLayerCount, 8)
        XCTAssertEqual(header.kvHeadCount, 4)
        XCTAssertEqual(header.keyLength, 256)
        XCTAssertEqual(header.valueLength, 256)
        XCTAssertEqual(header.chatTemplateKind, .chatML)
        XCTAssertTrue(header.hasCompleteMemoryModel)

        // Exact match with ModelArchitecture.bonsai2 in Sources/ModelLibrary.swift:
        // 8 attention layers * 4 kv heads * (256 + 256) = 16,384 values -> 9,216 bytes/token in Q4_0.
        XCTAssertEqual(header.q4KVBytesPerToken, 9_216)
        let weights4B: UInt64 = 1_212_103_520
        let recurrentPerLayer: UInt64 = 4096 * 128 * 4 + 4 * 4096 * 4
        let expectedQ4 = weights4B + (16_384 * 9_216) + (24 * recurrentPerLayer) + 384_000_000
        XCTAssertEqual(header.requiredBytes(weights: weights4B, contextSize: 16_384, quantizedKV: true), expectedQ4)
    }

    func testLFM3ShortConvAndPerLayerKVHeadArrayAndTruncatedTokenizerTable() throws {
        // Real LFM3-1.7B GGUF header uses lfm3.shortconv.l_cache=7 and lfm3.embedding_length=2048
        // alongside a 24-element head_count_kv array with 11 active attention layers.
        let kvHeadsPerLayer: [UInt32] = [
            4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0,
            4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 0, 0
        ]
        var b = GGUFBuilder(metadataCount: 10)
        b.addString("general.architecture", "lfm3")
        b.addUInt32("lfm3.block_count", 24)
        b.addUInt32("lfm3.context_length", 262_144)
        b.addUInt32("lfm3.embedding_length", 2048)
        b.addUInt32("lfm3.shortconv.l_cache", 7)
        b.addUInt32Array("lfm3.attention.head_count_kv", kvHeadsPerLayer)
        b.addUInt32("lfm3.attention.key_length", 128)
        b.addUInt32("lfm3.attention.value_length", 128)
        b.addString("tokenizer.chat_template", "<|startoftext|><|im_start|>system\n")
        // Simulate a 150,000-entry tokenizer.ggml.tokens array at the end of a header prefix slice.
        b.appendRawString("tokenizer.ggml.tokens")
        b.appendUInt32(9) // ARRAY
        b.appendUInt32(8) // STRING elements
        b.appendUInt64(150_000)

        let header = try GGUFHeader.parse(b.data)
        XCTAssertEqual(header.layerCount, 24)
        XCTAssertEqual(header.attentionLayerCount, 11)
        XCTAssertEqual(header.kvHeadCount, 4)
        XCTAssertEqual(header.ssmInnerSize, 2048)
        XCTAssertEqual(header.ssmStateSize, 0)
        XCTAssertEqual(header.ssmConvKernel, 7)
        XCTAssertEqual(header.chatTemplateKind, .lfm3)
        XCTAssertTrue(header.hasCompleteMemoryModel)
        // 11 layers * 4 heads * (128 + 128) * 2 bytes (F16) = 22,528 bytes/token
        XCTAssertEqual(header.f16KVBytesPerToken, 22_528)
        // Matches ModelLibrary.lfmArchitecture.requiredBytes(weights: 1_099_627_808, contextSize: 8192):
        // weights + (8192 * 22528) + (13 conv layers * 7 * 2048 * 4) + 384_000_000 = 1,668,922,656.
        let lfmWeights: UInt64 = 1_099_627_808
        let expectedLFM = lfmWeights + (8_192 * 22_528) + (13 * 7 * 2048 * 4) + 384_000_000
        XCTAssertEqual(header.requiredBytes(weights: lfmWeights, contextSize: 8_192), expectedLFM)

        // Real MiniCPM5-2B GGUF files set general.architecture="llama" and general.name="MiniCPM5 2.6B".
        var mini = GGUFBuilder(metadataCount: 7)
        mini.addString("general.architecture", "llama")
        mini.addString("general.name", "MiniCPM5 2.6B")
        mini.addUInt32("llama.block_count", 42)
        mini.addUInt32("llama.context_length", 131_072)
        mini.addUInt32("llama.attention.head_count_kv", 2)
        mini.addUInt32("llama.attention.key_length", 128)
        mini.addUInt32("llama.attention.value_length", 128)
        let miniHeader = try GGUFHeader.parse(mini.data)
        XCTAssertEqual(miniHeader.chatTemplateKind, .miniCPM5)
        XCTAssertEqual(miniHeader.f16KVBytesPerToken, 43_008)
    }

    func testMaliciousDimensionsAndTruncatedArchitectureFailClosedWithoutTrapping() {
        // 1. Minimal header with only general.architecture and block_count must fail closed (no guessed defaults).
        var minimal = GGUFBuilder(metadataCount: 2)
        minimal.addString("general.architecture", "llama")
        minimal.addUInt64("llama.block_count", 42)
        XCTAssertThrowsError(try GGUFHeader.parse(minimal.data)) { error in
            XCTAssertEqual(error as? CustomModelError, .missingMemoryMetadata("llama.context_length"))
        }

        // 2. Overflow probe: key_length = Int.max or UInt64.max must be rejected at parse time.
        var overflow = GGUFBuilder(metadataCount: 6)
        overflow.addString("general.architecture", "llama")
        overflow.addUInt64("llama.block_count", 42)
        overflow.addUInt64("llama.context_length", 8192)
        overflow.addUInt64("llama.attention.head_count_kv", 4)
        overflow.addUInt64("llama.attention.key_length", UInt64(Int.max))
        overflow.addUInt64("llama.attention.value_length", 128)
        XCTAssertThrowsError(try GGUFHeader.parse(overflow.data)) { error in
            guard case .invalidDimension? = error as? CustomModelError else {
                return XCTFail("Expected .invalidDimension, got \(error)")
            }
        }

        // 3. Even if a GGUFHeader is constructed directly with extreme values, saturating arithmetic never traps.
        let extremeHeader = GGUFHeader(
            version: 3, tensorCount: 1, metadataCount: 1, architecture: "llama", modelName: nil,
            layerCount: Int.max, attentionLayerCount: Int.max, fullAttentionInterval: 1,
            kvHeadCount: Int.max, keyLength: Int.max, valueLength: Int.max, contextLength: .max,
            ssmInnerSize: Int.max, ssmStateSize: Int.max, ssmConvKernel: Int.max,
            fileType: nil, chatTemplateKind: .chatML, hasCompleteMemoryModel: true
        )
        XCTAssertEqual(extremeHeader.q4KVBytesPerToken, UInt64.max)
        XCTAssertEqual(extremeHeader.f16KVBytesPerToken, UInt64.max)
        XCTAssertEqual(extremeHeader.requiredBytes(weights: .max, contextSize: .max), UInt64.max)
        XCTAssertEqual(DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: .max), (UInt64.max / 100) * 60)

        // 4. Negative INT32 dimension or mismatched head_count_kv array length must fail closed.
        var negative = GGUFBuilder(metadataCount: 5)
        negative.addString("general.architecture", "llama")
        negative.addInt32("llama.block_count", -4)
        negative.addUInt32("llama.context_length", 4096)
        negative.addUInt32("llama.attention.head_count_kv", 4)
        negative.addUInt32("llama.attention.key_length", 128)
        XCTAssertThrowsError(try GGUFHeader.parse(negative.data)) { error in
            guard case .invalidDimension? = error as? CustomModelError else {
                return XCTFail("Expected .invalidDimension, got \(error)")
            }
        }

        var wrongArrayLen = GGUFBuilder(metadataCount: 6)
        wrongArrayLen.addString("general.architecture", "lfm3")
        wrongArrayLen.addUInt32("lfm3.block_count", 24)
        wrongArrayLen.addUInt32("lfm3.context_length", 8192)
        wrongArrayLen.addUInt32Array("lfm3.attention.head_count_kv", [4, 0, 4]) // only 3 elements for 24 layers
        wrongArrayLen.addUInt32("lfm3.attention.key_length", 128)
        wrongArrayLen.addUInt32("lfm3.attention.value_length", 128)
        XCTAssertThrowsError(try GGUFHeader.parse(wrongArrayLen.data)) { error in
            guard case .invalidDimension? = error as? CustomModelError else {
                return XCTFail("Expected .invalidDimension, got \(error)")
            }
        }

        // 5. Truncation inside architectural metadata (metadataCount=6, but only 5 keys written) must fail closed.
        var truncatedArch = GGUFBuilder(metadataCount: 6)
        truncatedArch.addString("general.architecture", "llama")
        truncatedArch.addUInt32("llama.block_count", 32)
        truncatedArch.addUInt32("llama.context_length", 8192)
        truncatedArch.addUInt32("llama.attention.head_count_kv", 4)
        truncatedArch.addUInt32("llama.attention.key_length", 128)
        XCTAssertThrowsError(try GGUFHeader.parse(truncatedArch.data)) { error in
            guard case .corruptedHeader? = error as? CustomModelError else {
                return XCTFail("Expected .corruptedHeader on truncated non-tokenizer metadata, got \(error)")
            }
        }
    }

    func testRejectsInvalidMagicVersionsAndOversizedMetadataStrings() {
        XCTAssertThrowsError(try GGUFHeader.parse(Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? CustomModelError, .invalidMagic)
        }
        XCTAssertThrowsError(try GGUFHeader.parse(GGUFBuilder(version: 99, metadataCount: 0).data)) { error in
            XCTAssertEqual(error as? CustomModelError, .unsupportedVersion(99))
        }
        XCTAssertThrowsError(try GGUFHeader.parse(GGUFBuilder(metadataCount: 99_999).data)) { error in
            guard case .limitExceeded? = error as? CustomModelError else { return XCTFail("Expected metadata limit, got \(error)") }
        }
        var oversizedString = GGUFBuilder(metadataCount: 1)
        oversizedString.appendUInt64(10_000_000)
        XCTAssertThrowsError(try GGUFHeader.parse(oversizedString.data)) { error in
            guard case .limitExceeded? = error as? CustomModelError else { return XCTFail("Expected string limit, got \(error)") }
        }
    }

    func testLargeNonDimensionArrayIsSkippedButInvalidHeadArraysCannotFallBack() throws {
        func prefix() -> GGUFBuilder {
            var b = GGUFBuilder(metadataCount: 7)
            b.addString("general.architecture", "llama")
            b.addUInt32("llama.block_count", 32)
            b.addUInt32("llama.context_length", 8192)
            b.addUInt32("llama.attention.head_count", 16)
            b.addUInt32("llama.attention.key_length", 128)
            b.addUInt32("llama.attention.value_length", 128)
            return b
        }
        var harmless = prefix()
        harmless.addUInt32Array("prism.hadamard.sign_values", Array(repeating: 1, count: 5_000))
        XCTAssertEqual(try GGUFHeader.parse(harmless.data).kvHeadCount, 16)
        XCTAssertThrowsError(try GGUFHeader.parse(Data(harmless.data.dropLast())))

        var malformedHeads = prefix()
        malformedHeads.addUInt32Array("llama.attention.head_count_kv", Array(repeating: 4, count: 5_000))
        XCTAssertThrowsError(try GGUFHeader.parse(malformedHeads.data)) { error in
            guard case .invalidDimension? = error as? CustomModelError else { return XCTFail("Expected invalid dimension, got \(error)") }
        }
        var wrongHeadType = prefix()
        wrongHeadType.appendRawString("llama.attention.head_count_kv")
        wrongHeadType.appendUInt32(9)
        wrongHeadType.appendUInt32(6) // Float arrays must not fall back to scalar head_count.
        wrongHeadType.appendUInt64(32)
        for _ in 0..<32 { wrongHeadType.appendUInt32(0) }
        XCTAssertThrowsError(try GGUFHeader.parse(wrongHeadType.data))

        var wrongScalarType = prefix()
        wrongScalarType.addString("llama.attention.head_count_kv", "not an integer")
        XCTAssertThrowsError(try GGUFHeader.parse(wrongScalarType.data))

        var duplicate = prefix()
        duplicate.addUInt32("llama.context_length", 64)
        XCTAssertThrowsError(try GGUFHeader.parse(duplicate.data)) { error in
            guard case .corruptedHeader? = error as? CustomModelError else { return XCTFail("Expected duplicate rejection, got \(error)") }
        }
    }

    // MARK: - DeviceMemoryGate & ExperimentalModelSpec tests

    func testDeviceMemoryGateDefaultsToF16RejectsSubMinimumContextAndUnknownArchitectures() throws {
        var b = GGUFBuilder(metadataCount: 6)
        b.addString("general.architecture", "qwen2")
        b.addUInt32("qwen2.block_count", 36)
        b.addUInt32("qwen2.attention.head_count_kv", 8)
        b.addUInt32("qwen2.attention.key_length", 128)
        b.addUInt32("qwen2.attention.value_length", 128)
        b.addUInt32("qwen2.context_length", 32_768)
        let header = try GGUFHeader.parse(b.data)

        let iphone15ProRAM: UInt64 = 8_000_000_000
        let ipadPro16GBRAM: UInt64 = 16_000_000_000

        // Rejects targetContext=0 or below minimumAgentContext (2,048).
        let zeroContext = DeviceMemoryGate.evaluate(
            header: header,
            weightBytes: 1_000_000_000,
            targetContext: 0,
            physicalMemoryBytes: iphone15ProRAM
        )
        XCTAssertEqual(zeroContext, .contextBelowMinimum(contextSize: 0, minimumRequired: 2_048))
        XCTAssertFalse(zeroContext.isRunnable)

        // Default evaluation uses conservative FP16 KV cache:
        // 36 layers * 8 kvHeads * 256 * 2 = 147,456 bytes/token -> 8,192 tokens = 1,207,959,552 bytes KV.
        let fitVerdict = DeviceMemoryGate.evaluate(
            header: header,
            weightBytes: 2_400_000_000,
            targetContext: 8_192,
            physicalMemoryBytes: iphone15ProRAM
        )
        let expectedF16Required: UInt64 = 2_400_000_000 + (8_192 * 147_456) + 384_000_000
        XCTAssertEqual(fitVerdict, .fits(contextSize: 8_192, requiredBytes: expectedF16Required, budgetBytes: 4_500_000_000))

        // At 32K context in FP16 KV (4.83 GB KV alone), a 2.4 GB model steps down context to fit 4.5 GB.
        let steppedVerdict = DeviceMemoryGate.evaluate(
            header: header,
            weightBytes: 2_400_000_000,
            targetContext: 32_768,
            physicalMemoryBytes: iphone15ProRAM
        )
        if case .reducedContext(let reducedCtx, let req, let budget) = steppedVerdict {
            XCTAssertEqual(reducedCtx, 8_192)
            XCTAssertLessThanOrEqual(req, budget)
        } else {
            XCTFail("Expected .reducedContext, got \(steppedVerdict)")
        }

        // Exercise the heuristic budget with a large weight size and this synthetic layout.
        // This does not establish the real 27B model's fit or physical-device behaviour.
        let bonsai27BWeights: UInt64 = 7_626_008_928
        XCTAssertFalse(DeviceMemoryGate.evaluate(
            header: header, weightBytes: bonsai27BWeights, targetContext: 4_096, physicalMemoryBytes: iphone15ProRAM
        ).isRunnable)
        XCTAssertFalse(DeviceMemoryGate.evaluate(
            header: header, weightBytes: bonsai27BWeights, targetContext: 4_096, physicalMemoryBytes: 12_000_000_000
        ).isRunnable)
        XCTAssertTrue(DeviceMemoryGate.evaluate(
            header: header, weightBytes: bonsai27BWeights, targetContext: 4_096, physicalMemoryBytes: ipadPro16GBRAM
        ).isRunnable)

        // Unknown architectures fail closed in DeviceMemoryGate rather than guessing a memory formula.
        var unknown = GGUFBuilder(metadataCount: 5)
        unknown.addString("general.architecture", "rwkv6")
        unknown.addUInt32("rwkv6.block_count", 24)
        unknown.addUInt32("rwkv6.context_length", 8192)
        unknown.addUInt32("rwkv6.attention.head_count_kv", 4)
        unknown.addUInt32("rwkv6.attention.key_length", 128)
        let unknownHeader = try GGUFHeader.parse(unknown.data)
        XCTAssertFalse(unknownHeader.hasCompleteMemoryModel)
        XCTAssertEqual(
            DeviceMemoryGate.evaluate(header: unknownHeader, weightBytes: 1_000_000_000, physicalMemoryBytes: iphone15ProRAM),
            .unsupportedArchitecture("rwkv6")
        )
    }

    func testExperimentalShelfExcludesGatedOrMissingLinksAndGates27BTo16GB() {
        let on6GB = ExperimentalModelSpec.available(forPhysicalMemoryBytes: 6_000_000_000).map(\.id)
        let on8GB = ExperimentalModelSpec.available(forPhysicalMemoryBytes: 8_000_000_000).map(\.id)
        let on12GB = ExperimentalModelSpec.available(forPhysicalMemoryBytes: 12_000_000_000).map(\.id)
        let on16GB = ExperimentalModelSpec.available(forPhysicalMemoryBytes: 16_000_000_000).map(\.id)

        XCTAssertEqual(on6GB, ["lfm25-1.2b-thinking", "mini-agent-v2"])
        XCTAssertEqual(on8GB, ["lfm25-1.2b-thinking", "mini-agent-v2", "ternary-bonsai-8b"])
        XCTAssertEqual(on12GB, ["lfm25-1.2b-thinking", "mini-agent-v2", "ternary-bonsai-8b"])
        XCTAssertEqual(on16GB, ["lfm25-1.2b-thinking", "mini-agent-v2", "ternary-bonsai-8b", "ternary-bonsai-2-27b"])
        XCTAssertTrue(ExperimentalModelSpec.shelf.allSatisfy { !$0.isVerifiedDownload })
    }

    // MARK: - DynamicToolSelector heuristic tests

    func testDynamicToolSelectorKeepsWarmToolsAndFollowUpDependenciesWithinCap() {
        let catalog: [ToolRouteCandidate] = [
            ToolRouteCandidate(name: "list_files", summary: "List files in workspace", keywords: ["files", "list"], isCoreFallback: true),
            ToolRouteCandidate(name: "read_file", summary: "Read file lines", keywords: ["read", "file"], followUpTools: ["edit_file"], isCoreFallback: true),
            ToolRouteCandidate(name: "edit_file", summary: "Edit a file", keywords: ["edit", "patch"], isCoreFallback: true),
            ToolRouteCandidate(name: "run_sql", summary: "Run SQL query on CSV tables", keywords: ["sql", "csv", "table", "query"], followUpTools: ["run_js"], isCoreFallback: true),
            ToolRouteCandidate(name: "run_js", summary: "Run JavaScript in sandbox", keywords: ["javascript", "script", "chart"], isCoreFallback: true),
            ToolRouteCandidate(name: "read_url", summary: "Fetch and clean a webpage", keywords: ["url", "http", "web", "page"], followUpTools: ["edit_file"]),
            ToolRouteCandidate(name: "generate_image", summary: "Generate image offline", keywords: ["image", "draw", "photo", "picture"], followUpTools: ["upscale_image"]),
            ToolRouteCandidate(name: "upscale_image", summary: "4x Real-ESRGAN upscale", keywords: ["upscale", "4x", "resolution"]),
            ToolRouteCandidate(name: "slack_send", summary: "Send Slack message", keywords: ["slack", "message", "channel"]),
            ToolRouteCandidate(name: "notion_page", summary: "Read Notion page", keywords: ["notion", "wiki"])
        ]

        let selected = DynamicToolSelector.select(
            from: catalog,
            query: "make it higher resolution and update the file",
            recentToolNames: ["read_file", "generate_image"],
            maxActiveTools: 5
        ).map(\.name)

        XCTAssertEqual(selected.count, 5)
        XCTAssertTrue(selected.contains("read_file"))
        XCTAssertTrue(selected.contains("generate_image"))
        XCTAssertTrue(selected.contains("upscale_image"))
        XCTAssertTrue(selected.contains("edit_file"))

        let fallback = DynamicToolSelector.select(
            from: catalog,
            query: "help me",
            recentToolNames: [],
            maxActiveTools: 5
        ).map(\.name)
        XCTAssertEqual(fallback, ["list_files", "read_file", "edit_file", "run_sql", "run_js"])
    }
}
