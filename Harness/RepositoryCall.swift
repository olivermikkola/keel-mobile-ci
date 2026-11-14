import Foundation

// The catalog's pinned GGUF uses Qwen XML calls. Only these read tools
// exist here; an unknown name, extra argument or incomplete call never runs.
struct RepositoryCall: Equatable {
    let name: String
    let path: String
    let offset: Int
    let count: Int
    let query: String?
    var sql: String? = nil
    var code: String? = nil
    var label: String {
        if name == "list_files" { return "List \(path.isEmpty ? "/" : path)" }
        if name == "search_file" { return "Search \(path) · \(query ?? "")" }
        if name == "search_repo" { return "Search \(path.isEmpty ? "repository" : path) · \(query ?? "")" }
        if name == "run_sql" { return "Run SQL" }
        if name == "run_js" { return "Run JavaScript" }
        return "Read \(path) · lines \(offset + 1)–\(offset + count)"
    }

    /// The call template shows every value on its own line, and small models
    /// copy it. A query can never contain a line break, so one line break
    /// directly after the opening tag and one before the closing tag are
    /// format, not content. Spaces stay significant.
    static func unwrapLine(_ value: String) -> String {
        var text = Substring(value)
        if text.first == "\n" || text.first == "\r\n" { text = text.dropFirst() }
        if text.last == "\n" || text.last == "\r\n" { text = text.dropLast() }
        return String(text)
    }

    static func parse(_ output: String) throws -> RepositoryCall? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("<tool_call") || text.contains("<function=") || text.contains("</tool_call>") else { return nil }
        let pattern = #"\A(?:[^<]*\s*)?<tool_call>\s*<function=([a-z_]+)>([\s\S]*?)</function>\s*</tool_call>\s*\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text), let bodyRange = Range(match.range(at: 2), in: text) else {
            throw RepositoryAgentError.call
        }
        let name = String(text[nameRange])
        guard ["list_files", "read_file", "search_file", "search_repo", "run_sql", "run_js"].contains(name) else { throw RepositoryAgentError.call }
        var remaining = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: String] = [:]
        let parameter = try NSRegularExpression(pattern: #"\A<parameter=([a-z_]+)>([\s\S]*?)</parameter>"#)
        while !remaining.isEmpty {
            guard let part = parameter.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)),
                  let keyRange = Range(part.range(at: 1), in: remaining),
                  let valueRange = Range(part.range(at: 2), in: remaining),
                  let whole = Range(part.range, in: remaining) else { throw RepositoryAgentError.call }
            let key = String(remaining[keyRange])
            guard args[key] == nil else { throw RepositoryAgentError.call }
            let rawValue = String(remaining[valueRange])
            // Code and SQL are full of '<', and small models do not escape it.
            // Query, sql, and code arguments may carry a raw '<' as long as it
            // cannot be read as protocol; every other argument stays free of it.
            if ["query", "sql", "code"].contains(key) {
                guard !["<parameter=", "<function=", "<tool_call"].contains(where: { rawValue.contains($0) }) else { throw RepositoryAgentError.call }
            } else {
                guard !rawValue.contains("<") else { throw RepositoryAgentError.call }
            }
            // Preserve exact whitespace. Query, sql, and code support XML
            // entities so '<' and '&' work without nested protocol tags.
            // Decode ampersand last.
            args[key] = ["query", "sql", "code"].contains(key) ? unwrapLine(rawValue).replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&") : rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[whole.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "run_sql" {
            guard Set(args.keys) == ["sql"], let sql = args["sql"],
                  sql.utf8.count <= 64 * 1024, !sql.utf8.contains(0) else { throw RepositoryAgentError.call }
            return RepositoryCall(name: name, path: "", offset: 0, count: 0, query: nil, sql: sql)
        }
        if name == "run_js" {
            guard Set(args.keys) == ["code"], let code = args["code"],
                  code.utf8.count <= 64 * 1024, !code.utf8.contains(0) else { throw RepositoryAgentError.call }
            return RepositoryCall(name: name, path: "", offset: 0, count: 0, query: nil, code: code)
        }
        let allowed: [String]
        switch name {
        case "list_files": allowed = ["path", "offset", "count"]
        case "search_file": allowed = ["path", "query", "start_line", "count"]
        case "search_repo": allowed = ["query", "path", "offset", "count"]
        default: allowed = ["path", "start_line", "count"]
        }
        // Only a repository-wide search may leave the path out.
        guard Set(args.keys).isSubset(of: Set(allowed)),
              var rawPath = args["path"] ?? (name == "search_repo" ? "" : nil) else { throw RepositoryAgentError.call }
        // The repository map writes folders as "Sources/", and models copy that.
        if rawPath.utf8.count > 1, rawPath.hasSuffix("/"), !rawPath.hasSuffix("//") { rawPath.removeLast() }
        let path = rawPath == "." ? "" : rawPath
        let components = gitPathComponents(path)
        guard path.utf8.count <= 1024, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.isEmpty || (components.count <= 16 && components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })) else {
            throw RepositoryAgentError.path
        }
        func number(_ key: String, default value: Int, minimum: Int, maximum: Int) throws -> Int {
            guard let input = args[key] else { return value }
            guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(input), (minimum...maximum).contains(parsed) else {
                throw RepositoryArgumentError(name: key, minimum: minimum, maximum: maximum)
            }
            return parsed
        }
        let count = name == "search_repo" ? try number("count", default: 20, minimum: 1, maximum: 40)
            : try number("count", default: 30, minimum: 1, maximum: 60)
        let offset: Int
        if name == "list_files" || name == "search_repo" { offset = try number("offset", default: 0, minimum: 0, maximum: 100_000) }
        else { offset = try number("start_line", default: 1, minimum: 1, maximum: 262_145) - 1 }
        guard name == "list_files" || name == "search_repo" || !path.isEmpty else { throw RepositoryAgentError.path }
        let query = args["query"]
        if name == "search_file" || name == "search_repo" {
            guard let query, !query.isEmpty, query.utf8.count <= 256,
                  !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RepositoryAgentError.query
            }
        }
        return RepositoryCall(name: name, path: path, offset: offset, count: count, query: query)
    }
}

struct RepositoryArgumentError: LocalizedError {
    let name: String
    let minimum: Int
    let maximum: Int
    var errorDescription: String? {
        "The \(name) argument must be a whole number from \(minimum) to \(maximum). No repository request was executed. Correct the argument and try again."
    }
}

enum RepositoryAgentError: LocalizedError {
    case call, path, query, missing, range, output, steps, binding, storage, saving
    var errorDescription: String? {
        switch self {
        case .call: return "The model requested an invalid or unsupported tool. No action was taken. Send a follow-up to try again."
        case .path: return "Repository tools require a relative path within the selected snapshot."
        case .query: return "File search needs literal text from 1 to 256 UTF-8 bytes, without line breaks or control characters."
        case .missing: return "That path does not exist in the selected snapshot."
        case .range: return "That range is outside this file or directory."
        case .output: return "This tool result is too large for model context. Request a smaller count."
        case .steps: return "The agent reached its eight-tool limit. Send a follow-up to continue."
        case .binding: return "Start a new chat before choosing a different repository version."
        case .storage: return "Saved tasks could not be opened. Open Saved tasks to reset safely. The original file is kept."
        case .saving: return "The conversation could not be saved on this device. The agent stopped; check available storage and try again."
        }
    }
}

