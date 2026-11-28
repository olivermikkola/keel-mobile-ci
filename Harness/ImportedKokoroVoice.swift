import Foundation

/// A user-imported Kokoro-82M speaker voice embedding (from `.bin`, `.json`, or
/// NumPy `.npy` via Files or a public Hugging Face link).
///
/// FluidAudio's Core ML Kokoro pipeline expects each voice on disk as a flat
/// little-endian `[510, 256]` FP32 binary file (`522,240` bytes, all finite)
/// named `<id>.bin`, where `<id>` starts with an English prefix (`af_`, `am_`,
/// `bf_`, or `bm_`) and uses only lowercase ASCII letters, digits, and `_`.
public struct ImportedKokoroVoice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let sha256: String
    public let sourceFormat: String
    public let sourceLabel: String

    public static let rows = 510
    public static let cols = 256
    public static let elementCount = rows * cols
    public static let binaryByteCount = elementCount * 4 // 522,240 bytes
    /// Maximum accepted raw input file size (JSON voices are ~2–4 MB; cap at 16 MB).
    public static let maxInputBytes = 16 * 1024 * 1024
    /// Maximum number of custom Kokoro voices stored by Keel.
    public static let limit = 24

    /// FluidAudio v0.18.4 ANE-v3 pinned cache revision (kept in sync with `NarrationVoicePack.fluidAudioVersion`).
    public static let fluidAudioV3Revision = "6c0750dd02ef9d981fb82f147d784a3f171755ee"

    public init(
        id: String,
        name: String,
        sha256: String,
        sourceFormat: String,
        sourceLabel: String
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.sha256 = sha256
        self.sourceFormat = sourceFormat
        self.sourceLabel = Self.cleanSourceLabel(sourceLabel)
    }

    public var fileName: String { id + ".bin" }

    public var pickerLabel: String {
        let accent: String
        if id.hasPrefix("bf_") || id.hasPrefix("bm_") {
            accent = "British English · custom"
        } else {
            accent = "Custom voice"
        }
        return "\(name) · \(accent)"
    }

    /// Generates a FluidAudio-v3-compatible, collision-free voice ID such as
    /// `bf_custom_a1b2c3d4`, preserving the `af_`/`am_`/`bf_`/`bm_` prefix from
    /// the original filename when present.
    public static func newID(hint: String = "", suffix: String? = nil) -> String {
        let lower = hint.lowercased()
        let prefix: String
        if lower.hasPrefix("bf_") { prefix = "bf_" }
        else if lower.hasPrefix("bm_") { prefix = "bm_" }
        else if lower.hasPrefix("am_") { prefix = "am_" }
        else { prefix = "af_" }
        let hex = (suffix ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            .filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        let token = String(hex.prefix(8)).padding(toLength: 8, withPad: "0", startingAt: 0)
        return "\(prefix)custom_\(token)"
    }

    /// Turns a voice filename like `bf_emma.json` or `Warm_Narrator.npy` into a
    /// clean single-line display name (≤ 48 characters).
    public static func cleanName(_ raw: String) -> String {
        var text = raw
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".bin", ".json", ".npy"] {
            if text.lowercased().hasSuffix(ext) {
                text = String(text.dropLast(ext.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let lower = text.lowercased()
        for prefix in ["af_", "am_", "bf_", "bm_", "ef_", "em_", "ff_", "hf_", "hm_", "if_", "im_", "jf_", "jm_", "pf_", "pm_", "zf_", "zm_"] {
            if lower.hasPrefix(prefix), text.count > prefix.count {
                let tail = String(text.dropFirst(prefix.count))
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty {
                    text = tail.prefix(1).uppercased() + tail.dropFirst()
                    break
                }
            }
        }
        text = text.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Custom voice" : String(text.prefix(48))
    }

    private static func cleanSourceLabel(_ raw: String) -> String {
        let text = raw
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Files" : String(text.prefix(120))
    }

    /// Validates that a saved JSON record could only have been written by Keel.
    public var isValid: Bool {
        id.range(of: "^(af|am|bf|bm)_custom_[0-9a-f]{8}$", options: .regularExpression) != nil
            && !name.isEmpty && name.count <= 48
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && ["bin", "json", "npy"].contains(sourceFormat)
            && !sourceLabel.isEmpty && sourceLabel.count <= 120
    }

    /// Reads the saved voice list, keeping only valid, distinct records up to `limit`.
    public static func load(_ data: Data) -> [ImportedKokoroVoice] {
        guard let records = try? JSONDecoder().decode([ImportedKokoroVoice].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(records.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(limit))
    }
}

/// Decodes and validates Kokoro-82M speaker voice embeddings from `.bin`, `.json`,
/// or NumPy `.npy` into FluidAudio's canonical `[510, 256]` little-endian FP32
/// binary format (`522,240` bytes, all finite).
public enum KokoroVoiceCodec {
    public enum Format: String, Equatable, Sendable {
        case bin
        case json
        case npy
    }

    public enum Problem: LocalizedError, Equatable, Sendable {
        case fileTooLarge
        case unsupportedFormat(String)
        case invalidBinarySize(Int)
        case nonFiniteValues
        case invalidJSON(String)
        case invalidNumPy(String)

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return "This voice file is too large. Kokoro voice embeddings are under 16 MB (.bin, .json or .npy)."
            case .unsupportedFormat(let ext):
                return "Unsupported voice file type (\(ext.isEmpty ? "unknown" : ext)). Choose a Kokoro .bin, .json or .npy voice file."
            case .invalidBinarySize(let count):
                return "This .bin file is \(count) bytes; a Kokoro voice pack must be exactly \(ImportedKokoroVoice.binaryByteCount) bytes (510×256 float32)."
            case .nonFiniteValues:
                return "This voice file contains invalid (NaN or infinite) numbers and cannot be used."
            case .invalidJSON(let detail):
                return "This JSON file is not a valid Kokoro voice pack: \(detail)"
            case .invalidNumPy(let detail):
                return "This .npy file is not a valid Kokoro voice pack: \(detail)"
            }
        }
    }

    /// Detects the voice file format from extension and magic bytes, validates
    /// dimensions and finite values, and returns canonical `522,240`-byte FP32
    /// little-endian binary data plus the detected format.
    public static func normalize(_ data: Data, fileExtension: String) throws -> (binary: Data, format: Format) {
        guard data.count <= ImportedKokoroVoice.maxInputBytes else {
            throw Problem.fileTooLarge
        }
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        switch ext {
        case "bin":
            return (try normalizeBinary(data), .bin)
        case "json":
            return (try normalizeJSON(data), .json)
        case "npy":
            return (try normalizeNumPy(data), .npy)
        default:
            // Allow magic-based sniff if extension is missing.
            if data.starts(with: [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) {
                return (try normalizeNumPy(data), .npy)
            }
            if data.count == ImportedKokoroVoice.binaryByteCount {
                return (try normalizeBinary(data), .bin)
            }
            throw Problem.unsupportedFormat(ext)
        }
    }

    /// Validates a flat `[510, 256]` little-endian FP32 `.bin` voice pack.
    public static func normalizeBinary(_ data: Data) throws -> Data {
        guard data.count == ImportedKokoroVoice.binaryByteCount else {
            throw Problem.invalidBinarySize(data.count)
        }
        let valid = data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).allSatisfy { offset in
                let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                return Float(bitPattern: bits).isFinite
            }
        }
        guard valid else { throw Problem.nonFiniteValues }
        return data
    }

    /// Parses either FluidAudio's Kokoro v1.0 JSON object (`{"1": [256], ..., "510": [256]}`)
    /// or a nested 2D/3D JSON array (`[510][256]` or `[510][1][256]`).
    public static func normalizeJSON(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Problem.invalidJSON("file is empty.") }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Problem.invalidJSON("could not parse JSON.")
        }

        var floats: [Float] = []
        floats.reserveCapacity(ImportedKokoroVoice.elementCount)

        if let object = json as? [String: Any] {
            for row in 1...ImportedKokoroVoice.rows {
                guard let values = object[String(row)] as? [NSNumber],
                      values.count == ImportedKokoroVoice.cols else {
                    throw Problem.invalidJSON("expected keys \"1\"…\"510\" each with 256 numbers (problem at row \(row)).")
                }
                for num in values {
                    let f = num.floatValue
                    guard f.isFinite else { throw Problem.nonFiniteValues }
                    floats.append(f)
                }
            }
        } else if let array = json as? [Any] {
            guard array.count == ImportedKokoroVoice.rows else {
                throw Problem.invalidJSON("expected 510 rows, got \(array.count).")
            }
            for (index, item) in array.enumerated() {
                let rowValues: [NSNumber]
                if let direct = item as? [NSNumber] {
                    rowValues = direct
                } else if let nested = item as? [[NSNumber]], nested.count == 1 {
                    rowValues = nested[0]
                } else {
                    throw Problem.invalidJSON("row \(index) is not a 256-number array.")
                }
                guard rowValues.count == ImportedKokoroVoice.cols else {
                    throw Problem.invalidJSON("row \(index) has \(rowValues.count) numbers (expected 256).")
                }
                for num in rowValues {
                    let f = num.floatValue
                    guard f.isFinite else { throw Problem.nonFiniteValues }
                    floats.append(f)
                }
            }
        } else {
            throw Problem.invalidJSON("expected a JSON object or array.")
        }

        return packLittleEndianFloats(floats)
    }

    /// Parses a NumPy `.npy` v1/v2/v3 file with shape `(510, 256)` or `(510, 1, 256)`,
    /// C-order (`fortran_order: False`), and dtype `<f4`, `>f4`, `<f2`, or `<f8`.
    public static func normalizeNumPy(_ data: Data) throws -> Data {
        let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] // \x93NUMPY
        guard data.count >= 12, data.starts(with: magic) else {
            throw Problem.invalidNumPy("missing NUMPY header.")
        }
        let major = data[6]
        let minor = data[7]
        let headerLen: Int
        let headerStart: Int
        if major == 1 && minor == 0 {
            headerLen = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else if (major == 2 || major == 3) && minor == 0 {
            guard data.count >= 14 else { throw Problem.invalidNumPy("truncated v2/v3 header.") }
            headerLen = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        } else {
            throw Problem.invalidNumPy("unsupported .npy version \(major).\(minor).")
        }
        guard headerLen > 0, headerLen <= 16_384, headerStart + headerLen <= data.count else {
            throw Problem.invalidNumPy("invalid header length.")
        }

        let headerSlice = data[headerStart..<(headerStart + headerLen)]
        guard let headerText = String(data: headerSlice, encoding: .utf8) ?? String(data: headerSlice, encoding: .ascii) else {
            throw Problem.invalidNumPy("unreadable header text.")
        }

        guard let descr = extractQuotedValue(named: "descr", from: headerText) else {
            throw Problem.invalidNumPy("missing dtype ('descr') in header.")
        }
        guard let fortranOrder = extractBoolValue(named: "fortran_order", from: headerText), !fortranOrder else {
            throw Problem.invalidNumPy("only C-order (fortran_order: False) arrays are supported.")
        }
        guard let shape = extractShape(from: headerText),
              shape == [510, 256] || shape == [510, 1, 256] else {
            throw Problem.invalidNumPy("expected shape (510, 256) or (510, 1, 256).")
        }

        let payload = data.suffix(from: headerStart + headerLen)
        let count = ImportedKokoroVoice.elementCount

        switch descr {
        case "<f4", "|f4", "=f4", "f4":
            guard payload.count == count * 4 else {
                throw Problem.invalidNumPy("payload size \(payload.count) does not match 510×256 float32.")
            }
            return try normalizeBinary(Data(payload))

        case ">f4":
            guard payload.count == count * 4 else {
                throw Problem.invalidNumPy("payload size \(payload.count) does not match 510×256 big-endian float32.")
            }
            var floats = [Float](repeating: 0, count: count)
            try payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    let value = Float(bitPattern: bits)
                    guard value.isFinite else { throw Problem.nonFiniteValues }
                    floats[i] = value
                }
            }
            return packLittleEndianFloats(floats)

        case "<f2", "|f2", "=f2", "f2":
            guard payload.count == count * 2 else {
                throw Problem.invalidNumPy("payload size \(payload.count) does not match 510×256 float16.")
            }
            var floats = [Float](repeating: 0, count: count)
            try payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    let half = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    let value = float16ToFloat32(half)
                    guard value.isFinite else { throw Problem.nonFiniteValues }
                    floats[i] = value
                }
            }
            return packLittleEndianFloats(floats)

        case "<f8", "|f8", "=f8", "f8":
            guard payload.count == count * 8 else {
                throw Problem.invalidNumPy("payload size \(payload.count) does not match 510×256 float64.")
            }
            var floats = [Float](repeating: 0, count: count)
            try payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
                    let value = Float(Double(bitPattern: bits))
                    guard value.isFinite else { throw Problem.nonFiniteValues }
                    floats[i] = value
                }
            }
            return packLittleEndianFloats(floats)

        default:
            throw Problem.invalidNumPy("unsupported dtype '\(descr)' (expected float16, float32, or float64).")
        }
    }

    private static func packLittleEndianFloats(_ floats: [Float]) -> Data {
        var output = Data(capacity: floats.count * 4)
        for value in floats {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        }
        return output
    }

    /// IEEE 754 binary16 → binary32 conversion in pure Swift (works on Linux & iOS).
    static func float16ToFloat32(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exp = Int((half >> 10) & 0x1F)
        let mant = UInt32(half & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            var m = mant
            var e: Int32 = -14
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            let exp32 = UInt32(e + 127) << 23
            return Float(bitPattern: sign | exp32 | (m << 13))
        }
        if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        }
        let exp32 = UInt32(exp - 15 + 127) << 23
        return Float(bitPattern: sign | exp32 | (mant << 13))
    }

    private static func extractQuotedValue(named key: String, from header: String) -> String? {
        let pattern = #"['"]\#(key)['"]\s*:\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range])
    }

    private static func extractBoolValue(named key: String, from header: String) -> Bool? {
        let pattern = #"['"]\#(key)['"]\s*:\s*(True|False)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return header[range] == "True"
    }

    private static func extractShape(from header: String) -> [Int]? {
        let pattern = #"['"]shape['"]\s*:\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        let parts = header[range].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var dims: [Int] = []
        for part in parts {
            guard let n = Int(part), n > 0 else { return nil }
            dims.append(n)
        }
        return dims
    }
}

/// Validates and normalizes a public Hugging Face link to a Kokoro voice file
/// (`.bin`, `.json`, or `.npy`). Rewrites `/blob/` links to `/resolve/`.
public struct HuggingFaceKokoroVoiceLink: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let filePath: String
    public let fileName: String
    public let fileExtension: String
    public let resolveURL: URL

    private static let allowedExtensions: Set<String> = ["bin", "json", "npy"]
    private static let forbiddenQueryKeys: Set<String> = [
        "token", "access_token", "auth", "authorization", "key", "api_key", "secret", "sig", "signature"
    ]

    public static func parse(_ raw: String) throws -> HuggingFaceKokoroVoiceLink {
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
                let name = item.name.lowercased()
                if forbiddenQueryKeys.contains(name) { throw CustomModelError.credentialsInURL }
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
        guard rawSegments.first == "", rawSegments.count >= 6 else {
            throw CustomModelError.invalidPath("Expected /<owner>/<repo>/resolve/<revision>/<voice>.(bin|json|npy).")
        }

        var decoded: [String] = []
        for rawSeg in rawSegments.dropFirst() {
            guard !rawSeg.isEmpty,
                  let seg = String(rawSeg).removingPercentEncoding,
                  !seg.isEmpty, seg != ".", seg != "..",
                  !seg.contains("/"), !seg.contains("\\"),
                  !seg.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.controlCharacters.contains($0) }) else {
                throw CustomModelError.invalidPath("Invalid path segment in Hugging Face link.")
            }
            decoded.append(seg)
        }

        let owner = decoded[0], repo = decoded[1], mode = decoded[2], revision = decoded[3]
        let fileSegments = Array(decoded.dropFirst(4))
        guard mode == "resolve" || mode == "blob" else {
            throw CustomModelError.invalidPath("Expected '/resolve/' or '/blob/' in Hugging Face voice link.")
        }
        guard isSafeIdentifier(owner), isSafeIdentifier(repo), isSafeRevision(revision) else {
            throw CustomModelError.invalidPath("Invalid repository or revision characters.")
        }
        for dir in fileSegments.dropLast() {
            guard isSafeSegment(dir) else {
                throw CustomModelError.invalidPath("Invalid directory segment '\(dir)'.")
            }
        }
        guard let fileName = fileSegments.last, isSafeFileName(fileName) else {
            throw CustomModelError.invalidPath("Invalid voice file name.")
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext), fileName.count > ext.count + 1 else {
            throw KokoroVoiceCodec.Problem.unsupportedFormat(ext)
        }

        let filePath = fileSegments.joined(separator: "/")
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = "huggingface.co"
        clean.path = "/\(owner)/\(repo)/resolve/\(revision)/\(filePath)"
        guard let resolveURL = clean.url else {
            throw CustomModelError.invalidURL("Could not construct resolve URL.")
        }

        return HuggingFaceKokoroVoiceLink(
            repository: "\(owner)/\(repo)",
            revision: revision,
            filePath: filePath,
            fileName: fileName,
            fileExtension: ext,
            resolveURL: resolveURL
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
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" || $0 == " " }
    }

    private static func isSafeFileName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 180, !text.hasPrefix("."), !text.contains("..") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" }
    }
}
