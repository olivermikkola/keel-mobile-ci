import Foundation

/// Tool calls for Apple's on-device model. Its sampler cannot take Keel's
/// GBNF grammar, and left to itself it invents formats (`<tool>call=read_file
/// path=…</tool>`). Held to a schema with an "answer" choice it always
/// answered, inventing results. So the app registers each offered tool with
/// Apple's own tool calling, the path the model was trained on, takes the
/// first call it makes, and turns it into Keel's usual call text, which the
/// strict parser, limits and approvals then handle as for every model.
public struct AppleToolPlan: Equatable, Sendable {
    public enum ValueType: Equatable, Sendable {
        case string, integer, number, boolean
    }

    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let valueType: ValueType
        public let isInteger: Bool
        public let required: Bool
        public let description: String
        public let enumValues: [String]

        public init(
            name: String,
            isInteger: Bool,
            required: Bool,
            valueType: ValueType? = nil,
            description: String = "",
            enumValues: [String] = []
        ) {
            self.name = name
            self.valueType = valueType ?? (isInteger ? .integer : .string)
            self.isInteger = isInteger
            self.required = required
            self.description = description
            self.enumValues = enumValues
        }
    }
    public struct Tool: Equatable, Sendable {
        public let name: String
        public let description: String
        public let parameters: [Parameter]
    }

    public let tools: [Tool]

    /// Builds an `AppleToolPlan` directly from JSON tool schema lines.
    public static func make(tools lines: [String]) -> AppleToolPlan? {
        var seen = Set<String>()
        var tools: [Tool] = []
        for line in lines {
            guard let schema = ToolSchema(line), seen.insert(schema.name).inserted else { continue }
            tools.append(Tool(
                name: schema.name,
                description: schema.description,
                parameters: schema.parameters.map { param in
                    let valueType: ValueType
                    var enumValues: [String] = []
                    switch param.kind {
                    case .integer: valueType = .integer
                    case .number: valueType = .number
                    case .boolean: valueType = .boolean
                    case .enumValues(let values):
                        valueType = values.allSatisfy({ Int($0) != nil }) ? .integer : .string
                        enumValues = values
                    case .line, .query, .text, .code:
                        valueType = .string
                    }
                    return Parameter(
                        name: param.name,
                        isInteger: valueType == .integer,
                        required: param.required,
                        valueType: valueType,
                        description: param.description,
                        enumValues: enumValues
                    )
                }
            ))
        }
        return tools.isEmpty ? nil : AppleToolPlan(tools: tools)
    }

    /// The tools a rendered prompt offers (its first `<tools>` block), plus any
    /// `extraTools` loaded dynamically via `load_tools`, or nil when none.
    public static func make(prompt: String, extraTools: [String] = []) -> AppleToolPlan? {
        guard let open = prompt.range(of: "<tools>\n"),
              let close = prompt.range(of: "\n</tools>", range: open.upperBound..<prompt.endIndex) else { return nil }
        let base = prompt[open.upperBound..<close.lowerBound].components(separatedBy: "\n")
        return make(tools: base + extraTools)
    }

    /// Keel's call text for a call the model made, or nil when it names no
    /// offered tool or misses a required argument.
    public func callText(choice: String, arguments: [String: String]) -> String? {
        guard let tool = tools.first(where: { $0.name == choice }) else { return nil }
        var kept: [String: String] = [:]
        for parameter in tool.parameters {
            if let value = arguments[parameter.name] { kept[parameter.name] = value }
            else if parameter.required { return nil }
        }
        return NativeToolCall.canonicalCall(name: tool.name, arguments: kept)
    }

    /// What replaces Keel's tool list and XML call format in the system
    /// prompt: Apple's framework describes the registered tools itself.
    public static let instructions = """
        You have tools for files, data, code and the web. When the task needs one, call it; call one tool at a time and wait for its result. \
        Never write a tool call as text. Never say you created, changed, moved or read anything unless a tool result in this conversation says so.
        """

    /// The system prompt without its `# Tools` block (the tool list and the
    /// XML call format), with `instructions` in its place.
    public static func instructions(from system: String) -> String {
        guard let start = system.range(of: "# Tools\n\nYou have access to the following functions:"),
              let end = system.range(of: AgentPrompt.callFormat, range: start.upperBound..<system.endIndex) else {
            return system.replacingOccurrences(of: AgentPrompt.callFormat, with: instructions)
        }
        return system.replacingCharacters(in: start.lowerBound..<end.upperBound, with: instructions)
    }
}
