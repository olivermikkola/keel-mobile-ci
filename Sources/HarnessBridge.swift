import Foundation

// Connects the KeelHarness package (Harness/, docs/HARNESS.md) to the app's
// chat loop. The harness only ever changes the prompt; the saved transcript
// keeps every message as it happened.
enum HarnessBridge {
    /// System prompt and tool instructions must fit after the history, with the reply.
    static let reservedPromptTokens = 1_536

    /// Prompt history for a repository or Director step, compacted when it no
    /// longer fits. Returns the input unchanged when it fits.
    /// Keeps the previous step's folds (`StickyCompaction`), so the prompt only
    /// grows between folds and the phone reuses what it already read.
    static func promptHistory(_ history: [ChatMessage], compaction: inout StickyCompaction?, contextSize: UInt32,
                              replyTokens: Int = AgentPrompt.readingReplyTokens, imageTokens: Int = 0) -> [ChatMessage] {
        if compaction?.budget.maxContextTokens != Int(contextSize) { compaction = StickyCompaction(maxContextTokens: Int(contextSize)) }
        let messages = history.map { HarnessMessage(HarnessMessage.Role(rawValue: $0.role) ?? .user, $0.text) }
        let sent = compaction!.prompt(messages, reservedTokens: reservedPromptTokens + replyTokens + imageTokens)
        guard sent != messages else { return history }
        return restore(sent.map { (role: $0.role == .summary ? "tool" : $0.role.rawValue, text: $0.text) }, from: history)
    }

    private static func restore(_ compacted: [(role: String, text: String)], from history: [ChatMessage]) -> [ChatMessage] {
        var matched = Set<Int>()
        return compacted.map { item in
            if let index = history.indices.first(where: { !matched.contains($0) && history[$0].role == item.role && history[$0].text == item.text }) {
                matched.insert(index); return history[index]
            }
            return ChatMessage(role: item.role, text: item.text)
        }
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
