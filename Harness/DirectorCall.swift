import Foundation

// Director output requests reads or proposes data. It never authorizes applying
// a file change, pushing a branch, dispatching CI or opening a pull request.

enum DirectorToolError: LocalizedError, Equatable {
    case invalidCall(String)
    case approvalRequired
    var errorDescription: String? {
        switch self {
        case .invalidCall(let reason): return "Invalid tool call: \(reason)"
        case .approvalRequired: return "Not executed. Review and apply proposed changes in the UI. Publishing and CI need a separate UI decision; a model tool call cannot authorize them."
        }
    }
}

struct DirectorCall: Equatable {
    let name: String
    let arguments: [String: String]
    /// The text arguments exactly as the model wrote them, before entity
    /// decoding, for the rare file that contains a literal `&lt;` or `&amp;`.
    var rawArguments: [String: String] = [:]

    var label: String {
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
            let count = arguments["count"] ?? "30"
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
        case "run_ci":
            return "Run CI on GitHub Actions"
        case "finish_task":
            return "Create Pull Request · \(arguments["title"] ?? "Task complete")"
        default:
            return "Execute \(name)"
        }
    }

    static func parse(_ output: String) throws -> DirectorCall? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("<tool_call") || text.contains("<function=") || text.contains("</tool_call>") else { return nil }
        let pattern = #"\A(?:[^<]*\s*)?<tool_call>\s*<function=([a-z_]+)>([\s\S]*?)</function>\s*</tool_call>\s*\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else {
            throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
        }
        let name = String(text[nameRange])
        let allowedTools = ["list_files", "search_file", "search_repo", "read_file", "run_sql",
                            "propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file",
                            "run_ci", "finish_task"]
        guard allowedTools.contains(name) else {
            throw DirectorToolError.invalidCall("Unknown tool name: '\(name)'.")
        }

        var remaining = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: String] = [:]
        var raw: [String: String] = [:]
        let parameterRegex = try NSRegularExpression(pattern: #"\A<parameter=([a-z_]+)>([\s\S]*?)</parameter>"#)
        while !remaining.isEmpty {
            guard let part = parameterRegex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)),
                  let keyRange = Range(part.range(at: 1), in: remaining),
                  let valRange = Range(part.range(at: 2), in: remaining),
                  let wholeRange = Range(part.range, in: remaining) else {
                throw DirectorToolError.invalidCall("Malformed <parameter> tag inside \(name).")
            }
            let key = String(remaining[keyRange])
            guard args[key] == nil else { throw DirectorToolError.invalidCall("Duplicate argument: \(key).") }
            let rawValue = String(remaining[valRange])
            if key == "sql", ["<parameter=", "<function=", "<tool_call"].contains(where: { rawValue.contains($0) }) {
                throw DirectorToolError.invalidCall("Nested tool tag inside sql parameter.")
            }
            let unescaped = rawValue.replacingOccurrences(of: "&lt;", with: "<")
                                    .replacingOccurrences(of: "&gt;", with: ">")
                                    .replacingOccurrences(of: "&amp;", with: "&")
            if ["old_text", "new_text"].contains(key) {
                // The call template puts every value on its own line, and models
                // copy it: one line break after the opening tag and one before
                // the closing tag are format, not part of the edit.
                args[key] = RepositoryCall.unwrapLine(unescaped)
                raw[key] = RepositoryCall.unwrapLine(rawValue)
            } else if key == "sql" {
                args[key] = RepositoryCall.unwrapLine(unescaped)
            } else {
                args[key] = key == "query" ? unescaped : rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            remaining = String(remaining[wholeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return DirectorCall(name: name, arguments: args, rawArguments: raw)
    }
}


extension DirectorCall {
    /// The same request as a strict read call. Reads have one contract: the
    /// read parser's paths, numbers and limits apply to Director too.
    func readCall() throws -> RepositoryCall {
        let body = arguments.keys.sorted().map { key -> String in
            let raw = arguments[key]!
            let value = key == "query" ? raw.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") : raw
            return "<parameter=\(key)>\(value)</parameter>"
        }.joined()
        guard let call = try RepositoryCall.parse("<tool_call><function=\(name)>\(body)</function></tool_call>") else {
            throw DirectorToolError.invalidCall("Expected a repository read.")
        }
        return call
    }
}
