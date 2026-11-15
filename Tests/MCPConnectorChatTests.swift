import XCTest
@testable import KeelMobile

@MainActor
final class MCPConnectorChatTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
    }

    func testConnectorToolsAreOfferedAndExecutedOnlyWhenEnabledForTheChat() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubMCPProtocol.self]

        let model = StubMCPModel()
        let chat = LocalChat(
            transcript: file,
            generator: model,
            webConfiguration: config,
            connectorToken: { _ in "ntn_test_token_99" }
        )

        let tool = MCPConnector.Tool(
            remoteName: "search_pages",
            callName: "mcp_notion_search_pages",
            description: "Search Notion pages by query.",
            parameters: [MCPConnector.Parameter(name: "query", type: "string", description: "Search query", required: true)]
        )
        let server = MCPConnector.Server(
            id: "notion",
            name: "Notion",
            endpoint: "https://mcp.example.com/rpc",
            tools: [tool]
        )
        _ = try chat.saveConnector(server)

        // 1. By default in a new chat, the connector is NOT enabled, so its schema is omitted.
        XCTAssertFalse(chat.isConnectorEnabled("notion"))
        chat.send("Say hello", model: LocalModel.catalog[0], path: file)
        try await finish(chat)
        let disabledPrompt = await model.lastPrompt
        XCTAssertFalse(disabledPrompt.contains("mcp_notion_search_pages"))

        // 2. Enable the connector in this chat and verify the tool schema is included and executes.
        XCTAssertTrue(chat.setConnectorEnabled("notion", enabled: true))
        XCTAssertTrue(chat.isConnectorEnabled("notion"))

        await model.setCallNext(true)
        chat.send("Find the roadmap in Notion", model: LocalModel.catalog[0], path: file)
        try await finish(chat)

        let enabledPrompt = await model.lastPrompt
        XCTAssertTrue(enabledPrompt.contains("mcp_notion_search_pages"))
        XCTAssertTrue(chat.messages.contains(where: { $0.role == "tool" && $0.text.contains("Q4 Mobile Launch Roadmap") }))
        XCTAssertEqual(chat.messages.last?.text, "Found the Q4 Mobile Launch Roadmap in Notion.")

        // 3. Starting a second chat leaves the connector off in the new chat while preserving it on the first chat.
        let firstID = chat.activeTaskID
        XCTAssertTrue(chat.newChat())
        XCTAssertFalse(chat.isConnectorEnabled("notion"))
        XCTAssertTrue(chat.selectTask(firstID))
        XCTAssertTrue(chat.isConnectorEnabled("notion"))

        // Relaunch restores the per-chat connector state.
        let restored = LocalChat(transcript: file, generator: model, webConfiguration: config)
        XCTAssertTrue(restored.isConnectorEnabled("notion"))
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<500 {
            if !chat.running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Reply did not finish")
    }
}

private actor StubMCPModel: LocalGenerating {
    private(set) var lastPrompt = ""
    private var callNext = false
    private var step = 0

    func setCallNext(_ value: Bool) {
        callNext = value
        step = 0
    }

    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        lastPrompt = prompt
        if callNext && step == 0 {
            step = 1
            onText("""
            <tool_call>
            <function=mcp_notion_search_pages>
            <parameter=query>
            roadmap
            </parameter>
            </function>
            </tool_call>
            """)
            return 16
        }
        onText("Found the Q4 Mobile Launch Roadmap in Notion.")
        return 8
    }
}

private final class StubMCPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mcp.example.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "isError": false,
            "content": [
              { "type": "text", "text": "Page: Q4 Mobile Launch Roadmap" }
            ]
          }
        }
        """
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
