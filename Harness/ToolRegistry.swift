import Foundation

/// Functional grouping for on-device tools, used for progressive disclosure
/// (`load_tools`), prompt summaries, and routing.
public enum ToolCategory: String, Codable, CaseIterable, Sendable {
    case files
    case edit
    case compute
    case web
    case github
    case memory
    case calendar
    case shortcuts
    case media
    case connectors
    case meta

    public var title: String {
        switch self {
        case .files: return "Files"
        case .edit: return "File edits"
        case .compute: return "Code & SQL"
        case .web: return "Web"
        case .github: return "GitHub"
        case .memory: return "Memory & Recall"
        case .calendar: return "Calendar & Reminders"
        case .shortcuts: return "Shortcuts"
        case .media: return "Media"
        case .connectors: return "Connectors"
        case .meta: return "Tool loader"
        }
    }
}

/// Execution safety tier of a tool. Model output is always a request, never
/// permission: `localProposal` prepares an inert diff for UI review, and
/// `approvalRequired` pauses for an explicit UI confirmation.
public enum ToolSafety: String, Codable, Sendable {
    case readOnly
    case localProposal
    case approvalRequired
}

/// Single source of truth for Keel Mobile's tool names, categories, safety
/// tiers, labels, entity decoding, and schema-aware error recovery.
public enum ToolRegistry {
    /// Meta-tool that loads deferred tool schemas into the active session
    /// without mutating the system prompt (preserving KV-cache prefix reuse).
    public static let loadToolsName = "load_tools"

    public static let loadToolsSchemaLine = #"{"type":"function","function":{"name":"load_tools","description":"Load full parameter schemas for additional available tool groups or tool names listed in this chat. Pass group (e.g. calendar, github, connectors, web, compute, edit, memory, shortcuts, media, all), names (comma-separated tool names), or query.","parameters":{"type":"object","properties":{"group":{"type":"string"},"names":{"type":"string"},"query":{"type":"string"}},"required":[]}}}"#

    /// Canonical set of built-in tool names accepted by the strict parser.
    public static let builtInAllowedTools: Set<String> = [
        // Workspace reads
        "list_files", "search_file", "search_repo", "read_file",
        // Workspace proposals
        "propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file",
        // In-process compute
        "run_sql", "run_js", ShellTool.name,
        // Web
        "read_url", "web_search",
        // GitHub
        "github_repos", "github_open",
        // Personal memory & semantic recall
        "remember", "recall",
        // Media
        "generate_image", "create_short_video",
        // Apple / on-device
        "run_shortcut",
        "calendar_events", "reminders_list", "create_reminder", "create_calendar_event",
        // Progressive tool loader
        loadToolsName,
        // Legacy / explicitly refused UI-only actions (kept so DirectorToolError.approvalRequired runs)
        "run_ci", "finish_task",
    ]

    /// Frequently hallucinated small-model tool names mapped to Keel's real
    /// tool names. Used ONLY to suggest corrections — never silently executed.
    public static let commonAliases: [String: String] = [
        "ls": "list_files",
        "list_dir": "list_files",
        "list_directory": "list_files",
        "find_files": "list_files",
        "read": "read_file",
        "open_file": "read_file",
        "view_file": "read_file",
        "cat": "read_file",
        "search": "search_repo",
        "grep": "search_repo",
        "search_files": "search_repo",
        "find_in_files": "search_repo",
        "edit": "propose_edit",
        "edit_file": "propose_edit",
        "modify_file": "propose_edit",
        "replace_in_file": "propose_edit",
        "patch_file": "propose_edit",
        "write_file": "create_file",
        "new_file": "create_file",
        "save_file": "create_file",
        "remove_file": "delete_file",
        "rm": "delete_file",
        "move_file": "rename_file",
        "mv": "rename_file",
        "sql": "run_sql",
        "query_sql": "run_sql",
        "execute_sql": "run_sql",
        "js": "run_js",
        "bash": ShellTool.name,
        "sh": ShellTool.name,
        "terminal": ShellTool.name,
        "run_command": ShellTool.name,
        "run_shell": ShellTool.name,
        "run_bash": ShellTool.name,
        "exec": ShellTool.name,
        "execute_command": ShellTool.name,
        "javascript": "run_js",
        "run_code": "run_js",
        "eval_js": "run_js",
        "fetch_url": "read_url",
        "open_url": "read_url",
        "get_url": "read_url",
        "browse": "read_url",
        "search_web": "web_search",
        "internet_search": "web_search",
        "brave_search": "web_search",
        "save_memory": "remember",
        "add_memory": "remember",
        "search_memory": "recall",
        "memory_search": "recall",
        "create_image": "generate_image",
        "draw_image": "generate_image",
        "make_video": "create_short_video",
        "create_video": "create_short_video",
        "short_video": "create_short_video",
        "make_short": "create_short_video",
        "make_reel": "create_short_video",
        "shortcut": "run_shortcut",
        "list_events": "calendar_events",
        "get_events": "calendar_events",
        "get_calendar": "calendar_events",
        "list_reminders": "reminders_list",
        "get_reminders": "reminders_list",
        "add_reminder": "create_reminder",
        "new_reminder": "create_reminder",
        "add_event": "create_calendar_event",
        "create_event": "create_calendar_event",
        "new_event": "create_calendar_event",
        "list_repos": "github_repos",
        "open_repo": "github_open",
        "enable_tools": loadToolsName,
        "discover_tools": loadToolsName,
        "search_tools": loadToolsName,
    ]

    public static func isAllowedToolName(_ name: String) -> Bool {
        builtInAllowedTools.contains(name) || MCPConnector.isConnectorCall(name)
    }

    public static func category(for toolName: String) -> ToolCategory {
        if MCPConnector.isConnectorCall(toolName) { return .connectors }
        switch toolName {
        case "list_files", "read_file", "search_repo", "search_file": return .files
        case "propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file": return .edit
        case "run_sql", "run_js", ShellTool.name: return .compute
        case "read_url", "web_search": return .web
        case "github_repos", "github_open": return .github
        case "remember", "recall": return .memory
        case "calendar_events", "reminders_list", "create_reminder", "create_calendar_event": return .calendar
        case "run_shortcut": return .shortcuts
        case "generate_image", "create_short_video": return .media
        case loadToolsName: return .meta
        default: return .files
        }
    }

    public static func safety(for toolName: String, mcpReadOnly: Bool? = nil) -> ToolSafety {
        if MCPConnector.isConnectorCall(toolName) {
            return mcpReadOnly == true ? .readOnly : .approvalRequired
        }
        switch toolName {
        case "list_files", "read_file", "search_repo", "search_file",
             "run_sql", "run_js", "read_url", "github_repos", "github_open",
             "recall", "calendar_events", "reminders_list", loadToolsName:
            return .readOnly
        case "propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file",
             "generate_image", "create_short_video", ShellTool.name:
            return .localProposal
        case "web_search", "remember", "run_shortcut", "create_reminder", "create_calendar_event",
             "run_ci", "finish_task":
            return .approvalRequired
        default:
            return .approvalRequired
        }
    }

    /// Single-pass XML entity decoder for tool parameters (`&amp;lt;` becomes `&lt;`,
    /// never double-decoded). Handles `&lt;`, `&gt;`, `&quot;`, `&apos;`, and `&amp;`.
    public static func decodeXMLEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Human-readable activity label for a parsed call.
    static func label(for call: DirectorCall) -> String {
        let name = call.name
        let arguments = call.arguments
        switch name {
        case "list_files":
            let path = arguments["path"] ?? "/"
            return "List \(path.isEmpty ? "/" : path)"
        case "search_file":
            return "Search '\(arguments["query"] ?? "")' in \(arguments["path"] ?? "")"
        case "search_repo":
            let path = arguments["path"] ?? ""
            return "Search \(path.isEmpty || path == "." ? "repository" : path) · \(arguments["query"] ?? "")"
        case "read_file":
            let start = arguments["start_line"] ?? "1"
            guard let count = arguments["count"] else { return "Read \(arguments["path"] ?? "") · from line \(start)" }
            return "Read \(arguments["path"] ?? "") · lines \(start)+(\(count))"
        case "stage_file_edit", "propose_edit":
            return "Propose edit · \(arguments["path"] ?? "")"
        case "create_file":
            return "Propose create · \(arguments["path"] ?? "")"
        case "delete_file":
            return "Propose delete · \(arguments["path"] ?? "")"
        case "rename_file":
            return "Propose rename · \(arguments["path"] ?? "") → \(arguments["destination_path"] ?? "")"
        case "run_sql":
            return "Run SQL"
        case "run_js":
            return "Run JavaScript"
        case ShellTool.name:
            let command = (arguments["command"] ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Shell · " + (command.count > 60 ? String(command.prefix(60)) + "…" : command)
        case "web_search":
            return "Search the web"
        case "read_url":
            return "Read web page · \(URL(string: arguments["url"] ?? "")?.host ?? "")"
        case "github_repos":
            return "Look at your GitHub repositories"
        case "github_open":
            return "Open \(arguments["repository"] ?? "a repository") from GitHub"
        case "remember":
            return "Remember about you"
        case "recall":
            return "Look through earlier chats and files"
        case "generate_image":
            return "Make an image · \(arguments["path"] ?? "")"
        case "create_short_video":
            return "Make a short video · \(arguments["path"] ?? "")"
        case "run_shortcut":
            return "Run shortcut · \(arguments["name"] ?? "")"
        case "calendar_events":
            return "Check your Calendar"
        case "reminders_list":
            return "Check your Reminders"
        case "create_reminder":
            return "Add reminder · \(arguments["title"] ?? "")"
        case "create_calendar_event":
            return "Add calendar event · \(arguments["title"] ?? "")"
        case loadToolsName:
            let target = arguments["group"] ?? arguments["names"] ?? arguments["query"] ?? "more"
            return "Load tools · \(target)"
        case "run_ci":
            return "Run CI on GitHub Actions"
        case "finish_task":
            return "Create Pull Request · \(arguments["title"] ?? "Task complete")"
        default:
            if MCPConnector.isConnectorCall(name) {
                return "MCP · \(name.dropFirst(4))"
            }
            return "Execute \(name)"
        }
    }

    /// Compact one-line signature of a tool for model self-correction feedback:
    /// e.g. `read_file(path: string [required], start_line: integer, count: integer)`.
    static func signature(for schema: ToolSchema) -> String {
        guard !schema.parameters.isEmpty else { return "\(schema.name)()" }
        let params = schema.parameters.map { param -> String in
            let typeLabel: String
            switch param.kind {
            case .integer: typeLabel = "integer"
            case .number: typeLabel = "number"
            case .boolean: typeLabel = "boolean"
            case .enumValues(let values): typeLabel = values.joined(separator: "|")
            case .line, .query, .text, .code: typeLabel = "string"
            }
            return "\(param.name): \(typeLabel)\(param.required ? " [required]" : "")"
        }.joined(separator: ", ")
        return "\(schema.name)(\(params))"
    }

    /// Finds the closest valid offered tool name for an unknown or misspelled name.
    public static func suggestToolName(_ attempted: String, offered: [String], deferred: [String] = []) -> (name: String, isDeferred: Bool)? {
        let lower = attempted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        let offeredSet = Set(offered)
        let deferredSet = Set(deferred)

        if let alias = commonAliases[lower] {
            if offeredSet.contains(alias) { return (alias, false) }
            if deferredSet.contains(alias) { return (alias, true) }
        }
        if deferredSet.contains(lower) { return (lower, true) }

        var best: (name: String, distance: Int, isDeferred: Bool)?
        for candidate in offered {
            let d = levenshtein(lower, candidate.lowercased())
            if d <= 2, best == nil || d < best!.distance { best = (candidate, d, false) }
        }
        for candidate in deferred {
            let d = levenshtein(lower, candidate.lowercased())
            if d <= 2, best == nil || d < best!.distance { best = (candidate, d, true) }
        }
        return best.map { ($0.name, $0.isDeferred) }
    }

    /// Builds a concise, actionable error message when a model writes a malformed
    /// or invalid tool call, including exact parameter signatures or alias hints.
    static func correctionMessage(
        for rawOutput: String,
        attemptedTool: String? = nil,
        error: Error,
        offeredSchemas: [ToolSchema],
        deferredNames: [String] = []
    ) -> String {
        var parts = ["Not executed: \(error.localizedDescription)"]
        let toolName = attemptedTool ?? extractAttemptedToolName(from: rawOutput)
        let offeredNames = offeredSchemas.map(\.name)

        if let name = toolName {
            if let schema = offeredSchemas.first(where: { $0.name == name }) {
                parts.append("Expected signature: \(signature(for: schema)).")
            } else if let suggestion = suggestToolName(name, offered: offeredNames, deferred: deferredNames) {
                if suggestion.isDeferred {
                    parts.append("'\(suggestion.name)' is available via \(loadToolsName)(names=\"\(suggestion.name)\").")
                } else if let schema = offeredSchemas.first(where: { $0.name == suggestion.name }) {
                    parts.append("Did you mean \(signature(for: schema))?")
                } else {
                    parts.append("Did you mean '\(suggestion.name)'?")
                }
            } else if !offeredNames.isEmpty {
                parts.append("Available tools: \(offeredNames.joined(separator: ", ")).")
            }
        } else if !offeredNames.isEmpty {
            parts.append("Available tools: \(offeredNames.joined(separator: ", ")).")
        }
        parts.append("Correct the tool format and try again.")
        return parts.joined(separator: " ")
    }

    /// Best-effort extraction of whatever tool name the model attempted in raw output.
    static func extractAttemptedToolName(from output: String) -> String? {
        let patterns = [
            #"<function=([a-zA-Z0-9_.-]+)>"#,
            #"<function\s+name="([a-zA-Z0-9_.-]+)""#,
            #""name"\s*:\s*"([a-zA-Z0-9_.-]+)""#,
            #"<\|tool_call_start\|>\s*\[\s*([a-zA-Z0-9_.-]+)\s*\("#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else { continue }
            return String(output[range])
        }
        return nil
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let lhs = Array(a), rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var row = Array(0...rhs.count)
        for i in 1...lhs.count {
            var prev = row[0]
            row[0] = i
            for j in 1...rhs.count {
                let temp = row[j]
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + cost)
                prev = temp
            }
        }
        return row[rhs.count]
    }
}
