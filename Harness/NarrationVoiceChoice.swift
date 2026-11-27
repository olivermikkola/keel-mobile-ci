import Foundation

/// Which voice reads a video's lines. Kokoro voices keep their plain ids
/// (`af_heart`), so saved videos and settings stay valid. Apple's built-in
/// voices and the user's own Personal Voice are stored as `apple:` plus the
/// system voice identifier: they need no download and speak instantly, also
/// on phones too small for Kokoro.
public enum NarrationVoiceChoice: Equatable, Sendable {
    case kokoro(String)
    case apple(identifier: String)

    public static let applePrefix = "apple:"

    public init(id: String) {
        if id.hasPrefix(Self.applePrefix), id.count > Self.applePrefix.count {
            self = .apple(identifier: String(id.dropFirst(Self.applePrefix.count)))
        } else {
            self = .kokoro(id)
        }
    }

    public var id: String {
        switch self {
        case .kokoro(let voice): return voice
        case .apple(let identifier): return Self.applePrefix + identifier
        }
    }

    /// Whether the voice needs the Kokoro download.
    public var needsKokoro: Bool {
        if case .kokoro = self { return true }
        return false
    }

    /// An Apple voice as the picker lists it.
    public struct AppleVoice: Equatable, Sendable {
        public enum Quality: Int, Comparable, Sendable {
            case standard = 0, enhanced = 1, premium = 2
            public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        }
        public let identifier: String
        public let name: String
        public let language: String
        public let quality: Quality
        public let isPersonal: Bool
        public init(identifier: String, name: String, language: String, quality: Quality, isPersonal: Bool) {
            self.identifier = identifier; self.name = name; self.language = language
            self.quality = quality; self.isPersonal = isPersonal
        }
        public var label: String {
            if isPersonal { return "\(name) · your Personal Voice" }
            let tier = quality == .premium ? "premium" : quality == .enhanced ? "enhanced" : "standard"
            return "\(name) · Apple, \(tier)"
        }
    }

    /// The Apple voices worth offering for English narration: the user's
    /// Personal Voices first, then the best English voices, highest quality
    /// first, one per name, at most `limit` system voices.
    public static func offered(_ voices: [AppleVoice], limit: Int = 6) -> [AppleVoice] {
        let personal = voices.filter(\.isPersonal)
        var seen = Set<String>()
        let english = voices
            .filter { !$0.isPersonal && $0.language.lowercased().hasPrefix("en") }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
            .filter { seen.insert($0.name).inserted }
        return personal + english.prefix(limit)
    }
}
