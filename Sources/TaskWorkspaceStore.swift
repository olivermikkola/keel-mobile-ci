import Foundation

// One workspace database per saved task (Harness/TaskWorkspace.swift). It is
// derived state: the pinned snapshot and the task's applied edits can always
// rebuild it, so it is excluded from backup and removed with the task.
enum TaskWorkspaceStore {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    static func directory(beside transcript: URL) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent("Workspaces", isDirectory: true)
    }

    static func url(for task: UUID, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent("\(task.uuidString).sqlite")
    }

    static func scratchSQLURL(for task: UUID, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent("\(task.uuidString).scratch.sqlite")
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Runs `sql` against this task's persistent scratch SQLite database.
    static func runSQL(_ sql: String, task: UUID, in directory: URL = defaultDirectory, limits: SQLLimits = SQLLimits()) throws -> SQLResult {
        try prepareDirectory(directory)
        return try SQLSandbox(path: scratchSQLURL(for: task, in: directory).path, limits: limits).run(sql)
    }

    /// The task's workspace at `snapshot` with `edits` applied. Downloads the
    /// repository once per snapshot; later calls only refresh the edits.
    static func open(task: UUID, snapshot: RepositorySnapshot, client: GitHubRepository,
                     edits: [ProposedFileEdit], in directory: URL = defaultDirectory) async throws -> TaskWorkspace {
        let identity = TaskWorkspace.Identity(repository: snapshot.repository.fullName, commit: snapshot.commit, tree: snapshot.tree)
        let location = url(for: task, in: directory)
        let workspace = try await Task.detached(priority: .userInitiated) { () -> TaskWorkspace in
            try prepareDirectory(directory)
            return try TaskWorkspace(path: location.path)
        }.value
        // A pending file means an earlier download did not finish. Start it again.
        if workspace.identity != identity || workspace.counts.pending > 0 {
            let entries = try await client.fullTree(snapshot: snapshot)
            let archive = try await client.archive(snapshot: snapshot)
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                try workspace.setBase(identity, entries: entries)
                _ = try workspace.importArchive(archive)
            }.value
            // The archive is the same commit as the tree, so nothing should be
            // left over. If something is, the workspace is not a complete copy.
            guard workspace.counts.pending == 0 else { throw RepositoryError.response }
        }
        let operations = edits.flatMap(operations(for:))
        let key = edits.map(\.id.uuidString).joined(separator: ",")
        try await Task.detached(priority: .userInitiated) {
            try workspace.setOverlay(key: key, operations: operations)
        }.value
        return workspace
    }

    /// The files of a chat with no repository: its attachments and the
    /// changes applied in it (Harness/LocalFiles.swift).
    static func openLocal(task: UUID, attachments: [Attachment], edits: [ProposedFileEdit],
                          in directory: URL = defaultDirectory) async throws -> TaskWorkspace {
        let location = url(for: task, in: directory)
        let (key, operations) = localOverlay(attachments: attachments, edits: edits)
        return try await Task.detached(priority: .userInitiated) { () -> TaskWorkspace in
            try prepareDirectory(directory)
            let workspace = try TaskWorkspace(path: location.path)
            try LocalFiles.prepare(workspace, key: key, operations: operations)
            return workspace
        }.value
    }

    /// The overlay that makes a chat's own files: its key and operations.
    static func localOverlay(attachments: [Attachment], edits: [ProposedFileEdit]) -> (key: String, operations: [TaskWorkspace.Operation]) {
        let files = attachments.map { (path: AttachmentPromptFormatter.sanitizeWorkspacePath($0.filename), text: $0.extractedText) }
        let key = "local|" + attachments.map(\.id.uuidString).joined(separator: ",") + "|" + edits.map(\.id.uuidString).joined(separator: ",")
        return (key, LocalFiles.operations(attachments: files, changes: edits.flatMap(operations(for:))))
    }

    static func operations(for edit: ProposedFileEdit) -> [TaskWorkspace.Operation] {
        switch edit.kind {
        case .replace, .create: return [.write(path: edit.path, text: edit.after)]
        case .delete: return [.delete(path: edit.path)]
        case .rename: return [.delete(path: edit.path), .write(path: edit.afterPath, text: edit.after)]
        }
    }

    static func remove(task: UUID, in directory: URL = defaultDirectory) {
        for fileURL in [url(for: task, in: directory), scratchSQLURL(for: task, in: directory)] {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: fileURL.path + suffix) }
        }
    }
}
