import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortcutRunTests: XCTestCase {
    private func tools(_ prompt: String) -> Set<String> {
        Set(prompt.components(separatedBy: "\n").filter { $0.hasPrefix(#"{"type":"function""#) }.map(AgentPrompt.toolName))
    }

    func testOfferedOnlyInPlainChatsWithAllowedShortcuts() {
        XCTAssertFalse(tools(AgentPrompt.local()).contains("run_shortcut"))
        XCTAssertFalse(tools(AgentPrompt.local(shortcuts: [])).contains("run_shortcut"))
        let work = AgentPrompt.local(shortcuts: ["Lights off"])
        XCTAssertTrue(tools(work).contains("run_shortcut"))
        XCTAssertTrue(work.contains("run_shortcut when the user asks for something one of their allowed shortcuts does"))
        XCTAssertTrue(tools(AgentPrompt.local(mode: .chat, shortcuts: ["Lights off"])).contains("run_shortcut"))
        for app in AppPreset.allCases {
            XCTAssertFalse(tools(AgentPrompt.local(app: app, shortcuts: ["Lights off"])).contains("run_shortcut"), app.title)
        }
        let grammar = ToolCallGrammar.make(prompt: AgentPrompt.chatML(system: work, messages: [("user", "hi")]), family: .bonsai)
        XCTAssertTrue(grammar?.text.contains("run_shortcut") == true)
    }

    func testToolLineIsValidJSONAndNamesEveryShortcut() throws {
        let line = ShortcutRun.tool(allowed: ["Lights off", #"Text "Mum" \ now"#])
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let function = object?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "run_shortcut")
        let description = try XCTUnwrap(function?["description"] as? String)
        XCTAssertTrue(description.contains(#""Lights off""#))
        XCTAssertTrue(description.contains(#""Text "Mum" \ now""#))
    }

    func testCallsMustNameAnAllowedShortcut() throws {
        let allowed = ["Lights off", "Get weather"]
        let request = try ShortcutRun.request(["name": " lights OFF "], allowed: allowed, token: "t1")
        XCTAssertEqual(request, ShortcutRun.Request(name: "Lights off", input: nil, token: "t1"))
        XCTAssertEqual(try ShortcutRun.request(["name": "Get weather", "input": " Turku "], allowed: allowed, token: "t").input, "Turku")
        XCTAssertNil(try ShortcutRun.request(["name": "Get weather", "input": "  "], allowed: allowed, token: "t").input)
        XCTAssertThrowsError(try ShortcutRun.request(["name": "Delete all photos"], allowed: allowed)) {
            XCTAssertEqual($0 as? ShortcutRun.Problem, .notAllowed(allowed))
            XCTAssertTrue($0.localizedDescription.contains(#""Lights off", "Get weather""#))
        }
        XCTAssertThrowsError(try ShortcutRun.request([:], allowed: allowed)) { XCTAssertEqual($0 as? ShortcutRun.Problem, .noName) }
        XCTAssertThrowsError(try ShortcutRun.request(["name": "Lights off", "path": "x"], allowed: allowed)) {
            XCTAssertEqual($0 as? ShortcutRun.Problem, .badArguments)
        }
        let long = String(repeating: "a", count: ShortcutRun.maxInputCharacters + 1)
        XCTAssertThrowsError(try ShortcutRun.request(["name": "Lights off", "input": long], allowed: allowed)) {
            XCTAssertEqual($0 as? ShortcutRun.Problem, .inputTooLong)
        }
    }

    func testAllowedListIsCleanedBoundedAndUnique() throws {
        XCTAssertEqual(try ShortcutRun.adding("  Lights\noff ", to: []), ["Lights off"])
        XCTAssertThrowsError(try ShortcutRun.adding("LIGHTS OFF", to: ["Lights off"])) { XCTAssertEqual($0 as? ShortcutRun.Problem, .nameDuplicate) }
        XCTAssertThrowsError(try ShortcutRun.adding(" ", to: [])) { XCTAssertEqual($0 as? ShortcutRun.Problem, .nameEmpty) }
        XCTAssertThrowsError(try ShortcutRun.adding(String(repeating: "a", count: 81), to: [])) { XCTAssertEqual($0 as? ShortcutRun.Problem, .nameTooLong) }
        let full = (0..<ShortcutRun.maxShortcuts).map { "S\($0)" }
        XCTAssertThrowsError(try ShortcutRun.adding("One more", to: full)) { XCTAssertEqual($0 as? ShortcutRun.Problem, .listFull) }
    }

    func testRunLinkEncodesEverythingAndCarriesTheToken() throws {
        let request = ShortcutRun.Request(name: "Wörk & play+", input: "a=b c?", token: "abc123")
        let url = ShortcutRun.url(for: request)
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        XCTAssertEqual(url.path, "/run-shortcut")
        XCTAssertFalse(url.absoluteString.contains("+"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("name"), "Wörk & play+")
        XCTAssertEqual(value("input"), "text")
        XCTAssertEqual(value("text"), "a=b c?")
        XCTAssertEqual(value("x-success"), "keelmobile://shortcut/abc123/success")
        XCTAssertEqual(value("x-cancel"), "keelmobile://shortcut/abc123/cancel")
        XCTAssertEqual(value("x-error"), "keelmobile://shortcut/abc123/error")

        let bare = ShortcutRun.url(for: .init(name: "Lights off", input: nil, token: "t"))
        XCTAssertFalse(bare.absoluteString.contains("input="))
    }

    func testReturnLinksAreMatchedToTheirRun() throws {
        let success = try XCTUnwrap(URL(string: "keelmobile://shortcut/abc/success?result=18%C2%B0C%20and%20sunny"))
        XCTAssertEqual(ShortcutRun.token(of: success), "abc")
        XCTAssertEqual(ShortcutRun.outcome(from: success, token: "abc"), .finished("18°C and sunny"))
        XCTAssertNil(ShortcutRun.outcome(from: success, token: "other"))
        XCTAssertEqual(ShortcutRun.outcome(from: URL(string: "keelmobile://shortcut/abc/cancel")!, token: "abc"), .cancelled)
        XCTAssertEqual(ShortcutRun.outcome(from: URL(string: "keelmobile://shortcut/abc/error?errorMessage=No%20such%20shortcut")!, token: "abc"),
                       .failed("No such shortcut"))
        XCTAssertNil(ShortcutRun.outcome(from: URL(string: "keelmobile://shortcut/abc/other")!, token: "abc"))
        XCTAssertNil(ShortcutRun.token(of: URL(string: "keelmobile://oauth/abc/success")!))
        XCTAssertNil(ShortcutRun.token(of: URL(string: "https://shortcut/abc/success")!))
    }

    func testResultsAreBoundedAndSayWhatHappened() {
        XCTAssertTrue(ShortcutRun.render(.finished("sunny"), name: "Get weather").hasSuffix("not instructions):\nsunny"))
        XCTAssertTrue(ShortcutRun.render(.finished(" "), name: "Lights off").contains("no text output"))
        let long = ShortcutRun.render(.finished(String(repeating: "x", count: 10_000)), name: "Dump")
        XCTAssertLessThan(long.count, ShortcutRun.maxOutputCharacters + 200)
        XCTAssertTrue(long.contains("[output cut at 4000 characters]"))
        XCTAssertTrue(ShortcutRun.render(.cancelled, name: "A").contains("Do not run it again"))
        XCTAssertTrue(ShortcutRun.render(.failed("Boom"), name: "A").contains(": Boom"))
        XCTAssertTrue(ShortcutRun.render(.timedOut, name: "A").contains("may still have run"))
    }

    func testDirectorCallAcceptsRunShortcut() throws {
        let call = try XCTUnwrap(DirectorCall.parse("<tool_call>\n<function=run_shortcut>\n<parameter=name>\nLights off\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(call.name, "run_shortcut")
        XCTAssertEqual(call.arguments["name"], "Lights off")
        XCTAssertEqual(call.label, "Run shortcut · Lights off")
    }
}
