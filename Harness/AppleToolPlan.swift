import Foundation

/// Tool calls for Apple's on-device model. Its sampler cannot take Keel's
/// GBNF grammar, and left to itself it invents formats (`<tool>call=read_file
/// path=…</tool>`, several calls at once). Its framework can instead hold a
/// reply to a schema (guided generation). The app builds one choice per
/// offered tool plus an "answer" choice from this plan, and turns the choice
/// the model filled in back into Keel's usual call text, which the strict
/// parser, limits and approvals then handle as for every model.
public struct AppleToolPlan: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let isInteger: Bool
        public let required: Bool
    }
    public struct Tool: Equatable, Sendable {
        public let name: String
        public let parameters: [Parameter]
    }

    /// The choice that means "no tool: this is the reply", and its text field.
    public static let answer = "answer"
    public static let answerText = "text"
    /// The field every choice carries, naming the choice.
    public static let choiceField = "tool"

    public let tools: [Tool]

    /// The tools a rendered prompt offers (its first `<tools>` block), or nil when it offers none.
    public static func make(prompt: String) -> AppleToolPlan? {
        guard let open = prompt.range(of: "<tools>\n"),
              let close = prompt.range(of: "\n</tools>", range: open.upperBound..<prompt.endIndex) else { return nil }
        var seen = Set<String>()
        let tools = prompt[open.upperBound..<close.lowerBound].components(separatedBy: "\n")
            .compactMap(ToolSchema.init).filter { seen.insert($0.name).inserted && $0.name != answer }
            .map { Tool(name: $0.name, parameters: $0.parameters.map {
                Parameter(name: $0.name, isInteger: $0.kind == .integer, required: $0.required) }) }
        return tools.isEmpty ? nil : AppleToolPlan(tools: tools)
    }

    /// Keel's call text for a filled-in choice, or nil when the choice is the
    /// answer, names no offered tool, or misses a required argument.
    public func callText(choice: String, arguments: [String: String]) -> String? {
        guard choice != Self.answer, let tool = tools.first(where: { $0.name == choice }) else { return nil }
        var kept: [String: String] = [:]
        for parameter in tool.parameters {
            if let value = arguments[parameter.name] { kept[parameter.name] = value }
            else if parameter.required { return nil }
        }
        return NativeToolCall.canonicalCall(name: tool.name, arguments: kept)
    }

    /// What replaces Keel's XML call instructions in the system prompt, since
    /// the response format now carries the call.
    public static let instructions = """
        To use a function, choose it in the response format and fill in its arguments; choose one function at a time and wait for its result. \
        To reply to the user without a function, choose "answer" and write the reply in its text. Do not write tool calls as text.
        """

    /// The system prompt with the XML call format swapped for `instructions`.
    public static func instructions(from system: String) -> String {
        system.replacingOccurrences(of: AgentPrompt.callFormat, with: instructions)
    }
}
