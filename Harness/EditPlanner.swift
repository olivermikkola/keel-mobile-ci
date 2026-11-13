import Foundation

/// Why a proposed change could not be prepared. The wording is what the model
/// reads, so each message says how to correct the call.
enum EditPlanError: LocalizedError, Equatable {
    case arguments(String), path, size, match, unchanged, occupied, missingFolder

    var errorDescription: String? {
        switch self {
        case .arguments(let expected): return "Invalid tool call: \(expected)"
        case .path: return "Choose a relative file path inside this task’s repository."
        case .size: return "Edits support UTF-8 files up to 64 KB and replacement text up to 4 KB, without null characters."
        case .match: return "The original text must match exactly once. Include enough surrounding code to make the replacement unique."
        case .unchanged: return "This proposal does not change the file."
        case .occupied: return "A file already exists at that path. Use propose_edit to change it, or choose another path."
        case .missingFolder: return "That folder does not exist. Create the file in an existing folder; use list_files to see them."
        }
    }
}

enum ExactEdit {
    static let fileLimit = 65_536
    static let replacementLimit = 4_096

    /// Replaces `old` with `new` only when `old` occurs exactly once, comparing
    /// bytes. Overlapping occurrences count (`aa` in `aaa` is two), and Unicode
    /// canonical equivalence never widens the target.
    static func replaceOnce(in data: Data, old: Data, new: Data) -> Data? {
        guard !old.isEmpty, let range = data.range(of: old) else { return nil }
        guard data.range(of: old, in: (range.lowerBound + 1)..<data.endIndex) == nil else { return nil }
        var result = data
        result.replaceSubrange(range, with: new)
        return result
    }
}

/// A change worked out against the task's current files, ready for review.
struct PlannedEdit: Equatable {
    enum Kind: String { case replace, create, delete, rename }
    let kind: Kind
    let path: String
    let destinationPath: String?
    /// The file's current text and Git blob hash; empty text for a create.
    let before: String
    let beforeSHA: String
    let oldText: String
    let newText: String
    let after: String

    /// The same change as workspace operations, for applying it to the overlay.
    var operations: [TaskWorkspace.Operation] {
        switch kind {
        case .replace, .create: return [.write(path: path, text: after)]
        case .delete: return [.delete(path: path)]
        case .rename: return [.delete(path: path), .write(path: destinationPath ?? path, text: before)]
        }
    }
}

enum EditPlanner {
    private static func validPath(_ path: String) -> Bool {
        TaskWorkspace.validPath(path) && path.utf8.count <= 1024 && gitPathComponents(path).count <= 16
    }

    private static func parent(_ path: String) -> String {
        gitPathComponents(path).dropLast().joined(separator: "/")
    }

    /// Works out one proposal call against the workspace. Nothing is changed.
    static func plan(_ call: DirectorCall, workspace: TaskWorkspace) throws -> PlannedEdit {
        let arguments = call.arguments
        func expect(_ keys: [String]) throws {
            guard Set(arguments.keys) == Set(keys) else {
                throw EditPlanError.arguments("Expected \(keys.joined(separator: ", ")).")
            }
        }
        func current(_ path: String) throws -> TaskWorkspace.File {
            guard validPath(path) else { throw EditPlanError.path }
            return try workspace.read(path)
        }
        func absent(_ path: String) throws {
            guard validPath(path) else { throw EditPlanError.path }
            do { _ = try workspace.read(path) } catch WorkspaceError.missing { return }
            throw EditPlanError.occupied
        }
        switch call.name {
        case "propose_edit", "stage_file_edit":
            try expect(["path", "old_text", "new_text"])
            let path = arguments["path"]!, new = arguments["new_text"]!
            let file = try current(path)
            let data = Data(file.text.utf8)
            // Decoded entities first; the text as written covers a file that
            // really contains "&lt;" or "&amp;".
            var candidates = [(arguments["old_text"]!, new)]
            if let rawOld = call.rawArguments["old_text"], let rawNew = call.rawArguments["new_text"],
               rawOld != candidates[0].0 || rawNew != new { candidates.append((rawOld, rawNew)) }
            for (old, new) in candidates {
                guard old.utf8.count <= ExactEdit.replacementLimit, new.utf8.count <= ExactEdit.replacementLimit,
                      !old.utf8.contains(0), !new.utf8.contains(0), data.count <= ExactEdit.fileLimit else { throw EditPlanError.size }
                guard let result = ExactEdit.replaceOnce(in: data, old: Data(old.utf8), new: Data(new.utf8)) else { continue }
                guard result != data else { throw EditPlanError.unchanged }
                guard result.count <= ExactEdit.fileLimit else { throw EditPlanError.size }
                return PlannedEdit(kind: .replace, path: path, destinationPath: nil, before: file.text, beforeSHA: file.sha,
                                   oldText: old, newText: new, after: String(decoding: result, as: UTF8.self))
            }
            throw EditPlanError.match
        case "create_file":
            try expect(["path", "new_text"])
            let path = arguments["path"]!
            var text = arguments["new_text"]!
            // The value-per-line call format eats the file's final line break.
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            guard text.utf8.count <= ExactEdit.replacementLimit, !text.utf8.contains(0) else { throw EditPlanError.size }
            try absent(path)
            guard workspace.directoryExists(parent(path)) else { throw EditPlanError.missingFolder }
            return PlannedEdit(kind: .create, path: path, destinationPath: nil, before: "", beforeSHA: GitBlob.sha(""),
                               oldText: "", newText: text, after: text)
        case "delete_file":
            try expect(["path"])
            let path = arguments["path"]!
            let file = try current(path)
            guard file.text.utf8.count <= ExactEdit.fileLimit else { throw EditPlanError.size }
            return PlannedEdit(kind: .delete, path: path, destinationPath: nil, before: file.text, beforeSHA: file.sha,
                               oldText: "", newText: "", after: "")
        case "rename_file":
            try expect(["path", "destination_path"])
            let path = arguments["path"]!, destination = arguments["destination_path"]!
            guard Data(path.utf8) != Data(destination.utf8) else { throw EditPlanError.path }
            let file = try current(path)
            guard file.text.utf8.count <= ExactEdit.fileLimit else { throw EditPlanError.size }
            try absent(destination)
            guard workspace.directoryExists(parent(destination)) else { throw EditPlanError.missingFolder }
            return PlannedEdit(kind: .rename, path: path, destinationPath: destination, before: file.text, beforeSHA: file.sha,
                               oldText: "", newText: "", after: file.text)
        default:
            throw EditPlanError.arguments("Unsupported proposal tool: \(call.name)")
        }
    }

    /// Converts net post-script changes (`after: String?`, `nil` for deletion)
    /// against `workspace` into reviewable edits without changing `workspace`.
    static func planChanges(_ changes: [(path: String, after: String?)], workspace: TaskWorkspace) throws -> [PlannedEdit] {
        var planned: [PlannedEdit] = []
        for (path, after) in changes {
            guard validPath(path) else { throw EditPlanError.path }
            let current = try? workspace.read(path)
            switch (current, after) {
            case (.none, .none):
                continue
            case (.none, .some(let newText)):
                guard newText.utf8.count <= ExactEdit.replacementLimit, !newText.utf8.contains(0) else { throw EditPlanError.size }
                guard workspace.directoryExists(parent(path)) else { throw EditPlanError.missingFolder }
                planned.append(PlannedEdit(kind: .create, path: path, destinationPath: nil, before: "",
                                           beforeSHA: GitBlob.sha(""), oldText: "", newText: newText, after: newText))
            case (.some(let existing), .none):
                guard existing.text.utf8.count <= ExactEdit.fileLimit else { throw EditPlanError.size }
                planned.append(PlannedEdit(kind: .delete, path: path, destinationPath: nil, before: existing.text,
                                           beforeSHA: existing.sha, oldText: "", newText: "", after: ""))
            case (.some(let existing), .some(let newText)):
                let beforeData = Data(existing.text.utf8)
                let afterData = Data(newText.utf8)
                guard beforeData != afterData else { continue }
                guard beforeData.count <= ExactEdit.fileLimit, afterData.count <= ExactEdit.fileLimit,
                      !newText.utf8.contains(0) else { throw EditPlanError.size }
                guard let (oldSlice, newSlice) = uniqueReplacement(from: existing.text, to: newText) else {
                    throw EditPlanError.size
                }
                planned.append(PlannedEdit(kind: .replace, path: path, destinationPath: nil, before: existing.text,
                                           beforeSHA: existing.sha, oldText: oldSlice, newText: newSlice, after: newText))
            }
        }
        return planned
    }

    /// Finds the shortest unique line-aligned `(oldText, newText)` hunk within `ExactEdit.replacementLimit`.
    private static func uniqueReplacement(from before: String, to after: String) -> (String, String)? {
        let oldLines = splitLinesPreservingEndings(before)
        let newLines = splitLinesPreservingEndings(after)
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count),
              Data(oldLines[prefix].utf8) == Data(newLines[prefix].utf8) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldLines.count, newLines.count) - prefix,
              Data(oldLines[oldLines.count - 1 - suffix].utf8) == Data(newLines[newLines.count - 1 - suffix].utf8) {
            suffix += 1
        }
        var oldStart = prefix
        var oldEnd = oldLines.count - suffix
        var newStart = prefix
        var newEnd = newLines.count - suffix
        if oldStart == oldEnd {
            if oldStart > 0 { oldStart -= 1; newStart -= 1 }
            else if oldEnd < oldLines.count { oldEnd += 1; newEnd += 1 }
            else { return nil }
        }
        let beforeData = Data(before.utf8)
        while true {
            let oldText = oldLines[oldStart..<oldEnd].joined()
            let newText = newLines[newStart..<newEnd].joined()
            if ExactEdit.replaceOnce(in: beforeData, old: Data(oldText.utf8), new: Data(newText.utf8)) != nil {
                guard oldText.utf8.count <= ExactEdit.replacementLimit,
                      newText.utf8.count <= ExactEdit.replacementLimit else { return nil }
                return (oldText, newText)
            }
            var expanded = false
            if oldStart > 0 { oldStart -= 1; newStart -= 1; expanded = true }
            if oldEnd < oldLines.count { oldEnd += 1; newEnd += 1; expanded = true }
            if !expanded { return nil }
        }
    }

    private static func splitLinesPreservingEndings(_ text: String) -> [String] {
        var lines: [String] = []
        var start = text.startIndex
        for index in text.indices where text[index] == "\n" {
            let next = text.index(after: index)
            lines.append(String(text[start..<next]))
            start = next
        }
        if start < text.endIndex { lines.append(String(text[start..<text.endIndex])) }
        return lines
    }
}
