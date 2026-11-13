import Foundation

struct SavedTask: Codable, Identifiable {
    var id = UUID()
    var title = "New task"
    var automaticTitle = true
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var repository: RepositorySnapshot?
    var publish: PublishState? = nil
    // Optional for existing version-2 archives. Missing means proposals are off.
    var editProposalsEnabled: Bool? = nil

    var status: String {
        if messages.isEmpty { return "Ready" }
        if let note = messages.last?.note,
           ["Interrupted", "Stopped", "Responding", "Reading…", "Executing…", "Requested"].contains(where: note.hasPrefix) { return "Stopped" }
        return messages.last?.role == "user" ? "Needs reply" : "Reply saved"
    }

    static func title(for messages: [ChatMessage]) -> String {
        let text = messages.first(where: { $0.role == "user" })?.text ?? ""
        let title = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return title.isEmpty ? "New task" : String(title.prefix(80))
    }
}

struct SavedTasks: Codable {
    let version: Int
    var activeID: UUID
    var tasks: [SavedTask]

    init(task: SavedTask = SavedTask()) {
        version = 2; activeID = task.id; tasks = [task]
    }

    static func load(_ data: Data) throws -> SavedTasks {
        let decoder = JSONDecoder()
        var archive: SavedTasks
        if let legacy = try? decoder.decode([ChatMessage].self, from: data) {
            archive = SavedTasks(task: SavedTask(title: SavedTask.title(for: legacy), messages: legacy))
        } else {
            struct Legacy: Decodable {
                let version: Int
                let messages: [ChatMessage]
                let repository: RepositorySnapshot?
            }
            if let legacy = try? decoder.decode(Legacy.self, from: data), legacy.version == 1 {
                archive = SavedTasks(task: SavedTask(title: SavedTask.title(for: legacy.messages),
                                                    messages: legacy.messages, repository: legacy.repository))
            } else {
                archive = try decoder.decode(SavedTasks.self, from: data)
            }
        }
        guard archive.version == 2, !archive.tasks.isEmpty, archive.tasks.count <= 200,
              Set(archive.tasks.map(\.id)).count == archive.tasks.count,
              archive.tasks.contains(where: { $0.id == archive.activeID }) else { throw RepositoryAgentError.storage }
        for task in archive.tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.title.count <= 80,
                  task.messages.allSatisfy({ ["user", "assistant", "tool"].contains($0.role) }),
                  Set(task.messages.map(\.id)).count == task.messages.count,
                  // A chat without a repository proposes against its own files.
                  TaskFileEdit.validHistory(task.messages, snapshot: task.repository ?? .localFiles) else {
                throw RepositoryAgentError.storage
            }
        }
        // A publish record is useful metadata, never authorization. Drop an
        // inconsistent one rather than bricking the conversation history.
        for index in archive.tasks.indices {
            guard let publish = archive.tasks[index].publish else { continue }
            guard let repository = archive.tasks[index].repository, publish.isValid(for: repository) else {
                archive.tasks[index].publish = nil
                continue
            }
        }
        // Restoring every task is history only. No model or network request is replayed.
        for task in archive.tasks.indices {
            for index in archive.tasks[task].messages.indices {
                if ["Responding", "Reading…", "Executing…", "Requested"].contains(archive.tasks[task].messages[index].note ?? "") {
                    archive.tasks[task].messages[index].note = "Interrupted"
                    if archive.tasks[task].messages[index].role == "tool" {
                        archive.tasks[task].messages[index].text = "Request interrupted; no result was obtained."
                    }
                }
            }
        }
        return archive
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
