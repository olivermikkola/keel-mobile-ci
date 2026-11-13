import Foundation
import CryptoKit

enum FileEditError: LocalizedError, Equatable {
    case path, size, match, unchanged, stale, reviewSize, limit
    var errorDescription: String? {
        switch self {
        case .path: return "Choose a relative file path inside this task’s repository."
        case .size: return "Edits support UTF-8 files up to 64 KB and replacement text up to 4 KB, without null characters."
        case .match: return "The original text must match exactly once. Include enough surrounding code to make the replacement unique."
        case .unchanged: return "This proposal does not change the file."
        case .stale: return "This proposal is based on different content. Read the current file and propose the change again."
        case .reviewSize: return "This change is too large to review here. Propose a smaller change."
        case .limit: return "This task has reached its 16-proposal limit. Start a new task for further changes."
        }
    }
}

struct TaskFileEdit: Codable, Identifiable {
    enum Decision: String, Codable, Equatable { case pending, applied, discarded }
    let proposal: ProposedFileEdit
    var decision: Decision = .pending
    var appliedOrder: Int?
    var id: UUID { proposal.id }
    static func applied(in messages: [ChatMessage]) -> [ProposedFileEdit] {
        messages.compactMap(\.edit).filter { $0.decision == .applied }
            .sorted { ($0.appliedOrder ?? 0) < ($1.appliedOrder ?? 0) }.map(\.proposal)
    }
    static func validHistory(_ messages: [ChatMessage], snapshot: RepositorySnapshot?) -> Bool {
        let records = messages.compactMap(\.edit)
        guard records.count <= 16, Set(records.map(\.id)).count == records.count,
              messages.allSatisfy({ $0.edit == nil || $0.role == "tool" }),
              records.allSatisfy({ $0.proposal.snapshot == snapshot && ($0.decision == .applied || $0.appliedOrder == nil) }) else { return false }
        let applied = records.filter { $0.decision == .applied }.sorted { ($0.appliedOrder ?? 0) < ($1.appliedOrder ?? 0) }
        guard applied.compactMap(\.appliedOrder) == Array(1..<(applied.count + 1)) else { return false }
        enum PathState { case present(String), absent }
        // Keep absence as a tombstone. Removing the key would let a later
        // operation mistake a deleted/renamed path for an untouched base file.
        var currentPathSHA: [Data: PathState] = [:]
        func matchesSource(_ edit: ProposedFileEdit) -> Bool {
            switch currentPathSHA[Data(edit.path.utf8)] {
            case .some(.present(let sha)): return edit.beforeSHA == sha
            case .some(.absent): return false
            case .none: return edit.beforeSHA == edit.originalBlobSHA
            }
        }
        func isUnoccupied(_ path: Data) -> Bool {
            if case .some(.present(_)) = currentPathSHA[path] { return false }
            return true
        }
        for record in applied {
            let edit = record.proposal
            let source = Data(edit.path.utf8)
            switch edit.kind {
            case .create:
                guard isUnoccupied(source),
                      edit.originalBlobSHA == ProposedFileEdit.emptyBlobSHA,
                      edit.beforeSHA == ProposedFileEdit.emptyBlobSHA else { return false }
                currentPathSHA[source] = .present(edit.afterSHA)
            case .replace, .delete:
                guard matchesSource(edit) else { return false }
                currentPathSHA[source] = edit.kind == .delete ? .absent : .present(edit.afterSHA)
            case .rename:
                let destination = Data(edit.afterPath.utf8)
                guard destination != source, isUnoccupied(destination), matchesSource(edit) else { return false }
                currentPathSHA[source] = .absent
                currentPathSHA[destination] = .present(edit.afterSHA)
            }
        }
        return true
    }
    var observation: String {
        var value: [String: String] = ["result_type": "edit_proposal", "proposal_id": id.uuidString,
                                      "kind": proposal.kind.rawValue,
                                      "path": proposal.path, "commit": proposal.snapshot.commit,
                                      "status": decision.rawValue, "before_sha": proposal.beforeSHA,
                                      "after_sha": proposal.afterSHA,
                                      "note": decision == .pending ? "Prepared only. The user must review and apply this change in the UI. No file was changed." :
                                        (decision == .applied ? "The user applied this change to the saved task. GitHub has not been changed." : "The user discarded this proposal. No file was changed.")]
        if let destination = proposal.destinationPath { value["destination_path"] = destination }
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

// A proposal is data only. Constructing, decoding or displaying it never writes
// a repository file. The UI must separately authorize applying the reviewed
// proposal, using the actual current content in applying(to:...).
enum FileEditKind: String, Codable, Equatable {
    case replace, create, delete, rename
}

struct ProposedFileEdit: Codable, Identifiable {
    let id: UUID
    let snapshot: RepositorySnapshot
    let kind: FileEditKind
    let path: String
    let destinationPath: String?
    let originalBlobSHA: String
    let before: String
    let oldText: String
    let newText: String

    static let fileLimit = 65_536
    static let replacementLimit = 4096
    // SHA-1 of the Git object "blob 0\0". A create proves it started from no
    // file, just as a replace proves it started from the original blob.
    static let emptyBlobSHA = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"

    init(snapshot: RepositorySnapshot, path: String, originalBlobSHA: String,
         before: String, oldText: String, newText: String,
         kind: FileEditKind = .replace, destinationPath: String? = nil) throws {
        id = UUID(); self.snapshot = snapshot; self.kind = kind; self.path = path
        self.destinationPath = destinationPath
        self.originalBlobSHA = originalBlobSHA
        self.before = before; self.oldText = oldText; self.newText = newText
        try validate()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        snapshot = try values.decode(RepositorySnapshot.self, forKey: .snapshot)
        kind = try values.decodeIfPresent(FileEditKind.self, forKey: .kind) ?? .replace
        path = try values.decode(String.self, forKey: .path)
        destinationPath = try values.decodeIfPresent(String.self, forKey: .destinationPath)
        originalBlobSHA = try values.decode(String.self, forKey: .originalBlobSHA)
        before = try values.decode(String.self, forKey: .before)
        oldText = try values.decode(String.self, forKey: .oldText)
        newText = try values.decode(String.self, forKey: .newText)
        try validate()
    }

    private func validate() throws {
        let parts = gitPathComponents(path)
        guard !path.isEmpty, path.utf8.count <= 1024, parts.count <= 16,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FileEditError.path }
        if kind == .rename {
            guard let destinationPath, !destinationPath.isEmpty, Data(destinationPath.utf8) != Data(path.utf8),
                  destinationPath.utf8.count <= 1024,
                  !destinationPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw FileEditError.path
            }
            let destinationParts = gitPathComponents(destinationPath)
            guard destinationParts.count <= 16,
                  destinationParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw FileEditError.path
            }
        } else if destinationPath != nil {
            throw FileEditError.path
        }
        guard GitHubRepository.validSHA(originalBlobSHA), GitHubRepository.validSHA(snapshot.commit),
              GitHubRepository.validSHA(snapshot.tree) else { throw FileEditError.stale }
        guard before.utf8.count <= Self.fileLimit,
              oldText.utf8.count <= Self.replacementLimit, newText.utf8.count <= Self.replacementLimit,
              ![before, oldText, newText].contains(where: { $0.utf8.contains(0) }) else { throw FileEditError.size }
        switch kind {
        case .replace:
            guard !oldText.isEmpty else { throw FileEditError.size }
        case .create:
            guard before.isEmpty, oldText.isEmpty, originalBlobSHA == Self.emptyBlobSHA else { throw FileEditError.stale }
        case .delete, .rename:
            guard oldText.isEmpty, newText.isEmpty else { throw FileEditError.size }
        }
        let result = try replacement()
        guard result.count <= Self.fileLimit else { throw FileEditError.size }
        guard result != Data(before.utf8) || kind != .replace else { throw FileEditError.unchanged }
        // Long single-line files can otherwise turn a tiny replacement into
        // an unreadably large diff. Never silently clip the review.
        guard diff.text.utf8.count <= 32_768 else { throw FileEditError.reviewSize }
    }

    private func replacement() throws -> Data {
        switch kind {
        case .create:
            return Data(newText.utf8)
        case .delete:
            return Data()
        case .rename:
            return Data(before.utf8)
        case .replace:
            var data = Data(before.utf8)
            let needle = Data(oldText.utf8)
            guard !needle.isEmpty, let range = data.range(of: needle) else { throw FileEditError.match }
            // Start one byte after the first occurrence to catch overlapping
            // matches too (for example "aa" inside "aaa"). Match bytes exactly;
            // Unicode canonical equivalence must never widen an edit's target.
            let next = (range.lowerBound + 1)..<data.endIndex
            guard data.range(of: needle, in: next) == nil else { throw FileEditError.match }
            data.replaceSubrange(range, with: Data(newText.utf8))
            return data
        }
    }

    var after: String {
        // Both construction and decoding validate the replacement and UTF-8
        // boundaries. All fields are immutable after validation.
        String(decoding: try! replacement(), as: UTF8.self)
    }
    var afterPath: String { kind == .rename ? (destinationPath ?? path) : path }
    var beforeSHA: String { Self.blobSHA(before) }
    var afterSHA: String { Self.blobSHA(after) }

    static func blobSHA(_ text: String) -> String {
        let bytes = Data(text.utf8)
        var object = Data("blob \(bytes.count)\0".utf8); object.append(bytes)
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }

    func applying(to current: String, snapshot currentSnapshot: RepositorySnapshot, originalBlobSHA currentBlob: String) throws -> String {
        guard currentSnapshot == snapshot, currentBlob == originalBlobSHA else { throw FileEditError.stale }
        if kind == .create {
            guard originalBlobSHA == Self.emptyBlobSHA, current.isEmpty else { throw FileEditError.stale }
        } else {
            guard Data(current.utf8) == Data(before.utf8) else { throw FileEditError.stale }
        }
        return after
    }

    var diff: FileEditDiff {
        if kind == .rename {
            return FileEditDiff(path: path, before: before, after: before)
        }
        return FileEditDiff(path: path, before: before, after: after)
    }
}

struct FileEditDiff {
    enum Kind: Equatable { case context, removal, addition, noNewline }
    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }
    let header: String
    let hunk: String
    let lines: [Line]
    var text: String {
        ([header, hunk] + lines.map {
            switch $0.kind {
            case .context: return " " + $0.text
            case .removal: return "-" + $0.text
            case .addition: return "+" + $0.text
            case .noNewline: return "\\ No newline at end of file"
            }
        }).joined(separator: "\n")
    }

    private struct FileLine: Equatable {
        let text: String
        let newline: Bool
        static func == (lhs: FileLine, rhs: FileLine) -> Bool {
            lhs.newline == rhs.newline && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }
    private static func fileLines(_ text: String) -> [FileLine] {
        if text.isEmpty { return [] }
        let parts = text.components(separatedBy: "\n")
        return parts.enumerated().compactMap { index, line in
            if index == parts.count - 1 && line.isEmpty { return nil }
            return FileLine(text: line, newline: index < parts.count - 1)
        }
    }

    init(path: String, before: String, after: String) {
        let old = Self.fileLines(before), new = Self.fileLines(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let start = max(0, prefix - 3)
        let oldEnd = min(old.count, old.count - suffix + 3)
        let newEnd = min(new.count, new.count - suffix + 3)
        header = "--- a/\(path)\n+++ b/\(path)"
        let oldCount = oldEnd - start, newCount = newEnd - start
        hunk = "@@ -\(oldCount == 0 ? start : start + 1),\(oldCount) +\(newCount == 0 ? start : start + 1),\(newCount) @@"
        var result: [Line] = []
        func append(_ line: FileLine, kind: Kind, oldLine: Int?, newLine: Int?) {
            result.append(Line(id: result.count, kind: kind, text: line.text, oldLine: oldLine, newLine: newLine))
            if !line.newline { result.append(Line(id: result.count, kind: .noNewline, text: "No newline at end of file", oldLine: nil, newLine: nil)) }
        }
        for index in start..<prefix { append(old[index], kind: .context, oldLine: index + 1, newLine: index + 1) }
        for index in prefix..<(old.count - suffix) { append(old[index], kind: .removal, oldLine: index + 1, newLine: nil) }
        for index in prefix..<(new.count - suffix) { append(new[index], kind: .addition, oldLine: nil, newLine: index + 1) }
        for index in (old.count - suffix)..<oldEnd {
            append(old[index], kind: .context, oldLine: index + 1, newLine: new.count - old.count + index + 1)
        }
        lines = result
    }
}
