import Foundation

/// Standing instructions written by the user in Customize and added to every
/// chat's system prompt, bounded and defused so user text cannot inject
/// template or tool-call control tokens.
public enum CustomInstructions {
    public static let maxCharacters = 1_000

    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let capped = String(trimmed.prefix(maxCharacters))
        return capped
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "<s>", with: "< s>")
            .replacingOccurrences(of: "</s>", with: "</ s>")
            .replacingOccurrences(of: "<tool_call>", with: "< tool_call>")
            .replacingOccurrences(of: "</tool_call>", with: "</ tool_call>")
            .replacingOccurrences(of: "<function", with: "< function")
            .replacingOccurrences(of: "</function>", with: "</ function>")
            .replacingOccurrences(of: "<tool_response>", with: "< tool_response>")
            .replacingOccurrences(of: "</tool_response>", with: "</ tool_response>")
            .replacingOccurrences(of: "<__media__>", with: "< __media__>")
            .replacingOccurrences(of: "<think>", with: "< think>")
            .replacingOccurrences(of: "</think>", with: "</ think>")
    }

    public static func apply(_ custom: String, to systemPrompt: String) -> String {
        let clean = sanitize(custom)
        guard !clean.isEmpty else { return systemPrompt }
        return systemPrompt + "\n\nStanding instructions from the user for every chat:\n" + clean
    }
}
