import Foundation

/// The read tools, answered from the task workspace instead of the network.
/// Results are compact on purpose: every byte of a tool result is prefilled
/// by a small model on a phone before it can think about it.
struct WorkspaceTools {
    struct Output {
        /// The JSON handed to the model.
        let text: String
        /// Files whose text this result shows, for the "files read" evidence line.
        let paths: [String]
        /// True when the result includes a change applied in this task.
        let includesLocalChanges: Bool
    }

    static let resultLimit = 6_000
    let workspace: TaskWorkspace

    func execute(_ call: RepositoryCall) throws -> Output {
        switch call.name {
        case "list_files": return try list(call)
        case "read_file": return try read(call)
        case "search_file", "search_repo": return try search(call)
        default: throw RepositoryAgentError.call
        }
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= WorkspaceTools.resultLimit else { throw RepositoryAgentError.output }
        return String(decoding: data, as: UTF8.self)
    }

    private func list(_ call: RepositoryCall) throws -> Output {
        let children = try workspace.list(call.path)
        guard call.offset <= children.count else { throw RepositoryAgentError.range }
        let end = min(children.count, call.offset + call.count)
        var result: [String: Any] = ["result_type": "directory_listing", "path": call.path.isEmpty ? "." : call.path, "total": children.count]
        // Folders end with "/"; an entry that cannot be read as text says so.
        result["entries"] = children[call.offset..<end].map { child -> String in
            switch child.kind {
            case .directory: return child.name + "/"
            case .file: return child.name
            case .unsupported: return child.name + " (not text)"
            }
        }
        result["next_offset"] = end < children.count ? end as Any : NSNull()
        return Output(text: try encode(result), paths: [], includesLocalChanges: false)
    }

    private func read(_ call: RepositoryCall) throws -> Output {
        let file = try workspace.read(call.path)
        let lines = file.text.components(separatedBy: "\n")
        guard call.offset < lines.count else { throw RepositoryAgentError.range }
        let end = min(lines.count, call.offset + call.count)
        var result: [String: Any] = ["result_type": "file_lines", "path": call.path, "total_lines": lines.count,
                                     "start_line": call.offset + 1, "end_line": end,
                                     "content": lines[call.offset..<end].joined(separator: "\n")]
        if file.isLocal { result["note"] = "Includes changes applied in this task. GitHub has not been changed." }
        return Output(text: try encode(result), paths: [call.path], includesLocalChanges: file.isLocal)
    }

    private func search(_ call: RepositoryCall) throws -> Output {
        guard let query = call.query else { throw RepositoryAgentError.query }
        if !call.path.isEmpty, !workspace.directoryExists(call.path) {
            // A scope that is neither a folder nor a readable file is a mistake to correct, not "no match".
            _ = try workspace.read(call.path)
        }
        var found = try workspace.search(query, under: call.path, limit: call.count, offset: call.offset)
        func line(_ match: WorkspaceSearch.Match) -> String { "\(match.path):\(match.line): \(match.text)" }
        while true {
            var result: [String: Any] = ["result_type": "repository_search", "query": query, "match": found.mode.rawValue,
                                         "matches": found.matches.map(line),
                                         "next_offset": found.nextOffset.map { $0 as Any } ?? NSNull()]
            if !call.path.isEmpty { result["path"] = call.path }
            if !found.related.isEmpty { result["related"] = found.related.map(line) }
            if !found.pathMatches.isEmpty { result["files_named_like_query"] = found.pathMatches }
            if found.pendingFiles > 0 { result["files_not_searched"] = found.pendingFiles }
            switch found.mode {
            case .exact: break
            case .ignoreCase: result["note"] = "No exact match. These lines match when letter case is ignored."
            case .words: result["note"] = "No line contains the whole query. These lines come from the files that best match its words. Read a file before relying on it."
            case .none: result["note"] = "No match in \(found.searchedFiles) text files. Try a shorter or different query."
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            if data.count <= WorkspaceTools.resultLimit {
                let paths = (found.matches + found.related).map(\.path)
                var unique: [String] = []
                for path in paths where !unique.contains(where: { Data($0.utf8) == Data(path.utf8) }) { unique.append(path) }
                return Output(text: String(decoding: data, as: UTF8.self), paths: unique,
                              includesLocalChanges: unique.contains(where: workspace.hasLocalChange(at:)))
            }
            // Too long for the model's context: show fewer lines and say where to continue.
            if !found.related.isEmpty { found.related.removeLast() }
            else if found.matches.count > 1 {
                found.matches.removeLast()
                if found.mode != .words { found.nextOffset = call.offset + found.matches.count }
            } else { throw RepositoryAgentError.output }
        }
    }

    /// A message the model can act on, for failures it can correct itself.
    /// Nil means the failure is not the model's to fix and the turn should stop.
    static func recoverableMessage(_ error: Error) -> String? {
        if let failure = error as? RepositoryAgentError {
            switch failure {
            case .missing, .range, .output:
                return "Read error: \(failure.localizedDescription) No file result was obtained. Use list_files to discover exact names, or choose a smaller valid range."
            default: return nil
            }
        }
        guard let failure = error as? WorkspaceError else { return nil }
        switch failure {
        case .missing: return "Read error: That path does not exist in this task. No file result was obtained. Use list_files or search_repo to find the exact name."
        case .isDirectory: return "Read error: That path is a folder, not a file. Use list_files on it."
        case .notDirectory: return "Read error: That path is a file, not a folder. Use read_file on it."
        case .notText: return "Read error: Only UTF-8 text files up to 256 KB can be read. This entry is binary, too large, a symlink or a submodule. Choose another file."
        case .path: return "Read error: Use a relative path inside the repository, such as Sources/App.swift."
        case .notDownloaded, .tooLarge, .listing: return nil
        }
    }
}
