import XCTest
@testable import KeelMobile

final class PublishingTests: XCTestCase {
    private let baseCommit = String(repeating: "a", count: 40)
    private let baseTree = String(repeating: "b", count: 40)
    private let otherCommit = String(repeating: "f", count: 40)
    private let blobSHA = String(repeating: "c", count: 40)
    private let treeSHA = String(repeating: "d", count: 40)
    private let commitSHA = String(repeating: "e", count: 40)

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.responseHeaders = nil
        super.tearDown()
    }

    private func client() throws -> GitHubRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try GitHubRepository(repository: RepositoryID("owner/repo"), token: "fixture-token",
                                    configuration: configuration)
    }

    private func snapshot() throws -> RepositorySnapshot {
        RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main",
                           commit: baseCommit, tree: baseTree)
    }

    private func edit(_ snapshot: RepositorySnapshot, old: String = "Hello", new: String = "Hi") throws -> ProposedFileEdit {
        try ProposedFileEdit(snapshot: snapshot, path: "README.md", originalBlobSHA: blobSHA,
                             before: "Hello\n", oldText: old, newText: new)
    }

    private func workflow() -> GitHubRepository.Workflow {
        GitHubRepository.Workflow(id: 123, name: "CI", path: ".github/workflows/ci.yml", state: "active")
    }

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func tree(_ sha: String, _ entries: [(String, String, String, String)]) throws -> Data {
        try json(["sha": sha, "truncated": false,
                  "tree": entries.map { ["path": $0.0, "mode": $0.1, "type": $0.2, "sha": $0.3, "size": 1] as [String: Any] }])
    }
    private func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var collected = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            collected.append(contentsOf: bytes.prefix(count))
        }
        return collected
    }
    private func path(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    func testWorkflowDiscoveryKeepsOnlyActiveYAMLWorkflows() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/actions/workflows")
            return (200, try self.json([
                "total_count": 3,
                "workflows": [
                    ["id": 1, "name": "CI", "path": ".github/workflows/ci.yml", "state": "active"],
                    ["id": 2, "name": "Disabled", "path": ".github/workflows/off.yml", "state": "disabled_manually"],
                    ["id": 3, "name": "Not YAML", "path": "README.md", "state": "active"]
                ]
            ]))
        }
        let workflows = try await client().workflows()
        XCTAssertEqual(workflows.map(\.id), [1])
    }

    func testPublishPushesReviewedContentAndDispatchesChosenWorkflow() async throws {
        let snapshot = try snapshot()
        var requests: [String] = []
        StubProtocol.handler = { request in
            let path = self.path(request)
            requests.append("\(request.httpMethod ?? "") \(path)")
            if path.hasSuffix("/branches/keel%2Ftask-12345678") { return (404, Data()) }
            if path.hasSuffix("/git/blobs") {
                XCTAssertEqual(request.httpMethod, "POST")
                return (201, try self.json(["sha": self.blobSHA]))
            }
            if path.hasSuffix("/git/trees/\(self.baseTree)") {
                return (200, try self.tree(self.baseTree, [("README.md", "100644", "blob", self.blobSHA)]))
            }
            if path.hasSuffix("/git/trees") {
                return (201, try self.json(["sha": self.treeSHA]))
            }
            if path.hasSuffix("/git/commits") {
                return (201, try self.json(["sha": self.commitSHA]))
            }
            if path.hasSuffix("/git/refs") {
                XCTAssertEqual(request.httpMethod, "POST")
                return (201, try self.json(["ref": "refs/heads/keel/task-12345678"]))
            }
            if path.hasSuffix("/actions/workflows/123/dispatches") {
                XCTAssertEqual(request.httpMethod, "POST")
                return (204, Data())
            }
            XCTFail("Unexpected request: \(request)")
            return (500, Data())
        }
        let state = try await PublishingFlow.publish(
            client: try client(), snapshot: snapshot, edits: [try edit(snapshot)],
            branch: "keel/task-12345678", previous: nil, workflow: workflow(),
            commitMessage: "Test publish")
        XCTAssertEqual(state.commit, commitSHA)
        XCTAssertEqual(state.paths, ["README.md"])
        XCTAssertEqual(state.stage, .pushed)
        XCTAssertTrue(requests.contains("POST /repos/owner/repo/git/refs"))
    }

    func testPublishReplaysDeletesAndRenamesAndKeepsBaseFileModes() async throws {
        let snapshot = try snapshot()
        let scriptsTree = String(repeating: "9", count: 40)
        let edits = [
            try ProposedFileEdit(snapshot: snapshot, path: "scripts/run.sh", originalBlobSHA: blobSHA,
                                 before: "echo a\n", oldText: "a", newText: "b"),
            try ProposedFileEdit(snapshot: snapshot, path: "README.md", originalBlobSHA: blobSHA,
                                 before: "Hello\n", oldText: "", newText: "", kind: .delete),
            try ProposedFileEdit(snapshot: snapshot, path: "old.txt", originalBlobSHA: blobSHA,
                                 before: "keep\n", oldText: "", newText: "", kind: .rename,
                                 destinationPath: "new.txt"),
            try ProposedFileEdit(snapshot: snapshot, path: "tmp.txt", originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                 before: "", oldText: "", newText: "scratch\n", kind: .create),
            try ProposedFileEdit(snapshot: snapshot, path: "tmp.txt", originalBlobSHA: ProposedFileEdit.blobSHA("scratch\n"),
                                 before: "scratch\n", oldText: "", newText: "", kind: .delete)
        ]
        var treeBody: [[String: Any]] = []
        StubProtocol.handler = { request in
            let path = self.path(request)
            if path.hasSuffix("/branches/keel%2Ftask-12345678") { return (404, Data()) }
            if path.hasSuffix("/git/trees/\(self.baseTree)") {
                return (200, try self.tree(self.baseTree, [
                    ("README.md", "100644", "blob", self.blobSHA), ("old.txt", "100755", "blob", self.blobSHA),
                    ("scripts", "040000", "tree", scriptsTree)]))
            }
            if path.hasSuffix("/git/trees/\(scriptsTree)") {
                return (200, try self.tree(scriptsTree, [("run.sh", "100755", "blob", self.blobSHA)]))
            }
            if path.hasSuffix("/git/blobs") { return (201, try self.json(["sha": self.blobSHA])) }
            if path.hasSuffix("/git/trees") {
                let object = try JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any]
                XCTAssertEqual(object?["base_tree"] as? String, self.baseTree)
                treeBody = object?["tree"] as? [[String: Any]] ?? []
                return (201, try self.json(["sha": self.treeSHA]))
            }
            if path.hasSuffix("/git/commits") { return (201, try self.json(["sha": self.commitSHA])) }
            if path.hasSuffix("/git/refs") { return (201, try self.json(["ref": "refs/heads/keel/task-12345678"])) }
            XCTFail("Unexpected request: \(request)")
            return (500, Data())
        }
        let state = try await PublishingFlow.prepare(
            client: try client(), snapshot: snapshot, edits: edits, branch: "keel/task-12345678",
            previous: nil, workflow: workflow(), commitMessage: "Operations")

        let byPath = Dictionary(uniqueKeysWithValues: treeBody.map { ($0["path"] as! String, $0) })
        XCTAssertEqual(byPath.keys.sorted(), ["README.md", "new.txt", "old.txt", "scripts/run.sh"])
        XCTAssertTrue(byPath["README.md"]?["sha"] is NSNull, "A delete must send an explicit null SHA")
        XCTAssertTrue(byPath["old.txt"]?["sha"] is NSNull, "A rename must remove its source")
        XCTAssertEqual(byPath["new.txt"]?["sha"] as? String, blobSHA)
        XCTAssertEqual(byPath["new.txt"]?["mode"] as? String, "100755", "A rename keeps the source's mode")
        XCTAssertEqual(byPath["scripts/run.sh"]?["mode"] as? String, "100755", "An edit keeps the base mode")
        XCTAssertEqual(state.paths, ["README.md", "new.txt", "old.txt", "scripts/run.sh"])
        XCTAssertEqual(state.contentIdentity?["README.md"], PublishPlan.removedIdentity)
        XCTAssertEqual(state.contentIdentity?["new.txt"], ProposedFileEdit.blobSHA("keep\n"))
        XCTAssertTrue(state.isValid(for: snapshot))
        XCTAssertTrue(state.matches(edits: edits, snapshot: snapshot))
        XCTAssertFalse(state.matches(edits: Array(edits.dropLast()), snapshot: snapshot),
                       "Leaving the created file in place is different published content")
    }

    func testPublishRefusesATaskWhoseOnlyChangeCancelsOut() async throws {
        let snapshot = try snapshot()
        let edits = [
            try ProposedFileEdit(snapshot: snapshot, path: "tmp.txt", originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                 before: "", oldText: "", newText: "x", kind: .create),
            try ProposedFileEdit(snapshot: snapshot, path: "tmp.txt", originalBlobSHA: ProposedFileEdit.blobSHA("x"),
                                 before: "x", oldText: "", newText: "", kind: .delete)
        ]
        XCTAssertEqual(PublishingFlow.finalContent(edits).paths, [])
        StubProtocol.handler = { request in
            XCTFail("Nothing may be written for an empty change set: \(request)")
            return (500, Data())
        }
        do {
            _ = try await PublishingFlow.prepare(
                client: try client(), snapshot: snapshot, edits: edits, branch: "keel/task-12345678",
                previous: nil, workflow: workflow(), commitMessage: "Nothing")
            XCTFail("Must refuse an empty change set")
        } catch let error as PublishError {
            XCTAssertEqual(error, .noAppliedEdits)
        }
    }

    func testPublishRefusesAnExistingOrMovedTaskBranch() async throws {
        let snapshot = try snapshot()
        StubProtocol.handler = { request in
            if self.path(request).hasSuffix("/branches/keel%2Ftask-12345678") {
                return (200, try self.json(["name": "keel/task-12345678",
                                            "commit": ["sha": self.otherCommit,
                                                       "commit": ["tree": ["sha": self.baseTree]]]]))
            }
            XCTFail("No write may happen after a branch conflict")
            return (500, Data())
        }
        do {
            _ = try await PublishingFlow.publish(
                client: try client(), snapshot: snapshot, edits: [try edit(snapshot)],
                branch: "keel/task-12345678", previous: nil, workflow: workflow(),
                commitMessage: "Test publish")
            XCTFail("Must refuse an existing task branch")
        } catch let error as PublishError {
            XCTAssertEqual(error, .branchExists)
        }
    }

    func testUpdateBranchDoesNotForceOverANewerHead() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try self.json(["object": ["sha": self.otherCommit]]))
        }
        let moved = try await client().updateBranch(name: "keel/task-12345678",
                                                    commit: self.commitSHA, expected: self.baseCommit)
        XCTAssertFalse(moved)
    }

    func testRunLookupRequiresExactSHAAndWorkflow() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/actions/workflows/123/runs")
            return (200, try self.json([
                "total_count": 3,
                "workflow_runs": [
                    ["id": 1, "status": "completed", "conclusion": "success",
                     "head_sha": self.otherCommit, "workflow_id": 123],
                    ["id": 2, "status": "completed", "conclusion": "success",
                     "head_sha": self.commitSHA, "workflow_id": 999],
                    ["id": 3, "status": "completed", "conclusion": "success",
                     "head_sha": self.commitSHA, "workflow_id": 123,
                     "html_url": "https://github.com/owner/repo/actions/runs/3"]
                ]
            ]))
        }
        let run = try await client().findWorkflowRun(workflowID: 123, branch: "keel/task-12345678",
                                                     headSHA: self.commitSHA)
        XCTAssertEqual(run?.id, 3)
        XCTAssertEqual(run?.head_sha, self.commitSHA)
    }

    func testPullRequestIsGatedOnExactGreenRunAndIsIdempotent() async throws {
        let snapshot = try snapshot()
        var state = PublishState(branch: "keel/task-12345678", baseCommit: baseCommit, baseTree: baseTree,
                                 workflowID: 123, workflowName: "CI", paths: ["README.md"],
                                 commit: commitSHA, runID: nil, runURL: nil, conclusion: nil,
                                 prURL: nil, updatedAt: Date())
        do {
            _ = try await PublishingFlow.pullRequest(client: try client(), state: state,
                                                     baseBranch: "main", title: "Test")
            XCTFail("Must not open a PR before a run exists")
        } catch let error as PublishError {
            XCTAssertTrue(error.localizedDescription.contains("CI"))
        }

        state.runID = 9
        state.runURL = "https://github.com/owner/repo/actions/runs/9"
        state.conclusion = "failure"
        do {
            _ = try await PublishingFlow.pullRequest(client: try client(), state: state,
                                                     baseBranch: "main", title: "Test")
            XCTFail("Must not open a PR for a failed run")
        } catch let error as PublishError {
            XCTAssertTrue(error.localizedDescription.contains("CI"))
        }

        state.conclusion = "success"
        state.contentIdentity = ["README.md": ProposedFileEdit.blobSHA("Hi\n")]
        StubProtocol.handler = { request in
            if request.url?.path == "/repos/owner/repo/actions/runs/9" {
                return (200, try self.json(["id": 9, "status": "completed", "conclusion": "success",
                                           "head_sha": self.commitSHA, "workflow_id": 123,
                                           "html_url": "https://github.com/owner/repo/actions/runs/9"]))
            }
            if self.path(request).hasSuffix("/branches/keel%2Ftask-12345678") {
                return (200, try self.json(["name": "keel/task-12345678",
                                           "commit": ["sha": self.commitSHA,
                                                      "commit": ["tree": ["sha": self.treeSHA]]]]))
            }
            if request.httpMethod == "GET" && request.url?.path == "/repos/owner/repo/pulls" {
                return (200, try self.json([]))
            }
            if request.httpMethod == "POST" && request.url?.path == "/repos/owner/repo/pulls" {
                return (201, try self.json(["number": 7, "title": "Test",
                                            "html_url": "https://github.com/owner/repo/pull/7"]))
            }
            XCTFail("Unexpected request: \(request)")
            return (500, Data())
        }
        let opened = try await PublishingFlow.pullRequest(client: try client(), state: state,
                                                          baseBranch: "main", title: "Test")
        XCTAssertEqual(opened.prURL, "https://github.com/owner/repo/pull/7")

        StubProtocol.handler = { request in
            XCTFail("A saved PR must return without another request: \(request)")
            return (500, Data())
        }
        let again = try await PublishingFlow.pullRequest(client: try client(), state: opened,
                                                         baseBranch: "main", title: "Test")
        XCTAssertEqual(again.prURL, opened.prURL)
    }

    func testPublishStateRejectsPullRequestWithoutGreenCommit() throws {
        let snapshot = try snapshot()
        let state = PublishState(branch: "keel/task-12345678", baseCommit: baseCommit, baseTree: baseTree,
                                 workflowID: 123, workflowName: "CI", paths: ["README.md"],
                                 commit: commitSHA, runID: 9,
                                 runURL: "https://github.com/owner/repo/actions/runs/9",
                                 conclusion: "failure",
                                 prURL: "https://github.com/owner/repo/pull/7",
                                 updatedAt: Date())
        XCTAssertFalse(state.isValid(for: snapshot))
        XCTAssertFalse(state.canOpenPullRequest)
    }

    func testPublishStatePersistsOnlyExactCommitIdentity() throws {
        let snapshot = try snapshot()
        let state = PublishState(branch: "keel/task-12345678", baseCommit: baseCommit, baseTree: baseTree,
                                 workflowID: 123, workflowName: "CI", paths: ["README.md"],
                                 commit: commitSHA, runID: 9,
                                 runURL: "https://github.com/owner/repo/actions/runs/9",
                                 conclusion: "success", prURL: nil, updatedAt: Date(),
                                 contentIdentity: ["README.md": ProposedFileEdit.blobSHA("Hi\n")])
        XCTAssertTrue(state.isValid(for: snapshot))
        XCTAssertTrue(state.canOpenPullRequest)
        XCTAssertEqual(state.stage, .ciPassed)
        XCTAssertEqual(try JSONDecoder().decode(PublishState.self,
                                                from: JSONEncoder().encode(state)), state)
    }

    private func greenState() -> PublishState {
        PublishState(branch: "keel/task-12345678", baseCommit: baseCommit, baseTree: baseTree,
                     workflowID: 123, workflowName: "CI", paths: ["README.md"],
                     commit: commitSHA, runID: 9,
                     runURL: "https://github.com/owner/repo/actions/runs/9",
                     conclusion: "success", prURL: nil, updatedAt: Date(),
                     contentIdentity: ["README.md": ProposedFileEdit.blobSHA("Hi\n")])
    }

    func testRepublishedContentIdentityIncludesBytesAndSurvivesRelaunch() throws {
        let snapshot = try snapshot()
        let state = try JSONDecoder().decode(PublishState.self, from: JSONEncoder().encode(greenState()))
        XCTAssertTrue(state.matches(edits: [try edit(snapshot)], snapshot: snapshot))
        XCTAssertFalse(state.matches(edits: [try edit(snapshot, new: "Bye")], snapshot: snapshot),
                       "A second edit to the same path must invalidate the published review")
        var legacy = state
        legacy.contentIdentity = nil
        XCTAssertTrue(legacy.isValid(for: snapshot), "Keep old history readable")
        XCTAssertFalse(legacy.matches(edits: [try edit(snapshot)], snapshot: snapshot))
        XCTAssertFalse(legacy.canOpenPullRequest, "Missing review identity cannot authorize a PR")
    }

    func testRestartedRunClearsSavedSuccessAndPreventsPullRequest() async throws {
        let state = greenState()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/actions/runs/9")
            return (200, try self.json(["id": 9, "status": "in_progress",
                                       "head_sha": self.commitSHA, "workflow_id": 123,
                                       "html_url": "https://github.com/owner/repo/actions/runs/9"]))
        }
        let refreshed = try await PublishingFlow.refresh(client: try client(), state: state)
        XCTAssertNil(refreshed.conclusion)
        XCTAssertFalse(refreshed.canOpenPullRequest)
        do {
            _ = try await PublishingFlow.pullRequest(client: try client(), state: state,
                                                     baseBranch: "main", title: "Test")
            XCTFail("Cached green state must not bypass a restarted run")
        } catch let error as PublishError {
            guard case .ciNotGreen = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRefreshRefusesMissingWorkflowWrongRunAndWrongCommitIdentity() async throws {
        let state = greenState()
        var responses: [[String: Any]] = []
        let valid: [String: Any] = ["id": 9, "status": "completed", "conclusion": "success",
                                    "head_sha": commitSHA, "workflow_id": 123]
        var missing = valid; missing.removeValue(forKey: "workflow_id"); responses.append(missing)
        var wrongWorkflow = valid; wrongWorkflow["workflow_id"] = 999; responses.append(wrongWorkflow)
        var wrongRun = valid; wrongRun["id"] = 10; responses.append(wrongRun)
        var wrongCommit = valid; wrongCommit["head_sha"] = otherCommit; responses.append(wrongCommit)
        for response in responses {
            StubProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, try self.json(response))
            }
            do {
                _ = try await PublishingFlow.refresh(client: try client(), state: state)
                XCTFail("Unproven run identity must fail closed")
            } catch let error as PublishError { XCTAssertEqual(error, .response) }
        }
    }

    func testPullRequestRefusesMovedHeadEvenWithExactGreenRun() async throws {
        let state = greenState()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "A moved branch may not create a PR")
            if request.url?.path == "/repos/owner/repo/actions/runs/9" {
                return (200, try self.json(["id": 9, "status": "completed", "conclusion": "success",
                                           "head_sha": self.commitSHA, "workflow_id": 123,
                                           "html_url": "https://github.com/owner/repo/actions/runs/9"]))
            }
            XCTAssertTrue(self.path(request).hasSuffix("/branches/keel%2Ftask-12345678"))
            return (200, try self.json(["name": "keel/task-12345678",
                                       "commit": ["sha": self.otherCommit,
                                                  "commit": ["tree": ["sha": self.baseTree]]]]))
        }
        do {
            _ = try await PublishingFlow.pullRequest(client: try client(), state: state,
                                                     baseBranch: "main", title: "Test")
            XCTFail("A branch that moved after CI may not be published")
        } catch let error as PublishError { XCTAssertEqual(error, .branchMoved) }
    }
}
