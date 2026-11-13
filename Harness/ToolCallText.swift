import Foundation

/// Recovers a single Qwen-style tool call from untidy small-model output.
///
/// Small models often wrap the call in a Markdown code fence, add a sentence
/// after it, or drop the closing `</tool_call>`. Desktop Keel recovers these
/// as a text fallback. This only removes text *around* exactly one call. It
/// never invents, reorders or edits arguments; the app's strict parser still
/// validates the result. Two or more calls are ambiguous and are left as is,
/// so the strict parser rejects them.
public enum ToolCallText {
    public struct Normalized: Equatable {
        /// Text to hand to the strict parser: optional leading prose, then one call.
        public let text: String
        /// True when anything was removed or repaired.
        public let repaired: Bool
        /// Text after the call that was dropped (never executed).
        public let droppedTrailing: String
    }

    public static func normalize(_ output: String) -> Normalized {
        let unchanged = Normalized(text: output, repaired: false, droppedTrailing: "")
        guard occurrences(of: "<tool_call>", in: output) == 1,
              occurrences(of: "<function=", in: output) == 1,
              occurrences(of: "</function>", in: output) == 1,
              occurrences(of: "</tool_call>", in: output) <= 1,
              let open = output.range(of: "<tool_call>"),
              let functionEnd = output.range(of: "</function>"),
              open.upperBound <= functionEnd.lowerBound
        else { return unchanged }

        var end = functionEnd.upperBound
        var closedByModel = false
        if let close = output.range(of: "</tool_call>", range: functionEnd.upperBound..<output.endIndex) {
            // Only whitespace or a fence may sit between </function> and </tool_call>.
            let between = output[functionEnd.upperBound..<close.lowerBound]
            if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                end = close.upperBound
                closedByModel = true
            } else {
                return unchanged
            }
        }

        var leading = String(output[..<open.lowerBound])
        var trailing = String(output[end...])
        leading = stripFenceOpening(leading)
        trailing = stripFenceClosing(trailing)

        let call = String(output[open.lowerBound..<end]) + (closedByModel ? "" : "\n</tool_call>")
        let text = (leading.isEmpty ? "" : leading + "\n") + call
        let droppedTrailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        let repaired = text != output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Normalized(text: text, repaired: repaired, droppedTrailing: droppedTrailing)
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Removes a trailing ```xml / ``` line that opened a fence around the call.
    static func stripFenceOpening(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a leading ``` line that closed a fence around the call.
    static func stripFenceClosing(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "```" { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
