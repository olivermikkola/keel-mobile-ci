import Foundation

/// Markdown to HTML for the document viewer. Covers what a small model writes:
/// headings, paragraphs, nested and task lists, quotes, code, pipe tables,
/// rules, and inline emphasis, code and links. All text is HTML-escaped and
/// raw HTML is never passed through, so a document cannot run scripts.
public enum Markdown {
    public static func html(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return blocks(lines[...]).joined(separator: "\n")
    }

    // MARK: - Blocks

    private static func blocks(_ lines: ArraySlice<String>) -> [String] {
        var out: [String] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append("<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>") }
            paragraph = []
        }
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1
                out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                continue
            }
            if let heading = match(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#, trimmed) {
                flush()
                let level = heading[1].count
                out.append("<h\(level)>\(inline(heading[2]))</h\(level)>")
                index += 1; continue
            }
            if match(#"^([-*_])(\s*\1){2,}$"#, trimmed) != nil {
                flush(); out.append("<hr>"); index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.endIndex, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var text = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if text.first == " " { text = text.dropFirst() }
                    quoted.append(String(text)); index += 1
                }
                out.append("<blockquote>" + blocks(quoted[...]).joined(separator: "\n") + "</blockquote>")
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.endIndex, isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [lines[index]]
                let separator = lines[index + 1]
                index += 2
                while index < lines.endIndex, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(lines[index]); index += 1
                }
                out.append(table(header: rows[0], separator: separator, body: Array(rows.dropFirst())))
                continue
            }
            if listItem(line) != nil {
                flush()
                var items: [(indent: Int, ordered: Bool, text: String)] = []
                while index < lines.endIndex {
                    let current = lines[index]
                    if let item = listItem(current) {
                        // A numbered list right after a bulleted one (or the reverse) is a new list.
                        if item.indent <= items.first?.indent ?? 0, item.ordered != items.first?.ordered ?? item.ordered { break }
                        items.append(item)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.first == " " || current.first == "\t", !items.isEmpty {
                        // An indented line that is not an item continues the one before.
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                    } else if current.trimmingCharacters(in: .whitespaces).isEmpty,
                              index + 1 < lines.endIndex, listItem(lines[index + 1]) != nil {
                        // A blank line between items keeps the list going.
                    } else {
                        break
                    }
                    index += 1
                }
                var position = 0
                out.append(list(items, at: &position, indent: items[0].indent))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return out
    }

    private static func listItem(_ line: String) -> (indent: Int, ordered: Bool, text: String)? {
        guard let parts = match(#"^([ \t]*)([-*+]|\d{1,9}[.)])\s+(.*)$"#, line) else { return nil }
        let indent = parts[1].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (indent, parts[2].first?.isNumber ?? false, parts[3])
    }

    /// Items deeper than `indent` become a list inside the item before them.
    private static func list(_ items: [(indent: Int, ordered: Bool, text: String)], at position: inout Int, indent: Int) -> String {
        let tag = items[position].ordered ? "ol" : "ul"
        var html = "<\(tag)>"
        var open = false
        while position < items.count {
            let item = items[position]
            if item.indent < indent { break }
            if item.indent > indent, open {
                html += list(items, at: &position, indent: item.indent)
                continue
            }
            if open { html += "</li>" }
            html += "<li>" + taskItem(item.text)
            open = true
            position += 1
        }
        if open { html += "</li>" }
        return html + "</\(tag)>"
    }

    private static func taskItem(_ text: String) -> String {
        if let task = match(#"^\[([ xX])\]\s+(.*)$"#, text) {
            let checked = task[1] != " " ? " checked" : ""
            return "<input type=\"checkbox\" disabled\(checked)> " + inline(task[2])
        }
        return inline(text)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        match(#"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#, line) != nil && line.contains("-")
    }

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped { current.append(character == "|" ? "|" : "\\\(character)"); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func table(header: String, separator: String, body: [String]) -> String {
        let alignments = cells(separator).map { cell -> String in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return " style=\"text-align:center\""
            case (false, true): return " style=\"text-align:right\""
            default: return ""
            }
        }
        let headings = cells(header)
        func row(_ values: [String], tag: String) -> String {
            "<tr>" + headings.indices.map { column in
                let value = column < values.count ? values[column] : ""
                let align = column < alignments.count ? alignments[column] : ""
                return "<\(tag)\(align)>\(inline(value))</\(tag)>"
            }.joined() + "</tr>"
        }
        return "<div class=\"scroll\"><table><thead>" + row(headings, tag: "th") + "</thead><tbody>"
            + body.map { row(cells($0), tag: "td") }.joined() + "</tbody></table></div>"
    }

    // MARK: - Inline

    /// Code spans first, so emphasis and links inside them stay literal.
    static func inline(_ text: String) -> String {
        let parts = text.components(separatedBy: "`")
        guard parts.count >= 3 else { return emphasis(escape(text)) }
        var html = ""
        var index = 0
        while index < parts.count {
            if index % 2 == 1, index < parts.count - 1 || parts.count % 2 == 1 {
                html += "<code>" + escape(parts[index]) + "</code>"
            } else {
                html += emphasis(escape(index % 2 == 1 ? "`" + parts[index] : parts[index]))
            }
            index += 1
        }
        return html
    }

    private static let inlineRules: [(NSRegularExpression, String)] = [
        // A link target may hold one level of parentheses, as in javascript:alert(1).
        (#"!\[([^\]]*)\]\((?:[^()\s]|\([^()\s]*\))*\)"#, "$1"),
        (#"\[([^\]]+)\]\(((?:https?://|mailto:|#)(?:[^()\s]|\([^()\s]*\))*)\)"#, "<a href=\"$2\">$1</a>"),
        (#"\[([^\]]+)\]\((?:[^()\s]|\([^()\s]*\))*\)"#, "$1"),
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "<strong>$1</strong>"),
        (#"__(?=\S)(.+?)(?<=\S)__"#, "<strong>$1</strong>"),
        (#"(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])"#, "<em>$1</em>"),
        (#"(?<![_\w])_(?=\S)(.+?)(?<=\S)_(?![_\w])"#, "<em>$1</em>"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func emphasis(_ escaped: String) -> String {
        inlineRules.reduce(escaped) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { group in
            Range(result.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
