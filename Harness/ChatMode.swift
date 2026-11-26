import Foundation

/// Chat or Work, chosen per chat in the header.
///
/// Chat is for quick answers: a short prompt, read-only tools and the
/// connected services, short replies and few steps, so the phone reads less,
/// writes less and stays cooler. Work is the full agent: it writes files,
/// runs code and works through several steps. The runtime and model belong
/// to the model, not the mode; each mode only remembers which model the user
/// last picked for it and recommends a few.
public enum ChatMode: String, Codable, CaseIterable, Sendable {
    case chat, work

    public var title: String { self == .chat ? "Chat" : "Work" }

    /// One line in the mode menu.
    public var summary: String {
        switch self {
        case .chat: return "Quick answers. Reads files, links and connected services"
        case .work: return "Does the job: writes files, runs code, takes several steps"
        }
    }

    /// SF Symbol name.
    public var symbol: String { self == .chat ? "bubble.left" : "hammer" }

    /// Tools Chat keeps from the local tool set. Connector, GitHub, Shortcuts,
    /// Calendar/Reminders and `load_tools` are kept as well when enabled.
    static let chatTools: Set<String> = [
        "search_repo", "read_file", "list_files", "read_url", "web_search",
        "remember", "recall", "run_shortcut",
        "calendar_events", "reminders_list", "create_reminder", "create_calendar_event",
        ToolRegistry.loadToolsName,
    ]

    /// Whether this mode offers a tool from the local tool set.
    func offers(_ tool: String) -> Bool {
        self == .work || Self.chatTools.contains(tool) || tool.hasPrefix("mcp_") || tool.hasPrefix("github_")
    }

    /// Tool calls before the reply pauses to ask the user "Keep going?". Not
    /// a hard limit: each yes allows this many more. Repository chats use Work's.
    public var toolCheckIn: Int { self == .chat ? 8 : 25 }

    /// Reply cap per model step before any thinking budget. Chat never writes
    /// a whole file in one call, so it keeps the reading cap.
    public func replyTokens(writing: Bool) -> Int {
        self == .chat || !writing ? AgentPrompt.readingReplyTokens : AgentPrompt.writingReplyTokens
    }

    /// Catalog model IDs recommended for this mode, best first. Chat favours
    /// small, fast and multimodal models; Work the larger tool models.
    public var recommendedModelIDs: [String] {
        switch self {
        case .chat: return ["lfm3", "lfm3-vl", "minicpm5"]
        case .work: return ["9B", "4B"]
        }
    }

    /// The mode a chat is in. Chats saved before modes existed, apps and
    /// repository chats are Work: they need every tool they had.
    public static func resolve(saved: ChatMode?, app: Bool, repository: Bool) -> ChatMode {
        app || repository ? .work : (saved ?? .work)
    }
}
