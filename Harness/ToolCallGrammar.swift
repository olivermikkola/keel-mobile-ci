import Foundation

/// A GBNF grammar that lets the sampler write only well-formed tool calls.
///
/// The grammar is lazy: text before the call is free, and the grammar starts
/// when the output matches a trigger (`<tool_call>` or `<function`).
/// From there the model can only pick an offered tool, its own parameter names
/// (each at most once, with every required parameter present), and typed values
/// (integers, numbers, booleans, enums, single-line strings, queries, or text/code).
///
/// Supports:
/// - Qwen XML (`<tool_call><function=...>...</function></tool_call>` or bare `<function=...>`)
/// - MiniCPM5 native XML (`<function name="..."><param name="...">...</param></function>`)
/// - JSON tool calls (`<tool_call>{"name":"...","arguments":{...}}</tool_call>`)
/// - Single-call or multi-call turns (`options.maxCalls`)
/// - Optional order-independent parameters via a compact bitmask DAG (`options.flexibleParameterOrder`)
///
/// This shapes tokens; it grants nothing. The strict parser, limits and
/// approval gates still decide what runs.
public struct ToolCallGrammar: Equatable, Sendable {
    public static let root = "root"

    public enum Format: Equatable, Sendable {
        /// Choose Qwen XML for Bonsai/LFM3 and MiniCPM XML for MiniCPM5.
        case auto
        case qwenXML
        case miniCPMXML
        case json
    }

    public struct Options: Equatable, Sendable {
        /// Maximum number of tool calls allowed in a single model turn (1...6).
        public var maxCalls: Int
        /// Allow parameters in any order (for tools with up to 5 parameters)
        /// while still forbidding duplicate parameters and requiring all required ones.
        public var flexibleParameterOrder: Bool
        /// Wire format constrained by this grammar.
        public var format: Format

        public init(maxCalls: Int = 1, flexibleParameterOrder: Bool = false, format: Format = .auto) {
            self.maxCalls = max(1, min(6, maxCalls))
            self.flexibleParameterOrder = flexibleParameterOrder
            self.format = format
        }

        public static let single = Options(maxCalls: 1, flexibleParameterOrder: false, format: .auto)
        public static let multiTurnFlexible = Options(maxCalls: 4, flexibleParameterOrder: true, format: .auto)
    }

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
    static func make(tools: [String], family: ModelFamily, options: Options = .single) -> ToolCallGrammar? {
        var seen = Set<String>()
        let schemas = tools.compactMap(ToolSchema.init).filter { seen.insert($0.name).inserted }
        guard !schemas.isEmpty else { return nil }
        let resolvedFormat: Format = options.format == .auto
            ? (family == .miniCPM5 ? .miniCPMXML : .qwenXML)
            : options.format
        switch resolvedFormat {
        case .qwenXML, .auto:
            return qwen(schemas, options: options)
        case .miniCPMXML:
            return native(schemas, options: options)
        case .json:
            return json(schemas, options: options)
        }
    }

    /// The grammar for the tools a rendered prompt offers: the lines of its
    /// first `<tools>` block (which belongs to the system message), plus any
    /// `extraTools` dynamically activated via `load_tools` during the session.
    static func make(
        prompt: String,
        family: ModelFamily,
        extraTools: [String] = [],
        options: Options = .single
    ) -> ToolCallGrammar? {
        guard let open = prompt.range(of: "<tools>\n"),
              let close = prompt.range(of: "\n</tools>", range: open.upperBound..<prompt.endIndex) else { return nil }
        let base = prompt[open.upperBound..<close.lowerBound].components(separatedBy: "\n")
        return make(tools: base + extraTools, family: family, options: options)
    }

    // MARK: - Formats

    /// `<tool_call>\n<function=name>\n<parameter=key>\nvalue\n</parameter>\n</function>\n</tool_call>`,
    /// as `DirectorCall.parse` reads it. Bonsai and LFM3 write this. A call
    /// that starts at `<function` without `<tool_call>` is accepted bare;
    /// `ToolCallText.normalize` / `ToolCallParser` handles it.
    private static func qwen(_ schemas: [ToolSchema], options: Options) -> ToolCallGrammar {
        var rules: [(String, Node)] = []
        let singleWrapped = Node.sequence([.literal("<tool_call>"), .rule("ws"), .rule("call"), .rule("ws"), .literal("</tool_call>")])
        if options.maxCalls <= 1 {
            rules.append((root, .choice([singleWrapped, .rule("call")])))
        } else {
            rules.append((root, .sequence([
                .rule("call-block"),
                .repeated(.sequence([.rule("ws"), .rule("call-block")]), min: 0, max: options.maxCalls - 1)
            ])))
            rules.append(("call-block", .choice([singleWrapped, .rule("call")])))
        }
        rules.append(("call", .choice(schemas.map { .rule(ruleName($0.name)) })))

        var usedKinds = Set<KindTag>()
        var enumRules: [(String, Node)] = []

        for schema in schemas {
            let params = options.flexibleParameterOrder
                ? schema.parameters.sorted { $0.name < $1.name }
                : schema.parameters

            var paramRuleNames: [String] = []
            for parameter in params {
                let name = ruleName(schema.name + "-" + parameter.name)
                let valueNode = qwenValueNode(for: parameter, toolName: schema.name, used: &usedKinds, enumRules: &enumRules)
                rules.append((name, .sequence([.literal("<parameter=\(parameter.name)>"), valueNode, .literal("</parameter>")])))
                paramRuleNames.append(name)
            }

            if options.flexibleParameterOrder && params.count >= 2 && params.count <= 5 {
                let dag = flexibleParamDAG(
                    prefix: ruleName(schema.name),
                    open: .literal("<function=\(schema.name)>"),
                    close: .literal("</function>"),
                    params: params,
                    paramRuleNames: paramRuleNames
                )
                rules.append(contentsOf: dag)
            } else {
                var body: [Node] = [.literal("<function=\(schema.name)>")]
                for (index, parameter) in params.enumerated() {
                    let item = Node.sequence([.rule("ws"), .rule(paramRuleNames[index])])
                    body.append(parameter.required ? item : .repeated(item, min: 0, max: 1))
                }
                rules.append((ruleName(schema.name), .sequence(body + [.rule("ws"), .literal("</function>")])))
            }
        }

        rules.append(contentsOf: enumRules)
        rules.append(("ws", whitespace))
        if usedKinds.contains(.integer) {
            rules.append(("integer", .sequence([.rule("ws"), .repeated(digit, min: 1, max: 9), .rule("ws")])))
        }
        if usedKinds.contains(.number) {
            let sign = Node.repeated(.literal("-"), min: 0, max: 1)
            let frac = Node.repeated(.sequence([.literal("."), .repeated(digit, min: 1, max: 9)]), min: 0, max: 1)
            rules.append(("number", .sequence([.rule("ws"), sign, .repeated(digit, min: 1, max: 9), frac, .rule("ws")])))
        }
        if usedKinds.contains(.boolean) {
            rules.append(("boolean", .sequence([.rule("ws"), .choice([.literal("true"), .literal("false")]), .rule("ws")])))
        }
        if usedKinds.contains(.line) {
            let newline = Node.repeated(.literal("\n"), min: 0, max: 1)
            rules.append(("line", .sequence([newline, .repeated(.chars(["<", "\n", "\r"], negated: true), min: 1, max: nil), newline])))
        }
        if usedKinds.contains(.query) {
            // Queries stay on one line (with optional single wrapping newlines),
            // may contain raw `<` (HTML tags, generics, comparisons), and never
            // carry protocol tags or internal newlines.
            let newline = Node.repeated(.literal("\n"), min: 0, max: 1)
            rules.append(("query", .sequence([newline, .rule("query-body"), newline])))
            rules += excluding(["</parameter>", "<parameter=", "<function=", "<tool_call", "\n", "\r"], prefix: "query-body")
        }
        if usedKinds.contains(.text) { rules += excluding(["</parameter>"], prefix: "text") }
        // DirectorCall.parse rejects these inside code and sql.
        if usedKinds.contains(.code) {
            rules += excluding(["</parameter>", "<parameter=", "<function=", "<tool_call"], prefix: "code")
        }
        return ToolCallGrammar(rules: rules, triggers: ["(<tool_call>)", "(<function)"])
    }

    /// `<function name="x"><param name="k"><![CDATA[value]]></param></function>`,
    /// MiniCPM5's native XML, which `NativeToolCall.normalize` / `ToolCallParser` reads.
    private static func native(_ schemas: [ToolSchema], options: Options) -> ToolCallGrammar {
        var rules: [(String, Node)] = []
        if options.maxCalls <= 1 {
            rules.append((root, .choice(schemas.map { .rule(ruleName($0.name)) })))
        } else {
            rules.append((root, .sequence([
                .rule("call"),
                .repeated(.sequence([.rule("ws"), .rule("call")]), min: 0, max: options.maxCalls - 1)
            ])))
            rules.append(("call", .choice(schemas.map { .rule(ruleName($0.name)) })))
        }

        var usedNumber = false
        var usedBoolean = false
        var enumRules: [(String, Node)] = []

        for schema in schemas {
            let params = options.flexibleParameterOrder
                ? schema.parameters.sorted { $0.name < $1.name }
                : schema.parameters

            var paramRuleNames: [String] = []
            for parameter in params {
                let name = ruleName(schema.name + "-" + parameter.name)
                let valueNode: Node
                switch parameter.kind {
                case .integer: valueNode = .rule("xml-integer")
                case .number: usedNumber = true; valueNode = .rule("xml-number")
                case .boolean: usedBoolean = true; valueNode = .rule("xml-boolean")
                case .enumValues(let values):
                    let enumName = ruleName("enum-" + schema.name + "-" + parameter.name)
                    enumRules.append((enumName, .sequence([.rule("ws"), .choice(values.map { .literal(xmlEscaped($0)) }), .rule("ws")])))
                    valueNode = .rule(enumName)
                case .line, .query: valueNode = .rule("xml-line")
                case .text, .code: valueNode = .rule("xml-text")
                }
                rules.append((name, .sequence([.literal("<param name=\"\(parameter.name)\">"), valueNode, .literal("</param>")])))
                paramRuleNames.append(name)
            }

            if options.flexibleParameterOrder && params.count >= 2 && params.count <= 5 {
                let dag = flexibleParamDAG(
                    prefix: ruleName(schema.name),
                    open: .literal("<function name=\"\(schema.name)\">"),
                    close: .literal("</function>"),
                    params: params,
                    paramRuleNames: paramRuleNames
                )
                rules.append(contentsOf: dag)
            } else {
                var body: [Node] = [.literal("<function name=\"\(schema.name)\">")]
                for (index, parameter) in params.enumerated() {
                    let item = Node.sequence([.rule("ws"), .rule(paramRuleNames[index])])
                    body.append(parameter.required ? item : .repeated(item, min: 0, max: 1))
                }
                rules.append((ruleName(schema.name), .sequence(body + [.rule("ws"), .literal("</function>")])))
            }
        }

        rules.append(contentsOf: enumRules)
        let entity = Node.sequence([.literal("&"), .choice(["lt", "gt", "amp", "quot", "apos"].map { .literal($0) }), .literal(";")])
        rules += [
            ("ws", whitespace),
            ("xml-integer", .sequence([.rule("ws"), .repeated(digit, min: 1, max: 9), .rule("ws")])),
        ]
        if usedNumber {
            let sign = Node.repeated(.literal("-"), min: 0, max: 1)
            let frac = Node.repeated(.sequence([.literal("."), .repeated(digit, min: 1, max: 9)]), min: 0, max: 1)
            rules.append(("xml-number", .sequence([.rule("ws"), sign, .repeated(digit, min: 1, max: 9), frac, .rule("ws")])))
        }
        if usedBoolean {
            rules.append(("xml-boolean", .sequence([.rule("ws"), .choice([.literal("true"), .literal("false")]), .rule("ws")])))
        }
        rules += [
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

    /// `<tool_call>{"name":"...","arguments":{...}}</tool_call>`, for models
    /// trained on Hermes / Qwen-JSON / Llama 3 JSON tool calling.
    private static func json(_ schemas: [ToolSchema], options: Options) -> ToolCallGrammar {
        var rules: [(String, Node)] = []
        let wrapped = Node.sequence([.literal("<tool_call>"), .rule("ws"), .rule("call"), .rule("ws"), .literal("</tool_call>")])
        if options.maxCalls <= 1 {
            rules.append((root, wrapped))
        } else {
            rules.append((root, .sequence([
                .rule("call-block"),
                .repeated(.sequence([.rule("ws"), .rule("call-block")]), min: 0, max: options.maxCalls - 1)
            ])))
            rules.append(("call-block", wrapped))
        }
        rules.append(("call", .choice(schemas.map { .rule(ruleName($0.name)) })))

        var enumRules: [(String, Node)] = []
        for schema in schemas {
            let argsRuleName = ruleName(schema.name + "-args")
            var fieldNodes: [Node] = []
            for (index, parameter) in schema.parameters.enumerated() {
                let valueNode: Node
                switch parameter.kind {
                case .integer: valueNode = .rule("json-int")
                case .number: valueNode = .rule("json-num")
                case .boolean: valueNode = .rule("json-bool")
                case .enumValues(let values):
                    let eName = ruleName("jenum-" + schema.name + "-" + parameter.name)
                    let literals = values.map { val -> Node in
                        Int(val) != nil ? .literal(val) : .literal("\"\(jsonEscaped(val))\"")
                    }
                    enumRules.append((eName, .choice(literals)))
                    valueNode = .rule(eName)
                case .line, .query, .text, .code:
                    valueNode = .rule("json-string")
                }
                let pair = Node.sequence([.literal("\"\(parameter.name)\""), .rule("jws"), .literal(":"), .rule("jws"), valueNode])
                if index == 0 {
                    fieldNodes.append(parameter.required ? pair : .repeated(pair, min: 0, max: 1))
                } else {
                    let commaPair = Node.sequence([.rule("jws"), .literal(","), .rule("jws"), pair])
                    // If previous parameters were optional, allow starting without a leading comma.
                    let allPrevOptional = schema.parameters[..<index].allSatisfy { !$0.required }
                    let entry = allPrevOptional ? .choice([commaPair, pair]) : commaPair
                    fieldNodes.append(parameter.required ? entry : .repeated(entry, min: 0, max: 1))
                }
            }
            let argsBody = fieldNodes.isEmpty
                ? Node.sequence([.literal("{"), .rule("jws"), .literal("}")])
                : Node.sequence([.literal("{"), .rule("jws")] + fieldNodes + [.rule("jws"), .literal("}")])
            rules.append((argsRuleName, argsBody))
            rules.append((ruleName(schema.name), .sequence([
                .literal("{"), .rule("jws"),
                .literal("\"name\""), .rule("jws"), .literal(":"), .rule("jws"), .literal("\"\(schema.name)\""),
                .rule("jws"), .literal(","), .rule("jws"),
                .literal("\"arguments\""), .rule("jws"), .literal(":"), .rule("jws"), .rule(argsRuleName),
                .rule("jws"), .literal("}")
            ])))
        }

        rules.append(contentsOf: enumRules)
        let esc = Node.sequence([.literal("\\"), .choice([
            .chars(Set("\"\\/bfnrt"), negated: false),
            .sequence([.literal("u"), .repeated(.chars(Set("0123456789abcdefABCDEF"), negated: false), min: 4, max: 4)])
        ])])
        let jchar = Node.choice([.chars(["\"", "\\", "\n", "\r"], negated: true), esc])
        let sign = Node.repeated(.literal("-"), min: 0, max: 1)
        let frac = Node.repeated(.sequence([.literal("."), .repeated(digit, min: 1, max: 9)]), min: 0, max: 1)
        rules += [
            ("ws", whitespace),
            ("jws", Node.repeated(.chars([" ", "\t", "\n"], negated: false), min: 0, max: 4)),
            ("json-string", .sequence([.literal("\""), .repeated(jchar, min: 0, max: nil), .literal("\"")])),
            ("json-int", .sequence([sign, .repeated(digit, min: 1, max: 9)])),
            ("json-num", .sequence([sign, .repeated(digit, min: 1, max: 9), frac])),
            ("json-bool", .choice([.literal("true"), .literal("false")])),
        ]
        return ToolCallGrammar(rules: rules, triggers: ["(<tool_call>)"])
    }

    // MARK: - Order-Independent Parameter Bitmask DAG

    /// Generates an exact non-repeating parameter DAG for tools with 2...5 parameters:
    /// every state is a bitmask of already-emitted parameters. Duplicates are impossible,
    /// required parameters are guaranteed before `close`, and any parameter order is valid.
    private static func flexibleParamDAG(
        prefix: String,
        open: Node,
        close: Node,
        params: [ToolSchema.Parameter],
        paramRuleNames: [String]
    ) -> [(String, Node)] {
        let count = params.count
        let fullMask = (1 << count) - 1
        var requiredMask = 0
        for (i, param) in params.enumerated() where param.required {
            requiredMask |= (1 << i)
        }

        var dagRules: [(String, Node)] = []
        dagRules.append((prefix, .sequence([open, .rule("\(prefix)-s0")])))

        for mask in 0...fullMask {
            var choices: [Node] = []
            if (mask & requiredMask) == requiredMask {
                choices.append(.sequence([.rule("ws"), close]))
            }
            for i in 0..<count where (mask & (1 << i)) == 0 {
                let nextMask = mask | (1 << i)
                choices.append(.sequence([.rule("ws"), .rule(paramRuleNames[i]), .rule("\(prefix)-s\(nextMask)")]))
            }
            let node: Node = choices.count == 1 ? choices[0] : .choice(choices)
            dagRules.append(("\(prefix)-s\(mask)", node))
        }
        return dagRules
    }

    private enum KindTag: Hashable { case integer, number, boolean, line, query, text, code }

    private static func qwenValueNode(
        for parameter: ToolSchema.Parameter,
        toolName: String,
        used: inout Set<KindTag>,
        enumRules: inout [(String, Node)]
    ) -> Node {
        switch parameter.kind {
        case .integer:
            used.insert(.integer); return .rule("integer")
        case .number:
            used.insert(.number); return .rule("number")
        case .boolean:
            used.insert(.boolean); return .rule("boolean")
        case .enumValues(let values):
            let enumName = ruleName("enum-" + toolName + "-" + parameter.name)
            enumRules.append((enumName, .sequence([.rule("ws"), .choice(values.map { .literal($0) }), .rule("ws")])))
            return .rule(enumName)
        case .line:
            used.insert(.line); return .rule("line")
        case .query:
            used.insert(.query); return .rule("query")
        case .text:
            used.insert(.text); return .rule("text")
        case .code:
            used.insert(.code); return .rule("code")
        }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func jsonEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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

    indirect enum Node: Sendable {
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
/// ones first in their listed order, then optional ones in the order the
/// model was shown them.
public struct ToolSchema: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case integer
        case number
        case boolean
        case enumValues([String])
        case line
        case query
        case text
        case code
    }

    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let kind: Kind
        public let required: Bool
        public let description: String

        public init(name: String, kind: Kind, required: Bool, description: String = "") {
            self.name = name
            self.kind = kind
            self.required = required
            self.description = description
        }
    }

    public let name: String
    public let description: String
    public let parameters: [Parameter]

    /// Strict single-line string arguments (no `<`, no newlines).
    static let lineParameters: Set<String> = ["path", "destination_path", "url", "repository", "due", "start", "end"]
    /// Single-line search query arguments that may carry `<` (e.g. HTML tags or generics).
    static let queryParameters: Set<String> = ["query"]

    public init?(_ line: String) {
        // `{"type":"function","function":{…}}`, or the bare function object LFM3's template shows.
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let function = object["function"] as? [String: Any] ?? (object["name"] is String ? object : nil),
              let name = function["name"] as? String,
              name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        let description = function["description"] as? String ?? ""
        let schema = function["parameters"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = (schema["required"] as? [String] ?? []).filter { properties[$0] != nil }
        func position(_ key: String) -> Int {
            line.range(of: "\"\(key)\":{")?.lowerBound.utf16Offset(in: line) ?? Int.max
        }
        let optional = properties.keys.filter { !required.contains($0) }.sorted { (position($0), $0) < (position($1), $1) }
        var parameters: [Parameter] = []
        for key in required + optional {
            guard key.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil else { return nil }
            let prop = properties[key]
            let rawType = prop?["type"] as? String
            let propDesc = prop?["description"] as? String ?? ""
            let kind: Kind
            if let rawEnum = prop?["enum"] as? [Any], !rawEnum.isEmpty {
                let stringified = rawEnum.compactMap { item -> String? in
                    if let s = item as? String { return s }
                    if let i = item as? Int { return String(i) }
                    return nil
                }
                if stringified.count == rawEnum.count, stringified.count <= 20,
                   stringified.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("</parameter>") }) {
                    kind = .enumValues(stringified)
                } else {
                    kind = rawType == "integer" ? .integer : .text
                }
            } else if rawType == "integer" {
                kind = .integer
            } else if rawType == "number" {
                kind = .number
            } else if rawType == "boolean" {
                kind = .boolean
            } else if ["code", "sql"].contains(key) {
                kind = .code
            } else if Self.queryParameters.contains(key) {
                kind = .query
            } else if Self.lineParameters.contains(key) {
                kind = .line
            } else {
                kind = .text
            }
            parameters.append(Parameter(name: key, kind: kind, required: required.contains(key), description: propDesc))
        }
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}
