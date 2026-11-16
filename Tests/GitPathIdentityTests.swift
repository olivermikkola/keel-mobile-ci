import XCTest
@testable import KeelMobile

final class GitPathIdentityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Entry: Decodable {
            let path: String
            let content: String
            let sha: String
            let size: Int
            let mode: String
            let type: String
        }
        let tree: String
        let decomposedOnlyTree: String
        let leadingMarkChildTree: String
        let leadingMarkRootTree: String
        let entries: [Entry]
    }
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private func setup(onlyDecomposed: Bool = false) throws -> (GitHubRepository, RepositorySnapshot, Fixture) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "git-unicode-paths", withExtension: "json"))
        // Tree/blob SHAs generated independently with Git mktree/hash-object.
        // Both files have identical original bytes, so an edit routed by
        // linguistic equality could otherwise affect the wrong local file.
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let selected = onlyDecomposed ? [fixture.entries[1]] : fixture.entries
        let tree = onlyDecomposed ? fixture.decomposedOnlyTree : fixture.tree
        let snapshot = RepositorySnapshot(repository: try RepositoryID("owner/unicode"), branch: "main",
                                          commit: String(repeating: "a", count: 40), tree: tree)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response: [String: Any]
            if request.url!.path.hasSuffix("/trees/\(tree)") {
                response = ["sha": tree, "truncated": false, "tree": selected.map {
                    ["path": $0.path, "sha": $0.sha, "size": $0.size, "mode": $0.mode, "type": $0.type] as [String: Any]
                }]
            } else {
                let entry = try XCTUnwrap(selected.first(where: { request.url!.path.hasSuffix("/blobs/\($0.sha)") }))
                response = ["sha": entry.sha, "size": entry.size, "encoding": "base64", "content": Data(entry.content.utf8).base64EncodedString()]
            }
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return (try GitHubRepository(repository: snapshot.repository, configuration: config), snapshot, fixture)
    }

    func testByteDistinctGitNamesRemainSeparateThroughListingReadsAndAppliedHistory() async throws {
        let (client, snapshot, fixture) = try setup()
        XCTAssertEqual(fixture.entries[0].path, fixture.entries[1].path, "Swift text equality is canonical, not Git byte identity")
        let entries = try await client.entries(snapshot: snapshot, tree: snapshot.tree)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        let first = fixture.entries[0], second = fixture.entries[1]
        let proposed = try ProposedFileEdit(snapshot: snapshot, path: first.path, originalBlobSHA: first.sha,
                                            before: first.content, oldText: first.content, newText: "first change\n")
        let tools = RepositoryTools(client: client, snapshot: snapshot, appliedEdits: [proposed])
        let changed = try await tools.currentFile(first.path)
        let untouched = try await tools.currentFile(second.path)
        XCTAssertEqual(Data(changed.entry.path.utf8), Data(first.path.utf8))
        XCTAssertEqual(changed.text, "first change\n")
        XCTAssertEqual(Data(untouched.entry.path.utf8), Data(second.path.utf8))
        XCTAssertEqual(untouched.text, second.content, "Approving one byte-distinct path must not alter the other")
        let other = try ProposedFileEdit(snapshot: snapshot, path: second.path, originalBlobSHA: second.sha,
                                        before: second.content, oldText: second.content, newText: "second change\n")
        let records = [TaskFileEdit(proposal: proposed, decision: .applied, appliedOrder: 1),
                       TaskFileEdit(proposal: other, decision: .applied, appliedOrder: 2)]
        let history = records.map { ChatMessage(role: "tool", text: $0.observation, edit: $0) }
        XCTAssertTrue(TaskFileEdit.validHistory(history, snapshot: snapshot))
        let final = RepositoryTools(client: client, snapshot: snapshot, appliedEdits: TaskFileEdit.applied(in: history))
        let finalFirst = try await final.currentFile(first.path), finalSecond = try await final.currentFile(second.path)
        XCTAssertEqual(finalFirst.text, "first change\n"); XCTAssertEqual(finalSecond.text, "second change\n")
        print("Git path proof: actual Git tree with NFC/NFD names, identical original blobs, distinct UI IDs, exact selection and independent approved edits.")
    }

    func testCanonicalAliasIsRejectedWhenOnlyTheOtherSpellingExists() async throws {
        let (client, snapshot, fixture) = try setup(onlyDecomposed: true)
        let tools = RepositoryTools(client: client, snapshot: snapshot)
        do { _ = try await tools.currentFile(fixture.entries[0].path); XCTFail("Never silently normalize a requested Git path") }
        catch { XCTAssertEqual(error as? RepositoryAgentError, .missing) }
        let exact = try await tools.currentFile(fixture.entries[1].path)
        XCTAssertEqual(Data(exact.entry.path.utf8), Data(fixture.entries[1].path.utf8))
    }

    func testBranchSnapshotsAndResponsesPreserveExactRefSpelling() async throws {
        let (client, snapshot, _) = try setup()
        let composed = "é", decomposed = "e\u{301}"
        let left = RepositorySnapshot(repository: snapshot.repository, branch: composed, commit: snapshot.commit, tree: snapshot.tree)
        let right = RepositorySnapshot(repository: snapshot.repository, branch: decomposed, commit: snapshot.commit, tree: snapshot.tree)
        XCTAssertNotEqual(left, right)
        StubProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["name": decomposed, "commit": ["sha": snapshot.commit, "commit": ["tree": ["sha": snapshot.tree]]]]))
        }
        do { _ = try await client.snapshot(branch: composed); XCTFail("Do not bind a task to a differently spelled ref") }
        catch { XCTAssertEqual(error as? RepositoryError, .response) }
    }

    func testLiteralSeparatorsRemainSeparatorsBeforeCombiningMarks() async throws {
        let (client, original, fixture) = try setup()
        let path = "dir/\u{301}file.swift"
        XCTAssertEqual(gitPathComponents(path), ["dir", "\u{301}file.swift"])
        let file = fixture.entries[0]
        let snapshot = RepositorySnapshot(repository: original.repository, branch: original.branch,
                                          commit: original.commit, tree: fixture.leadingMarkRootTree)
        StubProtocol.handler = { request in
            let response: [String: Any]
            if request.url!.path.hasSuffix("/trees/\(fixture.leadingMarkRootTree)") {
                response = ["sha": fixture.leadingMarkRootTree, "truncated": false,
                            "tree": [["path": "dir", "sha": fixture.leadingMarkChildTree, "mode": "040000", "type": "tree"]]]
            } else if request.url!.path.hasSuffix("/trees/\(fixture.leadingMarkChildTree)") {
                response = ["sha": fixture.leadingMarkChildTree, "truncated": false,
                            "tree": [["path": "\u{301}file.swift", "sha": file.sha, "size": file.size, "mode": file.mode, "type": file.type] as [String: Any]]]
            } else {
                XCTAssertTrue(request.url!.path.hasSuffix("/blobs/\(file.sha)"))
                response = ["sha": file.sha, "size": file.size, "encoding": "base64", "content": Data(file.content.utf8).base64EncodedString()]
            }
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let tools = RepositoryTools(client: client, snapshot: snapshot)
        let resolved = try await tools.currentFile(path)
        XCTAssertEqual(resolved.text, file.content)
        let invalid = "<tool_call><function=read_file><parameter=path>/\u{301}file.swift</parameter></function></tool_call>"
        XCTAssertThrowsError(try RepositoryCall.parse(invalid), "Absolute paths remain absolute at the byte level")
    }
}
