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

    var label: String { ToolRegistry.label(for: self) }

    /// Small models trained on JSON function calling sometimes wrap `code` or `sql`
    /// inside a single-key JSON object (`{"code": "let x = 1;"}`). Unwrap only when
    /// the entire value is a JSON object with that exact single string key.
    static func unwrapSingleKeyJSON(_ value: String, key: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              object.count == 1, let inner = object[key] as? String else {
            return value
        }
        return inner
    }

    static func parse(_ output: String) throws -> DirectorCall? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("<tool_call") || text.contains("<function=") || text.contains("</tool_call>") else { return nil }
        let pattern = #"\A(?:[^<]*\s*)?<tool_call>\s*<function=([a-z_][a-z0-9_]*)>([\s\S]*?)</function>\s*</tool_call>\s*\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else {
            throw DirectorToolError.invalidCall("Malformed <tool_call> tags.")
        }
        let name = String(text[nameRange])
        guard ToolRegistry.isAllowedToolName(name) else {
            throw DirectorToolError.invalidCall("Unknown tool name: '\(name)'.")
        }

        var remaining = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: String] = [:]
        var raw: [String: String] = [:]
        let parameterRegex = try NSRegularExpression(pattern: #"\A<parameter=([a-z_][a-z0-9_]*)>([\s\S]*?)</parameter>"#)
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
            if ["sql", "code"].contains(key), ["<parameter=", "<function=", "<tool_call"].contains(where: { rawValue.contains($0) }) {
                throw DirectorToolError.invalidCall("Nested tool tag inside \(key) parameter.")
            }
            let unescaped = ToolRegistry.decodeXMLEntities(rawValue)
            if ["old_text", "new_text"].contains(key) {
                // The call template puts every value on its own line, and models
                // copy it: one line break after the opening tag and one before
                // the closing tag are format, not part of the edit.
                args[key] = RepositoryCall.unwrapLine(unescaped)
                raw[key] = RepositoryCall.unwrapLine(rawValue)
            } else if ["sql", "code"].contains(key) {
                args[key] = Self.unwrapSingleKeyJSON(RepositoryCall.unwrapLine(unescaped), key: key)
            } else if MCPConnector.isConnectorCall(name) {
                args[key] = RepositoryCall.unwrapLine(unescaped)
            } else if ["path", "destination_path"].contains(key) {
                // Paths keep exact bytes (a file literally named `a&lt;b` stays exact);
                // NativeToolCall.canonicalCall leaves path unescaped.
                args[key] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if key == "query" {
                args[key] = unescaped
            } else {
                // All other text arguments (url, fact, prompt, title, notes, location,
                // shortcut name/input, repository, load_tools group/names) decode XML entities.
                args[key] = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Converts a parsed `DirectorCall` into a validated `RepositoryCall` for read-only
    /// repository chats (reads, `run_sql`, `run_js`).
    func repositoryCall() throws -> RepositoryCall {
        if name == "run_sql" {
            guard Set(arguments.keys) == ["sql"], let rawSQL = arguments["sql"] else { throw RepositoryAgentError.call }
            let sql = DirectorCall.unwrapSingleKeyJSON(rawSQL, key: "sql")
            guard sql.utf8.count <= 64 * 1024, !sql.utf8.contains(0) else { throw RepositoryAgentError.call }
            return RepositoryCall(name: name, path: "", offset: 0, count: 0, query: nil, sql: sql)
        }
        if name == "run_js" {
            guard Set(arguments.keys) == ["code"], let rawCode = arguments["code"] else { throw RepositoryAgentError.call }
            let code = DirectorCall.unwrapSingleKeyJSON(rawCode, key: "code")
            guard code.utf8.count <= 64 * 1024, !code.utf8.contains(0) else { throw RepositoryAgentError.call }
            return RepositoryCall(name: name, path: "", offset: 0, count: 0, query: nil, code: code)
        }
        return try readCall()
    }
}
