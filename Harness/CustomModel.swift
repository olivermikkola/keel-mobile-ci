import Foundation

/// Errors returned when validating a Hugging Face link or inspecting a GGUF file header.
public enum CustomModelError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case credentialsInURL
    case unsupportedHost(String)
    case invalidPath(String)
    case notGGUFFile(String)
    case headerTooShort
    case invalidMagic
    case unsupportedVersion(UInt32)
    case limitExceeded(String)
    case corruptedHeader(String)
    case missingArchitecture
    case missingLayerCount
    case missingMemoryMetadata(String)
    case invalidDimension(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let detail): return "Invalid model link: \(detail)"
        case .credentialsInURL: return "Model links must not contain credentials or tokens."
        case .unsupportedHost(let host): return "Only huggingface.co links are supported (got \(host))."
        case .invalidPath(let detail): return "Invalid Hugging Face model path: \(detail)"
        case .notGGUFFile(let name): return "Model file must end in .gguf (got \(name))."
        case .headerTooShort: return "File is too small to contain a valid GGUF header."
        case .invalidMagic: return "File is not a GGUF model (missing GGUF magic bytes)."
        case .unsupportedVersion(let v): return "Unsupported GGUF format version \(v) (expected 2 or 3)."
        case .limitExceeded(let detail): return "GGUF header exceeds safety limits: \(detail)"
        case .corruptedHeader(let detail): return "Corrupted GGUF header: \(detail)"
        case .missingArchitecture: return "GGUF header is missing general.architecture."
        case .missingLayerCount: return "GGUF header is missing the model's block_count."
        case .missingMemoryMetadata(let key): return "GGUF header is missing required memory metadata: \(key)."
        case .invalidDimension(let detail): return "Invalid model dimension in GGUF header: \(detail)"
        }
    }
}

/// Validates and normalizes a user-supplied Hugging Face GGUF URL.
///
/// Browser links using `/blob/<revision>/` are rewritten to `/resolve/<revision>/`
/// so a download fetches binary weights rather than an HTML page. Links with
/// credentials, tokens, path traversal, control characters or non-HTTPS schemes
/// are rejected. Valid percent-encoded path segments are decoded once before
/// constructing `resolveURL` so they are never double-encoded.
public struct HuggingFaceGGUFLink: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let filePath: String
    public let fileName: String
    public let resolveURL: URL

    private static let forbiddenQueryKeys: Set<String> = [
        "token", "access_token", "auth", "authorization", "key", "api_key", "secret", "sig", "signature"
    ]

    public static func parse(_ raw: String) throws -> HuggingFaceGGUFLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else {
            throw CustomModelError.invalidURL("URL is empty or too long.")
        }
        guard !containsControlCharacters(trimmed) else {
            throw CustomModelError.invalidURL("Control characters are not allowed in URLs.")
        }
        guard let components = URLComponents(string: trimmed) else {
            throw CustomModelError.invalidURL("Could not parse URL.")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw CustomModelError.invalidURL("Only https:// links are allowed.")
        }
        if components.user != nil || components.password != nil {
            throw CustomModelError.credentialsInURL
        }
        if let fragment = components.fragment, !fragment.isEmpty {
            throw CustomModelError.invalidURL("URL fragments are not allowed.")
        }
        if let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if forbiddenQueryKeys.contains(name) {
                    throw CustomModelError.credentialsInURL
                }
                if name != "download" {
                    throw CustomModelError.invalidURL("Unsupported query parameter '\(item.name)'.")
                }
            }
        }
        guard let host = components.host?.lowercased(), host == "huggingface.co" else {
            throw CustomModelError.unsupportedHost(components.host ?? "none")
        }
        if let port = components.port, port != 443 {
            throw CustomModelError.invalidURL("Non-standard port \(port) is not allowed.")
        }

        let rawSegments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        // Leading "/" produces one empty first element; no other empty segments are allowed.
        guard rawSegments.first == "", rawSegments.count >= 6 else {
            throw CustomModelError.invalidPath("Expected /<owner>/<repo>/resolve/<revision>/<file>.gguf.")
        }

        var decodedSegments: [String] = []
        decodedSegments.reserveCapacity(rawSegments.count - 1)
        for rawSegment in rawSegments.dropFirst() {
            guard !rawSegment.isEmpty,
                  let decoded = String(rawSegment).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !containsControlCharacters(decoded) else {
                throw CustomModelError.invalidPath("Path traversal, control character, or invalid segment in URL.")
            }
            decodedSegments.append(decoded)
        }

        let owner = decodedSegments[0]
        let repo = decodedSegments[1]
        let mode = decodedSegments[2]
        let revision = decodedSegments[3]
        let fileSegments = Array(decodedSegments.dropFirst(4))
        guard mode == "resolve" || mode == "blob" else {
            throw CustomModelError.invalidPath("Expected '/resolve/' or '/blob/' in Hugging Face path.")
        }
        guard Self.isSafeIdentifier(owner), Self.isSafeIdentifier(repo), Self.isSafeRevision(revision) else {
            throw CustomModelError.invalidPath("Invalid repository or revision characters.")
        }
        for directorySegment in fileSegments.dropLast() {
            guard Self.isSafeDirectorySegment(directorySegment) else {
                throw CustomModelError.invalidPath("Invalid directory segment '\(directorySegment)'.")
            }
        }
        let filePath = fileSegments.joined(separator: "/")
        guard let fileName = fileSegments.last,
              fileName.lowercased().hasSuffix(".gguf"),
              fileName.count > 5,
              Self.isSafeFileName(fileName) else {
            throw CustomModelError.notGGUFFile(fileSegments.last ?? "")
        }

        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = "huggingface.co"
        clean.path = "/\(owner)/\(repo)/resolve/\(revision)/\(filePath)"
        guard let resolveURL = clean.url else {
            throw CustomModelError.invalidURL("Could not construct resolve URL.")
        }

        return HuggingFaceGGUFLink(
            repository: "\(owner)/\(repo)",
            revision: revision,
            filePath: filePath,
            fileName: fileName,
            resolveURL: resolveURL
        )
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func isSafeIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private static func isSafeRevision(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private static func isSafeDirectorySegment(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128,
              !text.hasPrefix("."), !text.hasSuffix("."),
              !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == "+" || scalar == " "
        }
    }

    private static func isSafeFileName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 180, !text.hasPrefix("."), !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." || scalar == "+"
        }
    }
}

/// Prompt and tool template family inferred from a GGUF file's metadata.
public enum GGUFChatTemplateKind: String, Codable, Equatable, Sendable {
    case chatML
    case lfm3
    case miniCPM5
    case gemma
    case llama3

    public static func classify(architecture: String, modelName: String? = nil, chatTemplate: String?) -> GGUFChatTemplateKind {
        let arch = architecture.lowercased()
        let name = (modelName ?? "").lowercased()
        let template = (chatTemplate ?? "").lowercased()
        if arch.hasPrefix("minicpm") || name.contains("minicpm") || (template.contains("<function") && template.contains("<param")) {
            return .miniCPM5
        }
        if arch.hasPrefix("lfm") || name.hasPrefix("lfm") || (template.contains("<|startoftext|>") && template.contains("<|im_start|>")) {
            return .lfm3
        }
        if arch.hasPrefix("gemma") || name.contains("gemma") || template.contains("<start_of_turn>") {
            return .gemma
        }
        if template.contains("<|start_header_id|>") {
            return .llama3
        }
        return .chatML
    }
}

/// Architecture and memory metadata extracted from a GGUF v2/v3 header in pure Swift.
///
/// All dimension fields are validated against strict bounds during parsing, and all
/// memory calculations use saturating `UInt64` arithmetic so untrusted headers can
/// never trigger an integer overflow trap.
public struct GGUFHeader: Equatable, Sendable {
    /// Maximum header slice read from disk or network (`256 KB`).
    public static let maxHeaderBytes = 256 * 1024
    /// Maximum metadata key-value entries scanned in one header.
    public static let maxMetadataEntries: UInt64 = 2_048
    /// Maximum length in bytes of a single metadata key or string value (`32 KB`).
    public static let maxStringBytes: UInt64 = 32 * 1024
    /// Maximum elements allowed in a non-tokenizer metadata array (`4,096`).
    public static let maxArrayElements: UInt64 = 4_096

    public static let maxLayerCount = 512
    public static let maxHeadCount = 256
    public static let maxHeadDimension = 4_096
    public static let maxEmbeddingLength = 65_536
    public static let maxContextLength = 1_048_576
    public static let maxSSMInnerSize = 65_536
    public static let maxSSMStateSize = 4_096
    public static let maxSSMConvKernel = 256

    /// Architectures whose KV and recurrent/shortconv state layout is explicitly modeled and tested.
    public static let modeledArchitectures: Set<String> = [
        "llama", "qwen2", "qwen35", "lfm2", "lfm3"
    ]

    public let version: UInt32
    public let tensorCount: UInt64
    public let metadataCount: UInt64
    public let architecture: String
    public let modelName: String?
    public let layerCount: Int
    public let attentionLayerCount: Int
    public let fullAttentionInterval: Int
    public let kvHeadCount: Int
    public let keyLength: Int
    public let valueLength: Int
    public let contextLength: UInt32
    public let ssmInnerSize: Int
    public let ssmStateSize: Int
    public let ssmConvKernel: Int
    public let fileType: UInt32?
    public let chatTemplateKind: GGUFChatTemplateKind
    /// True only when `architecture` belongs to `modeledArchitectures` and its full
    /// KV / recurrent / shortconv memory formula is accounted for.
    public let hasCompleteMemoryModel: Bool

    fileprivate static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : result
    }

    fileprivate static func saturatingMul(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? UInt64.max : result
    }

    private var kvValuesPerToken: UInt64 {
        let layers = UInt64(max(0, attentionLayerCount))
        let heads = UInt64(max(0, kvHeadCount))
        let keyVal = Self.saturatingAdd(UInt64(max(0, keyLength)), UInt64(max(0, valueLength)))
        return Self.saturatingMul(Self.saturatingMul(layers, heads), keyVal)
    }

    /// Q4_0 stores 32 values in 2 bytes of FP16 scale plus 16 bytes of 4-bit quants (18 bytes per 32 values).
    public var q4KVBytesPerToken: UInt64 {
        let values = kvValuesPerToken
        let (prod, overflow1) = values.multipliedReportingOverflow(by: 18)
        if overflow1 { return UInt64.max }
        let (sum, overflow2) = prod.addingReportingOverflow(31)
        if overflow2 { return UInt64.max }
        return sum / 32
    }

    /// FP16 KV cache stores 2 bytes per element.
    public var f16KVBytesPerToken: UInt64 {
        Self.saturatingMul(kvValuesPerToken, 2)
    }

    /// Estimated unified memory required for the given weight file size and context window,
    /// using the same formula and 384 MB app headroom as `ModelArchitecture.requiredBytes`.
    /// Defaults conservatively to `quantizedKV = false` (FP16 KV cache).
    public func requiredBytes(weights: UInt64, contextSize: UInt32, quantizedKV: Bool = false,
                              appHeadroom: UInt64 = 384_000_000) -> UInt64 {
        let perToken = quantizedKV ? q4KVBytesPerToken : f16KVBytesPerToken
        let kv = Self.saturatingMul(UInt64(contextSize), perToken)
        let linearLayers = UInt64(max(0, layerCount - attentionLayerCount))
        let inner = UInt64(max(0, ssmInnerSize))
        let stateBytes = Self.saturatingMul(Self.saturatingMul(inner, UInt64(max(0, ssmStateSize))), 4)
        let convBytes = Self.saturatingMul(Self.saturatingMul(UInt64(max(0, ssmConvKernel)), inner), 4)
        let recurrentPerLayer = Self.saturatingAdd(stateBytes, convBytes)
        let recurrentTotal = Self.saturatingMul(linearLayers, recurrentPerLayer)
        return Self.saturatingAdd(Self.saturatingAdd(weights, kv), Self.saturatingAdd(recurrentTotal, appHeadroom))
    }

    /// Parses a GGUF v2 or v3 binary header from `data`.
    ///
    /// Early termination is permitted **only** inside `tokenizer.*` metadata entries
    /// (such as the large `tokenizer.ggml.tokens` vocabulary table at the end of a
    /// 64–256 KB header prefix slice) and only after all required architectural and
    /// memory dimensions have been read. Truncation anywhere in `general.*` or
    /// `<arch>.*` metadata fails closed.
    public static func parse(_ data: Data) throws -> GGUFHeader {
        let slice = data.count > maxHeaderBytes ? data.prefix(maxHeaderBytes) : data
        guard slice.count >= 24 else { throw CustomModelError.headerTooShort }

        var reader = BinaryReader(slice)
        let magic = try reader.readBytes(4, allowEOF: false)
        guard magic.elementsEqual([0x47, 0x47, 0x55, 0x46]) else {
            throw CustomModelError.invalidMagic
        }
        let version = try reader.readUInt32(allowEOF: false)
        guard version == 2 || version == 3 else {
            throw CustomModelError.unsupportedVersion(version)
        }
        let tensorCount = try reader.readUInt64(allowEOF: false)
        let metadataCount = try reader.readUInt64(allowEOF: false)
        guard metadataCount <= maxMetadataEntries else {
            throw CustomModelError.limitExceeded("metadata_kv_count \(metadataCount) > \(maxMetadataEntries)")
        }

        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]
        var intArrays: [String: [Int]] = [:]
        var overflowKeys: Set<String> = []
        var enteredTokenizerSection = false
        var seenKeys: Set<String> = []

        for _ in 0..<metadataCount {
            let key: String
            do {
                key = try reader.readString(maxBytes: maxStringBytes, allowEOF: enteredTokenizerSection)
            } catch BinaryReader.TokenizerPrefixTruncated.truncatedInTokenizer {
                break
            }
            guard seenKeys.insert(key).inserted else {
                throw CustomModelError.corruptedHeader("Duplicate metadata key '\(key)'.")
            }
            if key.hasPrefix("tokenizer.") {
                enteredTokenizerSection = true
            }
            let isTokenizerKey = key.hasPrefix("tokenizer.")
            do {
                let rawType = try reader.readUInt32(allowEOF: isTokenizerKey)
                try reader.readValue(
                    forKey: key,
                    rawType: rawType,
                    allowTokenizerTruncation: isTokenizerKey,
                    strings: &strings,
                    ints: &ints,
                    intArrays: &intArrays,
                    overflowKeys: &overflowKeys
                )
            } catch BinaryReader.TokenizerPrefixTruncated.truncatedInTokenizer {
                break
            }
        }

        guard let arch = strings["general.architecture"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !arch.isEmpty else {
            throw CustomModelError.missingArchitecture
        }

        let archPrefix = "\(arch)."
        for key in overflowKeys where key.hasPrefix(archPrefix) || key == "general.file_type" {
            throw CustomModelError.invalidDimension("64-bit integer overflow for key '\(key)'.")
        }

        guard let layerCount = ints["\(arch).block_count"] else {
            throw CustomModelError.missingLayerCount
        }
        guard (1...maxLayerCount).contains(layerCount) else {
            throw CustomModelError.invalidDimension("\(arch).block_count=\(layerCount) outside 1...\(maxLayerCount).")
        }

        guard let rawContext = ints["\(arch).context_length"] else {
            throw CustomModelError.missingMemoryMetadata("\(arch).context_length")
        }
        guard (1...maxContextLength).contains(rawContext) else {
            throw CustomModelError.invalidDimension("\(arch).context_length=\(rawContext) outside 1...\(maxContextLength).")
        }
        let contextLength = UInt32(rawContext)

        let interval: Int
        if let rawInterval = ints["\(arch).full_attention_interval"] {
            guard (1...layerCount).contains(rawInterval), layerCount % rawInterval == 0 else {
                throw CustomModelError.invalidDimension("\(arch).full_attention_interval=\(rawInterval) invalid for \(layerCount) layers.")
            }
            interval = rawInterval
        } else {
            interval = 1
        }

        let attentionLayers: Int
        let kvHeads: Int
        if let headArray = intArrays["\(arch).attention.head_count_kv"] {
            guard headArray.count == layerCount else {
                throw CustomModelError.invalidDimension(
                    "\(arch).attention.head_count_kv array count \(headArray.count) != block_count \(layerCount)."
                )
            }
            guard headArray.allSatisfy({ (0...maxHeadCount).contains($0) }) else {
                throw CustomModelError.invalidDimension("\(arch).attention.head_count_kv contains out-of-range head count.")
            }
            let nonZero = headArray.filter { $0 > 0 }
            guard let maxKV = nonZero.max() else {
                throw CustomModelError.invalidDimension("\(arch).attention.head_count_kv has no active attention layers.")
            }
            attentionLayers = nonZero.count
            kvHeads = maxKV
        } else if let scalarKV = ints["\(arch).attention.head_count_kv"] ?? ints["\(arch).attention.head_count"] {
            guard (1...maxHeadCount).contains(scalarKV) else {
                throw CustomModelError.invalidDimension("head_count_kv=\(scalarKV) outside 1...\(maxHeadCount).")
            }
            attentionLayers = interval > 1 ? (layerCount / interval) : layerCount
            kvHeads = scalarKV
        } else {
            throw CustomModelError.missingMemoryMetadata("\(arch).attention.head_count_kv")
        }

        let keyLength: Int
        if let explicitKeyLen = ints["\(arch).attention.key_length"] {
            guard (1...maxHeadDimension).contains(explicitKeyLen) else {
                throw CustomModelError.invalidDimension("\(arch).attention.key_length=\(explicitKeyLen) outside 1...\(maxHeadDimension).")
            }
            keyLength = explicitKeyLen
        } else if let embeddingLength = ints["\(arch).embedding_length"],
                  let qHeads = ints["\(arch).attention.head_count"] {
            guard (1...maxEmbeddingLength).contains(embeddingLength),
                  (1...maxHeadCount).contains(qHeads),
                  embeddingLength % qHeads == 0 else {
                throw CustomModelError.invalidDimension(
                    "Cannot derive key_length from embedding_length=\(embeddingLength) and head_count=\(qHeads)."
                )
            }
            let derived = embeddingLength / qHeads
            guard (1...maxHeadDimension).contains(derived) else {
                throw CustomModelError.invalidDimension("Derived key_length=\(derived) outside 1...\(maxHeadDimension).")
            }
            keyLength = derived
        } else {
            throw CustomModelError.missingMemoryMetadata("\(arch).attention.key_length")
        }

        let valueLength: Int
        if let explicitValLen = ints["\(arch).attention.value_length"] {
            guard (1...maxHeadDimension).contains(explicitValLen) else {
                throw CustomModelError.invalidDimension("\(arch).attention.value_length=\(explicitValLen) outside 1...\(maxHeadDimension).")
            }
            valueLength = explicitValLen
        } else {
            valueLength = keyLength
        }

        let archLower = arch.lowercased()
        let isLFMFamily = archLower == "lfm2" || archLower == "lfm3"

        // LFM2 / LFM3 store short-convolution state as `<arch>.shortconv.l_cache`
        // and `<arch>.embedding_length` rather than `<arch>.ssm.{inner_size,conv_kernel}`.
        let rawSSMInner = ints["\(arch).ssm.inner_size"]
            ?? (isLFMFamily && attentionLayers < layerCount ? ints["\(arch).embedding_length"] : nil)
            ?? 0
        let rawSSMState = ints["\(arch).ssm.state_size"] ?? 0
        let rawSSMKernel = ints["\(arch).ssm.conv_kernel"]
            ?? (isLFMFamily && attentionLayers < layerCount ? ints["\(arch).shortconv.l_cache"] : nil)
            ?? 0

        guard (0...maxSSMInnerSize).contains(rawSSMInner),
              (0...maxSSMStateSize).contains(rawSSMState),
              (0...maxSSMConvKernel).contains(rawSSMKernel) else {
            throw CustomModelError.invalidDimension(
                "Recurrent/conv dimensions (\(rawSSMInner), \(rawSSMState), \(rawSSMKernel)) out of bounds."
            )
        }

        if interval > 1 {
            guard rawSSMInner > 0, rawSSMState > 0, rawSSMKernel > 0 else {
                throw CustomModelError.missingMemoryMetadata("\(arch).ssm.{inner_size,state_size,conv_kernel}")
            }
        } else if attentionLayers < layerCount {
            guard rawSSMInner > 0, rawSSMKernel > 0 else {
                let needed = isLFMFamily
                    ? "\(arch).{embedding_length,shortconv.l_cache}"
                    : "\(arch).ssm.{inner_size,conv_kernel}"
                throw CustomModelError.missingMemoryMetadata(needed)
            }
        }

        let fileType: UInt32?
        if let rawFT = ints["general.file_type"] {
            guard rawFT >= 0, let ft = UInt32(exactly: rawFT) else {
                throw CustomModelError.invalidDimension("general.file_type=\(rawFT) is negative or out of range.")
            }
            fileType = ft
        } else {
            fileType = nil
        }

        let templateKind = GGUFChatTemplateKind.classify(
            architecture: arch,
            modelName: strings["general.name"],
            chatTemplate: strings["tokenizer.chat_template"]
        )
        let hasCompleteMemoryModel = modeledArchitectures.contains(archLower)

        return GGUFHeader(
            version: version,
            tensorCount: tensorCount,
            metadataCount: metadataCount,
            architecture: arch,
            modelName: strings["general.name"],
            layerCount: layerCount,
            attentionLayerCount: attentionLayers,
            fullAttentionInterval: interval,
            kvHeadCount: kvHeads,
            keyLength: keyLength,
            valueLength: valueLength,
            contextLength: contextLength,
            ssmInnerSize: rawSSMInner,
            ssmStateSize: rawSSMState,
            ssmConvKernel: rawSSMKernel,
            fileType: fileType,
            chatTemplateKind: templateKind,
            hasCompleteMemoryModel: hasCompleteMemoryModel
        )
    }
}

private struct BinaryReader {
    enum TokenizerPrefixTruncated: Error {
        case truncatedInTokenizer
    }

    let bytes: [UInt8]
    var offset: Int = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func readBytes(_ count: Int, allowEOF: Bool) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            if allowEOF { throw TokenizerPrefixTruncated.truncatedInTokenizer }
            throw CustomModelError.corruptedHeader("Unexpected end of GGUF header at byte \(offset).")
        }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return slice
    }

    mutating func skip(_ count: Int, allowEOF: Bool) throws {
        guard count >= 0, offset + count <= bytes.count else {
            if allowEOF { throw TokenizerPrefixTruncated.truncatedInTokenizer }
            throw CustomModelError.corruptedHeader("Unexpected end of GGUF header while skipping \(count) bytes at \(offset).")
        }
        offset += count
    }

    mutating func readUInt8(allowEOF: Bool) throws -> UInt8 {
        let slice = try readBytes(1, allowEOF: allowEOF)
        return slice[slice.startIndex]
    }

    mutating func readUInt16(allowEOF: Bool) throws -> UInt16 {
        let s = try readBytes(2, allowEOF: allowEOF)
        let i = s.startIndex
        return UInt16(s[i]) | (UInt16(s[i + 1]) << 8)
    }

    mutating func readUInt32(allowEOF: Bool) throws -> UInt32 {
        let s = try readBytes(4, allowEOF: allowEOF)
        let i = s.startIndex
        return UInt32(s[i])
            | (UInt32(s[i + 1]) << 8)
            | (UInt32(s[i + 2]) << 16)
            | (UInt32(s[i + 3]) << 24)
    }

    mutating func readUInt64(allowEOF: Bool) throws -> UInt64 {
        let low = UInt64(try readUInt32(allowEOF: allowEOF))
        let high = UInt64(try readUInt32(allowEOF: allowEOF))
        return low | (high << 32)
    }

    mutating func readString(maxBytes: UInt64, allowEOF: Bool) throws -> String {
        let length = try readUInt64(allowEOF: allowEOF)
        guard length <= maxBytes else {
            throw CustomModelError.limitExceeded("String length \(length) > \(maxBytes)")
        }
        let slice = try readBytes(Int(length), allowEOF: allowEOF)
        guard let string = String(bytes: slice, encoding: .utf8) else {
            throw CustomModelError.corruptedHeader("Non-UTF8 string in GGUF metadata.")
        }
        return string
    }

    mutating func readValue(
        forKey key: String,
        rawType: UInt32,
        allowTokenizerTruncation: Bool,
        strings: inout [String: String],
        ints: inout [String: Int],
        intArrays: inout [String: [Int]],
        overflowKeys: inout Set<String>
    ) throws {
        if key.hasSuffix(".head_count_kv"), ![UInt32(0), 1, 2, 3, 4, 5, 9, 10, 11].contains(rawType) {
            throw CustomModelError.invalidDimension("KV-head metadata must contain integers for '\(key)'.")
        }
        switch rawType {
        case 0: // UINT8
            ints[key] = Int(try readUInt8(allowEOF: allowTokenizerTruncation))
        case 1: // INT8
            ints[key] = Int(Int8(bitPattern: try readUInt8(allowEOF: allowTokenizerTruncation)))
        case 2: // UINT16
            ints[key] = Int(try readUInt16(allowEOF: allowTokenizerTruncation))
        case 3: // INT16
            ints[key] = Int(Int16(bitPattern: try readUInt16(allowEOF: allowTokenizerTruncation)))
        case 4: // UINT32
            ints[key] = Int(try readUInt32(allowEOF: allowTokenizerTruncation))
        case 5: // INT32
            ints[key] = Int(Int32(bitPattern: try readUInt32(allowEOF: allowTokenizerTruncation)))
        case 6: // FLOAT32
            try skip(4, allowEOF: allowTokenizerTruncation)
        case 7: // BOOL
            let flag = try readUInt8(allowEOF: allowTokenizerTruncation)
            guard flag == 0 || flag == 1 else {
                throw CustomModelError.corruptedHeader("Invalid GGUF bool value \(flag) for key '\(key)'.")
            }
            ints[key] = Int(flag)
        case 8: // STRING
            let value = try readString(maxBytes: GGUFHeader.maxStringBytes, allowEOF: allowTokenizerTruncation)
            strings[key] = value
        case 9: // ARRAY
            let elementType = try readUInt32(allowEOF: allowTokenizerTruncation)
            let count = try readUInt64(allowEOF: allowTokenizerTruncation)
            if key.hasSuffix(".head_count_kv") {
                guard count <= UInt64(GGUFHeader.maxLayerCount), elementType == 4 || elementType == 5 else {
                    throw CustomModelError.invalidDimension("Invalid KV-head array shape or element type for '\(key)'.")
                }
            }
            if count > GGUFHeader.maxArrayElements {
                // Fixed-size scalar arrays (such as prism.hadamard.sign_values with 15,872 elements
                // or tokenizer.ggml.token_type) allocate zero memory when skipped in place.
                if let scalarSize = Self.scalarByteSize(for: elementType),
                   count <= 1_000_000,
                   let byteCount = Self.checkedByteCount(count: count, scalarSize: scalarSize),
                   byteCount <= remaining {
                    try skip(byteCount, allowEOF: allowTokenizerTruncation)
                    return
                }
                guard allowTokenizerTruncation else {
                    throw CustomModelError.limitExceeded("Array '\(key)' length \(count) > \(GGUFHeader.maxArrayElements)")
                }
                throw TokenizerPrefixTruncated.truncatedInTokenizer
            }
            if (elementType == 4 || elementType == 5), key.hasSuffix(".head_count_kv") {
                var values: [Int] = []
                values.reserveCapacity(Int(count))
                for _ in 0..<count {
                    let raw = try readUInt32(allowEOF: false)
                    let val = elementType == 4 ? Int(raw) : Int(Int32(bitPattern: raw))
                    values.append(val)
                }
                intArrays[key] = values
            } else if let scalarSize = Self.scalarByteSize(for: elementType) {
                guard let byteCount = Self.checkedByteCount(count: count, scalarSize: scalarSize) else {
                    throw CustomModelError.limitExceeded("Array '\(key)' byte size overflow.")
                }
                try skip(byteCount, allowEOF: allowTokenizerTruncation)
            } else if elementType == 8 {
                for _ in 0..<count {
                    _ = try readString(maxBytes: GGUFHeader.maxStringBytes, allowEOF: allowTokenizerTruncation)
                }
            } else {
                throw CustomModelError.corruptedHeader("Nested or unknown GGUF array element type \(elementType).")
            }
        case 10: // UINT64
            let raw = try readUInt64(allowEOF: allowTokenizerTruncation)
            if let value = Int(exactly: raw) {
                ints[key] = value
            } else {
                overflowKeys.insert(key)
            }
        case 11: // INT64
            let raw = Int64(bitPattern: try readUInt64(allowEOF: allowTokenizerTruncation))
            if let value = Int(exactly: raw) {
                ints[key] = value
            } else {
                overflowKeys.insert(key)
            }
        case 12: // FLOAT64
            try skip(8, allowEOF: allowTokenizerTruncation)
        default:
            throw CustomModelError.corruptedHeader("Unknown GGUF metadata value type \(rawType) for key '\(key)'.")
        }
    }

    private static func checkedByteCount(count: UInt64, scalarSize: Int) -> Int? {
        guard scalarSize > 0 else { return nil }
        let (product, overflow) = count.multipliedReportingOverflow(by: UInt64(scalarSize))
        guard !overflow else { return nil }
        return Int(exactly: product)
    }

    private static func scalarByteSize(for rawType: UInt32) -> Int? {
        switch rawType {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }
}

/// Evaluates whether a model fits inside a heuristic per-process memory budget.
public enum MemoryFitVerdict: Equatable, Sendable {
    /// Fits at the requested target context window.
    case fits(contextSize: UInt32, requiredBytes: UInt64, budgetBytes: UInt64)
    /// Weights fit, but the context window had to be stepped down to stay within the heuristic budget.
    case reducedContext(contextSize: UInt32, requiredBytes: UInt64, budgetBytes: UInt64)
    /// Requested or model-supported context is below `DeviceMemoryGate.minimumAgentContext` (2,048 tokens).
    case contextBelowMinimum(contextSize: UInt32, minimumRequired: UInt32)
    /// Architecture is not in `GGUFHeader.modeledArchitectures`, so no memory estimate is offered.
    case unsupportedArchitecture(String)
    /// Even at the minimum 2,048-token agent context window, the model exceeds the heuristic budget.
    case tooLarge(requiredBytes: UInt64, budgetBytes: UInt64)

    public var isRunnable: Bool {
        switch self {
        case .fits, .reducedContext: return true
        case .contextBelowMinimum, .unsupportedArchitecture, .tooLarge: return false
        }
    }
}

public enum DeviceMemoryGate {
    public static let minimumAgentContext: UInt32 = 2_048
    private static let candidateContexts: [UInt32] = [32_768, 16_384, 8_192, 4_096, 2_048]

    /// Returns a conservative heuristic estimate of single-app memory headroom from physical RAM.
    ///
    /// Based on published device tables referenced in `docs/ON_DEVICE_PLAN.md` §1 (~4.5 GB on an
    /// 8 GB iPhone 15 Pro). This is a planning heuristic, not an OS-guaranteed Metal or Jetsam limit.
    public static func estimatedAppBudgetBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        let gb = physicalMemoryBytes / 1_000_000_000
        if gb < 6 {
            return GGUFHeader.saturatingMul(physicalMemoryBytes / 100, 50)
        } else if gb < 8 {
            return 3_000_000_000
        } else if gb < 12 {
            return 4_500_000_000
        } else if gb < 16 {
            return 7_000_000_000
        } else {
            return GGUFHeader.saturatingMul(physicalMemoryBytes / 100, 60)
        }
    }

    public static func appMemoryBudgetBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Evaluates whether `header` and `weightBytes` fit within `estimatedAppBudgetBytes`.
    ///
    /// Defaults conservatively to `quantizedKV = false` (FP16 KV cache), because only
    /// specific model paths (such as Bonsai `Q2_0`) enable `Q4_0` KV cache in the app.
    public static func evaluate(header: GGUFHeader, weightBytes: UInt64,
                                targetContext: UInt32 = 8_192,
                                quantizedKV: Bool = false,
                                physicalMemoryBytes: UInt64) -> MemoryFitVerdict {
        guard header.hasCompleteMemoryModel else {
            return .unsupportedArchitecture(header.architecture)
        }
        guard targetContext >= minimumAgentContext, header.contextLength >= minimumAgentContext else {
            return .contextBelowMinimum(
                contextSize: min(targetContext, header.contextLength),
                minimumRequired: minimumAgentContext
            )
        }

        let budget = estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
        let cappedTarget = min(targetContext, header.contextLength)
        let targetRequired = header.requiredBytes(weights: weightBytes, contextSize: cappedTarget, quantizedKV: quantizedKV)
        if targetRequired <= budget {
            return .fits(contextSize: cappedTarget, requiredBytes: targetRequired, budgetBytes: budget)
        }

        for candidate in candidateContexts where candidate < cappedTarget && candidate >= minimumAgentContext {
            let req = header.requiredBytes(weights: weightBytes, contextSize: candidate, quantizedKV: quantizedKV)
            if req <= budget {
                return .reducedContext(contextSize: candidate, requiredBytes: req, budgetBytes: budget)
            }
        }

        let minRequired = header.requiredBytes(weights: weightBytes, contextSize: minimumAgentContext, quantizedKV: quantizedKV)
        return .tooLarge(requiredBytes: minRequired, budgetBytes: budget)
    }
}

/// Primary operational role for an on-device candidate model.
public enum AgentModelRole: String, Codable, Equatable, Sendable {
    case routerAndExtraction
    case codingAndSearch
    case functionSpecialist
    case deliberativeSub1GB
    case ternaryKnowledge
}

/// Upstream HTTP reachability status from unauthenticated HEAD probes (2026-11-14).
public enum CatalogAvailability: String, Codable, Equatable, Sendable {
    /// Unauthenticated `HEAD` returned 200 OK, but the revision and SHA-256 are not yet pinned in `ModelLibrary`.
    case unverifiedReachable
    /// Unauthenticated `HEAD` returned 401 or 404 (gated, renamed, or unavailable without authentication).
    case gatedOrUnavailable
}

/// Candidate entry for the planned "Experimental" model shelf.
///
/// Entries with `isVerifiedDownload == false` are unverified candidate specs (their
/// URLs point to `resolve/main/` without a pinned commit revision or SHA-256 checksum)
/// and must not be installed automatically until pinned and verified. Entries whose
/// upstream URL returned 401/404 (`availability == .gatedOrUnavailable`) are excluded
/// from `available(forPhysicalMemoryBytes:)` by default.
public struct ExperimentalModelSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let role: AgentModelRole
    public let link: HuggingFaceGGUFLink
    public let estimatedBytes: UInt64
    public let minimumPhysicalRAMGB: Int
    public let defaultContextSize: UInt32
    public let templateKind: GGUFChatTemplateKind
    public let availability: CatalogAvailability
    public let isVerifiedDownload: Bool

    public func isSupported(physicalMemoryBytes: UInt64, includeUnavailable: Bool = false) -> Bool {
        if !includeUnavailable && availability != .unverifiedReachable {
            return false
        }
        let ramGB = physicalMemoryBytes / 1_000_000_000
        return ramGB >= UInt64(max(0, minimumPhysicalRAMGB))
    }

    public static let shelf: [ExperimentalModelSpec] = [
        ExperimentalModelSpec(
            id: "lfm25-1.2b-thinking",
            name: "LFM 2.5 · 1.2B Thinking (Experimental)",
            detail: "Unverified candidate spec (730,899,072 bytes): sub-1GB hybrid thinking model for 6 GB+ devices; unmeasured in Keel.",
            role: .deliberativeSub1GB,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf"),
            estimatedBytes: 730_899_072,
            minimumPhysicalRAMGB: 6,
            defaultContextSize: 8_192,
            templateKind: .lfm3,
            availability: .unverifiedReachable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "mini-agent-v2",
            name: "mini-agent-v2 · 1.5B (Experimental)",
            detail: "Unverified candidate spec (986,050,816 bytes): Qwen2.5-Coder 1.5B fine-tune for 6 GB+ devices; unmeasured in Keel.",
            role: .functionSpecialist,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/F-A-I-L/mini-agent-v2-GGUF/resolve/main/mini-agent-v2-Q4_K_M.gguf"),
            estimatedBytes: 986_050_816,
            minimumPhysicalRAMGB: 6,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .unverifiedReachable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "ternary-bonsai-8b",
            name: "Ternary Bonsai · 8B (Experimental)",
            detail: "Unverified candidate spec (2,182,184,672 bytes): ternary 8B Q2_0 model for 8 GB+ devices; unmeasured in Keel.",
            role: .ternaryKnowledge,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/prism-ml/Ternary-Bonsai-8B-gguf/resolve/main/Ternary-Bonsai-8B-Q2_0.gguf"),
            estimatedBytes: 2_182_184_672,
            minimumPhysicalRAMGB: 8,
            defaultContextSize: 16_384,
            templateKind: .chatML,
            availability: .unverifiedReachable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "ternary-bonsai-2-27b",
            name: "Ternary Bonsai 2 · 27B (16 GB+ iPad Pro)",
            detail: "Unverified candidate spec (7,626,008,928 bytes): 27B ternary Q2_0 model, reserved for the planned 16 GB+ tier. Memory fit is unmeasured.",
            role: .ternaryKnowledge,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/main/Ternary-Bonsai-2-27B-Q2_0.gguf"),
            estimatedBytes: 7_626_008_928,
            minimumPhysicalRAMGB: 16,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .unverifiedReachable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "xlam-2-1b-fc-r",
            name: "xLAM 2 · 1B FC-R (Unavailable / Unverified)",
            detail: "Disabled candidate spec: upstream GGUF path returned HTTP 404 on 2026-11-14.",
            role: .functionSpecialist,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/Salesforce/xLAM-2-1b-fc-r-gguf/resolve/main/xLAM-2-1b-fc-r-Q4_K_M.gguf"),
            estimatedBytes: 650_000_000,
            minimumPhysicalRAMGB: 6,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .gatedOrUnavailable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "hammer-2.0-1.5b",
            name: "Hammer 2.0 · 1.5B (Gated / Unverified)",
            detail: "Disabled candidate spec: upstream repository returned HTTP 401 without authentication on 2026-11-14.",
            role: .functionSpecialist,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/MadeAgents/Hammer2.0-1.5b-gguf/resolve/main/hammer2.0-1.5b-q4_k_m.gguf"),
            estimatedBytes: 990_000_000,
            minimumPhysicalRAMGB: 6,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .gatedOrUnavailable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "granite-4.2-3b",
            name: "Granite 4.2 · 3B (Gated / Unverified)",
            detail: "Disabled candidate spec: upstream repository returned HTTP 401 without authentication on 2026-11-14.",
            role: .codingAndSearch,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/ibm-granite/granite-4.2-3b-instruct-GGUF/resolve/main/granite-4.2-3b-instruct-Q4_K_M.gguf"),
            estimatedBytes: 1_920_000_000,
            minimumPhysicalRAMGB: 8,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .gatedOrUnavailable,
            isVerifiedDownload: false
        ),
        ExperimentalModelSpec(
            id: "qwen3-4b-2507",
            name: "Qwen 3 · 4B 2507 (Gated / Unverified)",
            detail: "Disabled candidate spec: upstream repository returned HTTP 401 without authentication on 2026-11-14.",
            role: .codingAndSearch,
            link: try! HuggingFaceGGUFLink.parse("https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
            estimatedBytes: 2_650_000_000,
            minimumPhysicalRAMGB: 8,
            defaultContextSize: 8_192,
            templateKind: .chatML,
            availability: .gatedOrUnavailable,
            isVerifiedDownload: false
        )
    ]

    public static func available(forPhysicalMemoryBytes bytes: UInt64, includeUnavailable: Bool = false) -> [ExperimentalModelSpec] {
        shelf.filter { $0.isSupported(physicalMemoryBytes: bytes, includeUnavailable: includeUnavailable) }
    }
}

/// Descriptor for a tool in a larger catalog (workspace, connectors, media presets)
/// used by `DynamicToolSelector`.
public struct ToolRouteCandidate: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let keywords: [String]
    /// Tools commonly needed after this tool runs.
    public let followUpTools: [String]
    public let isCoreFallback: Bool

    public init(name: String, summary: String, keywords: [String],
                followUpTools: [String] = [], isCoreFallback: Bool = false) {
        self.name = name
        self.summary = summary
        self.keywords = keywords
        self.followUpTools = followUpTools
        self.isCoreFallback = isCoreFallback
    }
}

/// Unwired lexical and follow-up heuristic for selecting a small active tool subset.
///
/// This is a lightweight keyword + recent-turn follow-up heuristic inspired by
/// dynamic tool retrieval ideas, not a trained embedding retriever. It is not wired
/// into the app and must be evaluated with `tools/harness-eval` before adoption.
public enum DynamicToolSelector {
    public static let defaultMaxActiveTools = 5

    public static func select(
        from catalog: [ToolRouteCandidate],
        query: String,
        recentToolNames: [String] = [],
        maxActiveTools: Int = defaultMaxActiveTools
    ) -> [ToolRouteCandidate] {
        let limit = max(1, maxActiveTools)
        guard catalog.count > limit else { return catalog }

        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
        let warmNames = Array(recentToolNames.suffix(2))
        var selected: [ToolRouteCandidate] = []
        var seen: Set<String> = []

        func appendIfNeeded(_ candidate: ToolRouteCandidate) {
            guard selected.count < limit, !seen.contains(candidate.name) else { return }
            seen.insert(candidate.name)
            selected.append(candidate)
        }

        // 1. Keep warm tools from the last two turns in the active schema list.
        for name in warmNames {
            if let tool = byName[name] { appendIfNeeded(tool) }
        }

        // 2. Score remaining tools using query tokens + follow-up boosts from recent tools.
        let queryTokens = tokenize(query)
        let followUpBoosts = Set(warmNames.compactMap { byName[$0]?.followUpTools }.joined())

        var scored: [(candidate: ToolRouteCandidate, score: Int, index: Int)] = []
        for (index, candidate) in catalog.enumerated() where !seen.contains(candidate.name) {
            var score = 0
            let toolTokens = tokenize(candidate.name + " " + candidate.summary + " " + candidate.keywords.joined(separator: " "))
            for token in queryTokens where toolTokens.contains(token) {
                score += 2
            }
            for keyword in candidate.keywords {
                let kw = keyword.lowercased()
                if !kw.isEmpty, query.lowercased().contains(kw) {
                    score += 3
                }
            }
            if followUpBoosts.contains(candidate.name) {
                score += 4
            }
            if score > 0 {
                scored.append((candidate, score, index))
            }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        for entry in scored {
            appendIfNeeded(entry.candidate)
        }

        // 3. On ambiguous queries (or remaining slots), fill from the core fallback tools.
        for candidate in catalog where candidate.isCoreFallback {
            appendIfNeeded(candidate)
        }
        for candidate in catalog {
            appendIfNeeded(candidate)
        }

        return selected
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count >= 2 })
    }
}
