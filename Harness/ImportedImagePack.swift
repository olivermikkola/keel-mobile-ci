import Foundation

/// A user-supplied Core ML Stable Diffusion pack (from a local folder, `.zip`
/// archive, or public Hugging Face repository).
///
/// Only compiled `apple/ml-stable-diffusion`-layout Stable Diffusion 1.x, 2.x,
/// and LCM packs (`TextEncoder.mlmodelc`, `VAEDecoder.mlmodelc`, `Unet.mlmodelc`
/// or `UnetChunk1.mlmodelc` + `UnetChunk2.mlmodelc`, `vocab.json`, `merges.txt`)
/// are accepted. SDXL, SD3, Flux, and uncompiled `.mlpackage`-only bundles are
/// rejected before any weights are copied or downloaded.
public struct ImportedImagePack: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let bytes: Int64
    public let fileCount: Int
    public let sha256: String
    public var engine: ImageModelPack.Engine
    public let padToken: String
    public let chunkedUnet: Bool
    public let sourceLabel: String

    public static let limit = 6
    public static let maxPackBytes: Int64 = 3_500_000_000
    public static let maxFiles = 512
    public static let defaultNegativePrompt = "blurry, deformed, bad anatomy, low quality, watermark, text"

    public init(
        id: String = ImportedImagePack.newID(),
        name: String,
        bytes: Int64,
        fileCount: Int,
        sha256: String,
        engine: ImageModelPack.Engine,
        padToken: String,
        chunkedUnet: Bool,
        sourceLabel: String
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.bytes = bytes
        self.fileCount = fileCount
        self.sha256 = sha256
        self.engine = engine
        self.padToken = padToken
        self.chunkedUnet = chunkedUnet
        self.sourceLabel = Self.cleanSourceLabel(sourceLabel)
    }

    public var defaultSteps: Int { engine == .lcm ? 8 : 20 }
    public var defaultGuidance: Float { engine == .lcm ? 2.0 : 7.5 }

    public var engineSummary: String {
        let mode = engine == .lcm ? "LCM · 8 steps" : "Standard · 20 steps"
        let clip = padToken == "!" ? "SD 2.x" : "SD 1.x"
        return "\(clip) · \(mode)"
    }

    public func directory(in models: URL) -> URL {
        models.appendingPathComponent("image", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func asImageModelPack() -> ImageModelPack {
        ImageModelPack(
            id: id,
            name: name,
            repository: "imported",
            revision: "imported",
            remoteFolder: "",
            engine: engine,
            defaultSteps: defaultSteps,
            defaultGuidance: defaultGuidance,
            defaultNegativePrompt: Self.defaultNegativePrompt,
            padToken: padToken,
            files: [],
            recordedBytes: bytes
        )
    }

    public static func newID() -> String {
        "custom-img-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func cleanName(_ raw: String) -> String {
        var text = raw
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".zip") {
            text = String(text.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? "Imported image pack" : String(text.prefix(60))
    }

    private static func cleanSourceLabel(_ raw: String) -> String {
        let text = raw
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Files" : String(text.prefix(120))
    }

    /// Infers `.lcm` vs `.standard` from a pack name, zip name, or repo path.
    /// Matches `"lcm"` as an isolated token so unrelated words are never matched.
    public static func inferEngine(from hint: String) -> ImageModelPack.Engine {
        let tokens = hint.lowercased().split { !$0.isLetter && !$0.isNumber }
        return tokens.contains("lcm") ? .lcm : .standard
    }

    /// Detects OpenCLIP (SD 2.x, 1024-wide, pad `"!"`) vs OpenAI CLIP (SD 1.x,
    /// 768-wide, pad `"<|endoftext|>"`) from `TextEncoder.mlmodelc/metadata.json`.
    public static func detectPadToken(textEncoderMetadata: String?) -> String {
        guard let text = textEncoderMetadata else { return "<|endoftext|>" }
        if text.contains("[1, 77, 1024]") || text.contains("77 × 1024") {
            return "!"
        }
        return "<|endoftext|>"
    }

    /// Returns an explanation when `Unet.mlmodelc/metadata.json` belongs to an
    /// unsupported architecture (SDXL/SD3/Flux), or nil when compatible.
    public static func unsupportedMetadataReason(unetMetadata: String?) -> String? {
        guard let text = unetMetadata else { return nil }
        if text.contains("time_ids") || text.contains("text_embeds") {
            return "This looks like an SDXL pack (uses time_ids/text_embeds). Keel supports Stable Diffusion 1.x, 2.x and LCM Core ML packs."
        }
        return nil
    }

    /// Validates that a saved JSON record could only have been written by Keel.
    public var isValid: Bool {
        id.range(of: "^custom-img-[0-9a-f]{32}$", options: .regularExpression) != nil
            && !name.isEmpty && name.count <= 60
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && bytes > 0 && bytes <= Self.maxPackBytes
            && fileCount > 0 && fileCount <= Self.maxFiles
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && (padToken == "<|endoftext|>" || padToken == "!")
            && !sourceLabel.isEmpty && sourceLabel.count <= 120
    }

    /// Reads the saved list, keeping only valid, distinct records up to `limit`.
    public static func load(_ data: Data) -> [ImportedImagePack] {
        guard let records = try? JSONDecoder().decode([ImportedImagePack].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(records.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(limit))
    }

    /// Checks that an installed directory still holds the core compiled bundles
    /// and tokenizer files needed by `TextToImage`.
    public static func isPresent(in directory: URL, chunkedUnet: Bool, fileManager: FileManager = .default) -> Bool {
        var required = [
            "TextEncoder.mlmodelc/coremldata.bin",
            "VAEDecoder.mlmodelc/coremldata.bin",
            "vocab.json",
            "merges.txt",
        ]
        if chunkedUnet {
            required += ["UnetChunk1.mlmodelc/coremldata.bin", "UnetChunk2.mlmodelc/coremldata.bin"]
        } else {
            required.append("Unet.mlmodelc/coremldata.bin")
        }
        return required.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

/// Pure-Swift layout inspector for Core ML Stable Diffusion packs.
///
/// Works identically across local folders, `.zip` archives, and Hugging Face
/// repository trees: finds the best compiled pack root (preferring
/// `split_einsum_v2/compiled` for the Apple Neural Engine), filters out unused
/// bundles (`SafetyChecker`, `VAEEncoder`, `.mlpackage` sources), and enforces
/// memory and size limits before any weights are copied or downloaded.
public enum CoreMLImagePackLayout {
    public struct FileEntry: Equatable, Sendable {
        public let sourcePath: String
        public let relativePath: String
        public let bytes: Int64
        public let sha256: String?

        public init(sourcePath: String, relativePath: String, bytes: Int64, sha256: String? = nil) {
            self.sourcePath = sourcePath
            self.relativePath = relativePath
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Prefix inside the source folder/archive/repo (empty string for root).
        public let rootPrefix: String
        public let chunkedUnet: Bool
        public let files: [FileEntry]
        public let totalBytes: Int64
    }

    public enum Problem: LocalizedError, Equatable, Sendable {
        case empty
        case uncompiledOnly
        case unsupportedArchitecture(String)
        case missingFiles([String])
        case invalidTokenizer(String)
        case tooManyFiles(Int)
        case tooLarge(requiredBytes: UInt64, budgetBytes: UInt64)
        case memory(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "No files were found in this image pack."
            case .uncompiledOnly:
                return "This pack contains uncompiled .mlpackage models. Keel needs a compiled Core ML Stable Diffusion pack (.mlmodelc, such as split_einsum_v2/compiled)."
            case .unsupportedArchitecture(let detail):
                return detail
            case .missingFiles(let names):
                return "This is not a complete Core ML Stable Diffusion pack. Missing: \(names.joined(separator: ", "))."
            case .invalidTokenizer(let detail):
                return "The pack's tokenizer files are invalid: \(detail)"
            case .tooManyFiles(let count):
                return "This image pack has too many files (\(count), limit \(ImportedImagePack.maxFiles))."
            case .tooLarge(let required, let budget):
                return String(
                    format: "This image pack needs about %.1f GB of memory; this device gives an app about %.1f GB.",
                    Double(required) / 1_000_000_000,
                    Double(budget) / 1_000_000_000
                )
            case .memory(let detail):
                return detail
            }
        }
    }

    /// Resolves a list of candidate files from a folder, zip, or Hugging Face tree.
    public static func plan(
        entries: [(path: String, bytes: Int64, sha256: String?)],
        physicalMemoryBytes: UInt64
    ) throws -> Plan {
        let cleaned = entries.compactMap { item -> (path: String, bytes: Int64, sha256: String?)? in
            let normalized = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty, !shouldIgnore(path: normalized), item.bytes >= 0 else { return nil }
            return (normalized, item.bytes, item.sha256)
        }
        guard !cleaned.isEmpty else { throw Problem.empty }

        // Find every directory prefix that holds a `TextEncoder.mlmodelc/coremldata.bin` or `vocab.json`.
        var candidatePrefixes = Set<String>([""])
        for item in cleaned {
            let parts = item.path.split(separator: "/")
            if let markerIndex = parts.firstIndex(where: {
                $0 == "TextEncoder.mlmodelc" || $0 == "Unet.mlmodelc" || $0 == "UnetChunk1.mlmodelc"
                    || $0 == "VAEDecoder.mlmodelc" || $0 == "vocab.json"
            }) {
                let prefix = parts[..<markerIndex].joined(separator: "/")
                candidatePrefixes.insert(prefix)
            }
        }

        // Order candidate roots: prefer Apple Neural Engine split_einsum_v2/compiled first.
        let orderedPrefixes = candidatePrefixes.sorted { a, b in
            let rankA = prefixRank(a)
            let rankB = prefixRank(b)
            if rankA != rankB { return rankA < rankB }
            return a.count < b.count
        }

        var firstError: Problem?
        for prefix in orderedPrefixes {
            do {
                return try validatePrefix(prefix, entries: cleaned, physicalMemoryBytes: physicalMemoryBytes)
            } catch let problem as Problem {
                if case .unsupportedArchitecture = problem { throw problem }
                if case .tooLarge = problem { throw problem }
                if firstError == nil { firstError = problem }
            }
        }

        // Distinguish uncompiled .mlpackage repos from unrelated folders.
        let hasMLPackage = cleaned.contains {
            $0.path.contains(".mlpackage/") && ($0.path.contains("Unet") || $0.path.contains("TextEncoder"))
        }
        if hasMLPackage {
            throw Problem.uncompiledOnly
        }
        throw firstError ?? Problem.missingFiles(["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"])
    }

    /// Validates `vocab.json` and `merges.txt` contents before committing an import.
    public static func validateTokenizer(vocabData: Data, mergesData: Data) throws {
        guard !vocabData.isEmpty, vocabData.count <= 20_000_000 else {
            throw Problem.invalidTokenizer("vocab.json is empty or too large.")
        }
        guard let vocab = try? JSONSerialization.jsonObject(with: vocabData) as? [String: Any], !vocab.isEmpty else {
            throw Problem.invalidTokenizer("vocab.json must be a JSON object mapping tokens to IDs.")
        }
        guard !mergesData.isEmpty, mergesData.count <= 20_000_000,
              let merges = String(data: mergesData, encoding: .utf8),
              merges.contains("\n") else {
            throw Problem.invalidTokenizer("merges.txt must be a non-empty UTF-8 BPE merge table.")
        }
    }

    private static func validatePrefix(
        _ prefix: String,
        entries: [(path: String, bytes: Int64, sha256: String?)],
        physicalMemoryBytes: UInt64
    ) throws -> Plan {
        let scoped: [(source: String, relative: String, bytes: Int64, sha256: String?)]
        if prefix.isEmpty {
            scoped = entries.map { ($0.path, $0.path, $0.bytes, $0.sha256) }
        } else {
            let head = prefix + "/"
            scoped = entries.compactMap { item in
                guard item.path.hasPrefix(head) else { return nil }
                return (item.path, String(item.path.dropFirst(head.count)), item.bytes, item.sha256)
            }
        }

        let topNames = Set(scoped.compactMap { $0.relative.split(separator: "/").first.map(String.init) })
        if topNames.contains("TextEncoder2.mlmodelc") || topNames.contains("T5Encoder.mlmodelc")
            || topNames.contains("MMDiT.mlmodelc") || topNames.contains("MultimodalDiffusionTransformer.mlmodelc") {
            throw Problem.unsupportedArchitecture(
                "This looks like an SDXL, SD3 or Flux pack. Keel supports Stable Diffusion 1.x, 2.x and LCM Core ML packs."
            )
        }

        let relSet = Set(scoped.map(\.relative))
        let hasTextEncoder = relSet.contains("TextEncoder.mlmodelc/coremldata.bin")
        let hasVAE = relSet.contains("VAEDecoder.mlmodelc/coremldata.bin")
        let hasSingleUnet = relSet.contains("Unet.mlmodelc/coremldata.bin")
        let hasChunkedUnet = relSet.contains("UnetChunk1.mlmodelc/coremldata.bin")
            && relSet.contains("UnetChunk2.mlmodelc/coremldata.bin")
        let hasVocab = scoped.contains { $0.relative == "vocab.json" && $0.bytes > 0 }
        let hasMerges = scoped.contains { $0.relative == "merges.txt" && $0.bytes > 0 }

        var missing: [String] = []
        if !hasTextEncoder { missing.append("TextEncoder.mlmodelc") }
        if !hasSingleUnet && !hasChunkedUnet { missing.append("Unet.mlmodelc") }
        if !hasVAE { missing.append("VAEDecoder.mlmodelc") }
        if !hasVocab { missing.append("vocab.json") }
        if !hasMerges { missing.append("merges.txt") }
        if !missing.isEmpty {
            throw Problem.missingFiles(missing)
        }

        // Keep only the files `TextToImage` actually loads (skip SafetyChecker, VAEEncoder, etc.).
        let chunked = !hasSingleUnet && hasChunkedUnet
        let allowedRoots: Set<String> = chunked
            ? ["TextEncoder.mlmodelc", "UnetChunk1.mlmodelc", "UnetChunk2.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]
            : ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

        let selected = scoped.filter { item in
            guard let first = item.relative.split(separator: "/").first.map(String.init) else { return false }
            if first == "vocab.json" || first == "merges.txt" {
                return item.relative == first
            }
            return allowedRoots.contains(first)
        }

        guard selected.count <= ImportedImagePack.maxFiles else {
            throw Problem.tooManyFiles(selected.count)
        }

        var totalBytes: Int64 = 0
        for item in selected {
            let (next, overflow) = totalBytes.addingReportingOverflow(item.bytes)
            guard !overflow, next <= ImportedImagePack.maxPackBytes else {
                let budget = DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
                throw Problem.tooLarge(requiredBytes: UInt64(ImportedImagePack.maxPackBytes), budgetBytes: budget)
            }
            totalBytes = next
        }

        guard totalBytes > 0 else { throw Problem.empty }

        let workingBytes: UInt64 = 600_000_000
        if !ImageRequest.fits(imageModelBytes: UInt64(totalBytes), workingBytes: workingBytes, physicalMemoryBytes: physicalMemoryBytes) {
            let budget = DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
            throw Problem.tooLarge(requiredBytes: UInt64(totalBytes) + workingBytes, budgetBytes: budget)
        }

        let files = selected
            .sorted { $0.relative < $1.relative }
            .map { FileEntry(sourcePath: $0.source, relativePath: $0.relative, bytes: $0.bytes, sha256: $0.sha256) }

        return Plan(rootPrefix: prefix, chunkedUnet: chunked, files: files, totalBytes: totalBytes)
    }

    private static func prefixRank(_ prefix: String) -> Int {
        let lower = prefix.lowercased()
        if lower.contains("split_einsum_v2") && lower.contains("compiled") { return 0 }
        if lower.contains("split_einsum") && lower.contains("compiled") { return 1 }
        if lower.contains("compiled") && !lower.contains("original") { return 2 }
        if prefix.isEmpty { return 3 }
        if lower.contains("split_einsum") { return 4 }
        if lower.contains("original") { return 5 }
        return 6
    }

    private static func shouldIgnore(path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains { part in
            part == "__MACOSX" || part == ".DS_Store" || part.hasPrefix("._")
        }
    }
}

/// Validates and normalizes a public Hugging Face link to a Core ML image pack
/// repository or subfolder.
///
/// Accepts `https://huggingface.co/<owner>/<repo>` or
/// `https://huggingface.co/<owner>/<repo>/tree/<revision>[/<subpath>]`.
public struct HuggingFaceCoreMLPackLink: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let subpath: String
    public let displayName: String

    private static let forbiddenQueryKeys: Set<String> = [
        "token", "access_token", "auth", "authorization", "key", "api_key", "secret", "sig", "signature"
    ]

    public var treeAPIURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let tail = subpath.isEmpty ? "" : "/\(subpath)"
        components.path = "/api/models/\(repository)/tree/\(revision)\(tail)"
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        return components.url!
    }

    public func resolveURL(forRepoPath path: String) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(path)"
        return components.url
    }

    public static func parse(_ raw: String) throws -> HuggingFaceCoreMLPackLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else {
            throw CustomModelError.invalidURL("URL is empty or too long.")
        }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.controlCharacters.contains($0) }) else {
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
                if forbiddenQueryKeys.contains(item.name.lowercased()) {
                    throw CustomModelError.credentialsInURL
                }
                throw CustomModelError.invalidURL("Unsupported query parameter '\(item.name)'.")
            }
        }
        guard let host = components.host?.lowercased(), host == "huggingface.co" else {
            throw CustomModelError.unsupportedHost(components.host ?? "none")
        }
        if let port = components.port, port != 443 {
            throw CustomModelError.invalidURL("Non-standard port \(port) is not allowed.")
        }

        let rawPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawSegments = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawSegments.count >= 2 else {
            throw CustomModelError.invalidPath("Expected https://huggingface.co/<owner>/<repo> (or /tree/<revision>/<folder>).")
        }

        var decoded: [String] = []
        for seg in rawSegments {
            guard !seg.isEmpty,
                  let value = String(seg).removingPercentEncoding,
                  !value.isEmpty, value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\"),
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.controlCharacters.contains($0) }) else {
                throw CustomModelError.invalidPath("Invalid path segment in Hugging Face link.")
            }
            decoded.append(value)
        }

        let owner = decoded[0]
        let repo = decoded[1]
        guard isSafeIdentifier(owner), isSafeIdentifier(repo) else {
            throw CustomModelError.invalidPath("Invalid repository name.")
        }

        let revision: String
        let subpath: String
        if decoded.count == 2 {
            revision = "main"
            subpath = ""
        } else {
            guard decoded.count >= 4, decoded[2] == "tree" else {
                throw CustomModelError.invalidPath("Use a repository URL or a /tree/<revision>/<folder> link.")
            }
            revision = decoded[3]
            guard isSafeRevision(revision) else {
                throw CustomModelError.invalidPath("Invalid revision in Hugging Face link.")
            }
            let tail = Array(decoded.dropFirst(4))
            for part in tail {
                guard isSafeSegment(part) else {
                    throw CustomModelError.invalidPath("Invalid folder segment '\(part)'.")
                }
            }
            subpath = tail.joined(separator: "/")
        }

        return HuggingFaceCoreMLPackLink(
            repository: "\(owner)/\(repo)",
            revision: revision,
            subpath: subpath,
            displayName: ImportedImagePack.cleanName(repo)
        )
    }

    private static func isSafeIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isSafeRevision(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isSafeSegment(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128, !text.hasPrefix("."), !text.hasSuffix("."), !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" || $0 == " "
        }
    }
}

/// Decodes one item from Hugging Face's `/api/models/<repo>/tree/<rev>?recursive=true`.
public struct HuggingFaceTreeEntry: Decodable, Equatable, Sendable {
    public struct LFS: Decodable, Equatable, Sendable {
        public let oid: String
        public let size: Int64?
    }
    public let type: String
    public let path: String
    public let size: Int64?
    public let oid: String?
    public let lfs: LFS?

    public var effectiveBytes: Int64 { lfs?.size ?? size ?? 0 }
    public var lfsSHA256: String? {
        guard let oid = lfs?.oid.lowercased(),
              oid.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return oid
    }
}
