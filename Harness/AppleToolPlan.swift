import Foundation

/// Tool calls for Apple's on-device model. Its sampler cannot take Keel's
/// GBNF grammar, and left to itself it invents formats (`<tool>call=read_file
/// path=…</tool>`). Held to a schema with an "answer" choice it always
/// answered, inventing results. So the app registers each offered tool with
/// Apple's own tool calling, the path the model was trained on, takes the
/// first call it makes, and turns it into Keel's usual call text, which the
/// strict parser, limits and approvals then handle as for every model.
public struct AppleToolPlan: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let isInteger: Bool
        public let required: Bool
    }
    public struct Tool: Equatable, Sendable {
        public let name: String
        public let description: String
        public let parameters: [Parameter]
    }

    public let tools: [Tool]

    /// The tools a rendered prompt offers (its first `<tools>` block), or nil when it offers none.
    public static func make(prompt: String) -> AppleToolPlan? {
        guard let open = prompt.range(of: "<tools>\n"),
              let close = prompt.range(of: "\n</tools>", range: open.upperBound..<prompt.endIndex) else { return nil }
        var seen = Set<String>()
        var tools: [Tool] = []
        for line in prompt[open.upperBound..<close.lowerBound].components(separatedBy: "\n") {
            guard let schema = ToolSchema(line), seen.insert(schema.name).inserted else { continue }
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let function = object?["function"] as? [String: Any] ?? object
            tools.append(Tool(name: schema.name, description: function?["description"] as? String ?? "",
                              parameters: schema.parameters.map {
                                  Parameter(name: $0.name, isInteger: $0.kind == .integer, required: $0.required) }))
        }
        return tools.isEmpty ? nil : AppleToolPlan(tools: tools)
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
