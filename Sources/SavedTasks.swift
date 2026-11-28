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
    /// The app this chat was opened in (Websites, Sheets, Docs, Study). Nil is a plain chat.
    var app: AppPreset? = nil
    /// Whether capped thinking mode is enabled for this chat.
    var thinkingEnabled: Bool? = nil
    /// IDs of MCP connectors enabled for this chat. Nil or empty means no connector tools are loaded.
    var enabledConnectorIDs: [String]? = nil
    /// Chat or Work. Nil (chats saved before modes) is Work.
    var mode: ChatMode? = nil
    /// The project this chat belongs to, if any.
    var projectID: UUID? = nil
    /// The chat model wrote the title after the first reply (`ChatTitle`).
    var titledByModel: Bool? = nil

    var status: String {
        if messages.isEmpty { return "Ready" }
        if let note = messages.last?.note,
           ["Interrupted", "Stopped", "Responding", "Reading…", "Executing…", "Requested"].contains(where: note.hasPrefix) { return "Stopped" }
        return messages.last?.role == "user" ? "Needs reply" : "Reply saved"
    }

    static func title(for messages: [ChatMessage]) -> String {
        let title = tidyTitle(messages.first(where: { $0.role == "user" })?.text ?? "")
        return title.isEmpty ? "New task" : title
    }

    private static let trailingFillers: Set<String> = ["a", "an", "and", "the", "of", "to", "for", "in", "on", "with", "my", "or"]

    /// Polite openers dropped from the start of a title ("Can you make…" → "Make…").
    private static let openers: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["please"],
        ["hey"], ["hi"], ["hello"], ["i", "want", "you", "to"], ["i'd", "like", "you", "to"],
    ]

    /// A short title from the first message: its first line, without polite
    /// openers or an accidentally doubled word, cut at a word, capitalised.
    static func tidyTitle(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let raw = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var words = raw.indices.filter { $0 == 0 || raw[$0].lowercased() != raw[$0 - 1].lowercased() }.map { raw[$0] }
        func bare(_ word: String) -> String { word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        func startsWith(_ opener: [String]) -> Bool {
            opener.count < words.count && zip(words, opener).allSatisfy { bare($0) == $1 }
        }
        while let opener = openers.first(where: startsWith) {
            words.removeFirst(opener.count)
        }
        var title = ""
        for word in words {
            let next = title.isEmpty ? word : title + " " + word
            if next.count > limit { break }
            title = next
        }
        if title.isEmpty, let first = words.first { title = String(first.prefix(limit)) }
        if title.count < words.joined(separator: " ").count {   // cut short: don't end on a filler word
            var kept = title.split(separator: " ")
            while kept.count > 1, let last = kept.last, trailingFillers.contains(bare(String(last))) { kept.removeLast() }
            title = kept.joined(separator: " ")
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;: "))
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(needle) { return true }
        if status.localizedCaseInsensitiveContains(needle) { return true }
        if let repo = repository?.repository.fullName, repo.localizedCaseInsensitiveContains(needle) { return true }
        if let appTitle = app?.title, appTitle.localizedCaseInsensitiveContains(needle) { return true }
        return messages.contains { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    static func filter(_ tasks: [SavedTask], query: String) -> [SavedTask] {
        let sorted = tasks.sorted { $0.updatedAt > $1.updatedAt }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.matches(query: needle) }
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
                  task.messages.flatMap({ $0.attachments ?? [] }).compactMap(\.imageID).count <= AttachmentLimits.maxImages,
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

extension SavedTask {
    /// The title as shown: an untitled chat reads "New chat".
    var shownTitle: String { title == "New task" ? "New chat" : title }
}
