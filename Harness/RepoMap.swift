import Foundation

/// A compact, deterministic outline of the repository for the system prompt,
/// so a small model can see where things live without spending tool calls on
/// one directory listing after another.
///
/// It lists names only: directories, files and the declarations found in
/// them. It is a table of contents, not evidence. The model still has to read
/// a file before saying anything about its content.
public enum RepoMap {
    private static let typeKeywords: Set<String> = ["class", "struct", "enum", "protocol", "extension", "actor", "interface",
                                                    "trait", "type", "module", "namespace", "object", "record"]
    private static let functionKeywords: Set<String> = ["func", "def", "function", "fn", "fun"]
    private static let modifiers: Set<String> = ["public", "private", "internal", "fileprivate", "open", "final", "static", "export",
                                                 "default", "async", "pub", "abstract", "override", "indirect", "sealed", "data",
                                                 "nonisolated", "mutating", "unsafe", "extern", "inline", "declare", "protected"]
    private static let sourceExtensions: Set<String> = ["swift", "kt", "kts", "java", "cs", "py", "js", "jsx", "ts", "tsx", "mjs",
                                                        "cjs", "rs", "go", "rb", "php", "scala", "dart", "m", "mm", "c", "h", "cc",
                                                        "cpp", "hpp", "lua", "ex", "exs"]
    private static let minorDirectories: Set<String> = ["test", "tests", "spec", "specs", "uitests", "docs", "doc", "example",
                                                        "examples", "vendor", "node_modules", "third_party", "fixtures", "assets",
                                                        "resources", "build", "dist", ".github", "scripts", "ci"]

    /// Up to eight declaration names from one source file, types first.
    /// Types are taken at any shallow indentation; functions only at the top
    /// level, where they are the file's own interface rather than methods.
    public static func symbols(path: String, text: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), sourceExtensions.contains(name[name.index(after: dot)...].lowercased()) else { return "" }
        var types: [String] = []
        var functions: [String] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if types.count + functions.count >= 24 { break }
            var indent = 0
            for character in line {
                if character == " " { indent += 1 } else if character == "\t" { indent += 4 } else { break }
            }
            guard indent <= 4, line.count <= 400 else { continue }
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(8)[...]
            while let first = words.first, first.hasPrefix("@") || modifiers.contains(String(first))
                    || first.hasPrefix("pub(") { words = words.dropFirst() }
            guard let keyword = words.first, let rawName = words.dropFirst().first else { continue }
            let isType = typeKeywords.contains(String(keyword))
            guard isType || (indent == 0 && functionKeywords.contains(String(keyword))) else { continue }
            let identifier = String(rawName.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }))
            guard identifier.count >= 2, identifier.count <= 60, let first = identifier.first, first.isLetter || first == "_",
                  seen.insert(identifier).inserted else { continue }
            if isType { types.append(identifier) } else { functions.append(identifier) }
        }
        return Array((types + functions).prefix(8)).joined(separator: ", ")
    }

    struct FileRow {
        let path: String
        let symbols: String
    }

    /// Renders the map within `maxCharacters`. Detail is added in order of
    /// usefulness: every directory with its file count, then file names for
    /// the main source directories, then declarations, until the budget is used.
    static func render(_ files: [FileRow], maxCharacters: Int) -> String {
        guard !files.isEmpty else { return "Repository map: this workspace has no files yet." }
        struct Directory {
            let path: String
            var files: [FileRow] = []
            var total = 0
            var level = 1
            var depth: Int { path.isEmpty ? 0 : path.split(separator: "/").count }
            var isMinor: Bool {
                path.split(separator: "/").contains {
                    let name = $0.lowercased()
                    return RepoMap.minorDirectories.contains(name) || name.hasSuffix("tests") || name.hasSuffix(".xcassets")
                }
            }
        }
        var directories: [String: Directory] = ["": Directory(path: "")]
        for file in files {
            let parts = file.path.split(separator: "/")
            let parent = parts.dropLast().joined(separator: "/")
            directories[parent, default: Directory(path: parent)].files.append(file)
            var prefix = ""
            directories[""]!.total += 1
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                directories[prefix, default: Directory(path: prefix)].total += 1
            }
        }
        // Too many directories to name: keep the shallowest levels that fit in about forty lines.
        var maxDepth = directories.values.map(\.depth).max() ?? 0
        while maxDepth > 1, directories.values.filter({ $0.depth <= maxDepth }).count > 40 { maxDepth -= 1 }
        // Files of directories too deep to name are listed under their nearest shown ancestor.
        for directory in directories.values where directory.depth > maxDepth {
            let ancestor = directory.path.split(separator: "/").prefix(maxDepth).joined(separator: "/")
            directories[ancestor]!.files.append(contentsOf: directory.files)
        }
        var shown = directories.values.filter { $0.depth <= maxDepth }.sorted { $0.path < $1.path }
        for index in shown.indices { shown[index].files.sort { $0.path < $1.path } }

        func line(_ directory: Directory, level: Int) -> String {
            let label = directory.path.isEmpty ? "(root)" : directory.path + "/"
            if level == 1 { return "\(label) (\(directory.total) file\(directory.total == 1 ? "" : "s"))" }
            let names = directory.files.prefix(40).map { file -> String in
                let name = String(file.path.dropFirst(directory.path.isEmpty ? 0 : directory.path.count + 1))
                guard level == 3, !file.symbols.isEmpty else { return name }
                // A declaration named like its file adds nothing; keep the others.
                let base = name.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
                let extra = file.symbols.components(separatedBy: ", ").filter { $0 != base }.prefix(4)
                return extra.isEmpty ? name : name + " (" + extra.joined(separator: ", ") + ")"
            }
            let more = directory.files.count > 40 ? ", +\(directory.files.count - 40) more" : ""
            return "\(label): " + names.joined(separator: ", ") + more
        }
        // A directory whose files all sit in shown subdirectories needs no line of its own.
        shown.removeAll { $0.files.isEmpty }
        func total() -> Int { shown.reduce(0) { $0 + line($1, level: $1.level).count + 1 } }

        let header = "Repository map (\(files.count) files; names only, read a file before relying on it). Format: folder/: file (declarations in it), …"
        let budget = max(200, maxCharacters - header.count - 1)
        let order = shown.indices.sorted {
            let left = shown[$0], right = shown[$1]
            if left.depth != right.depth { return left.depth < right.depth }
            return left.path < right.path
        }
        // Main source folders get names, then declarations, before tests and docs get anything.
        for minor in [false, true] {
            for level in [2, 3] {
                for index in order where shown[index].isMinor == minor {
                    let previous = shown[index].level
                    shown[index].level = level
                    if total() > budget { shown[index].level = previous }
                }
            }
        }
        var body = shown.map { line($0, level: $0.level) }.joined(separator: "\n")
        if body.count > budget {
            // Even the bare directory list is too long: keep whole lines that fit.
            var kept: [Substring] = []
            var used = 0
            for row in body.split(separator: "\n") {
                guard used + row.count + 1 <= budget - 40 else { break }
                kept.append(row)
                used += row.count + 1
            }
            body = kept.joined(separator: "\n") + "\n(more directories not shown; use list_files)"
        }
        return header + "\n" + body
    }
}

extension TaskWorkspace {
    /// The repository map for the task's current state, within a character
    /// budget (roughly four characters per token).
    public func repoMap(maxCharacters: Int = 2_400) -> String {
        lock.lock(); defer { lock.unlock() }
        var rows: [RepoMap.FileRow] = []
        try? database.query("SELECT path, symbols FROM files ORDER BY path") {
            rows.append(RepoMap.FileRow(path: String(decoding: $0.blob(0), as: UTF8.self), symbols: $0.text(1)))
        }
        return RepoMap.render(rows, maxCharacters: maxCharacters)
    }
}
