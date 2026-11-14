import XCTest
@testable import KeelMobile

// Opt-in: scripts/prepare-agent-model.sh supplies the exact 4B catalog model.
// The normal suite stays small. Both tests run the actual model; recorded
// responses isolate tool use, while the live variant also requires GitHub.
// Neither proves phone performance or end-to-end editing/publishing quality.
final class BonsaiAgentSmokeTests: XCTestCase {
    @MainActor
    func testRealBonsaiReadsGitHubBeforeAnswering() async throws {
        try await runSmoke(recorded: false)
    }

    @MainActor
    func testRealBonsaiReadsRecordedRepositoryBeforeAnswering() async throws {
        try await runSmoke(recorded: true)
    }

    @MainActor
    func testRealBonsaiSearchesRecordedFileBeforeAnswering() async throws {
        try await runSmoke(recorded: true, search: true)
    }

    @MainActor
    private func runSmoke(recorded: Bool, search: Bool = false) async throws {
        guard let modelFile = Bundle(for: Self.self).url(forResource: "bonsai-agent-smoke", withExtension: "gguf", subdirectory: "fixtures") else {
            throw XCTSkip("Opt-in 1.21GB Bonsai smoke fixture was not downloaded.")
        }
        let model = LocalModel.catalog[0]
        try ModelLibrary.verify(modelFile, model: model)
        let configuration = URLSessionConfiguration.ephemeral
        if recorded {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-recording", withExtension: "json"))
            let responses = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            configuration.protocolClasses = [StubProtocol.self]
            StubProtocol.handler = { request in
                guard request.url?.host == "api.github.com", let path = request.url?.path,
                      let response = responses[path] else { throw URLError(.resourceUnavailable) }
                return (200, try JSONSerialization.data(withJSONObject: response))
            }
        }
        defer { if recorded { StubProtocol.handler = nil } }
        let client = try GitHubRepository(repository: RepositoryID("octocat/Hello-World"), configuration: configuration)
        let snapshot = try await client.snapshot(branch: "master")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let chat = LocalChat(transcript: file, repositoryClient: { _ in client })
        XCTAssertTrue(chat.attach(snapshot))
        let start = Date()
        let request = search
            ? "Use search_file to find the literal text Hello in the repository's README file. Discover its exact path first. Report the matching full line with its file path and line number. Do not guess."
            : "Read the repository's README file using read_file and quote its exact contents. Include the file path. Do not guess."
        chat.send(request, model: model, path: modelFile)
        for _ in 0..<1800 {
            if !chat.running { break }
            try await Task.sleep(for: .seconds(1))
        }
        if chat.running { chat.stop(); XCTFail("Real Bonsai agent exceeded the 30-minute smoke budget") }
        for message in chat.messages {
            // This fixture has only public repository data and no credential.
            print("Real model \(message.role) [\(message.note ?? "")]: \(message.text)")
        }
        XCTAssertNil(chat.error)
        let prefix = search ? "Search README" : "Read README"
        let reads = chat.messages.filter { $0.role == "tool" && $0.activity?.hasPrefix(prefix) == true && $0.note?.hasPrefix("Verified") == true }
        XCTAssertFalse(reads.isEmpty, "A guessed answer without an actual read is a failed agent gate")
        XCTAssertTrue(reads.contains(where: { $0.text.contains("Hello World!") }))
        if search { XCTAssertTrue(reads.contains(where: { $0.text.contains("file_search") && $0.text.contains("\"line\":1") })) }
        XCTAssertTrue(chat.messages.last?.role == "assistant")
        XCTAssertTrue(chat.messages.last?.text.contains("Hello World!") == true)
        print("Real Bonsai 4B native CPU agent with \(recorded ? "recorded GitHub responses" : "live GitHub"): \(String(format: "%.1f", Date().timeIntervalSince(start)))s, \(reads.count) verified README read(s), commit \(snapshot.commit).")
        print("Real model answer: \(chat.messages.last?.text ?? "missing")")
        await chat.inference.unload()
    }
}
