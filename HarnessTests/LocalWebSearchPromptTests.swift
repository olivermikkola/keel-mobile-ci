import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class LocalWebSearchPromptTests: XCTestCase {
    func testSearchIsOfferedOnlyWhenEnabledAndUsesTheExistingStrictArguments() throws {
        XCTAssertFalse(AgentPrompt.local().contains(WebSearch.tool))
        let prompt = AgentPrompt.local(webSearch: true)
        XCTAssertTrue(prompt.contains(WebSearch.tool))
        XCTAssertTrue(prompt.contains("approves the exact query"))
        XCTAssertFalse(AgentPrompt.director(name: "o/r", branch: "main", map: "").contains(WebSearch.tool))
        let call = try XCTUnwrap(DirectorCall.parse("<tool_call>\n<function=web_search>\n<parameter=query>\nTurku museums\n</parameter>\n<parameter=count>2</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(call.label, "Search the web")
        let args = try WebSearch.arguments(call.arguments)
        XCTAssertEqual(args.query, "Turku museums")
        XCTAssertEqual(args.count, 2)
        for family in [ModelFamily.bonsai, .lfm3, .miniCPM5] {
            XCTAssertNotNil(ToolCallGrammar.make(tools: AgentPrompt.toolLines(for: .local) + [WebSearch.tool], family: family))
        }
    }
}
