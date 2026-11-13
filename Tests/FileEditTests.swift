import XCTest
@testable import KeelMobile

final class FileEditTests: XCTestCase {
    func testDiffMatchesIndependentGitReferenceIncludingByteDistinctUnicode() throws {
        struct Reference: Decodable {
            let name: String
            let before: String
            let oldText: String
            let newText: String
            let expectedPatch: String
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "file-edit-git-reference", withExtension: "json"))
        // Produced independently with git diff --no-index --unified=3. Only
        // temporary file labels and optional ',1' hunk notation were normalized.
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
        for reference in references {
            let edit = try proposal(reference.before, reference.oldText, reference.newText)
            XCTAssertEqual(Data(edit.diff.text.utf8), Data(reference.expectedPatch.utf8), reference.name)
        }
    }

    private func snapshot(_ commit: String = String(repeating: "a", count: 40)) throws -> RepositorySnapshot {
        RepositorySnapshot(repository: try RepositoryID("owner/project"), branch: "main", commit: commit,
                           tree: String(repeating: "b", count: 40))
    }
    private func proposal(_ before: String, _ old: String, _ new: String, path: String = "Sources/a.swift") throws -> ProposedFileEdit {
        try ProposedFileEdit(snapshot: snapshot(), path: path, originalBlobSHA: ProposedFileEdit.blobSHA(before),
                             before: before, oldText: old, newText: new)
    }

    func testExactReplacementPreservesCRLFUnicodeAndSurroundingBytes() throws {
        let before = "// café\r\nlet value = 1\r\n// untouched\r\n"
        let edit = try proposal(before, "let value = 1", "let value = 2")
        let expected = "// café\r\nlet value = 2\r\n// untouched\r\n"
        XCTAssertEqual(Data(edit.after.utf8), Data(expected.utf8))
        XCTAssertEqual(try edit.applying(to: before, snapshot: snapshot(), originalBlobSHA: edit.originalBlobSHA), expected)
        let restored = try JSONDecoder().decode(ProposedFileEdit.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(restored.id, edit.id)
        XCTAssertEqual(restored.afterSHA, ProposedFileEdit.blobSHA(expected))
        XCTAssertEqual(restored.diff.text, edit.diff.text)
        print("Edit preparation proof: exact unique byte replacement, preserved CRLF/Unicode, deterministic diff and serialized proposal; preparation does not apply or publish a change.")
    }

    func testAmbiguousOverlappingAbsentAndCanonicallyEquivalentMatchesAreRejected() throws {
        for (before, old) in [("aaa", "aa"), ("same\nsame\n", "same"), ("different", "missing"), ("e\u{301}", "é")] {
            XCTAssertThrowsError(try proposal(before, old, "new")) { XCTAssertEqual($0 as? FileEditError, .match) }
        }
        XCTAssertThrowsError(try proposal("original", "", "new"))
        XCTAssertThrowsError(try proposal("original", "original", "original")) { XCTAssertEqual($0 as? FileEditError, .unchanged) }
    }

    func testChangedTaskCommitBlobOrFileContentCannotApplyAnOldProposal() throws {
        let edit = try proposal("let count = 1\n", "count = 1", "count = 2")
        XCTAssertThrowsError(try edit.applying(to: "let count = 3\n", snapshot: snapshot(), originalBlobSHA: edit.originalBlobSHA))
        XCTAssertThrowsError(try edit.applying(to: edit.before, snapshot: snapshot(String(repeating: "c", count: 40)), originalBlobSHA: edit.originalBlobSHA))
        XCTAssertThrowsError(try edit.applying(to: edit.before, snapshot: snapshot(), originalBlobSHA: String(repeating: "d", count: 40)))
        let next = try proposal(edit.after, "count = 2", "count = 3")
        XCTAssertThrowsError(try edit.applying(to: next.after, snapshot: snapshot(), originalBlobSHA: edit.originalBlobSHA))
    }

    func testUnifiedDiffHasRealLineNumbersContextAndMissingNewlineMarkers() throws {
        let before = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n"
        let edit = try proposal(before, "five\nsix", "FIVE\nSIX\nEXTRA")
        XCTAssertEqual(edit.diff.hunk, "@@ -2,8 +2,9 @@")
        XCTAssertEqual(edit.diff.lines.filter { $0.kind == .removal }.map(\.oldLine), [5, 6])
        XCTAssertEqual(edit.diff.lines.filter { $0.kind == .addition }.map(\.newLine), [5, 6, 7])
        XCTAssertEqual(edit.diff.lines.last?.oldLine, 9)
        XCTAssertEqual(edit.diff.lines.last?.newLine, 10)
        let newline = try proposal("line", "line", "line\n")
        XCTAssertTrue(newline.diff.text.contains("-line\n\\ No newline at end of file\n+line"))
        let empty = try proposal("line\n", "line\n", "")
        XCTAssertEqual(empty.after, "")
        XCTAssertEqual(empty.diff.hunk, "@@ -1,1 +0,0 @@")
    }

    func testCreateDeleteRenameAreInertByteExactProposals() throws {
        let snapshot = try snapshot()
        let create = try ProposedFileEdit(snapshot: snapshot, path: "Sources/new.swift",
                                          originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: "let value = 1\n",
                                          kind: .create)
        XCTAssertEqual(create.after, "let value = 1\n")
        XCTAssertEqual(create.afterSHA, ProposedFileEdit.blobSHA("let value = 1\n"))
        XCTAssertEqual(try create.applying(to: "", snapshot: snapshot,
                                           originalBlobSHA: ProposedFileEdit.emptyBlobSHA), "let value = 1\n")
        XCTAssertThrowsError(try create.applying(to: "x", snapshot: snapshot,
                                                 originalBlobSHA: ProposedFileEdit.emptyBlobSHA))

        let delete = try ProposedFileEdit(snapshot: snapshot, path: "Sources/a.swift",
                                          originalBlobSHA: ProposedFileEdit.blobSHA("old\n"),
                                          before: "old\n", oldText: "", newText: "", kind: .delete)
        XCTAssertEqual(delete.after, "")
        XCTAssertEqual(delete.afterSHA, ProposedFileEdit.emptyBlobSHA)

        let rename = try ProposedFileEdit(snapshot: snapshot, path: "Sources/a.swift",
                                          originalBlobSHA: ProposedFileEdit.blobSHA("old\n"),
                                          before: "old\n", oldText: "", newText: "",
                                          kind: .rename, destinationPath: "Sources/b.swift")
        XCTAssertEqual(rename.after, "old\n")
        XCTAssertEqual(rename.afterPath, "Sources/b.swift")
        XCTAssertEqual(rename.afterSHA, rename.beforeSHA)
        let decoded = try JSONDecoder().decode(ProposedFileEdit.self, from: JSONEncoder().encode(rename))
        XCTAssertEqual(decoded.kind, .rename)
        XCTAssertEqual(decoded.destinationPath, "Sources/b.swift")

        XCTAssertThrowsError(try ProposedFileEdit(snapshot: snapshot, path: "Sources/a.swift",
                                                  originalBlobSHA: ProposedFileEdit.blobSHA("old\n"),
                                                  before: "old\n", oldText: "", newText: "",
                                                  kind: .rename, destinationPath: "Sources/a.swift"))
    }

    func testAppliedCreateRenameChainIsValidatedByHashes() throws {
        let snapshot = try snapshot()
        let create = try ProposedFileEdit(snapshot: snapshot, path: "Sources/new.swift",
                                          originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: "fresh\n", kind: .create)
        let rename = try ProposedFileEdit(snapshot: snapshot, path: "Sources/new.swift",
                                          originalBlobSHA: ProposedFileEdit.blobSHA("fresh\n"),
                                          before: "fresh\n", oldText: "", newText: "",
                                          kind: .rename, destinationPath: "Sources/renamed.swift")
        let messages = [
            ChatMessage(role: "tool", text: "", edit: TaskFileEdit(proposal: create, decision: .applied, appliedOrder: 1)),
            ChatMessage(role: "tool", text: "", edit: TaskFileEdit(proposal: rename, decision: .applied, appliedOrder: 2))
        ]
        XCTAssertTrue(TaskFileEdit.validHistory(messages, snapshot: snapshot))
        let broken = [
            ChatMessage(role: "tool", text: "", edit: TaskFileEdit(proposal: create, decision: .applied, appliedOrder: 1)),
            ChatMessage(role: "tool", text: "", edit: TaskFileEdit(proposal: rename, decision: .applied, appliedOrder: 3))
        ]
        XCTAssertFalse(TaskFileEdit.validHistory(broken, snapshot: snapshot))
    }

    private func history(_ edits: [ProposedFileEdit]) -> [ChatMessage] {
        edits.enumerated().map { index, edit in
            ChatMessage(role: "tool", text: "", edit: TaskFileEdit(
                proposal: edit, decision: .applied, appliedOrder: index + 1))
        }
    }

    func testDeletedAndMovedSourcesCannotReappearWithoutAnExplicitCreate() throws {
        let snapshot = try snapshot()
        let before = "old\n"
        let delete = try ProposedFileEdit(snapshot: snapshot, path: "a", originalBlobSHA: ProposedFileEdit.blobSHA(before),
                                          before: before, oldText: "", newText: "", kind: .delete)
        let replace = try proposal(before, "old", "new", path: "a")
        XCTAssertFalse(TaskFileEdit.validHistory(history([delete, replace]), snapshot: snapshot))
        let secondDelete = try ProposedFileEdit(snapshot: snapshot, path: "a", originalBlobSHA: delete.originalBlobSHA,
                                                before: before, oldText: "", newText: "", kind: .delete)
        XCTAssertFalse(TaskFileEdit.validHistory(history([delete, secondDelete]), snapshot: snapshot))
        let rename = try ProposedFileEdit(snapshot: snapshot, path: "a", originalBlobSHA: delete.originalBlobSHA,
                                          before: before, oldText: "", newText: "", kind: .rename, destinationPath: "b")
        XCTAssertFalse(TaskFileEdit.validHistory(history([rename, replace]), snapshot: snapshot))
        let create = try ProposedFileEdit(snapshot: snapshot, path: "a", originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: before, kind: .create)
        XCTAssertTrue(TaskFileEdit.validHistory(history([delete, create, replace]), snapshot: snapshot))
    }

    func testEmptyFileOperationsAndByteDistinctPathsSurviveHistoryValidation() throws {
        let snapshot = try snapshot()
        let composed = "café.txt", decomposed = "cafe\u{301}.txt"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let create = try ProposedFileEdit(snapshot: snapshot, path: composed,
                                          originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: "", kind: .create)
        let other = try ProposedFileEdit(snapshot: snapshot, path: decomposed,
                                         originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                         before: "", oldText: "", newText: "other", kind: .create)
        XCTAssertTrue(TaskFileEdit.validHistory(history([create, other]), snapshot: snapshot))
        let duplicate = try ProposedFileEdit(snapshot: snapshot, path: composed,
                                             originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                             before: "", oldText: "", newText: "", kind: .create)
        XCTAssertFalse(TaskFileEdit.validHistory(history([create, duplicate]), snapshot: snapshot),
                       "An empty file is present, not an absent path")
        let rename = try ProposedFileEdit(snapshot: snapshot, path: composed,
                                          originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: "", kind: .rename, destinationPath: decomposed)
        let delete = try ProposedFileEdit(snapshot: snapshot, path: decomposed,
                                          originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                          before: "", oldText: "", newText: "", kind: .delete)
        XCTAssertTrue(TaskFileEdit.validHistory(history([create, rename, delete]), snapshot: snapshot))
    }

    func testPathSizeAndDecodedPayloadValidationCannotBeBypassed() throws {
        for path in ["../other", "/outside", "Sources//a", "Sources/./a", "Sources/../a", "a\nb"] {
            XCTAssertThrowsError(try proposal("a", "a", "b", path: path))
        }
        XCTAssertThrowsError(try proposal("a", "a", String(repeating: "b", count: 4097)))
        XCTAssertThrowsError(try proposal("a", "a", "b\0"))
        XCTAssertThrowsError(try proposal(String(repeating: "a", count: 65_537), "a", "b"))
        let valid = try proposal("a\n", "a", "b")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        value["oldText"] = "missing"
        XCTAssertThrowsError(try JSONDecoder().decode(ProposedFileEdit.self, from: JSONSerialization.data(withJSONObject: value)))
        value["oldText"] = "a"; value["path"] = "../outside"
        XCTAssertThrowsError(try JSONDecoder().decode(ProposedFileEdit.self, from: JSONSerialization.data(withJSONObject: value)))
        let longLine = String(repeating: "x", count: 20_000) + "unique"
        XCTAssertThrowsError(try proposal(longLine, "unique", "changed")) { XCTAssertEqual($0 as? FileEditError, .reviewSize) }
    }
}
