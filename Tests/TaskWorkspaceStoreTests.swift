import XCTest
@testable import KeelMobile

@MainActor
final class TaskWorkspaceStoreTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.responseHeaders = nil
        super.tearDown()
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keel-store-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func snapshot() throws -> RepositorySnapshot {
        RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main",
                           commit: ArchiveFixture.commit, tree: ArchiveFixture.tree)
    }

    private func client(_ repository: RepositoryID) throws -> GitHubRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try GitHubRepository(repository: repository, token: "fixture-token", configuration: config)
    }

    private func configureArchiveStub(onRequest: @escaping (URLRequest) -> Void = { _ in }) {
        let treeEntries = ArchiveFixture.entries.map { entry -> [String: Any] in
            var item: [String: Any] = ["path": entry.path, "mode": entry.mode, "type": entry.type, "sha": entry.sha]
            if let size = entry.size { item["size"] = size }
            return item
        }
        StubProtocol.handler = { request in
            onRequest(request)
            let path = request.url!.path
            if path.hasSuffix("/git/trees/\(ArchiveFixture.tree)") {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "sha": ArchiveFixture.tree, "truncated": false, "tree": treeEntries
                ]))
            }
            if path.hasSuffix("/tarball/\(ArchiveFixture.commit)") {
                return (200, ArchiveFixture.dynamic)
            }
            XCTFail("Unexpected HTTP request: \(request)")
            return (500, Data())
        }
    }

    func testOpenCachesWorkspaceRebuildsOverlayAndRemovesOnCleanup() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = try snapshot()
        let taskID = UUID()
        var requests = 0
        configureArchiveStub { _ in requests += 1 }
        let api = try client(snap.repository)

        let first = try await TaskWorkspaceStore.open(task: taskID, snapshot: snap, client: api, edits: [], in: dir)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(try first.read("Sources/Makefile").text, "all:\n\techo upper\n")

        StubProtocol.handler = { request in
            XCTFail("Cached workspace should not hit GitHub again: \(request)")
            return (500, Data())
        }
        let proposal = try ProposedFileEdit(snapshot: snap, path: "Sources/Makefile",
                                            originalBlobSHA: ArchiveFixture.entries.first { $0.path == "Sources/Makefile" }!.sha,
                                            before: "all:\n\techo upper\n", oldText: "upper", newText: "local")
        var applied = TaskFileEdit(proposal: proposal)
        applied.decision = .applied

        let second = try await TaskWorkspaceStore.open(task: taskID, snapshot: snap, client: api, edits: [proposal], in: dir)
        XCTAssertEqual(try second.read("Sources/Makefile").text, "all:\n\techo local\n")
        XCTAssertTrue(try second.read("Sources/Makefile").isLocal)
        XCTAssertEqual(applied.decision, .applied)

        let sqliteURL = TaskWorkspaceStore.url(for: taskID, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqliteURL.path))
        TaskWorkspaceStore.remove(task: taskID, in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sqliteURL.path))
    }

    func testDirectorSessionProposeUsesWorkspaceAndLocalOverlayWithoutNetwork() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = try snapshot()
        configureArchiveStub()
        let workspace = try await TaskWorkspaceStore.open(task: UUID(), snapshot: snap, client: try client(snap.repository), edits: [], in: dir)

        StubProtocol.handler = { _ in XCTFail("Proposing against TaskWorkspace must perform zero HTTP calls"); return (500, Data()) }
        let director = DirectorSession(client: try client(snap.repository), snapshot: snap)

        let replaceCall = try XCTUnwrap(try DirectorCall.parse(
            "<tool_call><function=propose_edit><parameter=path>Sources/Makefile</parameter><parameter=old_text>upper</parameter><parameter=new_text>updated</parameter></function></tool_call>"))
        let planned = try await director.propose(replaceCall, workspace: workspace)
        XCTAssertEqual(planned.kind, .replace)
        XCTAssertEqual(planned.after, "all:\n\techo updated\n")

        let createCall = try XCTUnwrap(try DirectorCall.parse(
            "<tool_call><function=create_file><parameter=path>Sources/Fresh.swift</parameter><parameter=new_text>struct Fresh {}</parameter></function></tool_call>"))
        let created = try await director.propose(createCall, workspace: workspace)
        XCTAssertEqual(created.kind, .create)
        XCTAssertEqual(created.after, "struct Fresh {}\n")
    }

    func testRepositoryActivityTextFormatsWorkspaceListingAndRepoSearch() {
        let listing = #"{"entries":["Sources/","README.md","link (not text)"],"next_offset":3,"path":".","result_type":"directory_listing","total":6}"#
        let formattedListing = repositoryActivityText(listing)
        XCTAssertTrue(formattedListing.contains("Sources/\nREADME.md\nlink (not text)"))
        XCTAssertTrue(formattedListing.contains("More from offset 3."))

        let search = #"{"files_named_like_query":["Sources/App.swift"],"match":"exact","matches":["Sources/App.swift:4: struct DownloadManager {}"],"next_offset":1,"path":"Sources","query":"DownloadManager","related":["README.md:1: app"],"result_type":"repository_search"}"#
        let formattedSearch = repositoryActivityText(search)
        XCTAssertTrue(formattedSearch.contains("Sources · search: DownloadManager"))
        XCTAssertTrue(formattedSearch.contains("Sources/App.swift:4: struct DownloadManager {}"))
        XCTAssertTrue(formattedSearch.contains("Related:\nREADME.md:1: app"))
        XCTAssertTrue(formattedSearch.contains("Matching filenames:\nSources/App.swift"))
        XCTAssertTrue(formattedSearch.contains("More matches from offset 1."))
    }

    func testScratchSQLPersistsPerTaskAndRemovesOnCleanup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let taskA = UUID()
        let taskB = UUID()

        let create = try TaskWorkspaceStore.runSQL("CREATE TABLE counts (k TEXT, v INTEGER); INSERT INTO counts VALUES ('a', 3);", task: taskA, in: dir)
        XCTAssertFalse(create.isError, create.text)

        let queryA = try TaskWorkspaceStore.runSQL("SELECT k, v FROM counts WHERE v < 10;", task: taskA, in: dir)
        XCTAssertFalse(queryA.isError, queryA.text)
        XCTAssertEqual(queryA.text, "k | v\na | 3\n1 row")

        let queryB = try TaskWorkspaceStore.runSQL("SELECT * FROM counts;", task: taskB, in: dir)
        XCTAssertTrue(queryB.isError)
        XCTAssertTrue(queryB.text.contains("no such table"))

        let dbURL = TaskWorkspaceStore.scratchSQLURL(for: taskA, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        TaskWorkspaceStore.remove(task: taskA, in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
    }
}
