import Foundation

/// A chat's own files when no repository is attached: what the user attached
/// and the changes they applied, with no base tree underneath. The same
/// workspace, tools and review flow as a repository task.
enum LocalFiles {
    static let identity = TaskWorkspace.Identity(
        repository: "local", commit: String(repeating: "0", count: 40), tree: String(repeating: "0", count: 40))

    /// Attachments first, then applied changes in order, so a change can edit an attached file.
    static func operations(attachments: [(path: String, text: String)], changes: [TaskWorkspace.Operation]) -> [TaskWorkspace.Operation] {
        attachments.map { .write(path: $0.path, text: $0.text) } + changes
    }

    /// Brings `workspace` to exactly these files. `key` names the set; an
    /// unchanged key leaves the workspace as it is.
    static func prepare(_ workspace: TaskWorkspace, key: String, operations: [TaskWorkspace.Operation]) throws {
        if workspace.identity != identity || workspace.counts.pending > 0 {
            try workspace.setBase(identity, entries: [])
        }
        try workspace.setOverlay(key: key, operations: operations)
    }

    /// True when the files still hold what a proposal was made against: the
    /// same text at its path, and nothing yet where it would create a file.
    static func stillApplies(_ kind: PlannedEdit.Kind, path: String, destinationPath: String?, before: String,
                             in workspace: TaskWorkspace) -> Bool {
        func text(_ path: String) -> String?? {
            do { return .some(try workspace.read(path).text) }
            catch WorkspaceError.missing { return .some(nil) }
            catch { return nil }
        }
        switch kind {
        case .create:
            return text(path) == .some(nil)
        case .replace, .delete:
            guard case .some(.some(let current)) = text(path) else { return false }
            return Data(current.utf8) == Data(before.utf8)
        case .rename:
            guard let destinationPath, case .some(.some(let current)) = text(path) else { return false }
            return Data(current.utf8) == Data(before.utf8) && text(destinationPath) == .some(nil)
        }
    }
}
