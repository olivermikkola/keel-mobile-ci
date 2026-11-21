import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ChatModeTests: XCTestCase {
    private func tools(_ prompt: String) -> Set<String> {
        Set(prompt.components(separatedBy: "\n").filter { $0.hasPrefix(#"{"type":"function""#) }.map(AgentPrompt.toolName))
    }

    func testPlainChatSkipsUnusedToolPromptWhileFilesAndLinksKeepTools() {
        let simple = AgentPrompt.local(mode: .chat, hasFiles: false, hasLink: false)
        XCTAssertFalse(simple.contains("<tools>"))
        XCTAssertLessThan(simple.utf8.count, 400)
        let withFile = AgentPrompt.local(mode: .chat, hasFiles: true, hasLink: false)
        XCTAssertTrue(withFile.contains("read_file"))
        let link = WebAddress.containsAddress(in: ["Read example.com/guide."])
        XCTAssertTrue(link)
        XCTAssertTrue(AgentPrompt.local(mode: .chat, hasFiles: false, hasLink: link).contains("read_url"))
        XCTAssertFalse(WebAddress.containsAddress(in: ["Write a text saying I'll be 10 minutes late."]))
        XCTAssertTrue(AgentPrompt.local(mode: .chat, memory: true, hasFiles: false, hasLink: false).contains("remember"))
    }

    func testWorkIsTheDefaultAndUnchanged() {
        XCTAssertEqual(AgentPrompt.local(), AgentPrompt.local(mode: .work))
        XCTAssertEqual(AgentPrompt.local(webSearch: true, github: true), AgentPrompt.local(mode: .work, webSearch: true, github: true))
    }

    func testChatOffersOnlyReadingToolsAndIsShorter() {
        let work = AgentPrompt.local(mode: .work, webSearch: true)
        let chat = AgentPrompt.local(mode: .chat, webSearch: true)
        XCTAssertEqual(tools(chat), ["search_repo", "read_file", "list_files", "read_url", "web_search"])
        XCTAssertTrue(tools(chat).isStrictSubset(of: tools(work)))
        for writer in ["propose_edit", "create_file", "delete_file", "rename_file", "run_js", "run_sql"] {
            XCTAssertFalse(tools(chat).contains(writer), writer)
        }
        XCTAssertLessThan(chat.utf8.count, work.utf8.count * 6 / 10, "Chat should read well under 60% of Work's prompt")
        XCTAssertFalse(chat.contains("tool calls per user message"), "No cap is announced to the model")
        XCTAssertTrue(chat.contains("switch to Work mode, where you can do it"))
    }

    func testChatKeepsConnectorsAndGitHub() {
        let server = MCPConnector.Server(id: "notion", name: "Notion", endpoint: "https://mcp.notion.com/mcp",
                                         tools: [.init(remoteName: "search", callName: "mcp_notion_search", description: "Search pages",
                                                       parameters: [.init(name: "query", type: "string", required: true)], readOnly: true)])
        let chat = AgentPrompt.local(mode: .chat, connectors: [server], github: true)
        XCTAssertTrue(tools(chat).contains("github_repos"))
        XCTAssertTrue(tools(chat).contains("github_open"))
        XCTAssertTrue(chat.contains("mcp_notion_search"))
    }

    func testAppsAreAlwaysWork() {
        for app in AppPreset.allCases {
            XCTAssertEqual(AgentPrompt.local(app: app, mode: .chat), AgentPrompt.local(app: app))
        }
        XCTAssertEqual(ChatMode.resolve(saved: .chat, app: true, repository: false), .work)
        XCTAssertEqual(ChatMode.resolve(saved: .chat, app: false, repository: true), .work)
        XCTAssertEqual(ChatMode.resolve(saved: nil, app: false, repository: false), .work, "Chats saved before modes keep their tools")
        XCTAssertEqual(ChatMode.resolve(saved: .chat, app: false, repository: false), .chat)
    }

    func testGrammarFollowsTheMode() throws {
        let grammar = try XCTUnwrap(ToolCallGrammar.make(prompt: AgentPrompt.chatML(system: AgentPrompt.local(mode: .chat), messages: [("user", "hi")]), family: .bonsai))
        XCTAssertTrue(grammar.text.contains("read_file"))
        XCTAssertFalse(grammar.text.contains("create_file"))
        XCTAssertFalse(grammar.text.contains("run_js"))
    }

    func testRepliesAndLimits() {
        XCTAssertEqual(ChatMode.chat.replyTokens(writing: true), AgentPrompt.readingReplyTokens)
        XCTAssertEqual(ChatMode.work.replyTokens(writing: true), AgentPrompt.writingReplyTokens)
        XCTAssertEqual(ChatMode.work.replyTokens(writing: false), AgentPrompt.readingReplyTokens)
        XCTAssertEqual(ChatMode.chat.toolCheckIn, 8)
        XCTAssertEqual(ChatMode.work.toolCheckIn, 25)
        XCTAssertFalse(ChatMode.chat.offers("create_file"))
        XCTAssertTrue(ChatMode.chat.offers("mcp_notion_search"))
        XCTAssertTrue(ChatMode.work.offers("create_file"))
    }

    func testRecommendationsDoNotOverlap() {
        XCTAssertTrue(Set(ChatMode.chat.recommendedModelIDs).isDisjoint(with: ChatMode.work.recommendedModelIDs))
    }
}
