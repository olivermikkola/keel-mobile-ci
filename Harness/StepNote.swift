import Foundation

/// The words a model writes before a tool call in the same reply ("Let me
/// check your files."). Shown to the user as one short update line, not as
/// the whole plan; the full text stays a tap away.
public enum StepNote {
    /// The longest update line, in characters.
    public static let maxSummaryCharacters = 100

    /// Text before the tool call, without reasoning markers or a half-written call.
    public static func narration(_ output: String) -> String {
        var text = output
        for marker in ["<tool_call>", "<|tool_call_start|>", "<function="] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        // A call still being written: drop an unfinished "<tool_c…" at the end.
        if let open = text.range(of: "<", options: .backwards), !text[open.lowerBound...].contains(">") {
            text = String(text[..<open.lowerBound])
        }
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.replacingOccurrences(of: "<think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line for the update: the first sentence, plain text, bounded. Nil when there is nothing to say.
    public static func summary(_ output: String) -> String? {
        let plain = narration(output)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in !line.isEmpty && !line.hasPrefix("#") } ?? ""
        guard !plain.isEmpty else { return nil }
        var sentence = plain
        if let end = plain.firstIndex(where: { ".!?:".contains($0) }) { sentence = String(plain[...end]) }
        if sentence.hasSuffix(":") { sentence = String(sentence.dropLast()) + "." }
        guard sentence.count > maxSummaryCharacters else { return sentence }
        return String(sentence.prefix(maxSummaryCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
