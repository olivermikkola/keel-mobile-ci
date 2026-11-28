import Foundation

/// A chat's title written by the chat model after its first reply.
///
/// The question is asked as one more user turn on the chat's own prompt, so
/// the model reuses everything it has already read and only reads this short
/// question and writes a few words. Anything that does not look like a title
/// is rejected and the tidied first message stays (`SavedTask.tidyTitle`).
public enum ChatTitle {
    /// The extra user turn. Short, so it costs a few dozen tokens to read.
    public static let ask = "Give this chat a short title of 2 to 6 words. Reply with only the title, no quotes."
    /// Enough for six words in any tokenizer we ship, and no more.
    public static let replyTokens = 20
    public static let maxCharacters = 60
    public static let maxWords = 8

    /// The title in a reply, or nil when the reply is not a usable title.
    public static func parse(_ reply: String) -> String? {
        var text = reply
        if text.contains("<think>") {
            guard text.contains("</think>") else { return nil }   // still reasoning: no title
            text = ToolCallText.afterThink(text)
        }
        guard !text.contains("<tool_call>"), !text.contains("<function") else { return nil }
        guard var line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        for prefix in ["title:", "chat title:", "# "] where line.lowercased().hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*_`#.:;, "))
        let words = line.split(whereSeparator: \.isWhitespace)
        guard line.count >= 2, line.count <= maxCharacters, !words.isEmpty, words.count <= maxWords else { return nil }
        guard line.contains(where: \.isLetter) else { return nil }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Only the first exchange of a chat gets a model title: one user message
    /// and the reply. Later turns keep it.
    public static func isFirstExchange(userMessages: Int) -> Bool { userMessages == 1 }
}
