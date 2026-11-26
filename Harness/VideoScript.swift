import Foundation

/// The Videos screen's script: the user picks photos and says what the video
/// is about; the chat model writes one spoken line per photo, in order, and
/// the narration voice reads them. The model never needs to see the photos,
/// so text-only models (Bonsai) can do it.
public enum VideoScript {
    /// Photos one video takes from the Videos screen.
    public static let maxPhotos = 6
    public static let maxDescriptionCharacters = 600
    /// One photo's note for the model: what the phone found in it.
    public static let maxNoteCharacters = 220

    /// A note from what the phone's Vision framework found in a photo: its
    /// strongest labels and the text in it. Empty when it found nothing.
    public static func note(labels: [String], text: String) -> String {
        let kinds = labels.map { $0.replacingOccurrences(of: "_", with: " ") }.filter { !$0.isEmpty }.prefix(3)
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var parts: [String] = []
        if !kinds.isEmpty { parts.append(kinds.joined(separator: ", ")) }
        if !words.isEmpty { parts.append("text: \"\(String(words.prefix(160)))\"") }
        return parts.joined(separator: "; ")
    }

    /// Words in one spoken line before it is cut, so a scene stays short.
    public static let maxWordsPerLine = 24
    /// Reply room for the model: about 40 tokens a line, plus slack.
    public static func replyTokens(photoCount: Int) -> Int { 64 + 48 * max(1, photoCount) }

    public struct Line: Codable, Equatable, Sendable {
        public let narration: String
        public let caption: String?
        public init(narration: String, caption: String? = nil) {
            self.narration = narration
            self.caption = caption
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case noPhotos, tooManyPhotos, description, script
        public var errorDescription: String? {
            switch self {
            case .noPhotos: return "Pick at least one photo."
            case .tooManyPhotos: return "Pick up to \(VideoScript.maxPhotos) photos."
            case .description: return "Say in a sentence what the video is about (up to \(VideoScript.maxDescriptionCharacters) characters)."
            case .script: return "The model did not write a line for every photo. Try again, or say it more simply."
            }
        }
    }

    /// What the model reads. `previous` and `change` are set when the user
    /// asks for a change to a video already made.
    public static func prompt(description: String, photoCount: Int, photoNotes: [String] = [], previous: [Line] = [],
                              change: String? = nil) throws -> (system: String, user: String) {
        guard photoCount > 0 else { throw Problem.noPhotos }
        guard photoCount <= maxPhotos else { throw Problem.tooManyPhotos }
        let about = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !about.isEmpty, about.count <= maxDescriptionCharacters else { throw Problem.description }
        let system = """
        You write the voice-over for a short vertical video, like a good product reel, made from \(photoCount) photo\(photoCount == 1 ? "" : "s") shown in order.
        Write exactly \(photoCount) line\(photoCount == 1 ? "" : "s"), numbered 1 to \(photoCount), one per photo, that together tell one short story about what the user wants:
        line 1 is a hook that makes people keep watching, the middle lines each show one concrete thing visible in that photo and why it matters, and the last line closes with a reason to care.
        Each line is one spoken sentence of at most 14 words, in plain, confident, everyday words. Speak to the viewer as "you".
        Use the photo notes for facts. Never invent features. Never use buzzwords like "unlock", "revolutionize", "seamless", "the future of".
        End every line with | and an on-screen caption of two to four words.
        Write nothing else: no title, no notes, no emoji.
        Example for 2 photos:
        1. What if your phone could do this with no internet at all? | NO INTERNET NEEDED
        2. Every answer is made right here, on the phone in your hand. | ALL ON DEVICE
        """
        var user = "The video is about: \(about)"
        let notes = photoNotes.prefix(photoCount).enumerated().compactMap { index, note -> String? in
            let text = note.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : "Photo \(index + 1): \(String(text.prefix(maxNoteCharacters)))"
        }
        if !notes.isEmpty { user += "\n\nWhat the photos show:\n" + notes.joined(separator: "\n") }
        if !previous.isEmpty {
            user += "\n\nThe lines so far:\n" + previous.enumerated().map { index, line in
                "\(index + 1). \(line.narration)" + (line.caption.map { " | \($0)" } ?? "")
            }.joined(separator: "\n")
        }
        if let change = change?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !change.isEmpty {
            user += "\n\nChange: \(String(change.prefix(maxDescriptionCharacters)))\nWrite all \(photoCount) lines again with this change."
        }
        return (system, user)
    }

    /// Reads the model's numbered lines. Thinking, blank lines and other text
    /// are skipped; each number keeps its first line. Fails unless every photo
    /// has a line.
    public static func parse(_ text: String, photoCount: Int) throws -> [Line] {
        var body = text
        if let end = body.range(of: "</think>") { body = String(body[end.upperBound...]) }
        var found: [Int: Line] = [:]
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "*-#> "))
            let digits = line.prefix { $0.isNumber }
            guard let number = Int(digits), (1...photoCount).contains(number), found[number] == nil else { continue }
            var rest = line.dropFirst(digits.count)
            guard let mark = rest.first, ".):".contains(mark) else { continue }
            rest = rest.dropFirst()
            let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let spoken = cleaned(parts.first ?? "")
            guard !spoken.isEmpty else { continue }
            let words = spoken.split(separator: " ")
            let narration = words.count > maxWordsPerLine ? words.prefix(maxWordsPerLine).joined(separator: " ") + "." : spoken
            let caption = parts.count > 1 ? cleaned(parts[1]).split(separator: " ").prefix(4).joined(separator: " ") : nil
            found[number] = Line(narration: String(narration.prefix(ShortVideoRequest.maxNarrationCharacters)),
                                 caption: caption.flatMap { $0.isEmpty ? nil : String($0.prefix(ShortVideoRequest.maxOverlayCharacters)) })
        }
        let lines = (1...max(1, photoCount)).compactMap { found[$0] }
        guard lines.count == photoCount else { throw Problem.script }
        return lines
    }

    /// The storyboard for the renderer: photos in the user's order, gentle
    /// motions taking turns so the video does not feel static.
    public static func arguments(lines: [Line], photoNames: [String], voice: String, aspect: ShortVideoRequest.AspectRatio = .vertical,
                                 title: String? = nil) -> ShortVideoRequest.Arguments {
        let motions: [ShortVideoRequest.Motion] = [.slowZoom, .panLeft, .panRight]
        let scenes = zip(lines, photoNames).enumerated().map { index, pair in
            ShortVideoRequest.Scene(imagePath: pair.1, narration: pair.0.narration, overlay: pair.0.caption,
                                    motion: motions[index % motions.count])
        }
        return ShortVideoRequest.Arguments(path: "video.mp4", scenes: scenes, voice: .init(id: voice), aspectRatio: aspect, title: title)
    }

    private static func cleaned(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*_ ").union(.whitespaces))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
