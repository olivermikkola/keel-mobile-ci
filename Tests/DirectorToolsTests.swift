import XCTest
@testable import KeelMobile

final class DirectorToolsTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let content = "return a - b\n"
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private func session() throws -> DirectorSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let repository = try RepositoryID("owner/repo")
        return DirectorSession(client: try GitHubRepository(repository: repository, token: "fixture-token", configuration: config),
                               snapshot: RepositorySnapshot(repository: repository, branch: "main", commit: commit, tree: tree))
    }
    private func serveFile(_ text: String? = nil) {
        let text = text ?? content
        let blob = ProposedFileEdit.blobSHA(text)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Model calls must never mutate GitHub")
            let object: [String: Any]
            if request.url!.path.hasSuffix("/git/trees/\(self.tree)") {
                object = ["sha": self.tree, "truncated": false, "tree": [["path": "calc.py", "sha": blob, "type": "blob", "mode": "100644", "size": text.utf8.count]]]
            } else {
                XCTAssertTrue(request.url!.path.hasSuffix("/git/blobs/\(blob)"))
                object = ["sha": blob, "size": text.utf8.count, "encoding": "base64", "content": Data(text.utf8).base64EncodedString()]
            }
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
    }

    func testProposingNeverAppliesAndExecutionRejectsEveryMutationTool() async throws {
        serveFile()
        let session = try session()
        let call = DirectorCall(name: "propose_edit", arguments: ["path": "calc.py", "old_text": "a - b", "new_text": "a + b"])
        let proposal = try await session.propose(call)
        XCTAssertEqual(proposal.after, "return a + b\n")
        let read = try await session.execute(DirectorCall(name: "read_file", arguments: ["path": "calc.py"]))
        XCTAssertTrue(read.contains("a - b"), "Proposing must not change subsequent reads")
        for name in ["propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file", "run_ci", "finish_task", "unknown"] {
            do { _ = try await session.execute(DirectorCall(name: name, arguments: [:])); XCTFail("Executed \(name)") }
            catch DirectorToolError.approvalRequired { }
        }
    }

    func testCreateDeleteAndRenameAreProposalsOnly() async throws {
        serveFile()
        let session = try session()
        let create = try await session.propose(DirectorCall(name: "create_file",
            arguments: ["path": "new.py", "new_text": "print(1)\n"]))
        XCTAssertEqual(create.kind, .create)
        XCTAssertEqual(create.after, "print(1)\n")
        XCTAssertEqual(create.originalBlobSHA, ProposedFileEdit.emptyBlobSHA)

        let delete = try await session.propose(DirectorCall(name: "delete_file",
            arguments: ["path": "calc.py"]))
        XCTAssertEqual(delete.kind, .delete)
        XCTAssertEqual(delete.after, "")

        let rename = try await session.propose(DirectorCall(name: "rename_file",
            arguments: ["path": "calc.py", "destination_path": "renamed.py"]))
        XCTAssertEqual(rename.kind, .rename)
        XCTAssertEqual(rename.afterPath, "renamed.py")
        XCTAssertEqual(rename.after, self.content)

        let read = try await session.execute(DirectorCall(name: "read_file", arguments: ["path": "calc.py"]))
        XCTAssertTrue(read.contains("a - b"), "Proposals must not change later reads")
    }

    func testCreateAndRenameRejectOccupiedDestinations() async throws {
        serveFile()
        let session = try session()
        do {
            _ = try await session.propose(DirectorCall(name: "create_file",
                arguments: ["path": "calc.py", "new_text": "x\n"]))
            XCTFail("Must not create over an existing file")
        } catch FileEditError.path { }
        do {
            _ = try await session.propose(DirectorCall(name: "rename_file",
                arguments: ["path": "calc.py", "destination_path": "calc.py"]))
            XCTFail("Must not rename onto itself")
        } catch FileEditError.path { }
    }

    func testEditMatchingIsByteExactAndRejectsOverlappingMatches() async throws {
        serveFile("é and e\u{301}\n")
        let proposal = try await session().propose(DirectorCall(name: "propose_edit", arguments: ["path": "calc.py", "old_text": "é", "new_text": "first"]))
        XCTAssertEqual(Data(proposal.after.utf8), Data("first and e\u{301}\n".utf8))
        serveFile("aaa")
        do {
            _ = try await session().propose(DirectorCall(name: "propose_edit", arguments: ["path": "calc.py", "old_text": "aa", "new_text": "b"]))
            XCTFail("Ambiguous edit accepted")
        } catch FileEditError.match { }
    }

    func testInvalidPathsAndNumericRangesMakeNoRequests() async throws {
        StubProtocol.handler = { _ in XCTFail("Invalid input caused I/O"); return (500, Data()) }
        let session = try session()
        for path in ["../secret", "/absolute", "a//b", "a/./b"] {
            do {
                _ = try await session.propose(DirectorCall(name: "propose_edit", arguments: ["path": path, "old_text": "a", "new_text": "b"]))
                XCTFail("Invalid path accepted")
            } catch { }
        }
        for value in ["-1", "10000000000000000000000", "no"] {
            do {
                _ = try await session.execute(DirectorCall(name: "list_files", arguments: ["path": ".", "offset": value]))
                XCTFail("Invalid offset accepted")
            } catch { }
        }
    }

    func testLongSingleLineReadIsBounded() async throws {
        serveFile(String(repeating: "x", count: 10_000))
        do {
            _ = try await session().execute(DirectorCall(name: "read_file", arguments: ["path": "calc.py"]))
            XCTFail("Unbounded result returned")
        } catch RepositoryAgentError.output { }
    }

    func testProtocolDecodesEntitiesExactlyOnceAndRejectsDuplicateArguments() throws {
        let xml = "<tool_call><function=propose_edit><parameter=path>calc.py</parameter><parameter=old_text>&amp;lt;</parameter><parameter=new_text>&lt;</parameter></function></tool_call>"
        let call = try XCTUnwrap(DirectorCall.parse(xml))
        XCTAssertEqual(call.arguments["old_text"], "&lt;")
        XCTAssertEqual(call.arguments["new_text"], "<")
        XCTAssertThrowsError(try DirectorCall.parse("<tool_call><function=read_file><parameter=path>a</parameter><parameter=path>b</parameter></function></tool_call>"))
        XCTAssertThrowsError(try DirectorCall.parse("<tool_call><function=rm_rf></function></tool_call>"))
        XCTAssertThrowsError(try DirectorCall.parse("<tool_call><function=read_file>"))
        XCTAssertNil(try DirectorCall.parse("A normal answer."))
    }
}
