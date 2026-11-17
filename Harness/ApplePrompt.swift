import Foundation

/// Apple's on-device model (the FoundationModels framework) takes plain
/// instructions and a prompt, not a raw chat template. Keel renders the Apple
/// model's chats as ChatML, like Bonsai's, and this turns that back into the
/// two parts: the system message becomes the instructions, and the
/// conversation becomes one prompt that ends asking for the next reply.
/// Tool calls stay in Keel's own text format and are parsed as for any model.
public enum ApplePrompt {
    public struct Parts: Equatable, Sendable {
        public let instructions: String
        public let prompt: String
    }

    /// Nil when `chatML` is not a system message, then turns, then an open assistant turn.
    public static func split(chatML: String) -> Parts? {
        var segments = chatML.components(separatedBy: "<|im_start|>")
        guard segments.first?.isEmpty == true else { return nil }
        segments.removeFirst()
        guard let first = segments.first, first.hasPrefix("system\n"),
              let last = segments.last, last.hasPrefix("assistant\n"), !last.contains("<|im_end|>") else { return nil }
        let instructions = body(first, role: "system")
        var turns: [(role: String, text: String)] = []
        for segment in segments.dropFirst().dropLast() {
            guard let newline = segment.firstIndex(of: "\n") else { return nil }
            let role = String(segment[..<newline])
            guard ["user", "assistant"].contains(role) else { return nil }
            var text = body(segment, role: role)
            if role == "assistant" { text = text.replacingOccurrences(of: "<think>\n\n</think>\n\n", with: "") }
            if role == "user", text.hasPrefix("<tool_response>") {
                let results = text.components(separatedBy: "<tool_response>").compactMap { part -> String? in
                    let result = part.replacingOccurrences(of: "</tool_response>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return result.isEmpty ? nil : result
                }
                turns += results.map { (role: "tool", text: $0) }
            } else {
                turns.append((role: role, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        guard !turns.isEmpty else { return nil }
        // A single question needs no transcript around it.
        if turns.count == 1, turns[0].role == "user" { return Parts(instructions: instructions, prompt: turns[0].text) }
        let labels = ["user": "User", "assistant": "You", "tool": "Tool result"]
        let transcript = turns.map { "\(labels[$0.role]!):\n\($0.text)" }.joined(separator: "\n\n")
        let ask = turns.last?.role == "tool"
            ? "Continue from the last tool result: call the next tool or answer the user."
            : "Write your reply to the user's last message."
        return Parts(instructions: instructions, prompt: "Conversation so far:\n\n\(transcript)\n\n\(ask)")
    }

    private static func body(_ segment: String, role: String) -> String {
        var text = String(segment.dropFirst(role.count + 1))
        if let end = text.range(of: "<|im_end|>", options: .backwards) { text = String(text[..<end.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apple's framework reports no token counts; this is the usual estimate
    /// of about four characters a token, for the speed line under a reply.
    public static func estimatedTokens(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }
}
