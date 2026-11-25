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
            parameters: [MCPConnector.Parameter(name: "query", type: "string", description: "Search query", required: true)],
            readOnly: true
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

    func testToolThatMayChangeThingsWaitsForTheUserAndAlwaysAllowIsRemembered() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubMCPProtocol.self]
        let model = StubMCPModel()
        let chat = LocalChat(transcript: file, generator: model, webConfiguration: config, connectorToken: { _ in "" })
        // Not marked read-only by the service, so Keel asks first.
        let tool = MCPConnector.Tool(
            remoteName: "search_pages", callName: "mcp_notion_search_pages", description: "Search Notion pages by query.",
            parameters: [MCPConnector.Parameter(name: "query", type: "string", required: true)])
        _ = try chat.saveConnector(MCPConnector.Server(id: "notion", name: "Notion", endpoint: "https://mcp.example.com/rpc", tools: [tool]))
        XCTAssertTrue(chat.setConnectorEnabled("notion", enabled: true))

        // Declined: nothing is sent and the model is told so.
        await model.setCallNext(true)
        chat.send("Find the roadmap in Notion", model: LocalModel.catalog[0], path: file)
        try await waitForApproval(chat)
        XCTAssertEqual(chat.pendingConnectorCall?.service, "Notion")
        XCTAssertEqual(chat.pendingConnectorCall?.tool, "search_pages")
        XCTAssertEqual(chat.pendingConnectorCall?.details, "query: roadmap")
        chat.decideConnectorCall(.deny)
        try await finish(chat)
        XCTAssertTrue(chat.messages.contains(where: { $0.role == "tool" && $0.text.contains("declined") }))
        XCTAssertFalse(chat.messages.contains(where: { $0.text.contains("Q4 Mobile Launch Roadmap") && $0.role == "tool" }))

        // Always allow: it runs now, and the next call does not ask.
        await model.setCallNext(true)
        chat.send("Try again", model: LocalModel.catalog[0], path: file)
        try await waitForApproval(chat)
        chat.decideConnectorCall(.always)
        try await finish(chat)
        XCTAssertTrue(chat.messages.contains(where: { $0.role == "tool" && $0.text.contains("Q4 Mobile Launch Roadmap") }))
        XCTAssertEqual(chat.connectors.first?.trusted, ["search_pages"])

        await model.setCallNext(true)
        chat.send("And once more", model: LocalModel.catalog[0], path: file)
        try await finish(chat)
        XCTAssertNil(chat.pendingConnectorCall)
        XCTAssertEqual(chat.messages.filter { $0.role == "tool" && $0.text.contains("Q4 Mobile Launch Roadmap") }.count, 2)
        // The choice survives a relaunch.
        XCTAssertEqual(LocalChat(transcript: file, generator: model, webConfiguration: config).connectors.first?.trusted, ["search_pages"])
    }

    func testReadOnlyConnectorRequiresApprovalWhenPrivateContextIsPresent() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubMCPProtocol.self]
        let model = StubMCPModel()
        let chat = LocalChat(transcript: file, generator: model, webConfiguration: config, connectorToken: { _ in "" })
        let tool = MCPConnector.Tool(
            remoteName: "search_pages", callName: "mcp_notion_search_pages", description: "Search Notion pages by query.",
            parameters: [MCPConnector.Parameter(name: "query", type: "string", required: true)],
            readOnly: true)
        _ = try chat.saveConnector(MCPConnector.Server(id: "notion", name: "Notion", endpoint: "https://mcp.example.com/rpc", tools: [tool]))
        XCTAssertTrue(chat.setConnectorEnabled("notion", enabled: true))

        // With a private attachment in the chat, even a read-only MCP tool must ask before sending arguments.
        let secret = Attachment(filename: "taxes.txt", mimeType: "text/plain", extractedText: "Private tax summary", byteSize: 19, source: .file)
        await model.setCallNext(true)
        chat.send("Compare this with Notion", attachments: [secret], model: LocalModel.catalog[0], path: file)
        try await waitForApproval(chat)
        XCTAssertEqual(chat.pendingConnectorCall?.tool, "search_pages")
        chat.decideConnectorCall(.deny)
        try await finish(chat)
        XCTAssertTrue(chat.messages.contains(where: { $0.role == "tool" && $0.text.contains("declined") }))
        XCTAssertFalse(chat.messages.contains(where: { $0.role == "tool" && $0.text.contains("Q4 Mobile Launch Roadmap") }))
    }

    private func waitForApproval(_ chat: LocalChat) async throws {
        for _ in 0..<500 {
            if chat.pendingConnectorCall != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("The chat never asked about the connector action")
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
