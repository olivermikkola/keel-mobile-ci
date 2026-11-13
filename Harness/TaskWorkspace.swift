import Foundation

public enum WorkspaceError: Error, Equatable {
    /// Not a relative path inside the workspace.
    case path
    /// No file or directory has this path in the task's current state.
    case missing
    /// The path names a directory where a file was needed, or the reverse.
    case isDirectory, notDirectory
    /// Binary, larger than the file limit, a symlink or a submodule.
    case notText
    /// A text file the pinned tree lists, whose bytes are not stored yet.
    case notDownloaded
    /// More files or bytes than the workspace accepts.
    case tooLarge
    /// The tree listing is malformed.
    case listing
}

/// The task's "virtual disk": one SQLite database holding a pinned repository
/// snapshot plus the changes the user applied in this task.
///
/// Paths are database keys compared byte for byte. They are never turned into
/// filesystem paths, so there is nothing to traverse out of, no symlink to
/// follow, and two names that differ only in case or Unicode form stay two
/// files, which a real folder on the phone's disk could not guarantee.
///
/// Base content is stored only after its Git blob hash matches the pinned
/// tree. The overlay is derived state: it is rebuilt from the applied edits
/// whenever their key changes, so the saved task remains the authority.
public final class TaskWorkspace: @unchecked Sendable {
    public struct Identity: Equatable, Sendable {
        public let repository: String
        public let commit: String
        public let tree: String
        public init(repository: String, commit: String, tree: String) {
            self.repository = repository
            self.commit = commit
            self.tree = tree
        }
    }

    /// One row of a recursive Git tree listing.
    public struct TreeEntry: Sendable {
        public let path: String
        public let mode: String
        public let type: String
        public let sha: String
        public let size: Int?
        public init(path: String, mode: String, type: String, sha: String, size: Int?) {
            self.path = path
            self.mode = mode
            self.type = type
            self.sha = sha
            self.size = size
        }
    }

    public struct Limits: Equatable, Sendable {
        public var maxFiles = 20_000
        /// Same bound as the app's verified blob reads.
        public var maxFileBytes = 262_144
        public var maxTextBytes = 64 * 1_048_576
        public var maxArchiveEntries = 100_000
        public var maxArchiveBytes = 1_024 * 1_048_576
        public init() {}
    }

    public enum ChildKind: String, Sendable { case directory, file, unsupported }
    public struct Child: Equatable, Sendable {
        public let name: String
        public let kind: ChildKind
    }

    public struct File: Equatable, Sendable {
        public let text: String
        public let sha: String
        /// True when the content comes from a change applied in this task.
        public let isLocal: Bool
    }

    public enum Operation: Sendable {
        case write(path: String, text: String)
        case delete(path: String)
    }

    public struct ImportReport: Equatable, Sendable {
        /// Files whose bytes matched the pinned tree and are now stored.
        public var stored = 0
        /// Verified files that are not UTF-8 text.
        public var binary = 0
        /// Archive files whose size or hash disagrees with the tree. Never stored.
        public var mismatched = 0
        /// Archive files the tree does not list as text. Ignored.
        public var skipped = 0
    }

    public struct Counts: Equatable, Sendable {
        public var text = 0
        public var unsupported = 0
        public var pending = 0
        public var local = 0
        public var files: Int { text + unsupported + pending }
    }

    enum Kind: Int { case text = 0, unsupported = 1, pending = 2 }

    public let limits: Limits
    let database: SQLiteDatabase
    let lock = NSRecursiveLock()
    private(set) var hasWordIndex = false

    /// Opens or creates the workspace database. Use `:memory:` in tests.
    public init(path: String, limits: Limits = Limits()) throws {
        self.limits = limits
        database = try SQLiteDatabase(path: path)
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                path BLOB NOT NULL UNIQUE,
                kind INTEGER NOT NULL,
                mode TEXT NOT NULL,
                sha TEXT NOT NULL,
                size INTEGER NOT NULL,
                origin INTEGER NOT NULL DEFAULT 0,
                content BLOB,
                symbols TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS shadow(
                path BLOB PRIMARY KEY,
                kind INTEGER NOT NULL,
                mode TEXT NOT NULL,
                sha TEXT NOT NULL,
                size INTEGER NOT NULL,
                content BLOB,
                symbols TEXT NOT NULL
            ) WITHOUT ROWID;
            """)
        // The word index is an optimisation. A SQLite without FTS5 still
        // gives exact search; ranked word search is then reported as absent.
        do {
            try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(path, body, content='', tokenize='unicode61')")
            hasWordIndex = true
        } catch {
            hasWordIndex = false
        }
    }

    // MARK: - Identity and state

    func meta(_ key: String) -> String? {
        if case .text(let value)? = try? database.scalar("SELECT value FROM meta WHERE key = ?", [.text(key)]) { return value }
        return nil
    }

    func exists(_ sql: String, _ values: [SQLiteValue] = []) -> Bool {
        ((try? database.scalar(sql, values)) ?? nil) != nil
    }

    func setMeta(_ key: String, _ value: String) throws {
        try database.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                         [.text(key), .text(value)])
    }

    /// The snapshot this workspace was listed from, or nil when it is empty.
    public var identity: Identity? {
        lock.lock(); defer { lock.unlock() }
        guard let repository = meta("repository"), let commit = meta("commit"), let tree = meta("tree") else { return nil }
        return Identity(repository: repository, commit: commit, tree: tree)
    }

    /// The key of the applied-edit overlay currently reflected in the files.
    public var overlayKey: String {
        lock.lock(); defer { lock.unlock() }
        return meta("overlay") ?? ""
    }

    public var counts: Counts {
        lock.lock(); defer { lock.unlock() }
        var result = Counts()
        try? database.query("SELECT kind, origin, count(*) FROM files GROUP BY kind, origin") { row in
            let count = row.int(2)
            switch Kind(rawValue: row.int(0)) {
            case .text?: result.text += count
            case .unsupported?: result.unsupported += count
            default: result.pending += count
            }
            if row.int(1) == 1 { result.local += count }
        }
        return result
    }

    /// True when every text file the tree lists is stored and verified, so
    /// search and the repository map cover the whole snapshot.
    public var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        guard meta("commit") != nil else { return false }
        return !exists("SELECT 1 FROM files WHERE kind = 2 LIMIT 1") && !exists("SELECT 1 FROM shadow WHERE kind = 2 LIMIT 1")
    }

    // MARK: - Base snapshot

    static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return path.utf8.split(separator: 47, omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !($0.count == 1 && $0.first == 46) && !($0.count == 2 && $0.allSatisfy { $0 == 46 })
        }
    }

    /// Replaces everything with the listing of one pinned tree. Text
    /// candidates start as pending; their bytes arrive through
    /// `importArchive` or `store` and are verified against `sha`.
    public func setBase(_ identity: Identity, entries: [TreeEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        let blobs = entries.filter { $0.type != "tree" }
        guard blobs.count <= limits.maxFiles else { throw WorkspaceError.tooLarge }
        guard Set(blobs.map { Data($0.path.utf8) }).count == blobs.count,
              blobs.allSatisfy({ TaskWorkspace.validPath($0.path) && GitBlob.isSHA($0.sha) }) else { throw WorkspaceError.listing }
        try database.transaction {
            try database.execute("DELETE FROM files; DELETE FROM shadow; DELETE FROM meta;")
            if hasWordIndex { try database.execute("INSERT INTO words(words) VALUES('delete-all')") }
            let insert = try database.prepare("INSERT INTO files(path, kind, mode, sha, size, origin) VALUES(?, ?, ?, ?, ?, 0)")
            for entry in blobs {
                let text = entry.type == "blob" && ["100644", "100755"].contains(entry.mode)
                    && (entry.size ?? Int.max) <= limits.maxFileBytes
                try insert.bind([.blob(Data(entry.path.utf8)), .integer(Int64(text ? Kind.pending.rawValue : Kind.unsupported.rawValue)),
                                 .text(entry.mode), .text(entry.sha), .integer(Int64(entry.size ?? 0))])
                _ = try insert.step()
            }
            try setMeta("repository", identity.repository)
            try setMeta("commit", identity.commit)
            try setMeta("tree", identity.tree)
            try setMeta("overlay", "")
        }
    }

    /// Text files the tree lists whose bytes are not stored yet.
    public func pendingFiles(limit: Int = 100) -> [(path: String, sha: String, size: Int)] {
        lock.lock(); defer { lock.unlock() }
        var result: [(String, String, Int)] = []
        try? database.query("SELECT path, sha, size FROM files WHERE kind = 2 ORDER BY path LIMIT ?", [.integer(Int64(limit))]) { row in
            result.append((String(decoding: row.blob(0), as: UTF8.self), row.text(1), row.int(2)))
        }
        return result
    }

    /// Stores one base file's bytes if, and only if, they hash to the SHA the
    /// pinned tree lists for `path`. Returns false when they do not.
    @discardableResult
    public func store(path: String, data: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try database.transaction { try storeVerified(Data(path.utf8), data) == .stored }
    }

    enum StoreOutcome { case stored, binary, mismatched, skipped }

    func storeVerified(_ path: Data, _ data: Data) throws -> StoreOutcome {
        var row: (id: Int, kind: Int, sha: String, size: Int)?
        try database.query("SELECT id, kind, sha, size FROM files WHERE path = ? AND origin = 0", [.blob(path)]) {
            row = ($0.int(0), $0.int(1), $0.text(2), $0.int(3))
        }
        guard let row, row.kind == Kind.pending.rawValue else { return .skipped }
        guard data.count == row.size, GitBlob.sha(data) == row.sha else { return .mismatched }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            try database.run("UPDATE files SET kind = 1 WHERE id = ?", [.integer(Int64(row.id))])
            return .binary
        }
        let name = String(decoding: path, as: UTF8.self)
        try database.run("UPDATE files SET kind = 0, content = ?, symbols = ? WHERE id = ?",
                         [.blob(data), .text(RepoMap.symbols(path: name, text: text)), .integer(Int64(row.id))])
        try indexAdd(id: row.id, path: name, text: text)
        return .stored
    }

    /// Unpacks a gzip tarball of the pinned commit (GitHub's tarball endpoint,
    /// or `git archive --prefix=x/`). The first path component is the
    /// archive's wrapper folder and is dropped. A file is stored only when its
    /// size and Git blob hash match the tree; anything else is counted and
    /// left out, so unverified bytes never enter the workspace.
    public func importArchive(_ gzip: Data) throws -> ImportReport {
        lock.lock(); defer { lock.unlock() }
        var report = ImportReport()
        var storedBytes = 0
        try database.transaction {
            let lookup = try database.prepare("SELECT size FROM files WHERE path = ? AND origin = 0 AND kind = 2")
            var reader = TarReader(maxEntries: limits.maxArchiveEntries)
            var currentPath: Data?
            var buffer = Data()
            var failure: Error?
            reader.onEntry = { entry in
                guard entry.isFile, let slash = entry.name.firstIndex(of: 47) else { return false }
                let path = entry.name.suffix(from: entry.name.index(after: slash))
                guard !path.isEmpty else { return false }
                try lookup.bind([.blob(Data(path))])
                guard try lookup.step() else { report.skipped += 1; return false }
                guard lookup.int(0) == entry.size else { report.mismatched += 1; return false }
                currentPath = Data(path)
                buffer.removeAll(keepingCapacity: true)
                return true
            }
            reader.onData = { buffer.append($0) }
            reader.onEntryEnd = { [self] in
                guard let path = currentPath else { return }
                currentPath = nil
                switch try storeVerified(path, buffer) {
                case .stored:
                    report.stored += 1
                    storedBytes += buffer.count
                    if storedBytes > limits.maxTextBytes { throw WorkspaceError.tooLarge }
                case .binary: report.binary += 1
                case .mismatched: report.mismatched += 1
                case .skipped: report.skipped += 1
                }
            }
            do {
                try Gunzip.inflate(gzip, limit: limits.maxArchiveBytes) { chunk in
                    do { try reader.consume(chunk) } catch { failure = error; throw error }
                }
            } catch {
                throw failure ?? error
            }
            guard reader.finished else { throw ArchiveError.tar }
        }
        return report
    }

    // MARK: - Task-local overlay

    /// Makes the files reflect exactly `operations` applied in order on top of
    /// the base. Calling again with the same key does nothing, so callers can
    /// pass the task's applied edits before every use.
    public func setOverlay(key: String, operations: [Operation]) throws {
        lock.lock(); defer { lock.unlock() }
        guard meta("overlay") != key else { return }
        try database.transaction {
            try resetOverlay()
            for operation in operations {
                switch operation {
                case .write(let path, let text):
                    guard TaskWorkspace.validPath(path) else { throw WorkspaceError.path }
                    try writeLocal(path, text)
                case .delete(let path):
                    guard TaskWorkspace.validPath(path) else { throw WorkspaceError.path }
                    try displace(Data(path.utf8))
                }
            }
            try setMeta("overlay", key)
        }
    }

    /// Adds one change on top of the current overlay without rebuilding it.
    /// The overlay key is cleared, so the next `setOverlay` with the task's
    /// saved key rebuilds from the saved edits. A change that was never saved
    /// there does not survive that rebuild.
    public func applyOverlay(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        try database.transaction {
            switch operation {
            case .write(let path, let text):
                guard TaskWorkspace.validPath(path) else { throw WorkspaceError.path }
                guard !directoryExists(path) else { throw WorkspaceError.isDirectory }
                var parent = ""
                for part in gitPathComponents(path).dropLast() {
                    parent = parent.isEmpty ? part : parent + "/" + part
                    guard !exists("SELECT 1 FROM files WHERE path = ?", [.blob(Data(parent.utf8))]) else { throw WorkspaceError.notDirectory }
                }
                try writeLocal(path, text)
            case .delete(let path):
                guard TaskWorkspace.validPath(path) else { throw WorkspaceError.path }
                guard exists("SELECT 1 FROM files WHERE path = ?", [.blob(Data(path.utf8))]) else {
                    throw directoryExists(path) ? WorkspaceError.isDirectory : WorkspaceError.missing
                }
                try displace(Data(path.utf8))
            }
            try setMeta("overlay", "")
        }
    }

    private func writeLocal(_ path: String, _ text: String) throws {
        try displace(Data(path.utf8))
        let data = Data(text.utf8)
        try database.run("INSERT INTO files(path, kind, mode, sha, size, origin, content, symbols) VALUES(?, 0, '100644', ?, ?, 1, ?, ?)",
                         [.blob(Data(path.utf8)), .text(GitBlob.sha(data)), .integer(Int64(data.count)),
                          .blob(data), .text(RepoMap.symbols(path: path, text: text))])
        try indexAdd(id: Int(database.lastInsertRowID), path: path, text: text)
    }

    /// Removes the current row at `path`. A base row is kept in `shadow` so
    /// resetting the overlay can restore it without refetching.
    private func displace(_ path: Data) throws {
        var row: (id: Int, kind: Int, origin: Int, content: Data?)?
        try database.query("SELECT id, kind, origin, content FROM files WHERE path = ?", [.blob(path)]) {
            row = ($0.int(0), $0.int(1), $0.int(2), $0.isNull(3) ? nil : $0.blob(3))
        }
        guard let row else { return }
        if row.origin == 0 {
            try database.run("INSERT INTO shadow(path, kind, mode, sha, size, content, symbols) SELECT path, kind, mode, sha, size, content, symbols FROM files WHERE id = ?",
                             [.integer(Int64(row.id))])
        }
        if row.kind == Kind.text.rawValue, let content = row.content {
            try indexRemove(id: row.id, path: String(decoding: path, as: UTF8.self), text: String(decoding: content, as: UTF8.self))
        }
        try database.run("DELETE FROM files WHERE id = ?", [.integer(Int64(row.id))])
    }

    private func resetOverlay() throws {
        var local: [Data] = []
        try database.query("SELECT path FROM files WHERE origin = 1") { local.append($0.blob(0)) }
        for path in local { try displace(path) }
        var restored: [(path: Data, kind: Int, content: Data?)] = []
        try database.query("SELECT path, kind, content FROM shadow") {
            restored.append(($0.blob(0), $0.int(1), $0.isNull(2) ? nil : $0.blob(2)))
        }
        for item in restored {
            try database.run("INSERT INTO files(path, kind, mode, sha, size, origin, content, symbols) SELECT path, kind, mode, sha, size, 0, content, symbols FROM shadow WHERE path = ?",
                             [.blob(item.path)])
            if item.kind == Kind.text.rawValue, let content = item.content {
                try indexAdd(id: Int(database.lastInsertRowID), path: String(decoding: item.path, as: UTF8.self),
                             text: String(decoding: content, as: UTF8.self))
            }
        }
        try database.execute("DELETE FROM shadow")
    }

    // MARK: - Reading

    func scope(_ directory: String) -> (lower: Data, upper: Data) {
        var lower = Data(directory.utf8)
        lower.append(47)
        var upper = Data(directory.utf8)
        upper.append(48)
        return (lower, upper)
    }

    /// Immediate children of a directory in the task's current state.
    /// `""` is the root. Directories come first; names sort case-insensitively.
    public func list(_ directory: String) throws -> [Child] {
        lock.lock(); defer { lock.unlock() }
        guard directory.isEmpty || TaskWorkspace.validPath(directory) else { throw WorkspaceError.path }
        // Keyed by bytes: Swift treats canonically equivalent strings as equal,
        // and two such names are two different files in Git.
        var kinds: [Data: ChildKind] = [:]
        func add(_ path: Data, _ kind: Int, dropping: Int) {
            let rest = path.dropFirst(dropping)
            if let slash = rest.firstIndex(of: 47) {
                kinds[Data(rest[rest.startIndex..<slash])] = .directory
            } else {
                kinds[Data(rest)] = kind == Kind.unsupported.rawValue ? .unsupported : .file
            }
        }
        if directory.isEmpty {
            try database.query("SELECT path, kind FROM files") { add($0.blob(0), $0.int(1), dropping: 0) }
        } else {
            let range = scope(directory)
            try database.query("SELECT path, kind FROM files WHERE path >= ? AND path < ?", [.blob(range.lower), .blob(range.upper)]) {
                add($0.blob(0), $0.int(1), dropping: range.lower.count)
            }
            if kinds.isEmpty {
                throw exists("SELECT 1 FROM files WHERE path = ?", [.blob(Data(directory.utf8))])
                    ? WorkspaceError.notDirectory : WorkspaceError.missing
            }
        }
        return kinds.sorted { left, right in
            if (left.value == .directory) != (right.value == .directory) { return left.value == .directory }
            let first = left.key.map(TaskWorkspace.lower), second = right.key.map(TaskWorkspace.lower)
            return first == second ? left.key.lexicographicallyPrecedes(right.key) : first.lexicographicallyPrecedes(second)
        }.map { Child(name: String(decoding: $0.key, as: UTF8.self), kind: $0.value) }
    }

    public func directoryExists(_ directory: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if directory.isEmpty { return true }
        guard TaskWorkspace.validPath(directory) else { return false }
        let range = scope(directory)
        return exists("SELECT 1 FROM files WHERE path >= ? AND path < ? LIMIT 1", [.blob(range.lower), .blob(range.upper)])
    }

    /// The current text of one file: the applied task change if there is one,
    /// otherwise the verified base content.
    public func read(_ path: String) throws -> File {
        lock.lock(); defer { lock.unlock() }
        guard TaskWorkspace.validPath(path) else { throw WorkspaceError.path }
        var result: File?
        var kind: Int?
        try database.query("SELECT kind, content, sha, origin FROM files WHERE path = ?", [.blob(Data(path.utf8))]) { row in
            kind = row.int(0)
            if kind == Kind.text.rawValue {
                result = File(text: String(decoding: row.blob(1), as: UTF8.self), sha: row.text(2), isLocal: row.int(3) == 1)
            }
        }
        if let result { return result }
        switch kind.flatMap(Kind.init(rawValue:)) {
        case .unsupported?: throw WorkspaceError.notText
        case .pending?: throw WorkspaceError.notDownloaded
        default: throw directoryExists(path) ? WorkspaceError.isDirectory : WorkspaceError.missing
        }
    }

    /// Every text file in the task's current state, in path order.
    public func textFiles() -> [(path: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        var result: [(String, String)] = []
        try? database.query("SELECT path, content FROM files WHERE kind = 0 ORDER BY path") {
            result.append((String(decoding: $0.blob(0), as: UTF8.self), String(decoding: $0.blob(1), as: UTF8.self)))
        }
        return result
    }

    /// True when `path` was created, changed or removed by this task.
    public func hasLocalChange(at path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = SQLiteValue.blob(Data(path.utf8))
        return exists("SELECT 1 FROM files WHERE path = ? AND origin = 1", [key]) || exists("SELECT 1 FROM shadow WHERE path = ?", [key])
    }

    // MARK: - Word index

    func indexAdd(id: Int, path: String, text: String) throws {
        guard hasWordIndex else { return }
        try database.run("INSERT INTO words(rowid, path, body) VALUES(?, ?, ?)",
                         [.integer(Int64(id)), .text(WorkspaceWords.terms(path)), .text(WorkspaceWords.terms(text))])
    }

    func indexRemove(id: Int, path: String, text: String) throws {
        guard hasWordIndex else { return }
        // A contentless index is told what to forget: the same text it was given.
        try database.run("INSERT INTO words(words, rowid, path, body) VALUES('delete', ?, ?, ?)",
                         [.integer(Int64(id)), .text(WorkspaceWords.terms(path)), .text(WorkspaceWords.terms(text))])
    }

    /// Ingests an attachment into the task workspace under `attachments/<sanitized_name>`.
    /// Stored with origin = 1 (local task file) and indexed in FTS5 words.
    public func ingestAttachment(_ attachment: Attachment) throws {
        let path = AttachmentPromptFormatter.sanitizeWorkspacePath(attachment.filename)
        try applyOverlay(.write(path: path, text: attachment.extractedText))
    }
}
