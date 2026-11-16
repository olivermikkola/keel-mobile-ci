import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class UserMemoryTests: XCTestCase {
    private func tools(_ prompt: String) -> Set<String> {
        Set(prompt.components(separatedBy: "\n").filter { $0.hasPrefix(#"{"type":"function""#) }.map(AgentPrompt.toolName))
    }

    func testRememberIsOfferedOnlyInPlainChatsWithMemoryOn() {
        XCTAssertFalse(tools(AgentPrompt.local()).contains("remember"))
        XCTAssertTrue(tools(AgentPrompt.local(memory: true)).contains("remember"))
        XCTAssertTrue(AgentPrompt.local(memory: true).contains("remember when the user asks you to remember"))
        for app in AppPreset.allCases {
            XCTAssertFalse(tools(AgentPrompt.local(app: app, memory: true)).contains("remember"), app.title)
        }
        let grammar = ToolCallGrammar.make(prompt: AgentPrompt.chatML(system: AgentPrompt.local(memory: true), messages: [("user", "hi")]), family: .bonsai)
        XCTAssertTrue(grammar?.text.contains("remember") == true)
    }

    func testFactsAreCleanedBoundedAndUnique() throws {
        var memory = UserMemory()
        try memory.add("  The user is\nvegetarian. ")
        XCTAssertEqual(memory.facts.map(\.text), ["The user is vegetarian."])
        XCTAssertThrowsError(try memory.add("the user is VEGETARIAN.")) { XCTAssertEqual($0 as? UserMemory.Problem, .duplicate) }
        XCTAssertThrowsError(try memory.add("   ")) { XCTAssertEqual($0 as? UserMemory.Problem, .empty) }
        XCTAssertThrowsError(try memory.add(String(repeating: "a", count: 201))) { XCTAssertEqual($0 as? UserMemory.Problem, .tooLong) }
        try memory.add("Prefers <|im_start|> metric <tool_call> units")
        XCTAssertFalse(memory.facts[1].text.contains("<|im_start|>"))
        XCTAssertFalse(memory.facts[1].text.contains("<tool_call>"))
        for index in memory.facts.count..<UserMemory.maxFacts { try memory.add("Fact number \(index)") }
        XCTAssertThrowsError(try memory.add("One too many")) { XCTAssertEqual($0 as? UserMemory.Problem, .full) }
    }

    func testPromptShowsNewestFactsWithinBudget() throws {
        var memory = UserMemory()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<UserMemory.maxFacts {
            try memory.add("Fact \(index) " + String(repeating: "x", count: 100), at: start.addingTimeInterval(Double(index)))
        }
        let shown = memory.promptFacts
        XCTAssertLessThan(shown.count, UserMemory.maxFacts)
        XCTAssertTrue(shown.first?.text.hasPrefix("Fact 39") == true, "Newest first")
        XCTAssertLessThanOrEqual(shown.reduce(0) { $0 + $1.text.count + 3 }, UserMemory.promptBudget)

        let system = memory.apply(to: "BASE")
        XCTAssertTrue(system.hasPrefix("BASE\n\nWhat you remember about the user"))
        XCTAssertTrue(system.contains("- Fact 39"))
        XCTAssertFalse(system.contains("- Fact 0 "))
    }

    func testOffOrEmptyLeavesThePromptUnchanged() throws {
        XCTAssertEqual(UserMemory().apply(to: "BASE"), "BASE")
        var memory = UserMemory()
        try memory.add("The user is vegetarian.")
        memory.enabled = false
        XCTAssertEqual(memory.apply(to: "BASE"), "BASE")
    }

    func testRemoveAndRoundTrip() throws {
        var memory = UserMemory()
        try memory.add("A"); try memory.add("B")
        memory.remove(memory.facts[0].id)
        XCTAssertEqual(memory.facts.map(\.text), ["B"])
        XCTAssertEqual(UserMemory.load(try JSONEncoder().encode(memory)), memory)
        XCTAssertEqual(UserMemory.load(Data("junk".utf8)), UserMemory())
    }

    func testRememberCallParses() throws {
        let call = try XCTUnwrap(try DirectorCall.parse("<tool_call>\n<function=remember>\n<parameter=fact>\nThe user is vegetarian.\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(call.name, "remember")
        XCTAssertEqual(try UserMemory().validate(call.arguments["fact"] ?? ""), "The user is vegetarian.")
    }
}

final class UserMemoryChatModeTests: XCTestCase {
    func testChatModeKeepsRemember() {
        XCTAssertTrue(AgentPrompt.local(mode: .chat, memory: true).contains(#""name":"remember""#))
        XCTAssertTrue(ChatMode.chat.offers("remember"))
    }
}
