import Foundation

/// Result of planning which tool schemas go directly into the system prompt vs
/// stay deferred behind `load_tools` to keep prompts lean and KV-cache stable.
public struct ToolRoutingPlan: Equatable, Sendable {
    /// Full JSON tool schema lines placed in the system prompt's `<tools>` block.
    public let activeToolLines: [String]
    /// Full JSON tool schema lines held back by category (still authorized for this chat).
    public let deferredByGroup: [ToolCategory: [String]]
    /// Every tool line authorized for this chat (active + deferred, excluding `load_tools`).
    public let allAvailableToolLines: [String]
    /// Compact one-line summary of deferred tool groups for the system prompt, or nil if none deferred.
    public let deferredSummary: String?
    /// True when at least one tool was deferred behind `load_tools`.
    public var usesProgressiveDisclosure: Bool { !deferredByGroup.isEmpty }

    /// Names of tools currently deferred.
    public var deferredToolNames: [String] {
        deferredByGroup.values.flatMap { $0 }.map(AgentPrompt.toolName)
    }

    /// Looks up the schema line for any authorized tool in this chat.
    public func schemaLine(named name: String) -> String? {
        allAvailableToolLines.first { AgentPrompt.toolName($0) == name }
    }
}

/// KV-cache-safe progressive tool router and date-context helper.
///
/// Why this works on a phone without busting KV cache:
/// - `plan(...)` runs ONCE at the start of a turn/chat to build a fixed system prompt.
/// - When total available tools fit within the model's comfortable budget, every tool
///   is active upfront with zero indirection.
/// - When tools exceed the budget (e.g., Apple's 4K model with 5-tool ceiling, or a chat
///   with Calendar + GitHub + MCP connectors enabled), only the most relevant tools +
///   `load_tools` go into the system prompt.
/// - If the model needs a deferred group later in the chat, it calls `load_tools`.
///   The system prompt stays byte-identical (100% KV prefix cache preserved), the tool
///   response returns the requested schemas, and the runtime adds those tools to the
///   active grammar/Apple tool set for subsequent steps!
public enum ToolRouter {
    /// Recommended active tool schema cap by runtime and context window.
    /// - Apple on-device (4K context): 5 tools (matches Apple TN3193 guidance).
    /// - <= 8K context models: 10 tools (covers standard local workspace directly).
    /// - 16K–32K local models: 12 tools (covers workspace + 1–2 extensions directly,
    ///   and activates progressive disclosure once larger sets like Calendar + MCP are enabled).
    public static func activeBudget(contextSize: UInt32, isAppleSystemModel: Bool, isSmallModel: Bool = false) -> Int {
        if isAppleSystemModel { return 5 }
        if contextSize <= 8_192 { return 10 }
        return 12
    }

    /// Plans active vs deferred tool schemas for a chat.
    public static func plan(
        availableToolLines: [String],
        initialQuery: String,
        mode: ChatMode,
        budget: Int,
        hasFiles: Bool = true,
        hasLink: Bool = false
    ) -> ToolRoutingPlan {
        // Deduplicate while preserving catalog order.
        var seen = Set<String>()
        let unique = availableToolLines.filter { line in
            let name = AgentPrompt.toolName(line)
            return !name.isEmpty && seen.insert(name).inserted
        }
        let cap = max(2, budget)
        guard unique.count > cap else {
            return ToolRoutingPlan(
                activeToolLines: unique,
                deferredByGroup: [:],
                allAvailableToolLines: unique,
                deferredSummary: nil
            )
        }

        let queryLower = initialQuery.lowercased()
        let queryTokens = tokenize(initialQuery)
        let slots = cap - 1 // Reserve 1 slot for `load_tools`.

        // Score every available tool using query intent, context signals, and category priority.
        var scored: [(line: String, name: String, score: Int, index: Int)] = []
        for (index, line) in unique.enumerated() {
            let name = AgentPrompt.toolName(line)
            let score = relevanceScore(
                toolName: name,
                schemaLine: line,
                queryLower: queryLower,
                queryTokens: queryTokens,
                mode: mode,
                hasFiles: hasFiles,
                hasLink: hasLink
            )
            scored.append((line, name, score, index))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }

        let chosenSet = Set(scored.prefix(slots).map(\.name))
        // Keep chosen tools in their original stable catalog order so prompt prefixes are deterministic.
        let activeLines = unique.filter { chosenSet.contains(AgentPrompt.toolName($0)) } + [ToolRegistry.loadToolsSchemaLine]
        let deferredLines = unique.filter { !chosenSet.contains(AgentPrompt.toolName($0)) }

        var byGroup: [ToolCategory: [String]] = [:]
        for line in deferredLines {
            let category = ToolRegistry.category(for: AgentPrompt.toolName(line))
            byGroup[category, default: []].append(line)
        }

        let summary = buildDeferredSummary(byGroup)
        return ToolRoutingPlan(
            activeToolLines: activeLines,
            deferredByGroup: byGroup,
            allAvailableToolLines: unique,
            deferredSummary: summary
        )
    }

    /// Resolves a `load_tools` call without changing the system prompt.
    /// Returns the newly activated tool names and a concise schema payload for `<tool_response>`.
    public static func resolveLoadTools(
        arguments: [String: String],
        plan: ToolRoutingPlan,
        alreadyActive: Set<String>
    ) -> (newlyActivated: [String], responseText: String) {
        let allowedKeys: Set<String> = ["group", "names", "query"]
        guard Set(arguments.keys).isSubset(of: allowedKeys) else {
            return ([], "Invalid load_tools arguments. Pass group, names, or query.")
        }

        let groupArg = (arguments["group"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namesArg = (arguments["names"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let queryArg = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var matchedLines: [String] = []
        var seen = Set<String>()

        func add(_ line: String) {
            let name = AgentPrompt.toolName(line)
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            matchedLines.append(line)
        }

        // 1. Match by explicit tool names (comma- or space-separated).
        if !namesArg.isEmpty {
            let requested = namesArg
                .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for rawName in requested {
                let resolved = ToolRegistry.commonAliases[rawName.lowercased()] ?? rawName
                if let line = plan.schemaLine(named: resolved) {
                    add(line)
                }
            }
        }

        // 2. Match by group name (or "all").
        if !groupArg.isEmpty {
            if groupArg == "all" {
                for category in ToolCategory.allCases {
                    for line in plan.deferredByGroup[category] ?? [] { add(line) }
                }
            } else if let category = matchCategory(groupArg) {
                for line in plan.deferredByGroup[category] ?? [] { add(line) }
                // Also include any already-active tools in that category if the model asked for the group.
                if matchedLines.isEmpty {
                    for line in plan.allAvailableToolLines where ToolRegistry.category(for: AgentPrompt.toolName(line)) == category {
                        add(line)
                    }
                }
            } else {
                // Allow matching a connector server slug like `group="notion"`.
                for line in plan.deferredByGroup[.connectors] ?? [] {
                    if AgentPrompt.toolName(line).hasPrefix("mcp_\(groupArg)_") { add(line) }
                }
            }
        }

        // 3. Match by free-text query across deferred tools.
        if !queryArg.isEmpty {
            let qTokens = tokenize(queryArg)
            for line in plan.allAvailableToolLines {
                let name = AgentPrompt.toolName(line)
                let haystack = (name + " " + line).lowercased()
                if haystack.contains(queryArg) || qTokens.contains(where: { haystack.contains($0) }) {
                    add(line)
                }
            }
        }

        // If nothing specified at all, list available deferred groups cleanly.
        if groupArg.isEmpty && namesArg.isEmpty && queryArg.isEmpty {
            let groups = ToolCategory.allCases.compactMap { cat -> String? in
                guard let lines = plan.deferredByGroup[cat], !lines.isEmpty else { return nil }
                return "\(cat.rawValue): " + lines.map(AgentPrompt.toolName).joined(separator: ", ")
            }
            if groups.isEmpty {
                return ([], "All available tools for this chat are already loaded.")
            }
            return ([], "Available deferred tool groups:\n" + groups.map { "- \($0)" }.joined(separator: "\n") + "\nCall load_tools with group or names to load their schemas.")
        }

        guard !matchedLines.isEmpty else {
            let availableGroups = ToolCategory.allCases.filter { !(plan.deferredByGroup[$0] ?? []).isEmpty }.map(\.rawValue)
            return ([], "No matching tools found in this chat. Available groups: \(availableGroups.joined(separator: ", ")).")
        }

        // Cap a single load_tools response to 8 schemas so one call cannot flood a small context.
        let bounded = Array(matchedLines.prefix(8))
        let newlyActivated = bounded.map(AgentPrompt.toolName).filter { !alreadyActive.contains($0) }
        var lines = ["Loaded \(bounded.count) tool\(bounded.count == 1 ? "" : "s") (now ready to call):"]
        for line in bounded {
            if let schema = ToolSchema(line) {
                lines.append("- \(ToolRegistry.signature(for: schema)): \(schema.description)")
            } else {
                lines.append("- \(line)")
            }
        }
        return (newlyActivated, lines.joined(separator: "\n"))
    }

    /// Day-level current date string for calendar/reminder grounding.
    /// Deliberately excludes hours/minutes/seconds so the system prompt prefix
    /// stays byte-identical across turns (zero KV-cache invalidation).
    public static func dateContextLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        return "Today is \(formatter.string(from: now)) (\(timeZone.identifier))."
    }

    // MARK: - Scoring Helpers

    private static func relevanceScore(
        toolName: String,
        schemaLine: String,
        queryLower: String,
        queryTokens: Set<String>,
        mode: ChatMode,
        hasFiles: Bool,
        hasLink: Bool
    ) -> Int {
        var score = 0

        // Context-driven baseline scores.
        switch toolName {
        case "read_file", "list_files", "search_repo":
            score += hasFiles ? 6 : 2
        case "propose_edit", "create_file":
            score += mode == .work ? 5 : 0
        case "run_js":
            score += mode == .work ? 4 : 0
        case "run_sql":
            score += (mode == .work && hasFiles) ? 4 : 1
        case "read_url":
            score += hasLink ? 12 : 1
        case "web_search":
            score += 3
        default:
            score += 1
        }

        // Keyword boosts from the initial query.
        let keywords = toolKeywords(for: toolName, schemaLine: schemaLine)
        for keyword in keywords {
            if queryLower.contains(keyword) {
                score += keyword.contains(" ") ? 10 : 7
            }
        }

        // Token overlap with tool name & description.
        let schemaTokens = tokenize(toolName.replacingOccurrences(of: "_", with: " ") + " " + (ToolSchema(schemaLine)?.description ?? ""))
        let overlap = queryTokens.intersection(schemaTokens).count
        score += min(overlap * 3, 12)

        return score
    }

    private static func toolKeywords(for toolName: String, schemaLine: String) -> [String] {
        switch toolName {
        case "search_repo": return ["search", "find", "where", "grep", "locate"]
        case "read_file": return ["read", "file", "show", "open", "readme", "notes", "code"]
        case "list_files": return ["list", "files", "folder", "directory"]
        case "propose_edit": return ["edit", "fix", "change", "update", "replace", "modify", "bug"]
        case "create_file": return ["create", "make", "write", "new", "build", "website", "page", "html", "csv", "markdown", "slides", "flashcards"]
        case "delete_file": return ["delete", "remove", "drop"]
        case "rename_file": return ["rename", "move"]
        case "run_sql": return ["sql", "csv", "table", "sum", "total", "average", "count", "highest", "spreadsheet", "rows", "group"]
        case "run_js": return ["javascript", "js", "script", "calculate", "compute", "math", "transform"]
        case "read_url": return ["http://", "https://", "url", "link", "webpage", "website", "article"]
        case "web_search": return ["search the web", "web", "online", "latest", "news", "look up", "today", "current", "price", "weather"]
        case "github_repos", "github_open": return ["github", "repo", "repository", "branch", "commit", "pull request"]
        case "remember": return ["remember", "don't forget", "preference", "my name", "about me"]
        case "recall": return ["earlier", "previous", "before", "last chat", "past", "remember when"]
        case "generate_image": return ["image", "picture", "draw", "generate", "illustration", "photo", "art", "png"]
        case "run_shortcut": return ["shortcut", "shortcuts", "homekit", "lights", "music", "message"]
        case "calendar_events": return ["calendar", "schedule", "meeting", "events", "today", "tomorrow", "week", "busy", "free"]
        case "reminders_list": return ["reminders", "reminder", "todo", "to-do", "tasks", "checklist"]
        case "create_reminder": return ["remind", "reminder", "add task", "todo", "don't forget"]
        case "create_calendar_event": return ["schedule", "calendar", "event", "meeting", "appointment", "book"]
        default:
            if MCPConnector.isConnectorCall(toolName) {
                return toolName.dropFirst(4).split(separator: "_").map(String.init).filter { $0.count >= 2 }
            }
            return []
        }
    }

    private static func matchCategory(_ raw: String) -> ToolCategory? {
        if let exact = ToolCategory(rawValue: raw) { return exact }
        switch raw {
        case "file", "read", "reading", "workspace": return .files
        case "edits", "write", "writing": return .edit
        case "code", "sql", "js", "javascript", "data": return .compute
        case "internet", "search", "url": return .web
        case "repo", "repos", "git": return .github
        case "reminders", "reminder", "events", "schedule": return .calendar
        case "shortcut": return .shortcuts
        case "image", "images", "picture": return .media
        case "mcp", "connector", "integrations": return .connectors
        default: return nil
        }
    }

    private static func buildDeferredSummary(_ byGroup: [ToolCategory: [String]]) -> String? {
        let parts = ToolCategory.allCases.compactMap { category -> String? in
            guard let lines = byGroup[category], !lines.isEmpty else { return nil }
            let names = lines.map(AgentPrompt.toolName).joined(separator: ", ")
            return "\(category.rawValue) (\(names))"
        }
        guard !parts.isEmpty else { return nil }
        return "More tools are available on demand via load_tools(group or names): \(parts.joined(separator: "; "))."
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count >= 2 })
    }
}
