import Foundation

/// Short-form video from photos plus narration (`create_short_video`).
///
/// The model writes a storyboard: a list of scenes with an image path, a
/// narration line, and optional overlay text and camera motion. On-device
/// neural TTS (Kokoro-class) speaks each line; the phone stitches images and
/// audio with AVFoundation. The model never has to "watch" the video — that
/// is the point on an 8 GB phone. Raw video understanding, local video
/// diffusion, cloud TTS, and Apple's system voices are out of scope for this
/// tool (`docs/PRODUCT_MAP.md`).
public enum ShortVideoRequest {
    public static let tool = #"{"type":"function","function":{"name":"create_short_video","description":"Make one short vertical video from photos already in this chat, with on-device neural narration. Pass scenes as a plain block: one scene per blank-line group with image: path, say: narration, and optional overlay: and motion: (none, slow_zoom, pan_left, pan_right). Optional voice is a downloaded on-device voice id such as af_heart (default). Aspect is 9:16 (default), 1:1 or 16:9. Saves a .mp4 the user can open and share.","parameters":{"type":"object","properties":{"path":{"type":"string"},"scenes":{"type":"string"},"voice":{"type":"string"},"aspect_ratio":{"type":"string","enum":["9:16","1:1","16:9"]},"title":{"type":"string"}},"required":["path","scenes"]}}}"#

    /// Default Kokoro-style English voice when the model omits `voice`.
    public static let defaultVoiceID = "af_heart"

    public static let maxScenes = 12
    public static let maxNarrationCharacters = 280
    public static let maxOverlayCharacters = 80
    public static let maxTitleCharacters = 80
    public static let maxScenesCharacters = 6_000
    /// Soft target for a short: keep clips short enough for Reels/TikTok-length output.
    public static let maxEstimatedSeconds: TimeInterval = 90
    public static let timeLimit: TimeInterval = 180
    public static let aspectRatios = ["9:16", "1:1", "16:9"]
    public static let defaultAspectRatio = "9:16"
    public static let motions = ["none", "slow_zoom", "pan_left", "pan_right"]
    /// Rough spoken pace used only to size the timeline before real TTS timing exists.
    public static let charactersPerSecond: Double = 14

    public enum AspectRatio: String, Codable, Equatable, Sendable, CaseIterable {
        case vertical = "9:16"
        case square = "1:1"
        case landscape = "16:9"

        public var pixelSize: (width: Int, height: Int) {
            switch self {
            case .vertical: return (1080, 1920)
            case .square: return (1080, 1080)
            case .landscape: return (1920, 1080)
            }
        }
    }

    public enum Motion: String, Codable, Equatable, Sendable, CaseIterable {
        case none, slowZoom = "slow_zoom", panLeft = "pan_left", panRight = "pan_right"
    }

    /// On-device neural voice id (Kokoro-style), e.g. `af_heart`.
    public struct Voice: Equatable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }

        public var label: String { id }
    }

    public struct Scene: Equatable, Sendable {
        public let imagePath: String
        public let narration: String
        public let overlay: String?
        public let motion: Motion

        public init(imagePath: String, narration: String, overlay: String? = nil, motion: Motion = .none) {
            self.imagePath = imagePath
            self.narration = narration
            self.overlay = overlay
            self.motion = motion
        }

        public var estimatedSeconds: TimeInterval {
            let spoken = max(narration.count, 1)
            return max(1.5, Double(spoken) / ShortVideoRequest.charactersPerSecond)
        }
    }

    public struct Arguments: Equatable, Sendable {
        public let path: String
        public let scenes: [Scene]
        public let voice: Voice
        public let aspectRatio: AspectRatio
        public let title: String?

        public init(path: String, scenes: [Scene], voice: Voice, aspectRatio: AspectRatio, title: String?) {
            self.path = path
            self.scenes = scenes
            self.voice = voice
            self.aspectRatio = aspectRatio
            self.title = title
        }

        public var estimatedSeconds: TimeInterval {
            scenes.reduce(0) { $0 + $1.estimatedSeconds }
        }
    }

    /// Pure timeline the iOS renderer consumes. No AVFoundation here so Linux
    /// harness tests can assert the plan without a phone.
    public struct RenderPlan: Equatable, Sendable {
        public struct Clip: Equatable, Sendable {
            public let imagePath: String
            public let narration: String
            public let overlay: String?
            public let motion: Motion
            public let duration: TimeInterval
            public let start: TimeInterval
        }

        public let path: String
        public let title: String?
        public let voice: Voice
        public let aspectRatio: AspectRatio
        public let width: Int
        public let height: Int
        public let clips: [Clip]
        public let totalSeconds: TimeInterval

        init(path: String, title: String?, voice: Voice, aspectRatio: AspectRatio, clips: [Clip]) {
            self.path = path
            self.title = title
            self.voice = voice
            self.aspectRatio = aspectRatio
            let size = aspectRatio.pixelSize
            self.width = size.width
            self.height = size.height
            self.clips = clips
            self.totalSeconds = clips.last.map { $0.start + $0.duration } ?? 0
        }

        public init(from arguments: Arguments) {
            self.path = arguments.path
            self.title = arguments.title
            self.voice = arguments.voice
            self.aspectRatio = arguments.aspectRatio
            let size = arguments.aspectRatio.pixelSize
            self.width = size.width
            self.height = size.height
            var cursor: TimeInterval = 0
            var built: [Clip] = []
            for scene in arguments.scenes {
                let duration = scene.estimatedSeconds
                built.append(Clip(
                    imagePath: scene.imagePath,
                    narration: scene.narration,
                    overlay: scene.overlay,
                    motion: scene.motion,
                    duration: duration,
                    start: cursor
                ))
                cursor += duration
            }
            self.clips = built
            self.totalSeconds = cursor
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case arguments, path, scenes, sceneCount, narration, overlay, motion, imagePath, aspect, voice, title, duration
        case missingImage(String)
        case engineUnavailable(String), memory, busy, slow

        public var errorDescription: String? {
            switch self {
            case .arguments: return "Expected path, scenes, and optional voice, aspect_ratio and title."
            case .path: return "path must be a new .mp4 file name, such as short.mp4."
            case .scenes: return "scenes must list 1 to \(ShortVideoRequest.maxScenes) scenes with image: and say: lines (or a JSON array of objects)."
            case .sceneCount: return "Use 1 to \(ShortVideoRequest.maxScenes) scenes."
            case .narration: return "Each say: line must be 1 to \(ShortVideoRequest.maxNarrationCharacters) characters."
            case .overlay: return "Each overlay: line must be at most \(ShortVideoRequest.maxOverlayCharacters) characters."
            case .motion: return "motion is none, slow_zoom, pan_left or pan_right."
            case .imagePath: return "Each image: path must be a workspace photo or .png/.jpg/.jpeg/.heic file name."
            case .aspect: return "aspect_ratio is 9:16, 1:1 or 16:9."
            case .voice: return "voice is an on-device neural voice id such as af_heart."
            case .title: return "title must be at most \(ShortVideoRequest.maxTitleCharacters) characters."
            case .duration: return "This storyboard would run longer than \(Int(ShortVideoRequest.maxEstimatedSeconds)) seconds. Use fewer or shorter scenes."
            case .missingImage(let names): return "These storyboard images are not in this chat yet: \(names). Attach the photos or generate them first, then use those file names."
            case .engineUnavailable(let name): return "The on-device voice '\(name)' is not downloaded on this phone. Pick a downloaded voice, or install the narration pack from Models."
            case .memory: return "This device does not have the memory to synthesise narration on the phone right now."
            case .busy: return "Another model is still loaded. Try again after this step."
            case .slow: return "Making the video took longer than \(Int(ShortVideoRequest.timeLimit)) seconds and was stopped. Nothing was saved."
            }
        }
    }

    /// Checks a call. `availableVoices` is the set of on-device voice ids the
    /// app has downloaded; empty means any well-formed id is accepted (harness
    /// tests). The tool is only offered once a neural pack is installed.
    public static func arguments(
        _ raw: [String: String],
        availableVoices: Set<String> = [],
        defaultVoice: Voice = Voice(id: ShortVideoRequest.defaultVoiceID)
    ) throws -> Arguments {
        guard Set(raw.keys).isSubset(of: ["path", "scenes", "voice", "aspect_ratio", "title"]),
              raw["path"] != nil, raw["scenes"] != nil else { throw Problem.arguments }

        let path = raw["path"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOutputPath(path) else { throw Problem.path }

        let scenes = try parseScenes(raw["scenes"]!)
        guard (1...maxScenes).contains(scenes.count) else { throw Problem.sceneCount }

        var aspect = AspectRatio.vertical
        if let text = raw["aspect_ratio"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard let parsed = AspectRatio(rawValue: text) else { throw Problem.aspect }
            aspect = parsed
        }

        var voice = defaultVoice
        if let text = raw["voice"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            voice = try parseVoice(text)
        }
        if !availableVoices.isEmpty, !availableVoices.contains(voice.id) {
            throw Problem.engineUnavailable(voice.id)
        }

        var title: String?
        if let text = raw["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard text.count <= maxTitleCharacters else { throw Problem.title }
            title = text
        }

        let args = Arguments(path: path, scenes: scenes, voice: voice, aspectRatio: aspect, title: title)
        guard args.estimatedSeconds <= maxEstimatedSeconds else { throw Problem.duration }
        return args
    }

    public static func plan(_ arguments: Arguments) -> RenderPlan {
        RenderPlan(from: arguments)
    }

    /// Whether a neural TTS pack fits alone after the chat model is unloaded.
    public static func neuralFits(modelBytes: UInt64, workingBytes: UInt64 = 400_000_000, physicalMemoryBytes: UInt64) -> Bool {
        modelBytes + workingBytes <= DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
    }

    public static func result(_ arguments: Arguments, seconds: Double, engineLabel: String? = nil) -> String {
        let plan = plan(arguments)
        let voice = engineLabel ?? arguments.voice.label
        let titleBit = arguments.title.map { " \"\($0)\"" } ?? ""
        return "Saved \(arguments.path)\(titleBit) (\(plan.width)×\(plan.height), \(arguments.scenes.count) scenes, ~\(Int(plan.totalSeconds.rounded())) s audio, \(voice)) in \(Int(seconds.rounded())) s. The user can open and share it."
    }

    // MARK: - Parsing

    static func isOutputPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(".mp4"), trimmed.count > 4, trimmed.count <= 120,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !trimmed.contains("\\") else { return false }
        return true
    }

    static func isImagePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160, !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !trimmed.contains("\\") else { return false }
        let lower = trimmed.lowercased()
        return [".png", ".jpg", ".jpeg", ".heic", ".webp"].contains { lower.hasSuffix($0) }
    }

    static func parseVoice(_ raw: String) throws -> Voice {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        // Refuse cloud / system-speech aliases outright — this tool is local neural only.
        let rejected = ["system", "avspeech", "siri", "elevenlabs", "eleven", "cloud"]
        if rejected.contains(lower) { throw Problem.voice }
        // `neural`, `kokoro`, or a bare / prefixed voice id.
        if lower == "neural" || lower == "kokoro" || lower == "on-device" || lower == "local" {
            return Voice(id: defaultVoiceID)
        }
        var id = text
        if let colon = text.firstIndex(of: ":") {
            let head = String(text[..<colon]).lowercased()
            let tail = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard ["neural", "kokoro"].contains(head), !tail.isEmpty, tail.count <= 64 else { throw Problem.voice }
            id = tail
        }
        guard id.range(of: #"^[A-Za-z][A-Za-z0-9_]{1,31}$"#, options: .regularExpression) != nil else {
            throw Problem.voice
        }
        return Voice(id: id)
    }

    static func parseScenes(_ raw: String) throws -> [Scene] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxScenesCharacters else { throw Problem.scenes }
        if trimmed.hasPrefix("[") {
            return try parseJSONScenes(trimmed)
        }
        return try parseBlockScenes(trimmed)
    }

    /// Small-model friendly block:
    ///
    ///     image: lighthouse.png
    ///     say: Still standing through the storm.
    ///     overlay: STILL STANDING
    ///     motion: slow_zoom
    ///
    ///     image: waves.jpg
    ///     say: The sea keeps coming.
    private static func parseBlockScenes(_ raw: String) throws -> [Scene] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = normalized.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !chunks.isEmpty else { throw Problem.scenes }

        var scenes: [Scene] = []
        for chunk in chunks {
            var image: String?
            var say: String?
            var overlay: String?
            var motion = Motion.none
            for line in chunk.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let (matched, value) = labelledField(trimmed, ["image", "photo", "picture"]) {
                    guard matched else { throw Problem.imagePath }
                    image = value
                } else if let (matched, value) = labelledField(trimmed, ["say", "narration", "line", "text"]) {
                    guard matched else { throw Problem.narration }
                    say = value
                } else if let (matched, value) = labelledField(trimmed, ["overlay", "caption", "title"]) {
                    guard matched else { throw Problem.overlay }
                    overlay = value
                } else if let (matched, value) = labelledField(trimmed, ["motion", "camera", "kenburns"]) {
                    guard matched, let parsed = Motion(rawValue: value.lowercased()) else { throw Problem.motion }
                    motion = parsed
                } else {
                    throw Problem.scenes
                }
            }
            scenes.append(try makeScene(image: image, say: say, overlay: overlay, motion: motion))
        }
        return scenes
    }

    private static func parseJSONScenes(_ raw: String) throws -> [Scene] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !root.isEmpty else { throw Problem.scenes }
        var scenes: [Scene] = []
        for item in root {
            let image = stringValue(item["image"] ?? item["photo"] ?? item["picture"])
            let say = stringValue(item["say"] ?? item["narration"] ?? item["text"] ?? item["line"])
            let overlay = stringValue(item["overlay"] ?? item["caption"] ?? item["title"])
            var motion = Motion.none
            if let rawMotion = stringValue(item["motion"] ?? item["camera"]) {
                guard let parsed = Motion(rawValue: rawMotion.lowercased()) else { throw Problem.motion }
                motion = parsed
            }
            scenes.append(try makeScene(image: image, say: say, overlay: overlay, motion: motion))
        }
        return scenes
    }

    private static func makeScene(image: String?, say: String?, overlay: String?, motion: Motion) throws -> Scene {
        guard let imagePath = image?.trimmingCharacters(in: .whitespacesAndNewlines), isImagePath(imagePath) else {
            throw Problem.imagePath
        }
        let narration = (say ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !narration.isEmpty, narration.count <= maxNarrationCharacters else { throw Problem.narration }
        var cleanedOverlay: String?
        if let overlay, !overlay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = overlay.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= maxOverlayCharacters else { throw Problem.overlay }
            cleanedOverlay = text
        }
        return Scene(imagePath: imagePath, narration: narration, overlay: cleanedOverlay, motion: motion)
    }

    /// Returns `(true, value)` when the line uses one of `labels` with a non-empty
    /// value, `(false, "")` when the label matches but the value is blank, and
    /// `nil` when the line is a different field.
    private static func labelledField(_ line: String, _ labels: [String]) -> (Bool, String)? {
        let pattern = #"^(?:\#(labels.joined(separator: "|")))\s*:\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let value = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (false, "") : (true, value)
    }

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
