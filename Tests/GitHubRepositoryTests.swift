import XCTest
import CryptoKit
@testable import KeelMobile

final class GitHubRepositoryTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private func client() throws -> GitHubRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try GitHubRepository(repository: RepositoryID("owner/repo"), token: "fixture-token", configuration: config)
    }
    private func snapshot() throws -> RepositorySnapshot {
        RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "feature/one", commit: commit, tree: tree)
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func blob(_ data: Data, mode: String = "100644") -> RepositoryEntry {
        var object = Data("blob \(data.count)\0".utf8); object.append(data)
        let sha = Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
        return RepositoryEntry(path: "README.md", mode: mode, type: "blob", sha: sha, size: data.count)
    }

    func testRepositoryAddressesCannotCarryCredentialsOrChangeHosts() throws {
        XCTAssertEqual(try RepositoryID("https://github.com/owner/repo.git/").fullName, "owner/repo")
        for input in ["https://secret@github.com/owner/repo", "https://github.com/owner/repo?token=secret",
                      "https://github.com/owner/repo#secret", "https://elsewhere.test/owner/repo",
                      "http://github.com/owner/repo", "owner/../repo", "owner/repo/extra", "../repo", "owner/%2Frepo"] {
            XCTAssertThrowsError(try RepositoryID(input))
        }
    }

    func testBranchSnapshotIsPinnedAndBranchSlashesStayInOneComponent() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                           "/repos/owner/repo/branches/feature%2Fone")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertNil(request.url?.query)
            return (200, try self.json(["name": "feature/one", "commit": ["sha": self.commit, "commit": ["tree": ["sha": self.tree]]]]))
        }
        let version = try await client().snapshot(branch: "feature/one")
        XCTAssertEqual(version.commit, commit)
        XCTAssertEqual(version.tree, tree)
    }

    func testDefaultBranchAndImmutableDirectoryTraversal() async throws {
        let api = try client()
        var requests = [String]()
        StubProtocol.handler = { request in
            let path = request.url!.path; requests.append(path)
            if path == "/repos/owner/repo" { return (200, try self.json(["default_branch": "main"])) }
            if path.hasSuffix("/branches/main") {
                return (200, try self.json(["name": "main", "commit": ["sha": self.commit, "commit": ["tree": ["sha": self.tree]]]]))
            }
            XCTAssertEqual(path, "/repos/owner/repo/git/trees/\(self.tree)")
            XCTAssertNil(request.url?.query)
            return (200, try self.json(["sha": self.tree, "truncated": false, "tree": [
                ["path": "README.md", "sha": self.commit, "type": "blob", "mode": "100644", "size": 3],
                ["path": "Sources", "sha": self.tree, "type": "tree", "mode": "040000"]
            ]]))
        }
        let version = try await api.snapshot(branch: "")
        let entries = try await api.entries(snapshot: version, tree: version.tree)
        XCTAssertEqual(entries.map(\.path), ["Sources", "README.md"])
        XCTAssertEqual(requests.count, 3)
    }

    func testTruncatedOrMismatchedTreesFailClosed() async throws {
        for truncated in [false, true] {
            StubProtocol.handler = { _ in (200, try self.json(["sha": self.commit, "truncated": truncated, "tree": []])) }
            do {
                _ = try await client().entries(snapshot: snapshot(), tree: tree)
                XCTFail("Must not present incomplete or mismatched directories")
            } catch { XCTAssertEqual(error as? RepositoryError, truncated ? .tooLarge : .response) }
        }
    }

    func testBlobTextIsVerifiedAgainstObjectHashAndSize() async throws {
        let data = Data("Hello from GitHub — 🛶\n".utf8)
        let entry = blob(data)
        for corrupt in [false, true] {
            StubProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/blobs/\(entry.sha)")
                let body = corrupt ? Data(repeating: 65, count: data.count) : data
                return (200, try self.json(["sha": entry.sha, "size": data.count, "encoding": "base64", "content": body.base64EncodedString() + "\n"]))
            }
            do {
                let text = try await client().read(snapshot: snapshot(), entry: entry)
                XCTAssertFalse(corrupt)
                XCTAssertEqual(text, String(data: data, encoding: .utf8))
            } catch {
                XCTAssertTrue(corrupt)
                XCTAssertEqual(error as? RepositoryError, .response)
            }
        }
    }

    func testRepeatedVerifiedBlobReadUsesTheBoundedContentCache() async throws {
        let data = Data("cached file\n".utf8)
        let entry = blob(data)
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/blobs/\(entry.sha)")
            return (200, try self.json(["sha": entry.sha, "size": data.count,
                                        "encoding": "base64", "content": data.base64EncodedString()]))
        }
        let api = try client()
        let first = try await api.read(snapshot: snapshot(), entry: entry)
        let second = try await api.read(snapshot: snapshot(), entry: entry)
        XCTAssertEqual(first, "cached file\n")
        XCTAssertEqual(second, "cached file\n")
        XCTAssertEqual(requests, 1, "A verified content-addressed blob must be reused")
    }

    func testOversizedAPIResponseIsRejectedBeforeDecoding() async throws {
        StubProtocol.handler = { _ in (200, Data(repeating: 65, count: 300_000)) }
        do {
            _ = try await client().snapshot(branch: "main")
            XCTFail("Must reject a response larger than the endpoint limit")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .tooLarge)
        }
    }

    func testUnsupportedAndOversizedEntriesNeverFetchAFile() async throws {
        StubProtocol.handler = { _ in XCTFail("Must reject the entry before any network request"); return (500, Data()) }
        let entries = [blob(Data(), mode: "120000"),
                       RepositoryEntry(path: "large.txt", mode: "100644", type: "blob", sha: commit, size: GitHubRepository.fileLimit + 1)]
        for entry in entries {
            do { _ = try await client().read(snapshot: snapshot(), entry: entry); XCTFail("Must reject unsupported content") }
            catch { XCTAssertEqual(error as? RepositoryError, entry.mode == "120000" ? .unsupported : .tooLarge) }
        }
    }

    func testStreamingResponseLimitAndHTTPPrivacy() async throws {
        StubProtocol.handler = { _ in (200, Data(repeating: 65, count: 262_145)) }
        do { _ = try await client().snapshot(branch: "main"); XCTFail("Must bound response memory") }
        catch { XCTAssertEqual(error as? RepositoryError, .tooLarge) }
        StubProtocol.handler = { _ in (401, Data("private server diagnostics".utf8)) }
        do { _ = try await client().snapshot(branch: "main"); XCTFail("Must reject authentication failure") }
        catch {
            XCTAssertEqual(error as? RepositoryError, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("private server diagnostics"))
        }
    }

    func testRateLimitExposesRetryTimeWithoutServerDiagnostics() async throws {
        let reset = Int(Date().timeIntervalSince1970) + 3600
        StubProtocol.responseHeaders = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(reset)]
        StubProtocol.handler = { _ in (403, Data("private diagnostics".utf8)) }
        do { _ = try await client().snapshot(branch: "main"); XCTFail("Must report the rate limit") }
        catch {
            XCTAssertEqual(error as? RepositoryError, .rateLimited(Date(timeIntervalSince1970: Double(reset))))
            XCTAssertFalse(error.localizedDescription.contains("private diagnostics"))
        }
    }

    func testRealGitHubKeychainIsSeparateFromGatewayCredential() throws {
        let account = UUID().uuidString
        let gateway = "https://\(account).example"
        defer { try? GitHubCredential.remove(account: account); try? PairingKeychain.remove(address: gateway) }
        XCTAssertEqual(try GitHubCredential.load(account: account), "")
        try PairingKeychain.save(token: "gateway-fixture", address: gateway)
        try GitHubCredential.save("github-fixture", account: account)
        XCTAssertTrue(GitHubCredential.contains(account: account))
        XCTAssertEqual(try GitHubCredential.load(account: account), "github-fixture")
        try GitHubCredential.save("updated-fixture", account: account)
        XCTAssertEqual(try GitHubCredential.load(account: account), "updated-fixture")
        try GitHubCredential.remove(account: account)
        XCTAssertFalse(GitHubCredential.contains(account: account))
        XCTAssertEqual(PairingKeychain.load(address: gateway), "gateway-fixture")
    }

    func testCreateBlobSendsAuthenticatedPost() async throws {
        let expectedSHA = String(repeating: "c", count: 40)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/blobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return (201, try self.json(["sha": expectedSHA]))
        }
        let sha = try await client().createBlob(content: "print('hello')\n")
        XCTAssertEqual(sha, expectedSHA)
    }

    func testCreateTreeAndCommitPipeline() async throws {
        let treeSHA = String(repeating: "d", count: 40)
        let commitSHA = String(repeating: "e", count: 40)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            if request.url?.path == "/repos/owner/repo/git/trees" {
                return (201, try self.json(["sha": treeSHA]))
            }
            if request.url?.path == "/repos/owner/repo/git/commits" {
                return (201, try self.json(["sha": commitSHA]))
            }
            XCTFail("Unexpected path: \(request.url?.path ?? "")")
            return (500, Data())
        }
        let api = try client()
        let createdTree = try await api.createTree(baseTree: self.tree, entries: [
            GitHubRepository.TreeEntryItem(path: "main.py", sha: self.commit)
        ])
        XCTAssertEqual(createdTree, treeSHA)
        let createdCommit = try await api.createCommit(message: "Fix bug", tree: createdTree, parents: [self.commit])
        XCTAssertEqual(createdCommit, commitSHA)
    }

    func testDispatchWorkflowAndPollRun() async throws {
        let runID = 42
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" && request.url?.path == "/repos/owner/repo/actions/workflows/ci.yml/dispatches" {
                return (204, Data())
            }
            if request.httpMethod == "GET" && request.url?.path == "/repos/owner/repo/actions/runs" {
                XCTAssertTrue((request.url?.query?.contains("branch=feature/one") ?? false) || (request.url?.query?.contains("branch=feature%2Fone") ?? false))
                return (200, try self.json([
                    "total_count": 1,
                    "workflow_runs": [
                        ["id": runID, "name": "CI", "status": "completed", "conclusion": "failure", "html_url": "https://github.com/owner/repo/actions/runs/42"]
                    ]
                ]))
            }
            if request.httpMethod == "GET" && request.url?.path == "/repos/owner/repo/actions/runs/42/jobs" {
                return (200, try self.json([
                    "jobs": [
                        ["id": 101, "name": "test", "conclusion": "failure"]
                    ]
                ]))
            }
            if request.httpMethod == "GET" && request.url?.path == "/repos/owner/repo/actions/jobs/101/logs" {
                return (200, Data("=== TEST FAILED ===\nAssertionError: expected 1 got 0\n".utf8))
            }
            XCTFail("Unexpected request: \(request)")
            return (500, Data())
        }
        let api = try client()
        try await api.dispatchWorkflow(workflowID: "ci.yml", ref: "feature/one")
        let run = try await api.latestWorkflowRun(branch: "feature/one")
        XCTAssertEqual(run?.id, runID)
        XCTAssertTrue(run?.isCompleted == true)
        XCTAssertTrue(run?.isFailure == true)
        let logs = try await api.fetchFailedJobLogs(runID: runID)
        XCTAssertTrue(logs.contains("AssertionError"))
    }

    func testFailedMatrixJobsAreCollectedAcrossPages() async throws {
        var logIDs = Set<Int>()
        var pages: [Int] = []
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/runs/42/jobs") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "filter" }?.value, "latest")
                XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "100")
                let page = Int(query.first { $0.name == "page" }!.value!)!; pages.append(page)
                let jobs: [[String: Any]] = page == 1 ? (1...100).map {
                    ["id": $0, "name": "matrix-\($0)", "conclusion": $0 == 1 ? "failure" : "success"]
                } : [["id": 101, "name": "matrix-101", "conclusion": "failure"]]
                return (200, try self.json(["total_count": 101, "jobs": jobs]))
            }
            if path.hasSuffix("/jobs/1/logs") { logIDs.insert(1); return (200, Data("first matrix error".utf8)) }
            if path.hasSuffix("/jobs/101/logs") { logIDs.insert(101); return (200, Data("second matrix error".utf8)) }
            XCTFail("Unexpected request: \(request)"); return (500, Data())
        }
        let logs = try await client().fetchFailedJobLogs(runID: 42)
        XCTAssertEqual(pages, [1, 2]); XCTAssertEqual(logIDs, [1, 101])
        XCTAssertTrue(logs.contains("first matrix error")); XCTAssertTrue(logs.contains("second matrix error"))
    }

    func testFailedStepLogsUseCredentialFreeSignedDownload() async throws {
        var downloadedStep = false
        StubProtocol.handler = { request in
            StubProtocol.responseHeaders = nil
            if request.url?.path.hasSuffix("/runs/42/jobs") == true {
                return (200, try self.json(["total_count": 1, "jobs": [
                    ["id": 101, "name": "iOS tests", "conclusion": "failure", "steps": [
                        ["number": 1, "name": "Checkout", "conclusion": "success"],
                        ["number": 2, "name": "Test", "conclusion": "failure"]
                    ]]
                ]]))
            }
            if request.url?.host == "api.github.com" && request.url?.path.hasSuffix("/steps/2/logs") == true {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                StubProtocol.responseHeaders = ["Location": "https://logs.example.test/step?sig=fixture-signed-url"]
                return (302, Data())
            }
            if request.url?.host == "logs.example.test" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                downloadedStep = true
                return (200, Data("Assertion failed; fixture-token must never appear in the result".utf8))
            }
            XCTFail("Whole-job logs must not be fetched when failed-step logs work: \(request)")
            return (500, Data())
        }
        let logs = try await client().fetchFailedJobLogs(runID: 42)
        XCTAssertTrue(downloadedStep); XCTAssertTrue(logs.contains("Step 2: Test"))
        XCTAssertTrue(logs.contains("Assertion failed")); XCTAssertTrue(logs.contains("[redacted]"))
        XCTAssertFalse(logs.contains("fixture-token")); XCTAssertFalse(logs.contains("fixture-signed-url"))
    }

    func testUnavailableStepEndpointFallsBackToJobOnce() async throws {
        var jobReads = 0
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/runs/42/jobs") {
                return (200, try self.json(["total_count": 1, "jobs": [[
                    "id": 101, "name": "Tests", "conclusion": "failure", "steps": [
                        ["number": 2, "name": "Test", "conclusion": "failure"],
                        ["number": 3, "name": "Cleanup", "conclusion": "failure"]
                    ]
                ]]]))
            }
            if path.hasSuffix("/steps/2/logs") { return (404, Data("private upstream error".utf8)) }
            if path.hasSuffix("/jobs/101/logs") { jobReads += 1; return (200, Data("full job failure".utf8)) }
            XCTFail("No second fallback should happen: \(request)"); return (500, Data())
        }
        let logs = try await client().fetchFailedJobLogs(runID: 42)
        XCTAssertEqual(jobReads, 1); XCTAssertTrue(logs.contains("Job log:"))
        XCTAssertTrue(logs.contains("full job failure")); XCTAssertFalse(logs.contains("private upstream error"))
    }

    func testLogRedirectRejectsUnsafeURLsAndChecksDownloadStatus() async throws {
        for location in ["http://logs.example.test/plain", "https://user:secret@logs.example.test/plain",
                         "https://logs.example.test:8080/plain", "https://logs.example.test/plain#fragment",
                         "https://logs.example.test/denied"] {
            var signedRequests = 0
            StubProtocol.handler = { request in
                StubProtocol.responseHeaders = nil
                if request.url?.path.hasSuffix("/runs/42/jobs") == true {
                    return (200, try self.json(["total_count": 1, "jobs": [["id": 101, "name": "Test", "conclusion": "failure"]]]))
                }
                if request.url?.host == "api.github.com" {
                    StubProtocol.responseHeaders = ["Location": location]; return (302, Data())
                }
                signedRequests += 1
                XCTAssertEqual(location, "https://logs.example.test/denied")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (403, Data("private error body should not become a log".utf8))
            }
            let logs = try await client().fetchFailedJobLogs(runID: 42)
            XCTAssertTrue(logs.contains("logs unavailable")); XCTAssertFalse(logs.contains("private error body"))
            XCTAssertEqual(signedRequests, location.hasSuffix("/denied") ? 1 : 0)
        }
    }

    func testLogAndFailedJobBoundsAreExplicit() async throws {
        var downloads = 0
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/runs/42/jobs") == true {
                return (200, try self.json(["total_count": 10, "jobs": (1...10).map {
                    ["id": $0, "name": "matrix-\($0)", "conclusion": "failure"]
                }]))
            }
            downloads += 1
            return (200, Data(repeating: 65, count: 140_000))
        }
        let logs = try await client().fetchFailedJobLogs(runID: 42)
        XCTAssertEqual(downloads, 8)
        XCTAssertTrue(logs.contains("2 additional unsuccessful jobs omitted"))
        XCTAssertTrue(logs.contains("truncated")); XCTAssertLessThan(logs.utf8.count, 65_536)
    }

    func testCreatePullRequestSendsPayload() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/pulls")
            return (201, try self.json([
                "number": 7,
                "title": "Fix bug",
                "html_url": "https://github.com/owner/repo/pull/7"
            ]))
        }
        let pr = try await client().createPullRequest(title: "Fix bug", head: "feature/one", base: "main", body: "Automated fix by Keel Director")
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.html_url, "https://github.com/owner/repo/pull/7")
    }

    func testFullTreeReturnsRecursiveEntriesAndRefusesTruncatedOrMismatched() async throws {
        let treeSHA = ArchiveFixture.tree
        let snap = RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main", commit: ArchiveFixture.commit, tree: treeSHA)
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/git/trees/\(treeSHA)") == true)
            XCTAssertEqual(request.url?.query, "recursive=1")
            return (200, try self.json([
                "sha": treeSHA, "truncated": false,
                "tree": ArchiveFixture.entries.map { entry -> [String: Any] in
                    var row: [String: Any] = ["path": entry.path, "mode": entry.mode, "type": entry.type, "sha": entry.sha]
                    if let size = entry.size { row["size"] = size }
                    return row
                }
            ]))
        }
        let entries = try await client().fullTree(snapshot: snap)
        XCTAssertEqual(entries.count, ArchiveFixture.entries.count)

        StubProtocol.handler = { _ in (200, try self.json(["sha": treeSHA, "truncated": true, "tree": []])) }
        do { _ = try await client().fullTree(snapshot: snap); XCTFail("Must refuse truncated tree") }
        catch { XCTAssertEqual(error as? RepositoryError, .tooLarge) }

        StubProtocol.handler = { _ in (200, try self.json(["sha": String(repeating: "c", count: 40), "truncated": false, "tree": []])) }
        do { _ = try await client().fullTree(snapshot: snap); XCTFail("Must verify tree SHA") }
        catch { XCTAssertEqual(error as? RepositoryError, .response) }
    }

    func testArchiveHandlesDirectResponseAndSignedRedirectWithoutForwardingToken() async throws {
        let snap = RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main", commit: ArchiveFixture.commit, tree: ArchiveFixture.tree)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/tarball/\(ArchiveFixture.commit)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return (200, ArchiveFixture.dynamic)
        }
        let direct = try await client().archive(snapshot: snap)
        XCTAssertEqual(direct, ArchiveFixture.dynamic)

        var requests = 0
        StubProtocol.handler = { request in
            StubProtocol.responseHeaders = nil
            requests += 1
            if request.url?.host == "api.github.com" {
                StubProtocol.responseHeaders = ["Location": "https://codeload.github.com/owner/repo/legacy.tar.gz/\(ArchiveFixture.commit)?token=signed"]
                return (302, Data())
            }
            XCTAssertEqual(request.url?.host, "codeload.github.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ArchiveFixture.dynamic)
        }
        let redirected = try await client().archive(snapshot: snap)
        XCTAssertEqual(redirected, ArchiveFixture.dynamic)
        XCTAssertEqual(requests, 2)

        StubProtocol.handler = { _ in
            StubProtocol.responseHeaders = ["Location": "http://codeload.github.com/insecure"]
            return (302, Data())
        }
        do { _ = try await client().archive(snapshot: snap); XCTFail("Must reject non-HTTPS redirect") }
        catch { XCTAssertEqual(error as? RepositoryError, .response) }
    }
}
