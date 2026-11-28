import Foundation

/// Something shared into Keel from another app's share sheet ("Send to
/// Keel"). The share extension saves it in the App Group folder both share,
/// then opens Keel with `keelmobile://share?id=…`; Keel also looks for it
/// whenever it comes to the front, in case iOS did not let the extension
/// open it. Plain Foundation: compiled into the app and the extension.
public struct SharedItem: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        /// A new chat with the link or text in the message box and the file attached.
        case chat
        /// The Videos screen with the photos picked.
        case video
        /// The Carousels screen with the photos picked.
        case carousel
    }

    public var id: UUID
    public var action: Action
    public var text: String?
    public var url: String?
    /// Photo file names in the item's folder, in the order shared.
    public var photos: [String]
    /// Other file names in the item's folder.
    public var files: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), action: Action, text: String? = nil, url: String? = nil,
                photos: [String] = [], files: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.text = text
        self.url = url
        self.photos = photos
        self.files = files
        self.createdAt = createdAt
    }

    /// What goes in the chat's message box: the link with a request to read
    /// it, the text, or both. Nil when only a file or photo was shared.
    public var prompt: String? {
        let note = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt: String
        switch (note.isEmpty, link.isEmpty) {
        case (true, true): return nil
        case (true, false): prompt = "Read and summarize \(link)"
        case (false, true): prompt = note
        case (false, false): prompt = note.contains(link) ? note : "\(note)\n\n\(link)"
        }
        return String(prompt.prefix(16_000))   // IncomingLink.maxPromptCharacters; the extension has only this file
    }
}

public enum SharedInbox {
    /// The App Group both the app and its share extension belong to.
    public static let appGroup = "group.com.olivermikkola.keelmobile"
    public static let maxPhotos = 6
    public static let maxFiles = 1
    /// Bigger files are refused in the share sheet, as in the chat.
    public static let maxFileBytes = 32 * 1024 * 1024
    /// Shares nobody opened are removed after this long.
    public static let keepFor: TimeInterval = 24 * 60 * 60
    static let manifestName = "share.json"

    /// The App Group's folder, or nil where the entitlement is missing.
    public static func root() -> URL? {
        #if os(Linux)
        return nil
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Share", isDirectory: true)
        #endif
    }

    public static func folder(_ id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Makes the folder for a new share; files go in it before `save`.
    public static func prepare(_ id: UUID, in root: URL) throws -> URL {
        let folder = folder(id, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Written last, so a share is only seen once its files are all there.
    public static func save(_ item: SharedItem, in root: URL) throws {
        let folder = try prepare(item.id, in: root)
        let encoder = JSONEncoder()
        try encoder.encode(item).write(to: folder.appendingPathComponent(manifestName), options: .atomic)
    }

    public static func load(_ id: UUID, in root: URL) -> SharedItem? {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: folder(id, in: root).appendingPathComponent(manifestName)),
              let item = try? decoder.decode(SharedItem.self, from: data), item.id == id else { return nil }
        return item
    }

    /// Shares not yet opened, oldest first; removes those older than `keepFor`.
    public static func pending(in root: URL, now: Date = Date()) -> [SharedItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var items: [SharedItem] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            if let item = load(id, in: root) {
                if now.timeIntervalSince(item.createdAt) > keepFor { remove(id, in: root) } else { items.append(item) }
            } else if let made = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      now.timeIntervalSince(made) > keepFor {
                remove(id, in: root)   // a share the extension never finished
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    /// Marks a share as opened: its manifest goes, so it is not offered
    /// again, while its files stay for the screen reading them until `keepFor`.
    public static func markOpened(_ id: UUID, in root: URL) {
        try? FileManager.default.removeItem(at: folder(id, in: root).appendingPathComponent(manifestName))
    }

    public static func remove(_ id: UUID, in root: URL) {
        try? FileManager.default.removeItem(at: folder(id, in: root))
    }

    /// `keelmobile://share?id=…`
    public static func link(_ id: UUID) -> URL {
        URL(string: "keelmobile://share?id=\(id.uuidString)")!
    }
}
