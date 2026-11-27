import Foundation

/// Maps storyboard `image:` paths to real on-device files the renderer can open.
///
/// Chat photos and `generate_image` outputs live in private sidecars today
/// (`PhotoInputs/`, `GeneratedImages/`), not as workspace text. The app fills
/// this index before `create_short_video` runs; the harness validates that
/// every scene path resolves.
public struct ShortVideoMediaIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Path the model writes in the storyboard (`lighthouse.png`).
        public let path: String
        /// Absolute file URL on device, when known. Harness tests may omit it.
        public let fileURL: URL?
        /// Optional byte size for the model-facing summary.
        public let bytes: Int?

        public init(path: String, fileURL: URL? = nil, bytes: Int? = nil) {
            self.path = path
            self.fileURL = fileURL
            self.bytes = bytes
        }
    }

    private var entries: [String: Entry]

    public init(_ entries: [Entry] = []) {
        var map: [String: Entry] = [:]
        for entry in entries {
            map[Self.normalize(entry.path)] = entry
        }
        self.entries = map
    }

    public var paths: [String] { entries.values.map(\.path).sorted() }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Registers or replaces an asset the storyboard may name.
    public mutating func register(_ entry: Entry) {
        entries[Self.normalize(entry.path)] = entry
    }

    public mutating func register(path: String, fileURL: URL? = nil, bytes: Int? = nil) {
        register(Entry(path: path, fileURL: fileURL, bytes: bytes))
    }

    public func entry(for path: String) -> Entry? {
        entries[Self.normalize(path)]
    }

    /// Resolves one storyboard image path, or throws `.imagePath` / `.missingImage`.
    public func resolve(_ path: String) throws -> Entry {
        guard ShortVideoRequest.isImagePath(path) else { throw ShortVideoRequest.Problem.imagePath }
        guard let entry = entry(for: path) else {
            throw ShortVideoRequest.Problem.missingImage(path)
        }
        return entry
    }

    /// Every scene image that is not in the index.
    public func missing(in scenes: [ShortVideoRequest.Scene]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for scene in scenes {
            let key = Self.normalize(scene.imagePath)
            guard entry(for: scene.imagePath) == nil, seen.insert(key).inserted else { continue }
            out.append(scene.imagePath)
        }
        return out
    }

    /// Ensures every scene path resolves before render.
    public func requireAll(in arguments: ShortVideoRequest.Arguments) throws {
        let absent = missing(in: arguments.scenes)
        guard absent.isEmpty else {
            throw ShortVideoRequest.Problem.missingImage(absent.joined(separator: ", "))
        }
    }

    /// A safe storyboard path from an attachment display name (`IMG_1234.HEIC` → `img_1234.heic`).
    public static func storyboardPath(fromAttachmentFilename filename: String, fallbackStem: String = "photo") -> String? {
        let last = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? filename
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ext: String
        let stem: String
        if let dot = trimmed.lastIndex(of: "."), dot > trimmed.startIndex {
            ext = String(trimmed[trimmed.index(after: dot)...]).lowercased()
            stem = String(trimmed[..<dot])
        } else {
            ext = "jpg"
            stem = trimmed
        }
        guard ["png", "jpg", "jpeg", "heic", "webp"].contains(ext) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var cleaned = String(stem.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if cleaned.isEmpty { cleaned = fallbackStem }
        cleaned = String(cleaned.prefix(48))
        let path = "\(cleaned).\(ext == "jpeg" ? "jpg" : ext)"
        return ShortVideoRequest.isImagePath(path) ? path : nil
    }

    /// Prefers the model's `generate_image` path when valid; otherwise a unique fallback.
    public static func storyboardPath(fromGeneratedPath path: String, unique: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if ShortVideoRequest.isImagePath(trimmed) { return trimmed }
        let fallback = "image-\(unique.prefix(8)).png"
        return ShortVideoRequest.isImagePath(fallback) ? fallback : "image.png"
    }

    private static func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension ShortVideoRequest {
    /// Storyboard block the app can save next to the `.mp4` for `propose_edit` + re-render.
    public static func storyboard(_ arguments: Arguments) -> String {
        var lines: [String] = []
        if let title = arguments.title {
            lines.append("title: \(title)")
        }
        lines.append("voice: \(arguments.voice.id)")
        lines.append("aspect_ratio: \(arguments.aspectRatio.rawValue)")
        lines.append("")
        for (index, scene) in arguments.scenes.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("image: \(scene.imagePath)")
            lines.append("say: \(scene.narration)")
            if let overlay = scene.overlay { lines.append("overlay: \(overlay)") }
            if scene.motion != .none { lines.append("motion: \(scene.motion.rawValue)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Rebuilds tool arguments from a saved storyboard file plus the output path.
    public static func arguments(
        storyboard text: String,
        path: String,
        voice: String? = nil,
        aspectRatio: String? = nil,
        title: String? = nil,
        availableVoices: Set<String> = []
    ) throws -> Arguments {
        var raw: [String: String] = ["path": path, "scenes": text]
        if let voice { raw["voice"] = voice }
        if let aspectRatio { raw["aspect_ratio"] = aspectRatio }
        if let title { raw["title"] = title }

        // Header lines `title:` / `voice:` / `aspect_ratio:` may sit above scenes.
        var scenesText = text
        var headerVoice: String?
        var headerAspect: String?
        var headerTitle: String?
        var body: [String] = []
        var inHeader = true
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inHeader, trimmed.isEmpty { continue }
            if inHeader, let value = headerValue(trimmed, "title") {
                headerTitle = value; continue
            }
            if inHeader, let value = headerValue(trimmed, "voice") {
                headerVoice = value; continue
            }
            if inHeader, let value = headerValue(trimmed, "aspect_ratio") {
                headerAspect = value; continue
            }
            inHeader = false
            body.append(line)
        }
        scenesText = body.joined(separator: "\n")
        raw["scenes"] = scenesText
        if raw["voice"] == nil, let headerVoice { raw["voice"] = headerVoice }
        if raw["aspect_ratio"] == nil, let headerAspect { raw["aspect_ratio"] = headerAspect }
        if raw["title"] == nil, let headerTitle { raw["title"] = headerTitle }
        return try arguments(raw, availableVoices: availableVoices)
    }

    private static func headerValue(_ line: String, _ key: String) -> String? {
        let pattern = #"^\#(key)\s*:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let value = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
