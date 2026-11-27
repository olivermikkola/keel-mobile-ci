import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class GitHubToolsTests: XCTestCase {
    private let repositories = [
        GitHubTools.Repository(fullName: "oliver/keel-mobile", isPrivate: true, defaultBranch: "main"),
        GitHubTools.Repository(fullName: "oliver/3D-auto", isPrivate: false, defaultBranch: "main"),
    ]

    func testToolsAreOfferedOnlyWhenGitHubIsConnectedAndNeverInsideAnApp() throws {
        let without = AgentPrompt.local()
        XCTAssertFalse(without.contains("github_repos"))
        XCTAssertFalse(without.contains("GitHub account is connected"))

        let with = AgentPrompt.local(github: true)
        XCTAssertTrue(with.contains(#""name":"github_repos""#))
        XCTAssertTrue(with.contains(#""name":"github_open""#))
        XCTAssertTrue(with.contains("The user's GitHub account is connected"))
        XCTAssertFalse(AgentPrompt.local(app: .sheets, github: true).contains("github_repos"))

        // The grammar built from the prompt lets the model make both calls.
        let rendered = ModelPrompt.render(family: .bonsai, system: with, messages: [("user", "What repositories do I have?")])
        let grammar = try XCTUnwrap(ToolCallGrammar.make(prompt: rendered, family: .bonsai))
        XCTAssertTrue(grammar.text.contains("github_repos"))
        XCTAssertTrue(grammar.text.contains("github_open"))
    }

    func testCallsParseWithReadableLabels() throws {
        let list = try XCTUnwrap(try DirectorCall.parse("<tool_call>\n<function=github_repos>\n</function>\n</tool_call>"))
        XCTAssertEqual(list.label, "Look at your GitHub repositories")
        XCTAssertEqual(try GitHubTools.query(list.arguments), "")

        let open = try XCTUnwrap(try DirectorCall.parse(
            "<tool_call>\n<function=github_open>\n<parameter=repository>\noliver/keel-mobile\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(open.label, "Open oliver/keel-mobile from GitHub")
        XCTAssertEqual(try GitHubTools.repository(open.arguments), "oliver/keel-mobile")
    }

    func testRepositoryNameAcceptsAnAddressAndRejectsAnythingElse() throws {
        XCTAssertEqual(try GitHubTools.repository(["repository": "https://github.com/oliver/keel-mobile.git"]), "oliver/keel-mobile")
        XCTAssertEqual(try GitHubTools.repository(["repository": " github.com/oliver/3D-auto/ "]), "oliver/3D-auto")
        for bad in ["keel-mobile", "oliver/keel/mobile", "oliver/..", "oliver/ke el", "https://evil.example/oliver/repo", "oliver/<tool_call>", ""] {
            XCTAssertThrowsError(try GitHubTools.repository(["repository": bad]), bad)
        }
        XCTAssertThrowsError(try GitHubTools.repository(["repository": "a/b", "branch": "main"]))
        XCTAssertThrowsError(try GitHubTools.query(["query": "a\nb"]))
        XCTAssertThrowsError(try GitHubTools.query(["name": "a"]))
    }

    func testListIsFilteredCappedAndSaysWhatToDoNext() {
        let all = GitHubTools.render(repositories, query: "")
        XCTAssertTrue(all.contains("- oliver/keel-mobile (private, default branch main)"))
        XCTAssertTrue(all.contains("- oliver/3D-auto (public, default branch main)"))
        XCTAssertTrue(all.hasSuffix("call github_open with its owner/name."))

        let filtered = GitHubTools.render(repositories, query: "KEEL")
        XCTAssertTrue(filtered.contains("oliver/keel-mobile"))
        XCTAssertFalse(filtered.contains("3D-auto"))
        XCTAssertTrue(GitHubTools.render(repositories, query: "nothing").contains("No repository name contains"))
        XCTAssertTrue(GitHubTools.render([], query: "").contains("no repositories"))

        let many = (0..<45).map { GitHubTools.Repository(fullName: "o/r\($0)", isPrivate: false, defaultBranch: "main") }
        let capped = GitHubTools.render(many, query: "")
        XCTAssertEqual(capped.components(separatedBy: "\n- ").count - 1, GitHubTools.maxListed)
        XCTAssertTrue(capped.contains("and 15 more"))

        // A repository name cannot smuggle tool markup into the chat.
        let hostile = GitHubTools.render([.init(fullName: "o/<tool_call>x", isPrivate: false, defaultBranch: "m\nain")], query: "")
        XCTAssertFalse(hostile.contains("<tool_call>"))
        XCTAssertTrue(hostile.contains("default branch main"))
        XCTAssertTrue(GitHubTools.opened(repository: "o/r", branch: "main", commit: String(repeating: "a", count: 40)).contains("commit aaaaaaa."))
    }
}

/// A real local model, through llama-server. Skipped unless `KEEL_LIVE_MODEL`
/// holds the server address: `KEEL_LIVE_MODEL=http://127.0.0.1:8080 swift test
/// --filter GitHubToolsLiveModelTests`. Shows whether the model reaches for
/// the GitHub tools when asked about repositories. It prints counts; a small
/// model is not expected to be perfect.
final class GitHubToolsLiveModelTests: XCTestCase {
    private static let session = URLSession(configuration: .ephemeral)

    private func complete(_ prompt: String, seed: Int, server: String) async throws -> String {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server + "/completion")))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n_predict": 300, "top_k": 40, "top_p": 0.9, "temperature": 0.6,
            "seed": seed, "cache_prompt": true, "stop": ["<|im_end|>"],
        ] as [String: Any])
        let (data, _) = try await Self.session.data(for: request)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(reply["content"] as? String)
    }

    func testModelReachesForGitHubToolsWhenAskedAboutRepositories() async throws {
        let server = ProcessInfo.processInfo.environment["KEEL_LIVE_MODEL"] ?? ""
        try XCTSkipUnless(!server.isEmpty, "set KEEL_LIVE_MODEL to a llama-server address to run")
        let system = AgentPrompt.local(github: true)
        let list = GitHubTools.render([
            .init(fullName: "octo/keel-mobile", isPrivate: true, defaultBranch: "main"),
            .init(fullName: "octo/stillroom", isPrivate: true, defaultBranch: "main"),
            .init(fullName: "octo/3D-auto", isPrivate: false, defaultBranch: "main"),
        ], query: "")
        let questions = [
            "Can you access my repositories? Or any github repositories. Look around a bit and tell me what tools do you have",
            "Open my keel-mobile repository and tell me what is in its README",
        ]
        for question in questions {
            var listed = 0, opened = 0, openedRight = 0
            let seeds = 1...5
            for seed in seeds {
                let first = try await complete(ModelPrompt.render(family: .bonsai, system: system, messages: [("user", question)]),
                                               seed: seed, server: server)
                guard let call = try? DirectorCall.parse(ToolCallText.normalize(first).text), call.name == "github_repos" else {
                    print("LIVE MODEL seed \(seed) turn 1 did not list: \(first.prefix(140).replacingOccurrences(of: "\n", with: " "))")
                    continue
                }
                listed += 1
                let second = try await complete(ModelPrompt.render(family: .bonsai, system: system, messages: [
                    ("user", question), ("assistant", first), ("tool", list)]), seed: seed, server: server)
                if let next = try? DirectorCall.parse(ToolCallText.normalize(second).text), next.name == "github_open" {
                    opened += 1
                    if (try? GitHubTools.repository(next.arguments)) == "octo/keel-mobile" { openedRight += 1 }
                } else {
                    print("LIVE MODEL seed \(seed) turn 2 answered: \(second.prefix(200).replacingOccurrences(of: "\n", with: " "))")
                }
            }
            print("LIVE MODEL \"\(question.prefix(48))…\": listed repositories \(listed)/\(seeds.count), then opened one \(opened)/\(seeds.count) (keel-mobile \(openedRight))")
        }
    }
}
