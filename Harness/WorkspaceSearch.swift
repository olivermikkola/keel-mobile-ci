import Foundation

/// What a repository-wide search found, and how it had to look to find it.
public struct WorkspaceSearch: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// The query's exact bytes occur on these lines.
        case exact
        /// No exact match; these lines match ignoring ASCII letter case.
        case ignoreCase = "ignore_case"
        /// No line contains the query; these files rank highest for its words.
        case words
        /// Nothing matched in any mode.
        case none
    }

    public struct Match: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let text: String
    }

    public var mode: Mode
    public var matches: [Match]
    /// When a several-word query matched literally on fewer than three lines:
    /// lines from the files that rank highest for the query's words.
    public var related: [Match] = []
    /// Files whose path contains the query, most direct first.
    public var pathMatches: [String]
    /// Pass as `offset` to continue. Nil when there is nothing more.
    public var nextOffset: Int?
    /// Text files covered by this search, and listed text files it could not
    /// cover because their bytes are not downloaded.
    public var searchedFiles: Int
    public var pendingFiles: Int
}

enum WorkspaceWords {
    static let stopwords: Set<String> = ["the", "a", "an", "is", "are", "was", "be", "to", "of", "in", "on", "at", "for", "and", "or",
                                         "it", "this", "that", "with", "from", "by", "as", "do", "does", "how", "what", "where",
                                         "which", "who", "when", "why", "can", "i", "me", "my", "there", "show", "find", "please"]

    /// Splits `prefixCache` and `HTTPTransfer` into their parts.
    static func parts(of identifier: Substring) -> [Substring] {
        var result: [Substring] = []
        var start = identifier.startIndex
        var previous: Character?
        var index = identifier.startIndex
        while index < identifier.endIndex {
            let character = identifier[index]
            if let last = previous, index > start {
                let next = identifier.index(after: index)
                let lowerToUpper = last.isLowercase && character.isUppercase
                let acronymEnd = last.isUppercase && character.isUppercase && next < identifier.endIndex && identifier[next].isLowercase
                let digitEdge = last.isNumber != character.isNumber
                if lowerToUpper || acronymEnd || digitEdge {
                    result.append(identifier[start..<index])
                    start = index
                }
            }
            previous = character
            index = identifier.index(after: index)
        }
        if result.isEmpty { return [] }
        result.append(identifier[start...])
        return result
    }

    /// Text for the word index: the original text, then the parts of every
    /// camelCase identifier, so `cache` finds `prefixCache`. Deterministic,
    /// because a contentless index is updated by repeating this exact text.
    static func terms(_ text: String) -> String {
        var extra: [Substring] = []
        var seen = Set<Substring>()
        for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) where word.count >= 4 && word.count <= 64 {
            guard word.contains(where: { $0.isUppercase }), !seen.contains(word) else { continue }
            seen.insert(word)
            extra.append(contentsOf: parts(of: word).filter { $0.count >= 2 })
            if extra.count > 4_000 { break }
        }
        return extra.isEmpty ? text : text + "\n" + extra.joined(separator: " ")
    }

    /// Lowercased search words from a free-text query.
    static func queryWords(_ query: String) -> [String] {
        var words: [String] = []
        for word in query.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let pieces = [word] + parts(of: word)
            for piece in pieces {
                let lower = piece.lowercased()
                guard lower.count >= 2, !stopwords.contains(lower), !words.contains(lower) else { continue }
                words.append(lower)
            }
        }
        return Array(words.prefix(12))
    }
}

extension TaskWorkspace {
    /// Searches every stored text file in the task's current state.
    ///
    /// It tries the strictest reading of the query first and says which one
    /// produced the result: exact bytes, then ignoring ASCII case, then files
    /// ranked by the query's words. `under` limits the search to one file or
    /// one directory. Long lines are cut at `maxLineBytes` and marked with `…`.
    public func search(_ query: String, under: String = "", limit: Int = 20, offset: Int = 0,
                       maxLineBytes: Int = 240) throws -> WorkspaceSearch {
        lock.lock(); defer { lock.unlock() }
        guard under.isEmpty || TaskWorkspace.validPath(under) else { throw WorkspaceError.path }
        var filter = ""
        var filterValues: [SQLiteValue] = []
        if !under.isEmpty {
            let range = scope(under)
            filter = " AND (path = ? OR (path >= ? AND path < ?))"
            filterValues = [.blob(Data(under.utf8)), .blob(range.lower), .blob(range.upper)]
        }
        func count(_ kind: Kind) -> Int {
            if case .integer(let value)? = try? database.scalar("SELECT count(*) FROM files WHERE kind = \(kind.rawValue)" + filter, filterValues) {
                return Int(value)
            }
            return 0
        }
        var result = WorkspaceSearch(mode: .none, matches: [], pathMatches: [], nextOffset: nil,
                                     searchedFiles: count(.text), pendingFiles: count(.pending))
        let needle = Array(query.utf8)
        guard !needle.isEmpty else { return result }

        if offset == 0 {
            try database.query("SELECT path FROM files WHERE instr(lower(CAST(path AS TEXT)), lower(?)) > 0" + filter
                               + " ORDER BY length(path), path LIMIT 8", [.text(query)] + filterValues) {
                result.pathMatches.append(String(decoding: $0.blob(0), as: UTF8.self))
            }
        }

        func lines(sql: String, values: [SQLiteValue], matches: ([UInt8]) -> Bool) throws -> Bool {
            var found: [WorkspaceSearch.Match] = []
            var skipped = 0
            let statement = try database.prepare(sql)
            try statement.bind(values)
            scan: while try statement.step() {
                let path = String(decoding: statement.blob(0), as: UTF8.self)
                let content = statement.blob(1)
                var number = 0
                for line in content.split(separator: 10, omittingEmptySubsequences: false) {
                    number += 1
                    var bytes = Array(line)
                    guard matches(bytes) else { continue }
                    if skipped < offset { skipped += 1; continue }
                    if found.count == limit {
                        result.nextOffset = offset + limit
                        break scan
                    }
                    if bytes.last == 13 { bytes.removeLast() }
                    found.append(WorkspaceSearch.Match(path: path, line: number, text: TaskWorkspace.clip(bytes, to: maxLineBytes)))
                }
            }
            result.matches = found
            return !found.isEmpty || skipped > 0
        }

        let words = WorkspaceWords.queryWords(query)
        /// Lines from the files ranking highest for the query's words.
        func ranked(excluding: [WorkspaceSearch.Match], room: Int) throws -> [WorkspaceSearch.Match] {
            guard hasWordIndex, !words.isEmpty, offset == 0, room > 0 else { return [] }
            let expression = words.map { "\"\($0)\"" + ($0.count >= 3 ? "*" : "") }.joined(separator: " OR ")
            var files: [(path: String, content: Data)] = []
            try database.query("SELECT f.path, f.content FROM words JOIN files f ON f.id = words.rowid WHERE words MATCH ? AND f.kind = 0"
                               + filter.replacingOccurrences(of: "path", with: "f.path")
                               + " ORDER BY bm25(words, 4.0, 1.0) LIMIT 6", [.text(expression)] + filterValues) {
                files.append((String(decoding: $0.blob(0), as: UTF8.self), $0.blob(1)))
            }
            let wordBytes = words.map { Array($0.utf8) }
            var found: [WorkspaceSearch.Match] = []
            for file in files {
                var best: [(score: Int, line: Int, bytes: [UInt8])] = []
                var number = 0
                for line in file.content.split(separator: 10, omittingEmptySubsequences: false) {
                    number += 1
                    if excluding.contains(where: { $0.line == number && Data($0.path.utf8) == Data(file.path.utf8) }) { continue }
                    let lower = line.map(TaskWorkspace.lower)
                    let score = wordBytes.reduce(0) { $0 + (TaskWorkspace.contains(lower, $1) ? 1 : 0) }
                    if score > 0 { best.append((score, number, Array(line))) }
                }
                let chosen = best.sorted { $0.score != $1.score ? $0.score > $1.score : $0.line < $1.line }.prefix(3).sorted { $0.line < $1.line }
                for item in chosen where found.count < room {
                    var bytes = item.bytes
                    if bytes.last == 13 { bytes.removeLast() }
                    found.append(WorkspaceSearch.Match(path: file.path, line: item.line, text: TaskWorkspace.clip(bytes, to: maxLineBytes)))
                }
                // The file ranked for its name alone: report the path.
                if chosen.isEmpty, result.pathMatches.count < 8, !result.pathMatches.contains(where: { Data($0.utf8) == Data(file.path.utf8) }) {
                    result.pathMatches.append(file.path)
                }
            }
            return found
        }
        func literal(_ mode: WorkspaceSearch.Mode) throws -> WorkspaceSearch {
            result.mode = mode
            if result.matches.count < 3, words.count >= 2, result.nextOffset == nil {
                result.related = try ranked(excluding: result.matches, room: min(6, limit - result.matches.count))
            }
            return result
        }

        if try lines(sql: "SELECT path, content FROM files WHERE kind = 0 AND instr(content, ?) > 0" + filter + " ORDER BY path",
                     values: [.blob(Data(needle))] + filterValues, matches: { TaskWorkspace.contains($0, needle) }) {
            return try literal(.exact)
        }
        let lowered = needle.map(TaskWorkspace.lower)
        if try lines(sql: "SELECT path, content FROM files WHERE kind = 0 AND instr(lower(CAST(content AS TEXT)), lower(?)) > 0" + filter + " ORDER BY path",
                     values: [.text(query)] + filterValues,
                     matches: { TaskWorkspace.contains($0.map(TaskWorkspace.lower), lowered) }) {
            return try literal(.ignoreCase)
        }
        result.matches = try ranked(excluding: [], room: limit)
        if !result.matches.isEmpty || !result.pathMatches.isEmpty { result.mode = .words }
        return result
    }

    static func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        let last = haystack.count - needle.count
        var index = 0
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < needle.count, haystack[index + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }

    /// Cuts on a UTF-8 character boundary and marks the cut.
    static func clip(_ bytes: [UInt8], to limit: Int) -> String {
        guard bytes.count > limit else { return String(decoding: bytes, as: UTF8.self) }
        var end = limit
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: bytes[0..<end], as: UTF8.self) + "…"
    }
}
