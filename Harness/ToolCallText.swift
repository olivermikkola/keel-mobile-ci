import Foundation

/// Recovers a single Qwen-style tool call from untidy small-model output.
///
/// Small models often wrap the call in a Markdown code fence, add a sentence
/// after it, drop the closing `</tool_call>`, or leak reasoning ending in
/// `</think>` before it. Desktop Keel recovers these
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

    /// Strips a completed `<think>...</think>` reasoning prefix from a plain
    /// assistant reply so the chat bubble shows the final answer.
    public static func visibleReply(_ output: String) -> String {
        if let close = output.range(of: "</think>", options: .backwards),
           !output[..<close.lowerBound].contains("<tool_call>"),
           !output[..<close.lowerBound].contains("<function") {
            let after = String(output[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { return after }
        }
        if output.hasPrefix("<think>") {
            return String(output.dropFirst("<think>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    /// Shown when an answer held nothing but broken tool or reasoning text.
    public static let brokenOnly = "The model wrote a broken tool request instead of an answer. Try again, or pick a model made for tool use."

    /// The final answer as the chat shows it. Besides a reasoning prefix, it
    /// drops what a model left behind when it never wrote a valid call:
    /// `<tool_call>` and `<function…>` blocks and stray `<think>`, `</think>`
    /// and parameter tags. Text inside Markdown code fences is left alone.
    /// `removed` is true when anything beyond the reasoning prefix went.
    public static func cleanReply(_ output: String) -> (text: String, removed: Bool) {
        var segments = output.components(separatedBy: "```")
        var removed = false
        for index in stride(from: 0, to: segments.count, by: 2) {
            var segment = segments[index]
            for pattern in strayBlocks {
                let cleaned = segment.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if cleaned != segment { removed = true; segment = cleaned }
            }
            segments[index] = segment
        }
        var text = segments.joined(separator: "```")
        // Reasoning that ended in a leaked </think> goes, as in visibleReply,
        // now that the call blocks that kept visibleReply from it are gone.
        if let close = text.range(of: "</think>", options: .backwards), !text[..<close.lowerBound].contains("```") {
            let after = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { text = after }
        }
        let parts = text.components(separatedBy: "```")
        text = parts.enumerated().map { index, part in
            guard index % 2 == 0 else { return part }
            let cleaned = part.replacingOccurrences(of: strayTag, with: "", options: .regularExpression)
            if cleaned != part { removed = true }
            return cleaned
        }.joined(separator: "```")
        let visible = visibleReply(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return (visible.isEmpty && removed ? brokenOnly : visible, removed)
    }

    /// A call block, closed or running to the end of the reply.
    static let strayBlocks = [#"<tool_call>[\s\S]*?(?:</tool_call>|\z)"#,
                              #"<function(?:=|\s|>)[\s\S]*?(?:</function>|\z)"#]
    /// Tags left over on their own.
    static let strayTag = #"</?(?:think|tool_call|function|param(?:eter)?)(?:[= ][^>\n]*)?>"#

    public static func normalize(_ output: String) -> Normalized {
        // Thinking is off, yet small models (LFM3 1.7B) sometimes write their
        // reasoning and a closing </think> before the call. The reasoning is
        // not part of the call: judge only what follows the last </think>.
        if let close = output.range(of: "</think>", options: .backwards),
           !output[..<close.lowerBound].contains("<tool_call>"),
           !output[..<close.lowerBound].contains("<function"),
           output[close.upperBound...].contains("<tool_call>") || output[close.upperBound...].contains("<function=") {
            let call = normalize(String(output[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            return Normalized(text: call.text, repaired: true, droppedTrailing: call.droppedTrailing)
        }
        let unchanged = Normalized(text: output, repaired: false, droppedTrailing: "")
        // The grammar also starts at a bare `<function=` (fine-tunes that drop
        // the wrapper). Put the wrapper back so the strict parser reads it.
        if occurrences(of: "<tool_call>", in: output) == 0, occurrences(of: "</tool_call>", in: output) == 0,
           occurrences(of: "<function=", in: output) == 1, occurrences(of: "</function>", in: output) == 1,
           let open = output.range(of: "<function="), let end = output.range(of: "</function>"),
           open.upperBound <= end.lowerBound {
            let wrapped = String(output[..<open.lowerBound]) + "<tool_call>\n" + String(output[open.lowerBound..<end.upperBound])
                + "\n</tool_call>" + String(output[end.upperBound...])
            let call = normalize(wrapped)
            return Normalized(text: call.text, repaired: true, droppedTrailing: call.droppedTrailing)
        }
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
