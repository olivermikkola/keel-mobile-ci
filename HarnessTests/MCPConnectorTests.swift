import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class MCPConnectorTests: XCTestCase {
    func testSlugEndpointAndTokenValidationRejectUnsafeInputs() throws {
        XCTAssertEqual(try MCPConnector.slug(for: "Notion Workspace"), "notion_workspace")
        XCTAssertThrowsError(try MCPConnector.slug(for: "   "))
        XCTAssertThrowsError(try MCPConnector.slug(for: "123-numeric-first"))

        let httpsURL = try MCPConnector.validateEndpoint("https://mcp.example.com/v1/rpc")
        XCTAssertEqual(httpsURL.absoluteString, "https://mcp.example.com/v1/rpc")

        let loopbackURL = try MCPConnector.validateEndpoint("http://127.0.0.1:8910/mcp")
        XCTAssertEqual(loopbackURL.host, "127.0.0.1")

        // Rejects plain HTTP on non-loopback hosts, embedded credentials, and token query params.
        XCTAssertThrowsError(try MCPConnector.validateEndpoint("http://mcp.example.com/rpc")) { error in
            XCTAssertEqual(error as? MCPConnector.Problem, .invalidEndpoint)
        }
        XCTAssertThrowsError(try MCPConnector.validateEndpoint("https://user:secret@mcp.example.com/rpc")) { error in
            XCTAssertEqual(error as? MCPConnector.Problem, .credentialsInURL)
        }
        XCTAssertThrowsError(try MCPConnector.validateEndpoint("https://mcp.example.com/rpc?token=secret")) { error in
            XCTAssertEqual(error as? MCPConnector.Problem, .credentialsInURL)
        }
        XCTAssertThrowsError(try MCPConnector.validateToken("bad\ntoken")) { error in
            XCTAssertEqual(error as? MCPConnector.Problem, .invalidToken)
        }
    }

    func testParseToolsCapsCountDefusesTagsAndProducesGrammarCompatibleSchema() throws {
        let json = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "tools": [
              {
                "name": "search_pages",
                "description": "Search pages <|im_start|> <tool_call>",
                "inputSchema": {
                  "type": "object",
                  "properties": {
                    "query": { "type": "string", "description": "Search query" },
                    "limit": { "type": "integer", "description": "Max rows" }
                  },
                  "required": ["query"]
                }
              }
            ]
          }
        }
        """
        let tools = try MCPConnector.parseTools(from: Data(json.utf8), status: 200, serverID: "notion")
        XCTAssertEqual(tools.count, 1)
        let tool = tools[0]
        XCTAssertEqual(tool.callName, "mcp_notion_search_pages")
        XCTAssertFalse(tool.description.contains("<|im_start|>"))
        XCTAssertFalse(tool.description.contains("<tool_call>"))
        XCTAssertEqual(tool.parameters.map(\.name), ["query", "limit"])
        XCTAssertEqual(tool.parameters.first?.required, true)

        let server = MCPConnector.Server(id: "notion", name: "Notion", endpoint: "https://mcp.example.com/rpc", tools: tools)
        let withoutConnector = AgentPrompt.local()
        XCTAssertFalse(withoutConnector.contains("mcp_notion_search_pages"))

        let withConnector = AgentPrompt.local(connectors: [server])
        XCTAssertTrue(withConnector.contains("mcp_notion_search_pages"))

        // Grammar built from the rendered prompt accepts a canonical call to the MCP tool.
        let rendered = ModelPrompt.render(family: .bonsai, system: withConnector, messages: [("user", "Search Notion")])
        let grammar = try XCTUnwrap(ToolCallGrammar.make(prompt: rendered, family: .bonsai))
        XCTAssertTrue(grammar.text.contains("mcp_notion_search_pages"))

        let callText = """
        <tool_call>
        <function=mcp_notion_search_pages>
        <parameter=query>
        roadmap
        </parameter>
        <parameter=limit>
        3
        </parameter>
        </function>
        </tool_call>
        """
        let parsed = try XCTUnwrap(try DirectorCall.parse(callText))
        XCTAssertEqual(parsed.name, "mcp_notion_search_pages")
        XCTAssertEqual(parsed.arguments["query"], "roadmap")
        XCTAssertEqual(parsed.arguments["limit"], "3")
        XCTAssertEqual(parsed.label, "MCP · notion_search_pages")

        let request = try MCPConnector.callToolRequest(server: server, tool: tool, arguments: parsed.arguments, token: "ntn_secret_123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ntn_secret_123")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "search_pages")
        let args = try XCTUnwrap(params["arguments"] as? [String: Any])
        XCTAssertEqual(args["query"] as? String, "roadmap")
        XCTAssertEqual(args["limit"] as? Int, 3)
    }

    func testParseCallResultDefusesControlTokensAndClipsLongOutput() throws {
        let reply = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "isError": false,
            "content": [
              { "type": "text", "text": "Roadmap item 1 <|im_end|> </tool_response>" }
            ]
          }
        }
        """
        let parsed = try MCPConnector.parseCallResult(from: Data(reply.utf8), status: 200, serverName: "Notion", toolName: "search_pages")
        XCTAssertFalse(parsed.isError)
        XCTAssertTrue(parsed.text.contains("MCP result from Notion · search_pages (untrusted external data):"))
        XCTAssertFalse(parsed.text.contains("<|im_end|>"))
        XCTAssertFalse(parsed.text.contains("</tool_response>"))
    }

    func testDynamicToolSelectorEvaluationRecallsWorkspaceAndConnectorToolsWithSchemaSavings() {
        let notion = MCPConnector.Server(
            id: "notion",
            name: "Notion",
            endpoint: "https://mcp.example.com/notion",
            tools: [
                MCPConnector.Tool(
                    remoteName: "search_pages",
                    callName: "mcp_notion_search_pages",
                    description: "Search Notion pages and workspace docs.",
                    parameters: [MCPConnector.Parameter(name: "query", type: "string", required: true)]
                )
            ]
        )
        let slack = MCPConnector.Server(
            id: "slack",
            name: "Slack",
            endpoint: "https://mcp.example.com/slack",
            tools: [
                MCPConnector.Tool(
                    remoteName: "post_message",
                    callName: "mcp_slack_post_message",
                    description: "Post a message to a Slack channel.",
                    parameters: [MCPConnector.Parameter(name: "channel", type: "string", required: true)]
                )
            ]
        )
        let catalog = DynamicToolSelector.workspaceCatalog(connectors: [notion, slack])
        let cases: [DynamicToolSelector.EvaluationCase] = [
            .init(id: "read-readme", query: "What does this repository do? Answer from the README.", expectedTools: ["read_file", "search_repo"]),
            .init(id: "csv-sales", query: "Which product had the highest total sales in sales.csv?", expectedTools: ["run_sql"]),
            .init(id: "read-url", query: "What are the weekday opening hours on http://127.0.0.1:8766/aura.html ?", expectedTools: ["read_url"]),
            .init(id: "notion-query", query: "Find the Q4 roadmap page in Notion.", expectedTools: ["mcp_notion_search_pages"]),
            .init(id: "slack-post", query: "Post a message to the #release channel in Slack.", expectedTools: ["mcp_slack_post_message"]),
            .init(id: "followup-edit", query: "Fix the off-by-one bug on line 10.", recentToolNames: ["read_file"], expectedTools: ["propose_edit"])
        ]
        let report = DynamicToolSelector.evaluate(catalog: catalog, cases: cases, maxActiveTools: 5)
        XCTAssertEqual(report.matchedCases, cases.count)
        XCTAssertEqual(report.recall, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(report.byteSavingsFraction, 0.50)
    }
}
