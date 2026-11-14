import Foundation

// Connects the KeelHarness package (Harness/, docs/HARNESS.md) to the app's
// chat loop. The harness only ever changes the prompt; the saved transcript
// keeps every message as it happened.
enum HarnessBridge {
    /// System prompt and tool instructions must fit after the history, with the reply.
    static let reservedPromptTokens = 1_536

    /// Prompt history for a repository or Director step, compacted when it no
    /// longer fits. Returns the input unchanged when it fits.
    static func promptHistory(_ history: [ChatMessage], contextSize: UInt32,
                              replyTokens: Int = AgentPrompt.readingReplyTokens) -> [ChatMessage] {
        let budget = ContextBudget(maxContextTokens: Int(contextSize))
        guard let compacted = budget.compactPrompt(history.map { (role: $0.role, text: $0.text) },
                                                   reservedTokens: reservedPromptTokens + replyTokens) else { return history }
        return compacted.map { ChatMessage(role: $0.role, text: $0.text) }
    }

    static func arguments(_ call: RepositoryCall) -> [String: String] {
        if call.name == "run_sql" { return ["sql": call.sql ?? ""] }
        if call.name == "run_js" { return ["code": call.code ?? ""] }
        var arguments = ["path": call.path, "offset": String(call.offset), "count": String(call.count)]
        if let query = call.query { arguments["query"] = query }
        return arguments
    }

    static func failure(_ error: Error) -> CircuitBreaker.Failure {
        switch error {
        case RepositoryError.rateLimited, RepositoryError.http(429): return .rateLimited
        case RepositoryError.http(401), RepositoryError.http(403), RepositoryError.credential: return .unauthorized
        case RepositoryError.http(404), RepositoryAgentError.missing, RepositoryAgentError.range,
             WorkspaceError.missing, WorkspaceError.notDirectory, WorkspaceError.isDirectory,
             EditPlanError.path, EditPlanError.missingFolder: return .notFound
        case is URLError: return .network
        default: return .other(String(describing: type(of: error)))
        }
    }
}
