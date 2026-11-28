import Foundation

/// The Carousels screen's words: a cover, one slide per photo and a closing
/// slide, written by the chat model from the user's sentence and what the
/// phone found in each photo. Same approach as `VideoScript`, for swipeable
/// image posts instead of a video.
public enum CarouselScript {
    public static let maxPhotos = 6
    public static let maxHeadlineWords = 7
    public static let maxBodyWords = 24

    public struct Slide: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case cover, photo, closing }
        public let kind: Kind
        public let headline: String
        public let body: String
        public init(kind: Kind, headline: String, body: String) {
            self.kind = kind; self.headline = headline; self.body = body
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case noPhotos, tooManyPhotos, description, script
        public var errorDescription: String? {
            switch self {
            case .noPhotos: return "Pick at least one photo."
            case .tooManyPhotos: return "Pick up to \(CarouselScript.maxPhotos) photos."
            case .description: return "Say in a sentence what the carousel is about."
            case .script: return "The model did not write every slide. Try again, or say it more simply."
            }
        }
    }

    /// Lines the model writes: the cover, one per photo, the closing slide.
    public static func lineCount(photoCount: Int) -> Int { photoCount + 2 }
    public static func replyTokens(photoCount: Int) -> Int { 96 + 56 * lineCount(photoCount: photoCount) }

    public static func prompt(description: String, photoCount: Int, photoNotes: [String] = [],
                              previous: [Slide] = [], change: String? = nil) throws -> (system: String, user: String) {
        guard photoCount > 0 else { throw Problem.noPhotos }
        guard photoCount <= maxPhotos else { throw Problem.tooManyPhotos }
        let about = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !about.isEmpty, about.count <= 600 else { throw Problem.description }
        let total = lineCount(photoCount: photoCount)
        let system = """
        You write a swipeable social media carousel: a cover slide, then one slide per photo (\(photoCount) photo\(photoCount == 1 ? "" : "s"), in order), then a closing slide.
        The user's sentence says what the carousel is about: that is its subject and its tone. Every slide is about that subject. If the sentence names someone (a person, a pet), say the name.
        Match the tone the user asks for: funny if they say funny, warm if warm, a pitch only if they are selling something.
        The photo notes are rough guesses from the phone and often list only the background (furniture, walls, objects). Use a note only when it fits the subject; never make a slide about the background.
        Write exactly \(total) lines, numbered 1 to \(total). Line 1 is the cover, lines 2 to \(photoCount + 1) are the photos in order, line \(total) closes.
        Each line is a headline of at most \(maxHeadlineWords) words, then |, then one sentence of at most 20 words.
        The cover makes people swipe. Each photo slide says one concrete thing about that photo. The closing slide gives a reason to care or one thing to do.
        Write in your own words: use the user's request and the photo notes for facts, but never copy their text. Never invent features. Start every headline differently.
        Plain, confident, everyday words; no hashtags, no emoji, no buzzwords like "unlock", "revolutionize", "seamless".
        Write nothing else. Each line looks like this:
        1. <headline> | <one sentence>
        """
        var user = "The carousel is about: \(about)"
        let notes = photoNotes.prefix(photoCount).enumerated().compactMap { index, note -> String? in
            let text = note.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : "Photo \(index + 1): \(String(text.prefix(VideoScript.maxNoteCharacters)))"
        }
        if !notes.isEmpty { user += "\n\nWhat the photos show:\n" + notes.joined(separator: "\n") }
        if !previous.isEmpty {
            user += "\n\nThe slides so far:\n" + previous.enumerated().map { index, slide in
                "\(index + 1). \(slide.headline)" + (slide.body.isEmpty ? "" : " | \(slide.body)")
            }.joined(separator: "\n")
        }
        if let change = change?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !change.isEmpty {
            user += "\n\nChange: \(String(change.prefix(600)))\nWrite all \(total) lines again with this change."
        }
        return (system, user)
    }

    /// Reads the model's numbered lines into slides; fails unless every
    /// slide is there.
    public static func parse(_ text: String, photoCount: Int) throws -> [Slide] {
        var body = text
        if let end = body.range(of: "</think>") { body = String(body[end.upperBound...]) }
        let total = lineCount(photoCount: photoCount)
        var found: [Int: (String, String)] = [:]
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*-#> "))
            let digits = line.prefix { $0.isNumber }
            guard let number = Int(digits), (1...total).contains(number), found[number] == nil else { continue }
            var rest = line.dropFirst(digits.count)
            guard let mark = rest.first, ".):".contains(mark) else { continue }
            rest = rest.dropFirst()
            let parts = rest.split(separator: "|", maxSplits: 1).map { clean($0) }
            guard let headline = parts.first, !headline.isEmpty else { continue }
            let words = headline.split(separator: " ")
            found[number] = (words.prefix(maxHeadlineWords).joined(separator: " "),
                             parts.count > 1 ? parts[1].split(separator: " ").prefix(maxBodyWords).joined(separator: " ") : "")
        }
        guard found.count == total else { throw Problem.script }
        return (1...total).map { number in
            let kind: Slide.Kind = number == 1 ? .cover : number == total ? .closing : .photo
            return Slide(kind: kind, headline: found[number]!.0, body: found[number]!.1)
        }
    }

    private static func clean(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*_ ").union(.whitespaces))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One carousel slide as a sealed HTML page (see `HTMLMotionCapture`): the
/// photo full-bleed under a dark fade (or in a phone frame for screenshots so
/// text is not cropped), a big headline and a short line, and a page counter.
/// All text is escaped; the photo comes in as a data URL.
public enum CarouselPage {
    public enum Style: String, Equatable, Sendable {
        case photo
        case screenshot
    }

    /// Screenshots go inside a phone frame so their text is not cropped;
    /// everything else fills the slide.
    public static func style(forPhotoNote note: String) -> Style {
        note.lowercased().contains("screenshot") ? .screenshot : .photo
    }

    public static func html(_ slide: CarouselScript.Slide, photo: String?, index: Int, count: Int,
                            style: Style = .photo) -> String {
        let accent = "#2bd4a3"
        let headline = escape(slide.headline)
        let body = escape(slide.body)
        let swipe = slide.kind == .cover ? "<div class=\"swipe\">Swipe →</div>" : ""
        if style == .screenshot, let photo {
            let safePhoto = escape(photo)
            let headlineSize = slide.kind == .photo ? "7.4vw" : "9.2vw"
            return """
            <style>
            html,body{margin:0;width:100%;height:100%;overflow:hidden;background:radial-gradient(circle at 50% 28%,#163a32,#071311 72%);font-family:-apple-system,Helvetica,sans-serif}
            .device{position:absolute;left:22%;right:22%;top:8%;height:55%;border-radius:5vw;border:1.3vw solid #1c1f20;box-shadow:0 3.5vw 9vw rgba(0,0,0,.6);background:url('\(safePhoto)') top/cover no-repeat}
            .text{position:absolute;left:7%;right:7%;bottom:7%;text-align:center}
            .kicker{display:inline-block;width:12vw;height:1.4vw;background:\(accent);border-radius:1vw;margin-bottom:3vw}
            h1{margin:0;color:#fff;font-weight:900;font-size:\(headlineSize);line-height:1.04;letter-spacing:-.02em}
            p{margin:2.8vw 0 0;color:rgba(255,255,255,.9);font-size:4.2vw;line-height:1.3;font-weight:500}
            .count{position:absolute;top:5%;right:7%;color:#fff;font-size:3.4vw;font-weight:700;background:rgba(0,0,0,.35);padding:1.2vw 2.6vw;border-radius:5vw}
            .swipe{margin-top:3.6vw;color:\(accent);font-size:4vw;font-weight:800}
            </style>
            <div class="device"></div>
            <div class="count">\(index + 1)/\(count)</div>
            <div class="text"><div class="kicker"></div><h1>\(headline)</h1>\(body.isEmpty ? "" : "<p>\(body)</p>")\(swipe)</div>
            <script>window.renderFrame=function(t){};</script>
            """
        }
        let background = photo.map { "url('\(escape($0))') center/cover no-repeat" } ?? "linear-gradient(160deg,#0f2a24,#071311)"
        let headlineSize = slide.kind == .photo ? "9vw" : "12vw"
        return """
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#071311;font-family:-apple-system,Helvetica,sans-serif}
        .photo{position:absolute;inset:0;background:\(background)}
        .fade{position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,0) 35%,rgba(0,0,0,.82) 78%)}
        .text{position:absolute;left:7%;right:7%;bottom:9%}
        .kicker{display:inline-block;width:12vw;height:1.4vw;background:\(accent);border-radius:1vw;margin-bottom:4vw}
        h1{margin:0;color:#fff;font-weight:900;font-size:\(headlineSize);line-height:1.02;letter-spacing:-.02em}
        p{margin:3.5vw 0 0;color:rgba(255,255,255,.9);font-size:4.6vw;line-height:1.3;font-weight:500}
        .count{position:absolute;top:5%;right:7%;color:#fff;font-size:3.4vw;font-weight:700;background:rgba(0,0,0,.35);padding:1.2vw 2.6vw;border-radius:5vw}
        .swipe{margin-top:5vw;color:\(accent);font-size:4.2vw;font-weight:800}
        </style>
        <div class="photo"></div><div class="fade"></div>
        <div class="count">\(index + 1)/\(count)</div>
        <div class="text"><div class="kicker"></div><h1>\(headline)</h1>\(body.isEmpty ? "" : "<p>\(body)</p>")\(swipe)</div>
        <script>window.renderFrame=function(t){};</script>
        """
    }

    /// Text safe to put inside HTML and inside a quoted attribute.
    public static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
