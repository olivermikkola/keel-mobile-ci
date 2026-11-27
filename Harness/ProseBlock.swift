import Foundation

/// The prose of a reply (everything outside its code fences), split into the
/// blocks a chat shows: headings, paragraphs, lists, quotes, tables and rules.
/// Small models write Markdown whether asked to or not; shown raw it reads as
/// stray `#`, `**` and `|`. Only the block structure is decided here. Inline
/// marks (bold, italic, inline code) are left in the text for the view.
public enum ProseBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([Item])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct Item: Equatable, Sendable {
        /// What is drawn before the text: "•", "1.", "☐" or "☑".
        public let marker: String
        /// Nesting, 0 for the outer list. Capped at `maxDepth`.
        public let depth: Int
        public let text: String

        public init(marker: String, depth: Int, text: String) {
            self.marker = marker; self.depth = depth; self.text = text
        }
    }

    public static let maxDepth = 3
    /// A table wider than this is left as a paragraph: it would not fit a phone.
    public static let maxColumns = 8

    public static func parse(_ source: String) -> [ProseBlock] {
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() { if !items.isEmpty { blocks.append(.list(items)); items = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.isEmpty {
                // A blank line ends a paragraph or quote. A list stays open: models
                // often put blank lines between its items.
                flushParagraph(); flushQuote()
                continue
            }
            if let heading = heading(trimmed) {
                flushAll(); blocks.append(heading); continue
            }
            if isRule(trimmed) {
                flushAll(); blocks.append(.rule); continue
            }
            if let item = item(line) {
                flushParagraph(); flushQuote(); items.append(item); continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if index + 1 < lines.count, let header = cells(trimmed), isSeparator(lines[index + 1], columns: header.count) {
                flushAll()
                var rows: [[String]] = []
                var next = index + 2
                while next < lines.count, let row = cells(lines[next].trimmingCharacters(in: .whitespaces), atLeast: 1) {
                    // Rows are fitted to the header: short ones padded, long ones cut.
                    rows.append((row + Array(repeating: "", count: header.count)).prefix(header.count).map { $0 })
                    next += 1
                }
                blocks.append(.table(header: header, rows: rows))
                index = next - 1
                continue
            }
            // An indented line right after a list item continues that item.
            if let last = items.last, paragraph.isEmpty, line.first == " " || line.first == "\t",
               index > 0, !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                items[items.count - 1] = Item(marker: last.marker, depth: last.depth, text: last.text + " " + trimmed)
                continue
            }
            flushList(); flushQuote()
            paragraph.append(trimmed)
        }
        flushAll()
        return blocks
    }

    /// Text made safe to hand to an inline Markdown renderer: a link becomes
    /// its text followed by the address in brackets, so the address a model
    /// wrote is always visible and never a hidden tap target, and `<` is
    /// escaped so tag-like text is shown instead of being read as HTML.
    public static func inlineSafe(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "]"),
                  after[after.index(after: close)...].first == "(",
                  let end = after[close...].firstIndex(of: ")"),
                  !after[..<close].contains("\n") else {
                result += rest[...open]; rest = after; continue
            }
            var before = rest[..<open]
            if before.last == "!" { before = before.dropLast() }   // an image: show it as a link
            let label = after[..<close]
            let address = after[after.index(close, offsetBy: 2)..<end].trimmingCharacters(in: .whitespaces)
            result += before
            result += address.isEmpty || address == label ? String(label) : "\(label) (\(address))"
            rest = after[after.index(after: end)...]
        }
        result += rest
        return result.replacingOccurrences(of: "<", with: "\\<")
    }

    private static func heading(_ trimmed: String) -> ProseBlock? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func item(_ line: String) -> Item? {
        var indent = 0
        var body = Substring(line)
        while let first = body.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1; body = body.dropFirst()
        }
        let depth = min(indent / 2, maxDepth)
        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            for (box, marker) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(box) {
                return Item(marker: marker, depth: depth, text: String(text.dropFirst(box.count)))
            }
            return Item(marker: "•", depth: depth, text: text)
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Item(marker: "\(digits).", depth: depth, text: text)
    }

    /// The cells of a table row, or nil when the line is not one.
    private static func cells(_ trimmed: String, atLeast minimum: Int = 2) -> [String]? {
        guard trimmed.contains("|") else { return nil }
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true; current.append(character) }
            else if character == "|" { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        if trimmed.hasPrefix("|") { parts.removeFirst() }
        if trimmed.hasSuffix("|"), !parts.isEmpty { parts.removeLast() }
        let result = parts.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        return result.count >= minimum && result.count <= maxColumns ? result : nil
    }

    /// The `|---|:--:|` line under a table header, with the header's column count.
    private static func isSeparator(_ line: String, columns: Int) -> Bool {
        guard let parts = cells(line.trimmingCharacters(in: .whitespaces)), parts.count == columns else { return false }
        return parts.allSatisfy { part in
            let dashes = part.filter { $0 == "-" }.count
            return dashes >= 1 && part.allSatisfy { "-: ".contains($0) }
        }
    }
}
