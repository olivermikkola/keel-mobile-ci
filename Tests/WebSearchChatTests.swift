import XCTest
@testable import KeelMobile

@MainActor
final class WebSearchChatTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }
    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }
    private func call(_ name: String, _ key: String, _ value: String) -> String {
        "<tool_call>\n<function=\(name)>\n<parameter=\(key)>\n\(value)\n</parameter>\n</function>\n</tool_call>"
    }
    private func chat(_ outputs: [String], key: String = "fixture-search-key") -> LocalChat {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return LocalChat(transcript: file(), generator: SearchModel(outputs), webConfiguration: configuration, searchKey: { key })
    }
    private func approval(_ chat: LocalChat) async throws {
        for _ in 0..<1000 {
            if chat.pendingWebSearch != nil { return }
            if !chat.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("No query approval appeared")
    }
    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<2000 {
            if !chat.running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Chat did not stop")
    }
    func testApprovalSendsOnlyTheShownQueryAndAllowsOnlyAnActualResultURL() async throws {
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if request.url?.host == "api.search.brave.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "fixture-search-key")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "Turku museums")
                return (200, Data(#"{"web":{"results":[{"title":"Museum","url":"https://museum.example/hours","description":"Opening hours"}]}}"#.utf8))
            }
            XCTAssertEqual(request.url?.absoluteString, "https://museum.example/hours")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Subscription-Token"))
            StubProtocol.responseHeaders = ["Content-Type": "text/plain"]
            return (200, Data("Open Tuesday".utf8))
        }
        let chat = chat([call("web_search", "query", "Turku museums"), call("read_url", "url", "https://museum.example/hours"), call("read_url", "url", "https://museum.example/hours?secret=notes"), "It opens Tuesday."])
        chat.send("Find museum hours", model: LocalModel.catalog[0], path: file())
        try await approval(chat)
        XCTAssertEqual(chat.pendingWebSearch?.query, "Turku museums")
        XCTAssertTrue(requests.isEmpty, "Even a key does not authorize a model-selected query")
        chat.decideWebSearch(true)
        try await finish(chat)
        XCTAssertNil(chat.error)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.contains("Open Tuesday") })
        XCTAssertTrue(chat.messages.contains { $0.note == "Not opened" })
        XCTAssertFalse(chat.messages.contains { $0.text.contains("fixture-search-key") })
        XCTAssertNil(chat.pendingWebSearch)
    }
    func testSearchResultAuthorizationDoesNotCrossChats() async throws {
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, Data(#"{"web":{"results":[{"title":"Museum","url":"https://museum.example/hours","description":"Hours"}]}}"#.utf8))
        }
        let chat = chat([call("web_search", "query", "Museums"), "Found a museum.", call("read_url", "url", "https://museum.example/hours"), "Please provide the link."])
        chat.send("Find museums", model: LocalModel.catalog[0], path: file())
        try await approval(chat)
        chat.decideWebSearch(true)
        try await finish(chat)
        XCTAssertTrue(chat.newChat())
        chat.send("Read it", model: LocalModel.catalog[0], path: file())
        try await finish(chat)
        XCTAssertEqual(requests, 1, "The previous chat's result must not authorize another chat")
        XCTAssertTrue(chat.messages.contains { $0.note == "Not opened" })
    }

    func testDecliningAQueryMakesNoNetworkRequest() async throws {
        StubProtocol.handler = { _ in XCTFail("Declined query reached the network"); return (200, Data()) }
        let chat = chat([call("web_search", "query", "private file text"), "Search cancelled."])
        chat.send("Search for information", model: LocalModel.catalog[0], path: file())
        try await approval(chat)
        chat.decideWebSearch(false)
        try await finish(chat)
        XCTAssertTrue(chat.messages.contains { $0.note == "Not sent" })
        XCTAssertNil(chat.pendingWebSearch)
    }
    func testStoppingWhileApprovalIsOpenReleasesThePendingOperation() async throws {
        StubProtocol.handler = { _ in XCTFail("Stopped query reached the network"); return (200, Data()) }
        let chat = chat([call("web_search", "query", "Turku")])
        chat.send("Find information", model: LocalModel.catalog[0], path: file())
        try await approval(chat)
        chat.stop()
        try await finish(chat)
        XCTAssertNil(chat.pendingWebSearch)
        XCTAssertFalse(chat.running)
    }
    func testMissingKeyMakesNoRequestOrApproval() async throws {
        StubProtocol.handler = { _ in XCTFail("Missing key reached the network"); return (200, Data()) }
        let chat = chat([call("web_search", "query", "Turku"), "Add a search key first."], key: "")
        chat.send("Find information", model: LocalModel.catalog[0], path: file())
        try await finish(chat)
        XCTAssertNil(chat.pendingWebSearch)
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.contains("API key") })
    }
    func testSearchKeysUseAnIsolatedKeychainRecord() throws {
        let account = "test-" + UUID().uuidString
        defer { try? WebSearchCredential.remove(account: account) }
        XCTAssertEqual(try WebSearchCredential.load(account: account), "")
        try WebSearchCredential.save("fixture-one", account: account)
        XCTAssertEqual(try WebSearchCredential.load(account: account), "fixture-one")
        try WebSearchCredential.save("fixture-two", account: account)
        XCTAssertEqual(try WebSearchCredential.load(account: account), "fixture-two")
        XCTAssertThrowsError(try WebSearchCredential.save("bad\nkey", account: account))
        try WebSearchCredential.remove(account: account)
        XCTAssertEqual(try WebSearchCredential.load(account: account), "")
    }
}

private actor SearchModel: LocalGenerating {
    private var outputs: [String]
    init(_ outputs: [String]) { self.outputs = outputs }
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try Task.checkCancellation()
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }
}
