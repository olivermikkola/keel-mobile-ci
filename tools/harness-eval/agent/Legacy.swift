import Foundation

/// The tools and prompts the app had before the task workspace, for
/// comparison runs: one folder per listing, one file per search, no map.
/// The prompt text is read from the app's source so it cannot drift.
enum Legacy {
    static func prompt(root: URL, file: String, marker: String, replacing: [String: String]) throws -> String {
        let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        guard let start = source.range(of: marker),
              let open = source.range(of: "\"\"\"\n", range: start.upperBound..<source.endIndex),
              let close = source.range(of: "\"\"\"", range: open.upperBound..<source.endIndex) else {
            throw NSError(domain: "eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "prompt not found in \(file)"])
        }
        var lines = source[open.upperBound..<close.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        lines = lines.map { String($0.dropFirst(min(indent, $0.count))) }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, value) in replacing { text = text.replacingOccurrences(of: key, with: value) }
        return text
    }

    static func execute(_ call: RepositoryCall, workspace: TaskWorkspace, commit: String) throws -> WorkspaceTools.Output {
        var result: [String: Any] = ["path": call.path, "commit": commit]
        var paths: [String] = []
        var local = false
        switch call.name {
        case "list_files":
            let children = try workspace.list(call.path)
            guard call.offset <= children.count else { throw RepositoryAgentError.range }
            let end = min(children.count, call.offset + call.count)
            result["result_type"] = "directory_listing"
            result["note"] = "Names and types only. No file contents are included. Use read_file for text."
            result["entries"] = children[call.offset..<end].map { ["name": $0.name, "kind": $0.kind.rawValue] }
            result["total"] = children.count
            result["next_offset"] = end < children.count ? end as Any : NSNull()
        case "read_file", "search_file":
            let file = try workspace.read(call.path)
            local = file.isLocal
            paths = [call.path]
            result["content_source"] = local ? "approved_task_changes" : "pinned_repository_blob"
            if local { result["note"] = "Includes changes explicitly applied to this saved task. The commit identifies the original base; GitHub has not been changed." }
            let lines = file.text.components(separatedBy: "\n")
            guard call.offset < lines.count else { throw RepositoryAgentError.range }
            result["total_lines"] = lines.count
            if call.name == "search_file", let query = call.query {
                let needle = Data(query.utf8)
                let matches = lines.enumerated().filter { $0.offset >= call.offset && Data($0.element.utf8).range(of: needle) != nil }
                result["result_type"] = "file_search"
                result["query"] = query
                result["search_start_line"] = call.offset + 1
                result["remaining_matches"] = matches.count
                result["matches"] = matches.prefix(call.count).map { ["line": $0.offset + 1, "content": $0.element] as [String: Any] }
                result["next_start_line"] = matches.count > call.count ? matches[call.count].offset + 1 as Any : NSNull()
            } else {
                result["result_type"] = "file_lines"
                let end = min(lines.count, call.offset + call.count)
                result["start_line"] = call.offset + 1
                result["end_line"] = end
                result["content"] = lines[call.offset..<end].joined(separator: "\n")
            }
        default:
            throw RepositoryAgentError.call
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 6000 else { throw RepositoryAgentError.output }
        return WorkspaceTools.Output(text: String(decoding: data, as: UTF8.self), paths: paths, includesLocalChanges: local)
    }
}
