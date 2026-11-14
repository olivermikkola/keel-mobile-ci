import Foundation

/// A GBNF grammar that lets the sampler write only a well-formed tool call.
///
/// The grammar is lazy: text before the call is free, and the grammar starts
/// when the output matches a trigger (`<tool_call>`, or `<function` for
/// MiniCPM5). From there the model can only pick a tool offered in the prompt,
/// its own parameter names, each at most once, every required parameter, and
/// digits for integers. Once the call is closed nothing but end-of-turn can
/// follow. This shapes tokens; it grants nothing. The strict parser, limits and
/// approval gates still decide what runs.
public struct ToolCallGrammar: Equatable, Sendable {
    public static let root = "root"
    /// The grammar in llama.cpp's GBNF syntax.
    public let text: String
    /// Regular expressions for `llama_sampler_init_grammar_lazy_patterns`.
    public let triggerPatterns: [String]
    let rules: [(name: String, node: Node)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.triggerPatterns == rhs.triggerPatterns
    }

    /// Builds the grammar for the tool lines given to `AgentPrompt.toolBlock`.
    /// Returns nil when no line describes a usable tool.
    static func make(tools: [String], family: ModelFamily) -> ToolCallGrammar? {
        var seen = Set<String>()
        let schemas = tools.compactMap(ToolSchema.init).filter { seen.insert($0.name).inserted }
        guard !schemas.isEmpty else { return nil }
        return family == .miniCPM5 ? native(schemas) : qwen(schemas)
    }

    // MARK: - Formats

    /// `<tool_call>\n<function=name>\n<parameter=key>\nvalue\n</parameter>\n</function>\n</tool_call>`,
    /// as `DirectorCall.parse` reads it. Bonsai and LFM3 write this.
    private static func qwen(_ schemas: [ToolSchema]) -> ToolCallGrammar {
        var rules: [(String, Node)] = [
            (root, .sequence([.literal("<tool_call>"), .rule("ws"), .rule("call"), .rule("ws"), .literal("</tool_call>")])),
            ("call", .choice(schemas.map { .rule(ruleName($0.name)) })),
        ]
        for schema in schemas {
            var body: [Node] = [.literal("<function=\(schema.name)>")]
            for parameter in schema.parameters {
                let name = ruleName(schema.name + "-" + parameter.name)
                rules.append((name, .sequence([.literal("<parameter=\(parameter.name)>"),
                                               .rule(parameter.kind.rawValue), .literal("</parameter>")])))
                let item = Node.sequence([.rule("ws"), .rule(name)])
                body.append(parameter.required ? item : .repeated(item, min: 0, max: 1))
            }
            rules.append((ruleName(schema.name), .sequence(body + [.rule("ws"), .literal("</function>")])))
        }
        let used = Set(schemas.flatMap { $0.parameters.map(\.kind) })
        rules.append(("ws", whitespace))
        if used.contains(.integer) {
            rules.append(("integer", .sequence([.rule("ws"), .repeated(digit, min: 1, max: 9), .rule("ws")])))
        }
        if used.contains(.line) {
            // The read parser unwraps one formatting newline at each end;
            // extra newlines would become part of a query and be rejected.
            let newline = Node.repeated(.literal("\n"), min: 0, max: 1)
            rules.append(("line", .sequence([newline, .repeated(.chars(["<", "\n", "\r"], negated: true), min: 1, max: nil), newline])))
        }
        if used.contains(.text) { rules += excluding(["</parameter>"], prefix: "text") }
        // DirectorCall.parse rejects these inside code and sql.
        if used.contains(.code) {
            rules += excluding(["</parameter>", "<parameter=", "<function=", "<tool_call"], prefix: "code")
        }
        return ToolCallGrammar(rules: rules, triggers: ["(<tool_call>)"])
    }

    /// `<function name="x"><param name="k"><![CDATA[value]]></param></function>`,
    /// MiniCPM5's native XML, which `NativeToolCall.normalize` reads.
    private static func native(_ schemas: [ToolSchema]) -> ToolCallGrammar {
        var rules: [(String, Node)] = [(root, .choice(schemas.map { .rule(ruleName($0.name)) }))]
        for schema in schemas {
            var body: [Node] = [.literal("<function name=\"\(schema.name)\">")]
            for parameter in schema.parameters {
                let name = ruleName(schema.name + "-" + parameter.name)
                let value = parameter.kind == .integer ? "xml-integer" : parameter.kind == .line ? "xml-line" : "xml-text"
                rules.append((name, .sequence([.literal("<param name=\"\(parameter.name)\">"), .rule(value), .literal("</param>")])))
                let item = Node.sequence([.rule("ws"), .rule(name)])
                body.append(parameter.required ? item : .repeated(item, min: 0, max: 1))
            }
            rules.append((ruleName(schema.name), .sequence(body + [.rule("ws"), .literal("</function>")])))
        }
        let entity = Node.sequence([.literal("&"), .choice(["lt", "gt", "amp", "quot", "apos"].map { .literal($0) }), .literal(";")])
        rules += [
            ("ws", whitespace),
            ("xml-integer", .sequence([.rule("ws"), .repeated(digit, min: 1, max: 9), .rule("ws")])),
            // XML text: entities and CDATA sections. A bare < or & is not XML,
            // and > is left out so text can never close a CDATA section (]]>).
            ("xml-text", .repeated(.choice([.chars(["<", "&", ">"], negated: true), entity,
                                            .sequence([.literal("<![CDATA["), .rule("cdata"), .literal("]]>")])]), min: 0, max: nil)),
        ]
        rules.append(("xml-line", .repeated(.choice([
            .chars(["<", "&", ">", "\n", "\r"], negated: true), entity,
            .sequence([.literal("<![CDATA["), .rule("cdata-line"), .literal("]]>")])
        ]), min: 1, max: nil)))
        rules += excluding(["]]>"], prefix: "cdata")
        rules += excluding(["]]>", "\n", "\r"], prefix: "cdata-line")
        return ToolCallGrammar(rules: rules, triggers: ["(<function)"])
    }

    private init(rules: [(String, Node)], triggers: [String]) {
        self.rules = rules
        self.triggerPatterns = triggers
        self.text = rules.map { "\($0.0) ::= \(Self.render($0.1, top: true))" }.joined(separator: "\n") + "\n"
    }

    private static let whitespace = Node.repeated(.chars([" ", "\t", "\n"], negated: false), min: 0, max: 4)
    private static let digit = Node.chars(Set("0123456789"), negated: false)

    /// GBNF rule names allow letters, digits and dashes.
    static func ruleName(_ name: String) -> String {
        "t-" + String(name.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
    }

    // MARK: - Text that never contains given strings

    /// Rules matching any text that contains none of `patterns`: an
    /// Aho-Corasick automaton written as right-recursive rules, one per state.
    /// The first rule (`prefix`) is the start state; every state may end.
    static func excluding(_ patterns: [String], prefix: String) -> [(String, Node)] {
        var next: [[Character: Int]] = [[:]], terminal = [false]
        for pattern in patterns {
            var state = 0
            for character in pattern {
                if let known = next[state][character] { state = known; continue }
                next.append([:]); terminal.append(false)
                next[state][character] = next.count - 1
                state = next.count - 1
            }
            terminal[state] = true
        }
        // Failure links in breadth-first order; a state is terminal if any
        // suffix of its text is a pattern.
        var fail = Array(repeating: 0, count: next.count), queue = Array(next[0].values)
        while !queue.isEmpty {
            let state = queue.removeFirst()
            for (character, child) in next[state] {
                var link = fail[state]
                while link != 0 && next[link][character] == nil { link = fail[link] }
                let target = next[link][character] ?? 0
                fail[child] = state == 0 ? 0 : target
                terminal[child] = terminal[child] || terminal[fail[child]]
                queue.append(child)
            }
        }
        func step(_ state: Int, _ character: Character) -> Int {
            var current = state
            while true {
                if let target = next[current][character] { return target }
                if current == 0 { return 0 }
                current = fail[current]
            }
        }
        let alphabet = Set(patterns.joined()).sorted()
        let live = (0..<next.count).filter { !terminal[$0] }
        let names = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1, $0 == 0 ? prefix : "\(prefix)-\($0)") })
        return live.map { state in
            var byTarget: [Int: Set<Character>] = [:]
            var leavesRoot = Set<Character>()
            for character in alphabet {
                let target = step(state, character)
                if terminal[target] { leavesRoot.insert(character); continue }
                if target != 0 { byTarget[target, default: []].insert(character); leavesRoot.insert(character) }
            }
            var options: [Node] = [.sequence([.chars(leavesRoot, negated: true), .rule(prefix)])]
            for target in byTarget.keys.sorted() {
                options.append(.sequence([.chars(byTarget[target]!, negated: false), .rule(names[target]!)]))
            }
            return (names[state]!, .repeated(.choice(options), min: 0, max: 1))
        }
    }

    // MARK: - Grammar tree and GBNF text

    indirect enum Node {
        case literal(String)
        case chars(Set<Character>, negated: Bool)
        case rule(String)
        case sequence([Node])
        case choice([Node])
        case repeated(Node, min: Int, max: Int?)
    }

    private static func render(_ node: Node, top: Bool = false) -> String {
        switch node {
        case .literal(let text):
            return "\"" + text.map { character -> String in
                switch character {
                case "\"": return "\\\""
                case "\\": return "\\\\"
                case "\n": return "\\n"
                case "\r": return "\\r"
                case "\t": return "\\t"
                default: return String(character)
                }
            }.joined() + "\""
        case .chars(let set, let negated):
            let body = set.sorted().map { character -> String in
                switch character {
                case "\n": return "\\n"
                case "\r": return "\\r"
                case "\t": return "\\t"
                case "\\", "]", "[", "^", "-": return "\\" + String(character)
                default: return String(character)
                }
            }.joined()
            if set.isEmpty && negated { return "." }
            return "[" + (negated ? "^" : "") + body + "]"
        case .rule(let name):
            return name
        case .sequence(let items):
            let text = items.map { render($0) }.joined(separator: " ")
            return top || items.count == 1 ? text : "(" + text + ")"
        case .choice(let items):
            let text = items.map { render($0, top: true) }.joined(separator: " | ")
            return top ? text : "(" + text + ")"
        case .repeated(let item, let min, let max):
            let inner = render(item)
            let wrapped: String
            if case .rule = item { wrapped = inner }
            else if case .chars = item { wrapped = inner }
            else if case .literal = item { wrapped = inner }
            else if inner.hasPrefix("(") && inner.hasSuffix(")") { wrapped = inner }
            else { wrapped = "(" + inner + ")" }
            switch (min, max) {
            case (0, 1): return wrapped + "?"
            case (0, nil): return wrapped + "*"
            case (1, nil): return wrapped + "+"
            case (let low, let high?): return wrapped + "{\(low),\(high)}"
            case (let low, nil): return wrapped + "{\(low),}"
            }
        }
    }
}

/// A tool as the prompt describes it: name, then parameters with required
/// ones first in their listed order, then optional ones in the order written.
struct ToolSchema: Equatable {
    enum Kind: String { case integer, line, text, code }
    struct Parameter: Equatable {
        let name: String
        let kind: Kind
        let required: Bool
    }
    let name: String
    let parameters: [Parameter]

    /// Single-line string arguments; every other string may span lines.
    static let lineParameters: Set<String> = ["path", "destination_path", "query"]

    init?(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let function = object["function"] as? [String: Any],
              let name = function["name"] as? String,
              name.range(of: "^[a-z_]+$", options: .regularExpression) != nil else { return nil }
        let schema = function["parameters"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = (schema["required"] as? [String] ?? []).filter { properties[$0] != nil }
        func position(_ key: String) -> Int {
            line.range(of: "\"\(key)\":{")?.lowerBound.utf16Offset(in: line) ?? Int.max
        }
        let optional = properties.keys.filter { !required.contains($0) }.sorted { (position($0), $0) < (position($1), $1) }
        var parameters: [Parameter] = []
        for key in required + optional {
            guard key.range(of: "^[a-z_]+$", options: .regularExpression) != nil else { return nil }
            let kind: Kind
            if properties[key]?["type"] as? String == "integer" { kind = .integer }
            else if ["code", "sql"].contains(key) { kind = .code }
            else if Self.lineParameters.contains(key) { kind = .line }
            else { kind = .text }
            parameters.append(Parameter(name: key, kind: kind, required: required.contains(key)))
        }
        self.name = name
        self.parameters = parameters
    }
}
