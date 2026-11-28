import Foundation

/// What a chat's context holds, for the rule that guards calls leaving the phone.
///
/// A small model cannot be trusted to ignore instructions planted in a web page,
/// a connector result or a repository file. The harm needs three things in one
/// context: private data, text someone else wrote, and a call that sends
/// model-chosen arguments off the phone. Labelling the outside text "untrusted"
/// helps the model; this rule does not depend on the model at all. Once a chat
/// holds both private data and outside text, every outbound call that could
/// carry that data somewhere new asks the user, every time, and "Always allow"
/// does not skip it.
///
/// The state is saved on each tool result (`ChatMessage.taint`), so it carries
/// over to later turns of the same chat: earlier results stay in the context.
public struct TurnTaint: Codable, Equatable, Sendable {
    /// Where the private data in the context came from: `phone`, `github`, or a
    /// connector (`connector(id)`). Sending data back to where it came from
    /// leaks it to nobody new, so such a call keeps the user's usual choice.
    public private(set) var privateOrigins: Set<String>
    /// Text written by someone other than the user: web pages, search results,
    /// connector results, repository files, Shortcuts output.
    public private(set) var outsideText: Bool

    public static let phone = "phone"
    public static let github = "github"
    public static func connector(_ serverID: String) -> String { "connector:" + serverID }

    public init(privateOrigins: Set<String> = [], outsideText: Bool = false) {
        self.privateOrigins = privateOrigins
        self.outsideText = outsideText
    }

    public var isEmpty: Bool { privateOrigins.isEmpty && !outsideText }
    public var hasPrivateData: Bool { !privateOrigins.isEmpty }

    public mutating func merge(_ other: TurnTaint) {
        privateOrigins.formUnion(other.privateOrigins)
        outsideText = outsideText || other.outsideText
    }

    /// What a finished tool's result adds to the context.
    /// - Parameters:
    ///   - connectorID: the server id when `name` is a connector call.
    ///   - inRepository: file tools read a GitHub repository, whose files were
    ///     written by other people, rather than the user's own chat files.
    public static func effect(ofTool name: String, connectorID: String? = nil, inRepository: Bool = false) -> TurnTaint {
        if let connectorID {
            // A connector returns the user's data (mail, notes) that other people wrote.
            return TurnTaint(privateOrigins: [connector(connectorID)], outsideText: true)
        }
        switch name {
        case "read_file", "search_file", "search_repo", "run_js", "run_sql", ShellTool.name:
            return inRepository
                ? TurnTaint(privateOrigins: [github], outsideText: true)
                : TurnTaint(privateOrigins: [phone])
        case "recall", "calendar_events", "reminders_list", ContactsTools.name:
            return TurnTaint(privateOrigins: [phone])
        case ClipboardTool.name:
            // Copied text is the user's, but it may have come from any web page or message.
            return TurnTaint(privateOrigins: [phone], outsideText: true)
        case "github_repos":
            return TurnTaint(privateOrigins: [github])
        case "run_shortcut":
            // Shortcuts can read messages, notes or files the user has, which others wrote.
            return TurnTaint(privateOrigins: [phone], outsideText: true)
        case "read_url", "web_search":
            return TurnTaint(outsideText: true)
        default:
            // list_files shows names only; edits, memory writes, media and the
            // tool loader add nothing the model did not already have.
            return TurnTaint()
        }
    }

    /// The state a chat starts a turn with: every earlier result's taint, plus
    /// private data that is in the prompt before any tool runs.
    public static func initial(history: [TurnTaint?], privatePrompt: Bool) -> TurnTaint {
        var taint = TurnTaint(privateOrigins: privatePrompt ? [phone] : [])
        for item in history { if let item { taint.merge(item) } }
        return taint
    }

    public enum Gate: Equatable, Sendable {
        /// Run without asking.
        case run
        /// Ask; the user may choose "Always allow".
        case ask
        /// Ask, and offer no "Always allow": private data and outside text are
        /// both in the context, and this call could carry the data out.
        case askEveryTime
    }

    /// Decides a call that sends model-chosen arguments to `destination`.
    /// - Parameters:
    ///   - needsApproval: the tool asks anyway (it may change things, or the
    ///     user has not allowed it).
    ///   - alwaysAllowed: the user chose "Always allow" for this tool.
    ///
    /// Only private data from somewhere else escalates. Data going back to the
    /// service it came from keeps the user's usual choice: many services do not
    /// mark their tools read-only, and asking on every repeat call would teach
    /// the user to tap Allow without reading. The cost: a tool the user marked
    /// "Always allow" on a service (say, send mail) can still be steered by text
    /// from that same service.
    public func gate(destination: String, needsApproval: Bool, alwaysAllowed: Bool) -> Gate {
        let carried = privateOrigins.subtracting([destination])
        if outsideText && !carried.isEmpty { return .askEveryTime }
        if needsApproval { return .ask }
        if !carried.isEmpty && !alwaysAllowed { return .ask }
        return .run
    }

    /// One line for the approval prompt when the gate is `askEveryTime`.
    public static let everyTimeReason =
        "This chat holds your private data and text from outside (a web page, a connector or a repository). Keel asks every time before anything leaves the phone, so planted instructions cannot send your data out."
}
