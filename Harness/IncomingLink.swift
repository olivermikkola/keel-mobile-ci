import Foundation

/// Parses incoming deep links (`keelmobile://ask?text=...`, `keelmobile://open?url=...`)
/// and shared file URLs (`file://...`) handed to Keel Mobile from iOS Share Sheet,
/// Files, Safari, or Shortcuts.
public enum IncomingLink: Equatable, Sendable {
    public static let maxPromptCharacters = 16_000

    /// Prefill the chat composer with text (e.g. from `keelmobile://ask?text=...` or `keelmobile://open?url=...`).
    case draftPrompt(String)
    /// Attach a local file shared into Keel via "Open in Keel Mobile".
    case sharedFile(URL)
    /// Something sent from another app's share sheet (`SharedInbox`).
    case shared(UUID)

    public static func parse(_ url: URL) -> IncomingLink? {
        if url.isFileURL {
            return .sharedFile(url)
        }
        guard url.scheme?.lowercased() == "keelmobile" else { return nil }
        let host = (url.host ?? "").lowercased()
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []

        switch host {
        case "ask":
            let raw = items.first(where: { $0.name == "text" || $0.name == "prompt" || $0.name == "q" })?.value ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let bounded = String(trimmed.prefix(maxPromptCharacters))
            return .draftPrompt(bounded)

        case "open":
            let rawURL = (items.first(where: { $0.name == "url" })?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let target = URL(string: rawURL),
                  let scheme = target.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  target.host != nil else { return nil }
            let note = (items.first(where: { $0.name == "text" || $0.name == "prompt" })?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = note.isEmpty
                ? "Read and summarize \(target.absoluteString)"
                : "\(note)\n\n\(target.absoluteString)"
            return .draftPrompt(String(prompt.prefix(maxPromptCharacters)))

        case "share":
            guard let raw = items.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: raw) else { return nil }
            return .shared(id)

        default:
            return nil
        }
    }
}
