import Foundation

/// Prepares an assistant reply for `AVSpeechSynthesizer` so reading a message
/// aloud skips tool XML, fenced code blocks, and Markdown punctuation.
public enum SpeechText {
    /// Maximum characters sent to the system speech synthesizer for one reply.
    public static let maxCharacters = 8_000

    public static func spoken(from raw: String) -> String {
        var text = stripThinkingAndToolCalls(raw)
        let hadCode = containsFencedCode(text)
        text = stripFencedCode(text)
        text = stripMarkdown(text)
        let cleaned = collapseWhitespace(text)
        if cleaned.isEmpty {
            return hadCode ? "Code block." : ""
        }
        return String(cleaned.prefix(maxCharacters))
    }

    private static func stripThinkingAndToolCalls(_ source: String) -> String {
        var text = source
        if let close = text.range(of: "</think>", options: .backwards) {
            if let open = text.range(of: "<think>") {
                if open.lowerBound < close.lowerBound {
                    text.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    text = String(text[close.upperBound...])
                }
            } else {
                text = String(text[close.upperBound...])
            }
        }
        while let open = text.range(of: "<tool_call>") {
            if let close = text.range(of: "</tool_call>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        while let open = text.range(of: "<function") {
            if let close = text.range(of: "</function>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text
    }

    private static func fence(_ line: String) -> (Character, Int, String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let count = rest.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let suffix = rest.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines)
        if first == "`" && suffix.contains("`") { return nil }
        return (first, count, suffix)
    }

    private static func containsFencedCode(_ source: String) -> Bool {
        source.components(separatedBy: "\n").contains { fence($0) != nil }
    }

    private static func stripFencedCode(_ source: String) -> String {
        var kept: [String] = []
        var open: (character: Character, length: Int)?
        for line in source.components(separatedBy: "\n") {
            if let active = open {
                if let closing = fence(line), closing.0 == active.character,
                   closing.1 >= active.length, closing.2.isEmpty {
                    open = nil
                }
            } else if let opening = fence(line) {
                open = (opening.0, opening.1)
            } else {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    private static func stripMarkdown(_ source: String) -> String {
        var lines: [String] = []
        for rawLine in source.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("> ") {
                line = String(line.dropFirst(2))
            }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") {
                line = String(line.dropFirst(6))
            } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line.hasPrefix("* [x] ") || line.hasPrefix("* [X] ") {
                line = String(line.dropFirst(6))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2))
            }
            lines.append(stripInlineMarkdown(line))
        }
        return lines.joined(separator: "\n")
    }

    private static func stripInlineMarkdown(_ line: String) -> String {
        var result = line
        // Replace Markdown links [label](url) with label.
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }
        result = result.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return result
    }

    private static func collapseWhitespace(_ source: String) -> String {
        let paragraphs = source
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        var out: [String] = []
        for line in paragraphs {
            if line.isEmpty {
                if out.last != "" && !out.isEmpty { out.append("") }
            } else {
                out.append(line)
            }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
