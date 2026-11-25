import Foundation

/// Local tasks read from a JSON file (`--task-file`) instead of the built-in
/// eval suite. LLM-lab uses it to record training conversations through the
/// app's own prompts, tools and guards. The checks are declarative, and a file
/// task may not reuse an eval task's id or prompt, so training tasks cannot
/// quietly copy the eval.
struct TaskFileEntry: Decodable {
    struct Attachment: Decodable { let path: String; let text: String }
    /// A file the chat must hold afterwards: `path` exactly, or any file ending in `suffix`.
    struct FileCheck: Decodable {
        var path: String?
        var suffix: String?
        var contains: [String]?
        var excludes: [String]?
    }
    struct Check: Decodable {
        /// Every group: the final answer holds one of its strings (ignoring case).
        var answer: [[String]]?
        /// The final answer holds none of these (ignoring case).
        var answerExcludes: [String]?
        var files: [FileCheck]?
        var minSteps: Int?
        var maxSteps: Int?
    }
    let id: String
    let prompt: String
    var mode: String?
    var app: String?
    var attachments: [Attachment]?
    /// Files already in the chat from earlier turns: listed and readable, but not in the message.
    var files: [Attachment]?
    var memory: [String]?
    var image: Bool?
    var check: Check?

    static func load(_ path: String) throws -> [EvalTask] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try decoder.decode([TaskFileEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let evalIDs = Set(evalTasks.map(\.id))
        let evalPrompts = Set(evalTasks.map { $0.prompt.lowercased() })
        var seen = Set<String>()
        return try entries.map { entry in
            guard !evalIDs.contains(entry.id), seen.insert(entry.id).inserted else { throw TaskFileError.id(entry.id) }
            guard !evalPrompts.contains(entry.prompt.lowercased()) else { throw TaskFileError.evalPrompt(entry.id) }
            return try entry.task()
        }
    }

    func task() throws -> EvalTask {
        var task = EvalTask(id: id, kind: .local, fixture: "local", prompt: prompt)
        if let mode {
            guard let value = ChatMode(rawValue: mode) else { throw TaskFileError.value(id, "mode \(mode)") }
            task.mode = value
        }
        if let app {
            guard let value = AppPreset(rawValue: app) else { throw TaskFileError.value(id, "app \(app)") }
            task.app = value
        }
        task.attachments = (attachments ?? []).map { ($0.path, $0.text) }
        task.files = (files ?? []).map { ($0.path, $0.text) }
        task.memory = memory
        task.image = image ?? false
        // As the app: the user reviews proposals in the interface, so there is no second round.
        task.rounds = 1
        let check = check ?? Check()
        task.check = { workspace, answer, steps in
            let reply = answer.lowercased()
            if let groups = check.answer, !groups.allSatisfy({ $0.contains { reply.contains($0.lowercased()) } }) { return false }
            if let banned = check.answerExcludes, banned.contains(where: { reply.contains($0.lowercased()) }) { return false }
            if let least = check.minSteps, steps < least { return false }
            if let most = check.maxSteps, steps > most { return false }
            let files = workspace.textFiles()
            return (check.files ?? []).allSatisfy { want in
                files.contains { file in
                    (want.path.map { file.path == $0 } ?? true)
                        && (want.suffix.map { file.path.hasSuffix($0) } ?? true)
                        && (want.contains ?? []).allSatisfy { file.text.contains($0) }
                        && !(want.excludes ?? []).contains { file.text.contains($0) }
                }
            }
        }
        return task
    }
}

enum TaskFileError: LocalizedError {
    case id(String), evalPrompt(String), value(String, String)
    var errorDescription: String? {
        switch self {
        case .id(let id): return "task id \(id) is an eval task's id or appears twice"
        case .evalPrompt(let id): return "task \(id) reuses an eval task's prompt"
        case .value(let id, let value): return "task \(id): unknown \(value)"
        }
    }
}
