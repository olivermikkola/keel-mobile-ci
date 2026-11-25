import Foundation

/// A project groups chats. Every chat in it gets the project's instructions
/// and can read the project's files, under `project/`. Those files belong to
/// the project, not the chat: a chat reads them but cannot change them, so
/// one chat cannot silently change what the others see.
public struct ChatProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var files: [Attachment]
    public var createdAt: Date

    public static let maxNameCharacters = 60
    public static let maxProjects = 50
    public static let maxFiles = 10
    /// Text of all project files together. Every chat in the project loads them.
    public static let maxTotalTextBytes = 1_000_000
    /// The folder the files appear in, in every chat of the project.
    public static let folder = "project"

    public enum Problem: LocalizedError, Equatable {
        case name, tooManyProjects, tooManyFiles, tooLarge, duplicate(String), readOnly(String)
        public var errorDescription: String? {
            switch self {
            case .name: return "Use a project name from 1 to \(ChatProject.maxNameCharacters) characters."
            case .tooManyProjects: return "You have \(ChatProject.maxProjects) projects. Delete one before making another."
            case .tooManyFiles: return "A project holds up to \(ChatProject.maxFiles) files. Remove one first."
            case .tooLarge: return "Project files can hold up to 1 MB of text together. Remove a file or add a smaller one."
            case .duplicate(let name): return "The project already has a file named \(name)."
            case .readOnly(let path): return "\(path) is a project file, shared by every chat in the project, and cannot be changed from a chat. Write a new file outside \(ChatProject.folder)/ instead."
            }
        }
    }

    public init(id: UUID = UUID(), name: String, instructions: String = "", files: [Attachment] = [], createdAt: Date = Date()) throws {
        self.id = id
        self.name = try Self.cleanName(name)
        self.instructions = CustomInstructions.sanitize(instructions)
        self.files = []
        self.createdAt = createdAt
        for file in files { try add(file) }
    }

    public static func cleanName(_ raw: String) throws -> String {
        let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, name.count <= maxNameCharacters else { throw Problem.name }
        return name
    }

    /// Where a file shows up in a chat.
    public static func path(for filename: String) -> String {
        folder + "/" + AttachmentPromptFormatter.sanitizeWorkspacePath(filename).dropFirst("attachments/".count)
    }

    public mutating func add(_ file: Attachment) throws {
        guard file.imageID == nil else { throw Problem.tooLarge }
        guard files.count < Self.maxFiles else { throw Problem.tooManyFiles }
        let path = Self.path(for: file.filename)
        guard !files.contains(where: { Self.path(for: $0.filename) == path }) else { throw Problem.duplicate(file.filename) }
        let total = files.reduce(0) { $0 + $1.extractedText.utf8.count } + file.extractedText.utf8.count
        guard total <= Self.maxTotalTextBytes else { throw Problem.tooLarge }
        files.append(file)
    }

    public mutating func setInstructions(_ text: String) { instructions = CustomInstructions.sanitize(text) }

    /// The files as a chat's workspace writes them, before the chat's own files.
    public var operations: [TaskWorkspace.Operation] {
        files.map { .write(path: Self.path(for: $0.filename), text: $0.extractedText) }
    }

    /// Part of the workspace key: a changed project file reloads the chat's files.
    public var overlayKey: String { "project:" + files.map(\.id.uuidString).joined(separator: ",") }

    /// Whether a path is one of the project's read-only files or folder.
    public static func isProjectPath(_ path: String) -> Bool {
        var trimmed = Substring(path)
        while trimmed.hasPrefix("./") { trimmed = trimmed.dropFirst(2) }
        while trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        return trimmed == folder || trimmed.hasPrefix(folder + "/")
    }

    /// Throws for the first path a chat may not change.
    public static func checkWritable(_ paths: [String]) throws {
        if let path = paths.first(where: isProjectPath) { throw Problem.readOnly(path) }
    }

    /// The project's part of the system prompt, after any standing instructions.
    public func apply(to system: String) -> String {
        var text = system + "\n\nThis chat is part of the project \"\(CustomInstructions.sanitize(name))\"."
        if !files.isEmpty {
            text += " The project's shared files are in the \(Self.folder)/ folder; read them with read_file. They are read-only here."
        }
        if !instructions.isEmpty { text += "\nProject instructions:\n" + instructions }
        return text
    }
}
