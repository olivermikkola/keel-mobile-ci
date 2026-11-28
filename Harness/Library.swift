import Foundation

/// Everything the agent made, across chats: the files that applied changes
/// left in each chat's own files, newest chat first. Attachments the user
/// added are not listed (the user already has them), and nor are repository
/// changes (those live in the repository).
public enum Library {
    public struct Chat: Sendable {
        public let taskID: UUID
        public let title: String
        public let updatedAt: Date
        /// Applied changes in the order they were applied.
        public let operations: [TaskWorkspace.Operation]
        public init(taskID: UUID, title: String, updatedAt: Date, operations: [TaskWorkspace.Operation]) {
            self.taskID = taskID; self.title = title; self.updatedAt = updatedAt; self.operations = operations
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { taskID.uuidString + "/" + path }
        public let taskID: UUID
        public let chatTitle: String
        public let path: String
        public let text: String
        public let updatedAt: Date
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        public var kind: FileView.Kind? { FileView.kind(path: path, text: text) }
    }

    public enum Filter: String, CaseIterable, Sendable {
        case all, pages, documents, tables, cards, images, videos, carousels
        public var title: String {
            switch self {
            case .all: return "All"
            case .pages: return "Pages"
            case .documents: return "Docs"
            case .tables: return "Tables"
            case .cards: return "Cards"
            case .images: return "Images"
            case .videos: return "Videos"
            case .carousels: return "Carousels"
            }
        }
        func includes(_ kind: FileView.Kind?) -> Bool {
            switch self {
            case .all: return true
            case .pages: return kind == .page
            case .documents: return kind == .document
            case .tables: return kind == .table
            case .cards: return kind == .cards
            case .images, .videos, .carousels: return false
            }
        }
    }

    /// The files each chat's applied changes left, newest chat first, then by path.
    public static func items(_ chats: [Chat]) -> [Item] {
        chats.sorted { $0.updatedAt > $1.updatedAt }.flatMap { chat -> [Item] in
            var files: [String: String] = [:]
            for operation in chat.operations {
                switch operation {
                case .write(let path, let text): files[path] = text
                case .delete(let path): files[path] = nil
                }
            }
            return files.keys.sorted().map {
                Item(taskID: chat.taskID, chatTitle: chat.title, path: $0, text: files[$0]!, updatedAt: chat.updatedAt)
            }
        }
    }

    public static func filter(_ items: [Item], _ filter: Filter, query: String = "") -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            filter.includes(item.kind) && (needle.isEmpty || item.path.localizedCaseInsensitiveContains(needle)
                || item.chatTitle.localizedCaseInsensitiveContains(needle))
        }
    }

    /// The viewer page for an item; a page's stylesheets and scripts come from
    /// the same chat. Nil for a file with no viewer.
    public static func document(for item: Item, in items: [Item]) -> String? {
        FileView.document(path: item.path, text: item.text) { path in
            items.first { $0.taskID == item.taskID && $0.path == path }?.text
        }
    }
}
