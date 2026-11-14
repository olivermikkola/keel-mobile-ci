import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ToolCallGrammarTests: XCTestCase {
    private let localTools = AgentPrompt.toolLines(for: .local)

    private func grammar(_ family: ModelFamily = .lfm3) throws -> ToolCallGrammar {
        try XCTUnwrap(ToolCallGrammar.make(tools: localTools, family: family))
    }

    func testCanonicalCallsForEveryOfferedToolMatchAndParse() throws {
        let grammar = try grammar()
        let calls = [
            "<tool_call>\n<function=list_files>\n<parameter=path>\n.\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=read_file>\n<parameter=path>\nsrc/app.js\n</parameter>\n<parameter=start_line>\n12\n</parameter>\n<parameter=count>\n30\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=search_repo>\n<parameter=query>\nfetch(&lt;url&gt;)\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=create_file>\n<parameter=path>\nindex.html\n</parameter>\n<parameter=new_text>\n<!doctype html>\n<p class=\"a\">2 < 3 & ok</p>\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=propose_edit>\n<parameter=path>\na.txt\n</parameter>\n<parameter=old_text>\nx</paramete\n</parameter>\n<parameter=new_text>\ny\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=rename_file>\n<parameter=path>\na.md\n</parameter>\n<parameter=destination_path>\ndocs/a.md\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=delete_file>\n<parameter=path>\nold.csv\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=run_sql>\n<parameter=sql>\nSELECT SUM(amount) FROM \"numbers.csv\" WHERE amount &lt; 5;\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=run_js>\n<parameter=code>\nconst t = await keel.readFile('a.txt');\nconsole.log(t.length < 3 ? \"short\" : 'long');\n</parameter>\n</function>\n</tool_call>",
            "<tool_call><function=list_files><parameter=path>docs</parameter></function></tool_call>",
        ]
        for call in calls {
            XCTAssertTrue(GrammarMatcher(grammar).matches(call), call)
            XCTAssertNotNil(try DirectorCall.parse(call), call)
        }
    }

    func testLFM3WrappedJSONArgumentsCannotBeWritten() throws {
        // The failure from #62's CI runs, verbatim in shape.
        let wrapped = "<tool_call>\n<function=run_sql>\n<parameter=parameters>\n{\"sql\": \"SELECT SUM(amount) FROM numbers.csv\"}\n</parameter>\n</function>\n</tool_call>"
        XCTAssertFalse(GrammarMatcher(try grammar()).matches(wrapped))
    }

    func testRejectsUnknownToolsMissingRequiredDuplicatesAndBadNumbers() throws {
        let matcher = GrammarMatcher(try grammar())
        let rejected = [
            "<tool_call>\n<function=run_shell>\n<parameter=code>\nls\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=propose_edit>\n<parameter=path>\na\n</parameter>\n<parameter=new_text>\nb\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=read_file>\n<parameter=path>\na\n</parameter>\n<parameter=path>\nb\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=read_file>\n<parameter=path>\na\n</parameter>\n<parameter=count>\nthirty\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=read_file>\n<parameter=path>\na\nb\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=run_js>\n<parameter=code>\nx<parameter=sql>\n</parameter>\n</function>\n</tool_call>",
            "<tool_call>\n<function=list_files>\n<parameter=path>\n.\n</parameter>\n</function>\n</tool_call>\nDone, I listed the files.",
            "<tool_call>\n<function=list_files>\n<parameter=path>\n.\n</parameter>\n</function>\n",
        ]
        for text in rejected { XCTAssertFalse(matcher.matches(text), text) }
        // A partial call is a live prefix: the grammar keeps going rather than dead-ending.
        XCTAssertTrue(matcher.isPrefix("<tool_call>\n<function=read_file>\n<parameter=path>\nsrc/"))
        XCTAssertFalse(matcher.isPrefix("<tool_call>\n<function=read_fil>"))
    }

    func testOnlyOfferedToolsAreReachable() throws {
        let readOnly = try XCTUnwrap(ToolCallGrammar.make(tools: AgentPrompt.toolLines(for: .repository), family: .bonsai))
        let edit = "<tool_call>\n<function=create_file>\n<parameter=path>\na\n</parameter>\n<parameter=new_text>\nb\n</parameter>\n</function>\n</tool_call>"
        XCTAssertFalse(GrammarMatcher(readOnly).matches(edit))
        XCTAssertTrue(GrammarMatcher(readOnly).matches("<tool_call>\n<function=search_repo>\n<parameter=query>\nmain\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertNil(ToolCallGrammar.make(tools: [], family: .bonsai))
        XCTAssertNil(ToolCallGrammar.make(tools: ["not json"], family: .bonsai))
    }

    func testMiniCPMNativeCallsMatchAndNormalize() throws {
        let grammar = try grammar(.miniCPM5)
        XCTAssertEqual(grammar.triggerPatterns, ["(<function)"])
        let accepted = [
            "<function name=\"run_sql\"><param name=\"sql\"><![CDATA[SELECT SUM(amount) FROM \"numbers.csv\" WHERE a < 3 && b]]></param></function>",
            "<function name=\"read_file\"><param name=\"path\">a&amp;b.txt</param><param name=\"count\">20</param></function>",
            "<function name=\"create_file\">\n<param name=\"path\">x.js</param>\n<param name=\"new_text\"><![CDATA[a]]]]><![CDATA[>b]]></param>\n</function>",
        ]
        for call in accepted {
            XCTAssertTrue(GrammarMatcher(grammar).matches(call), call)
            XCTAssertNoThrow(try NativeToolCall.normalize(call, family: .miniCPM5), call)
        }
        let rejected = [
            "<function name=\"read_file\"><param name=\"path\">a & b</param></function>",
            "<function name=\"read_file\"><param name=\"count\">20</param></function>",
            "<function name=\"run_sql\"><param name=\"sql\"><![CDATA[a]]>]]></param></function>",
            "<function name=\"run_sql\"><param name=\"parameters\">{}</param></function>",
        ]
        for call in rejected { XCTAssertFalse(GrammarMatcher(grammar).matches(call), call) }
    }

    func testSingleLineArgumentsCannotHideExtraNewlines() throws {
        let qwen = try grammar(.lfm3)
        for value in ["\n\nword\n", "\nword\n\n", "word\rnext", "word\r\nnext"] {
            let call = "<tool_call><function=search_repo><parameter=query>" + value + "</parameter></function></tool_call>"
            XCTAssertFalse(GrammarMatcher(qwen).matches(call), value)
        }
        let native = try grammar(.miniCPM5)
        for value in ["first\nsecond", "first\rsecond", "first\r\nsecond"] {
            for text in [value, "<![CDATA[" + value + "]]>"] {
                let call = "<function name=\"search_repo\"><param name=\"query\">" + text + "</param></function>"
                XCTAssertFalse(GrammarMatcher(native).matches(call), call)
            }
        }
    }

    func testTriggersAndTextAreStable() throws {
        let first = try grammar(.bonsai), second = try grammar(.bonsai)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.triggerPatterns, ["(<tool_call>)"])
        XCTAssertEqual(try grammar(.lfm3), first)
        XCTAssertTrue(first.text.hasPrefix("root ::= \"<tool_call>\" ws call ws \"</tool_call>\"\n"))
        for line in first.text.split(separator: "\n") {
            let name = line.components(separatedBy: " ::= ").first ?? ""
            XCTAssertNotNil(name.range(of: "^[a-z0-9-]+$", options: .regularExpression), String(line))
        }
    }

    func testExclusionAutomatonAgreesWithSubstringSearch() {
        let patterns = ["</parameter>", "<parameter=", "<function=", "<tool_call"]
        let rules = ToolCallGrammar.excluding(patterns, prefix: "x")
        let matcher = GrammarMatcher(rules: rules, start: "x")
        var generator = SystemRandomNumberGenerator()
        let pieces = ["<", "/", "p", "a", "r", "m", "e", "t", ">", "=", "f", "u", "n", "c", "i", "o", "_", "l", "\n", "ä"]
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 0...24, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            XCTAssertEqual(matcher.matches(text), !patterns.contains { text.contains($0) }, text)
        }
        for text in ["</parameter>", "a<</parameter>", "<tool_call>", "<<parameter=x"] {
            XCTAssertFalse(matcher.matches(text), text)
        }
        XCTAssertTrue(matcher.matches("</paramete <parameter <function <tool_cal"))
    }
}

/// Runs the grammar tree directly: the set of end positions reachable from
/// each start. Small and slow, for tests only; llama.cpp runs the GBNF text.
private struct GrammarMatcher {
    let rules: [String: ToolCallGrammar.Node]
    let start: String

    init(_ grammar: ToolCallGrammar) { self.init(rules: grammar.rules, start: ToolCallGrammar.root) }
    init(rules: [(name: String, node: ToolCallGrammar.Node)], start: String) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.name, $0.node) })
        self.start = start
    }

    func matches(_ text: String) -> Bool {
        let characters = text.unicodeScalars.map { Character(String($0)) }
        return run(.rule(start), from: [0], characters, prefix: false).contains(characters.count)
    }

    /// True if some continuation of `text` would match.
    func isPrefix(_ text: String) -> Bool {
        let characters = text.unicodeScalars.map { Character(String($0)) }
        return run(.rule(start), from: [0], characters, prefix: true).contains(characters.count)
    }

    /// With `prefix`, reaching the end of the input part-way through a node counts as the end.
    private func run(_ node: ToolCallGrammar.Node, from starts: Set<Int>, _ text: [Character], prefix: Bool) -> Set<Int> {
        var ends = Set<Int>()
        switch node {
        case .literal(let literal):
            let expected = Array(literal)
            for start in starts {
                var index = 0
                while index < expected.count, start + index < text.count, text[start + index] == expected[index] { index += 1 }
                if index == expected.count { ends.insert(start + index) }
                else if prefix && start + index == text.count { ends.insert(text.count) }
            }
        case .chars(let set, let negated):
            for start in starts {
                if start < text.count, set.contains(text[start]) != negated { ends.insert(start + 1) }
                else if prefix && start == text.count { ends.insert(start) }
            }
        case .rule(let name):
            ends = run(rules[name]!, from: starts, text, prefix: prefix)
        case .sequence(let items):
            ends = items.reduce(starts) { run($1, from: $0, text, prefix: prefix) }
        case .choice(let items):
            for item in items { ends.formUnion(run(item, from: starts, text, prefix: prefix)) }
        case .repeated(let item, let min, let max):
            var current = starts, count = 0
            if min == 0 { ends = starts }
            while !current.isEmpty, max.map({ count < $0 }) ?? true {
                // Stop on positions already seen with no progress, so `*` terminates.
                let next = run(item, from: current, text, prefix: prefix)
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
