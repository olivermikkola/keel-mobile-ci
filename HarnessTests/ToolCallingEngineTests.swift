import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ToolCallingEngineTests: XCTestCase {

    // MARK: - ToolRegistry & Entity Decoding & ChatMode Fixes

    func testEntityDecodingWorksAcrossAllBuiltInTextTools() throws {
        let rememberXML = "<tool_call><function=remember><parameter=fact>Likes R&amp;B &amp; jazz &lt;3</parameter></function></tool_call>"
        let rememberCall = try XCTUnwrap(DirectorCall.parse(rememberXML))
        XCTAssertEqual(rememberCall.arguments["fact"], "Likes R&B & jazz <3")

        let searchXML = "<tool_call><function=web_search><parameter=query>A &amp; B &lt; 10</parameter></function></tool_call>"
        let searchCall = try XCTUnwrap(DirectorCall.parse(searchXML))
        XCTAssertEqual(searchCall.arguments["query"], "A & B < 10")

        let imageXML = "<tool_call><function=generate_image><parameter=prompt>Tom &amp; Jerry style</parameter><parameter=path>art.png</parameter></function></tool_call>"
        let imageCall = try XCTUnwrap(DirectorCall.parse(imageXML))
        XCTAssertEqual(imageCall.arguments["prompt"], "Tom & Jerry style")
        XCTAssertEqual(imageCall.arguments["path"], "art.png")

        // Single-pass decoding: `&amp;lt;` becomes `&lt;`, never double-decoded to `<`.
        XCTAssertEqual(ToolRegistry.decodeXMLEntities("&amp;lt;tag&amp;gt;"), "&lt;tag&gt;")
    }

    func testChatModeOffersCalendarShortcutsAndLoadToolsWhileBlockingWriters() {
        for allowed in ["calendar_events", "reminders_list", "create_reminder", "create_calendar_event", "run_shortcut", ToolRegistry.loadToolsName] {
            XCTAssertTrue(ChatMode.chat.offers(allowed), "Chat mode should allow \(allowed)")
        }
        for blocked in ["propose_edit", "create_file", "delete_file", "rename_file", "run_sql", "run_js"] {
            XCTAssertFalse(ChatMode.chat.offers(blocked), "Chat mode must block \(blocked)")
        }
    }

    func testSchemaAwareErrorRecoverySuggestsAliasesTyposDeferredAndExactSignatures() {
        let schemas = AgentPrompt.toolLines(for: .local).compactMap(ToolSchema.init)
        let badAlias = ToolRegistry.correctionMessage(
            for: "<tool_call><function=edit_file><parameter=path>a.txt</parameter></function></tool_call>",
            error: DirectorToolError.invalidCall("Unknown tool name: 'edit_file'."),
            offeredSchemas: schemas
        )
        XCTAssertTrue(badAlias.contains("propose_edit("), badAlias)
        XCTAssertTrue(badAlias.contains("old_text: string [required]"), badAlias)

        let typo = ToolRegistry.correctionMessage(
            for: "<tool_call><function=read_fil><parameter=path>a.txt</parameter></function></tool_call>",
            error: DirectorToolError.invalidCall("Unknown tool name: 'read_fil'."),
            offeredSchemas: schemas
        )
        XCTAssertTrue(typo.contains("Did you mean read_file("), typo)

        let deferredHint = ToolRegistry.correctionMessage(
            for: "<tool_call><function=calendar_events></function></tool_call>",
            error: DirectorToolError.invalidCall("Not currently loaded."),
            offeredSchemas: schemas,
            deferredNames: ["calendar_events", "reminders_list"]
        )
        XCTAssertTrue(deferredHint.contains("load_tools(names=\"calendar_events\")"), deferredHint)

        let badParams = ToolRegistry.correctionMessage(
            for: "<tool_call><function=read_file></function></tool_call>",
            attemptedTool: "read_file",
            error: DirectorToolError.invalidCall("Missing path."),
            offeredSchemas: schemas
        )
        XCTAssertTrue(badParams.contains("Expected signature: read_file(path: string [required]"), badParams)
    }

    // MARK: - Multi-Format & Multi-Call Parser

    func testParsesMultiCallQwenXMLAndBareFunctions() throws {
        let multi = """
        Checking both files now.
        <tool_call>
        <function=read_file>
        <parameter=path>README.md</parameter>
        <parameter=count>40</parameter>
        </function>
        </tool_call>
        <tool_call>
        <function=list_files>
        <parameter=path>Sources</parameter>
        </function>
        </tool_call>
        """
        let parsed = try XCTUnwrap(ToolCallParser.parseAll(multi))
        XCTAssertEqual(parsed.format, .qwenXML)
        XCTAssertEqual(parsed.narration, "Checking both files now.")
        XCTAssertEqual(parsed.calls.count, 2)
        XCTAssertEqual(parsed.calls[0].name, "read_file")
        XCTAssertEqual(parsed.calls[0].arguments, ["path": "README.md", "count": "40"])
        XCTAssertEqual(parsed.calls[1].name, "list_files")
        XCTAssertEqual(parsed.calls[1].arguments, ["path": "Sources"])

        // Bare multi-call without `<tool_call>` wrapper
        let bare = """
        <function=calendar_events><parameter=days>3</parameter></function>
        <function=reminders_list></function>
        """
        let bareParsed = try XCTUnwrap(ToolCallParser.parseAll(bare))
        XCTAssertEqual(bareParsed.calls.map(\.name), ["calendar_events", "reminders_list"])
        XCTAssertTrue(bareParsed.repaired)

        // Exceeding maxCalls is rejected
        XCTAssertThrowsError(try ToolCallParser.parseAll(multi, maxCalls: 1))
    }

    func testParsesJSONToolCallsSingleArrayAndStringifiedArguments() throws {
        let single = """
        Let me read that.
        <tool_call>
        {"name": "read_file", "arguments": {"path": "Sources/App.swift", "start_line": 10, "count": 50}}
        </tool_call>
        """
        let p1 = try XCTUnwrap(ToolCallParser.parseAll(single))
        XCTAssertEqual(p1.format, .jsonTag)
        XCTAssertEqual(p1.narration, "Let me read that.")
        XCTAssertEqual(p1.calls.count, 1)
        XCTAssertEqual(p1.calls[0].name, "read_file")
        XCTAssertEqual(p1.calls[0].arguments, ["path": "Sources/App.swift", "start_line": "10", "count": "50"])

        // Batch JSON array inside one `<tool_call>` block
        let batch = """
        <tool_call>
        [
          {"name": "calendar_events", "arguments": {"days": 7}},
          {"name": "mcp_notion_search", "arguments": {"query": "roadmap", "include_archived": false, "limit": 5}}
        ]
        </tool_call>
        """
        let p2 = try XCTUnwrap(ToolCallParser.parseAll(batch))
        XCTAssertEqual(p2.format, .jsonTag)
        XCTAssertEqual(p2.calls.count, 2)
        XCTAssertEqual(p2.calls[0].name, "calendar_events")
        XCTAssertEqual(p2.calls[0].arguments["days"], "7")
        XCTAssertEqual(p2.calls[1].name, "mcp_notion_search")
        XCTAssertEqual(p2.calls[1].arguments["include_archived"], "false")
        XCTAssertEqual(p2.calls[1].arguments["limit"], "5")

        // OpenAI-style nested function with stringified arguments
        let nested = #"<tool_call>{"type":"function","function":{"name":"web_search","arguments":"{\"query\":\"Turku weather\",\"count\":3}"}}</tool_call>"#
        let p3 = try XCTUnwrap(ToolCallParser.parseAll(nested))
        XCTAssertEqual(p3.calls.count, 1)
        XCTAssertEqual(p3.calls[0].name, "web_search")
        XCTAssertEqual(p3.calls[0].arguments, ["query": "Turku weather", "count": "3"])

        // Unknown tool in JSON is rejected
        XCTAssertThrowsError(try ToolCallParser.parseAll(#"<tool_call>{"name":"run_shell","arguments":{"cmd":"ls"}}</tool_call>"#))
    }

    func testParsesMiniCPM5MultiCallAndBlocksXXE() throws {
        let multi = """
        <function name="calendar_events"><param name="days">5</param></function>
        <function name="reminders_list"><param name="limit">10</param></function>
        """
        let parsed = try XCTUnwrap(ToolCallParser.parseAll(multi, family: .miniCPM5))
        XCTAssertEqual(parsed.format, .miniCPMXML)
        XCTAssertEqual(parsed.calls.count, 2)
        XCTAssertEqual(parsed.calls[0].name, "calendar_events")
        XCTAssertEqual(parsed.calls[0].arguments["days"], "5")
        XCTAssertEqual(parsed.calls[1].name, "reminders_list")
        XCTAssertEqual(parsed.calls[1].arguments["limit"], "10")

        let xxe = "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><function name=\"read_file\"><param name=\"path\">&e;</param></function>"
        XCTAssertThrowsError(try ToolCallParser.parseAll(xxe, family: .miniCPM5))
    }

    func testParsesLFMPythonicSingleAndMultiCalls() throws {
        let lfm = #"<|tool_call_start|>[read_file(path="README.md", count=30), search_repo(query="Array<Int>", path='Sources')]<|tool_call_end|>"#
        let parsed = try XCTUnwrap(ToolCallParser.parseAll(lfm, family: .lfm3))
        XCTAssertEqual(parsed.format, .lfmPython)
        XCTAssertEqual(parsed.calls.count, 2)
        XCTAssertEqual(parsed.calls[0].name, "read_file")
        XCTAssertEqual(parsed.calls[0].arguments, ["path": "README.md", "count": "30"])
        XCTAssertEqual(parsed.calls[1].name, "search_repo")
        XCTAssertEqual(parsed.calls[1].arguments, ["query": "Array<Int>", "path": "Sources"])

        // Escaped quotes, booleans, None skipped
        let mcp = #"<|tool_call_start|>[mcp_linear_list(team="Eng \"Core\"", active=True, cursor=None)]<|tool_call_end|>"#
        let p2 = try XCTUnwrap(ToolCallParser.parseAll(mcp, family: .lfm3))
        XCTAssertEqual(p2.calls[0].arguments, ["team": #"Eng "Core""#, "active": "true"])

        // Leaked LFM call text is cleaned from plain chat replies
        let cleaned = ToolCallText.cleanReply("Here is the answer.\n<|tool_call_start|>[bad()]<|tool_call_end|>")
        XCTAssertEqual(cleaned.text, "Here is the answer.")
        XCTAssertTrue(cleaned.removed)
    }

    func testThinkLeakStrippingCannotHideEarlierCall() throws {
        let leaked = "Thinking about files...</think>\n<tool_call>{\"name\":\"list_files\",\"arguments\":{\"path\":\".\"}}</tool_call>"
        let parsed = try XCTUnwrap(ToolCallParser.parseAll(leaked))
        XCTAssertEqual(parsed.calls.map(\.name), ["list_files"])
        XCTAssertTrue(parsed.repaired)

        // Plain reply returns nil
        XCTAssertNil(try ToolCallParser.parseAll("Just a normal answer with 2 < 3."))
    }

    // MARK: - Upgraded ToolCallGrammar (Query '<', Typed Params, Multi-Call, Flexible Order, JSON)

    func testGrammarAllowsAngleBracketsInSearchQueryWhileBlockingProtocolAndNewlines() throws {
        let grammar = try XCTUnwrap(ToolCallGrammar.make(tools: AgentPrompt.toolLines(for: .local), family: .bonsai))
        let matcher = EngineGrammarMatcher(grammar)

        // Previously broken: `<` in `search_repo` query was forbidden by `line`.
        for valid in [
            "<tool_call>\n<function=search_repo>\n<parameter=query>\nArray<Int>\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=search_repo>\n<parameter=query>\n<div class=\"card\">\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=search_repo>\n<parameter=query>\nif a < b && c > d\n</parameter>\n</function>\n</tool_call>",
        ] {
            XCTAssertTrue(matcher.matches(valid), "Should allow query: \(valid)")
        }
        // Still rejects protocol injection & multiline queries
        for invalid in [
            "<tool_call>\n<function=search_repo>\n<parameter=query>\nline1\nline2\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=search_repo>\n<parameter=query>\nx<parameter=path>y\n</parameter>\n</function>\n</tool_call>",
        ] {
            XCTAssertFalse(matcher.matches(invalid), "Should reject query: \(invalid)")
        }
    }

    func testGrammarEnforcesBooleanNumberAndEnumTypes() throws {
        let mcpTool = MCPConnector.Tool(
            remoteName: "filter",
            callName: "mcp_demo_filter",
            description: "Filter items",
            parameters: [
                .init(name: "archived", type: "boolean", required: true),
                .init(name: "min_score", type: "number", required: true),
            ],
            readOnly: true
        )
        let shortcut = ShortcutRun.tool(allowed: ["Lights off", "Morning routine"])
        let grammar = try XCTUnwrap(ToolCallGrammar.make(tools: [mcpTool.schemaLine, shortcut, ImageRequest.tool], family: .bonsai))
        let matcher = EngineGrammarMatcher(grammar)

        XCTAssertTrue(matcher.matches("<tool_call><function=mcp_demo_filter><parameter=archived>true</parameter><parameter=min_score>-12.5</parameter></function></tool_call>"))
        XCTAssertFalse(matcher.matches("<tool_call><function=mcp_demo_filter><parameter=archived>yes</parameter><parameter=min_score>1.0</parameter></function></tool_call>"))
        XCTAssertFalse(matcher.matches("<tool_call><function=mcp_demo_filter><parameter=archived>false</parameter><parameter=min_score>abc</parameter></function></tool_call>"))

        // Shortcut enum enforces exact allowed shortcut names at sampler level!
        XCTAssertTrue(matcher.matches("<tool_call><function=run_shortcut><parameter=name>Lights off</parameter></function></tool_call>"))
        XCTAssertFalse(matcher.matches("<tool_call><function=run_shortcut><parameter=name>Delete everything</parameter></function></tool_call>"))

        // ImageRequest size enum enforces 256|384|512!
        XCTAssertTrue(matcher.matches("<tool_call><function=generate_image><parameter=prompt>a cat</parameter><parameter=path>cat.png</parameter><parameter=size>384</parameter></function></tool_call>"))
        XCTAssertFalse(matcher.matches("<tool_call><function=generate_image><parameter=prompt>a cat</parameter><parameter=path>cat.png</parameter><parameter=size>999</parameter></function></tool_call>"))
    }

    func testGrammarSupportsFlexibleParameterOrderAndMultiCallWithoutDuplicates() throws {
        let grammar = try XCTUnwrap(ToolCallGrammar.make(
            tools: AgentPrompt.toolLines(for: .local),
            family: .bonsai,
            options: .init(maxCalls: 3, flexibleParameterOrder: true)
        ))
        let matcher = EngineGrammarMatcher(grammar)

        // Optional `count` BEFORE required `path`
        XCTAssertTrue(matcher.matches("<tool_call><function=read_file><parameter=count>20</parameter><parameter=path>a.swift</parameter></function></tool_call>"))
        // `new_text` BEFORE `old_text` BEFORE `path`
        XCTAssertTrue(matcher.matches("<tool_call><function=propose_edit><parameter=new_text>b</parameter><parameter=old_text>a</parameter><parameter=path>x.txt</parameter></function></tool_call>"))
        // Duplicate parameter STILL rejected!
        XCTAssertFalse(matcher.matches("<tool_call><function=read_file><parameter=path>a.swift</parameter><parameter=path>b.swift</parameter></function></tool_call>"))
        // Missing required parameter STILL rejected!
        XCTAssertFalse(matcher.matches("<tool_call><function=read_file><parameter=count>20</parameter></function></tool_call>"))

        // Multi-call: 2 calls accepted, 4 calls rejected (maxCalls = 3)
        let one = "<tool_call><function=list_files><parameter=path>.</parameter></function></tool_call>"
        XCTAssertTrue(matcher.matches(one + "\n" + one))
        XCTAssertTrue(matcher.matches(one + "\n" + one + "\n" + one))
        XCTAssertFalse(matcher.matches(one + "\n" + one + "\n" + one + "\n" + one))
        XCTAssertFalse(matcher.matches(one + "\nExtra prose after call."))
    }

    func testJSONFormatGrammarMatchesAndParses() throws {
        let grammar = try XCTUnwrap(ToolCallGrammar.make(
            tools: AgentPrompt.toolLines(for: .repository),
            family: .bonsai,
            options: .init(maxCalls: 2, flexibleParameterOrder: false, format: .json)
        ))
        let matcher = EngineGrammarMatcher(grammar)
        let valid = #"<tool_call>{"name":"read_file","arguments":{"path":"README.md","start_line":1,"count":40}}</tool_call>"#
        XCTAssertTrue(matcher.matches(valid))
        XCTAssertEqual(try ToolCallParser.parseAll(valid)?.calls.first?.name, "read_file")

        let two = valid + "\n" + #"<tool_call>{"name":"list_files","arguments":{"path":"."}}</tool_call>"#
        XCTAssertTrue(matcher.matches(two))
        XCTAssertEqual(try ToolCallParser.parseAll(two)?.calls.count, 2)

        // Unknown tool rejected
        XCTAssertFalse(matcher.matches(#"<tool_call>{"name":"delete_file","arguments":{"path":"README.md"}}</tool_call>"#))
    }

    func testGrammarExtraToolsUnlocksDynamicallyLoadedToolsWithoutPromptMutation() throws {
        let prompt = AgentPrompt.chatML(system: AgentPrompt.local(mode: .chat, hasFiles: true, hasLink: false), messages: [("user", "hi")])
        let baseGrammar = try XCTUnwrap(ToolCallGrammar.make(prompt: prompt, family: .bonsai))
        XCTAssertFalse(baseGrammar.text.contains("calendar_events"))

        let expanded = try XCTUnwrap(ToolCallGrammar.make(prompt: prompt, family: .bonsai, extraTools: CalendarTools.allTools))
        XCTAssertTrue(expanded.text.contains("calendar_events"))
        XCTAssertTrue(expanded.text.contains("read_file"))
    }

    // MARK: - Upgraded ToolCallStopDetector (Multi-Call + All Formats)

    func testMultiCallStopDetectorAllowsBackToBackCallsAndCutsTrailingProse() {
        let call1 = "<tool_call><function=read_file><parameter=path>a.txt</parameter></function></tool_call>"
        let call2 = "<tool_call><function=read_file><parameter=path>b.txt</parameter></function></tool_call>"

        // Allows 2nd call to follow 1st call when maxCalls = 3
        var d1 = ToolCallStopDetector(maxCalls: 3)
        XCTAssertFalse(d1.feed(call1))
        XCTAssertEqual(d1.completedCalls, 1)
        XCTAssertFalse(d1.feed("\n"))
        XCTAssertFalse(d1.feed(call2))
        XCTAssertEqual(d1.completedCalls, 2)
        // As soon as trailing prose starts after call2, stop and trim back to end of call2!
        XCTAssertTrue(d1.feed("\nNow I will summarize"))
        XCTAssertEqual(d1.text, call1 + "\n" + call2)

        // Stops immediately at maxCalls
        var d2 = ToolCallStopDetector(maxCalls: 2)
        XCTAssertFalse(d2.feed(call1 + "\n"))
        XCTAssertTrue(d2.feed(call2 + " trailing"))
        XCTAssertEqual(d2.text, call1 + "\n" + call2)

        // MiniCPM bare function & LFM block also trigger clean stop
        var dMini = ToolCallStopDetector(maxCalls: 1)
        XCTAssertTrue(dMini.feed("<function name=\"list_files\"><param name=\"path\">.</param></function> extra"))
        XCTAssertEqual(dMini.text, "<function name=\"list_files\"><param name=\"path\">.</param></function>")

        var dLFM = ToolCallStopDetector(maxCalls: 1)
        XCTAssertTrue(dLFM.feed("<|tool_call_start|>[list_files(path=\".\")]<|tool_call_end|> extra"))
        XCTAssertEqual(dLFM.text, "<|tool_call_start|>[list_files(path=\".\")]<|tool_call_end|>")
    }

    // MARK: - KV-Cache-Safe ToolRouter & Progressive Disclosure

    func testToolRouterKeepsSmallCatalogsDirectAndDefersLargeOrApple4KCatalogs() {
        let standardTools = AgentPrompt.localCatalog(mode: .work)
        XCTAssertEqual(standardTools.count, 8)

        // <= 8K context budget = 10 -> zero indirection for standard 10-tool chat (even at 4K simulator context)!
        let smallBudget = ToolRouter.activeBudget(contextSize: 8_192, isAppleSystemModel: false, isSmallModel: true)
        XCTAssertEqual(smallBudget, 10)
        XCTAssertEqual(ToolRouter.activeBudget(contextSize: 4_096, isAppleSystemModel: false, isSmallModel: true), 10)
        XCTAssertEqual(ToolRouter.activeBudget(contextSize: 16_384, isAppleSystemModel: false, isSmallModel: true), 12)
        let directPlan = ToolRouter.plan(availableToolLines: standardTools, initialQuery: "Make a web page", mode: .work, budget: smallBudget)
        XCTAssertFalse(directPlan.usesProgressiveDisclosure)
        XCTAssertEqual(directPlan.activeToolLines.count, 8)

        // Apple 4K model budget = 5 -> progressive disclosure keeps prompt lean!
        let appleBudget = ToolRouter.activeBudget(contextSize: 4_096, isAppleSystemModel: true)
        XCTAssertEqual(appleBudget, 5)
        let richCatalog = AgentPrompt.localCatalog(
            mode: .work, webSearch: true, github: true, memory: true, recall: true,
            shortcuts: ["Lights off"], calendar: true
        )
        XCTAssertGreaterThan(richCatalog.count, 15)

        let applePlan = ToolRouter.plan(
            availableToolLines: richCatalog,
            initialQuery: "Check my calendar events for tomorrow and add a reminder",
            mode: .work,
            budget: appleBudget
        )
        XCTAssertTrue(applePlan.usesProgressiveDisclosure)
        XCTAssertEqual(applePlan.activeToolLines.count, 5)
        let activeNames = Set(applePlan.activeToolLines.map(AgentPrompt.toolName))
        XCTAssertTrue(activeNames.contains(ToolRegistry.loadToolsName))
        XCTAssertTrue(activeNames.contains("calendar_events") || activeNames.contains("create_reminder"), "\(activeNames)")
        XCTAssertNotNil(applePlan.deferredSummary)

        // Resolving `load_tools` loads deferred groups cleanly without mutating the system prompt
        let loaded = ToolRouter.resolveLoadTools(arguments: ["group": "github"], plan: applePlan, alreadyActive: activeNames)
        XCTAssertEqual(Set(loaded.newlyActivated), ["github_repos", "github_open"])
        XCTAssertTrue(loaded.responseText.contains("github_repos"))
        XCTAssertTrue(loaded.responseText.contains("github_open"))

        // Requesting an unauthorized tool name returns nothing
        let denied = ToolRouter.resolveLoadTools(arguments: ["names": "run_subprocess"], plan: applePlan, alreadyActive: activeNames)
        XCTAssertTrue(denied.newlyActivated.isEmpty)
        XCTAssertTrue(denied.responseText.contains("No matching tools"))

        // AgentPrompt.local integrates routingPlan + day-level date context
        let prompt = AgentPrompt.local(
            mode: .work, webSearch: true, github: true, calendar: true,
            routingPlan: applePlan,
            currentDate: ToolRouter.dateContextLine(now: Date(timeIntervalSince1970: 1_795_564_800), timeZone: TimeZone(secondsFromGMT: 0)!)
        )
        XCTAssertTrue(prompt.contains("Today is "))
        XCTAssertTrue(prompt.contains("load_tools"))
        XCTAssertTrue(prompt.contains("More tools are available on demand"))
    }

    func testToolRouterKeepsWarmToolsAndFollowUpsWhenCatalogExceedsBudget() {
        let richCatalog = AgentPrompt.localCatalog(
            mode: .work, webSearch: true, github: true, memory: true, image: true,
            recall: true, shortcuts: ["Lights off"], calendar: true
        )
        XCTAssertGreaterThan(richCatalog.count, 15)

        let plan = ToolRouter.plan(
            availableToolLines: richCatalog,
            initialQuery: "make the resolution higher and update the file",
            mode: .work,
            budget: 5,
            hasFiles: true,
            hasLink: false,
            recentToolNames: ["read_file", "generate_image"]
        )
        XCTAssertTrue(plan.usesProgressiveDisclosure)
        let activeNames = Set(plan.activeToolLines.map(AgentPrompt.toolName))
        XCTAssertTrue(activeNames.contains(ToolRegistry.loadToolsName))
        XCTAssertTrue(activeNames.contains("read_file"), "\(activeNames)")
        XCTAssertTrue(activeNames.contains("generate_image"), "\(activeNames)")
        // Follow-ups from the warm set should win a scarce Apple-sized budget.
        XCTAssertTrue(activeNames.contains("propose_edit") || activeNames.contains("create_file"), "\(activeNames)")
    }

    func testToolRouterRecentToolNamesExtractsFromAssistantMarkup() {
        let texts = [
            #"<tool_call><function=read_file><parameter=path>a.md</parameter></function></tool_call>"#,
            #"<tool_call>{"name": "generate_image", "arguments": {"path": "out.png"}}</tool_call>"#,
            #"<function name="propose_edit"><param name="path">a.md</param></function>"#
        ]
        // Chronological texts → last two unique names.
        let recent = ToolRouter.recentToolNames(fromAssistantToolTexts: texts, limit: 2)
        XCTAssertEqual(recent, ["generate_image", "propose_edit"])

        let qwenOnly = ToolRouter.recentToolNames(
            fromAssistantToolTexts: [texts[0], texts[0]],
            limit: 2
        )
        XCTAssertEqual(qwenOnly, ["read_file"])
    }

    func testLFMPythonRawStringsPreserveBackslashesForRegexAndShellCommands() throws {
        let rawCall = #"<|tool_call_start|>[search_repo(query=r"^\d+\s+foo\n"), shell(command=R'grep -E "\w+\.swift" Sources/App.swift')]<|tool_call_end|>"#
        let parsed = try XCTUnwrap(ToolCallParser.parseAll(rawCall, family: .lfm3))
        XCTAssertEqual(parsed.format, .lfmPython)
        XCTAssertEqual(parsed.calls.count, 2)
        XCTAssertEqual(parsed.calls[0].name, "search_repo")
        XCTAssertEqual(parsed.calls[0].arguments["query"], #"^\d+\s+foo\n"#)
        XCTAssertEqual(parsed.calls[1].name, "shell")
        XCTAssertEqual(parsed.calls[1].arguments["command"], #"grep -E "\w+\.swift" Sources/App.swift"#)
    }
}

/// Lightweight grammar matcher for verifying new grammar features in this test file.
private struct EngineGrammarMatcher {
    let rules: [String: ToolCallGrammar.Node]
    let start: String

    init(_ grammar: ToolCallGrammar) {
        self.rules = Dictionary(uniqueKeysWithValues: grammar.rules.map { ($0.name, $0.node) })
        self.start = ToolCallGrammar.root
    }

    func matches(_ text: String) -> Bool {
        let characters = text.unicodeScalars.map { Character(String($0)) }
        return run(.rule(start), from: [0], characters).contains(characters.count)
    }

    private func run(_ node: ToolCallGrammar.Node, from starts: Set<Int>, _ text: [Character]) -> Set<Int> {
        var ends = Set<Int>()
        switch node {
        case .literal(let literal):
            let expected = Array(literal)
            for start in starts {
                var index = 0
                while index < expected.count, start + index < text.count, text[start + index] == expected[index] { index += 1 }
                if index == expected.count { ends.insert(start + index) }
            }
        case .chars(let set, let negated):
            for start in starts {
                if start < text.count, set.contains(text[start]) != negated { ends.insert(start + 1) }
            }
        case .rule(let name):
            ends = run(rules[name]!, from: starts, text)
        case .sequence(let items):
            ends = items.reduce(starts) { run($1, from: $0, text) }
        case .choice(let items):
            for item in items { ends.formUnion(run(item, from: starts, text)) }
        case .repeated(let item, let min, let max):
            var current = starts, count = 0
            if min == 0 { ends = starts }
            while !current.isEmpty, max.map({ count < $0 }) ?? true {
                let next = run(item, from: current, text)
                count += 1
                let fresh = next.subtracting(count > min ? ends : [])
                if count >= min { ends.formUnion(next) }
                if max == nil && fresh.isEmpty { break }
                current = max == nil ? fresh : next
            }
        }
        return ends
    }
}
