import Foundation

/// Facts about the user that carry across chats: "I'm vegetarian", "my
/// daughter is called Aino". The model asks to save one with `remember`;
/// nothing is saved until the user says yes. Saved facts go into the system
/// prompt of every plain chat, newest first, within a fixed budget. The user
/// sees and deletes them in Customize, and can turn memory off there.
public struct UserMemory: Codable, Equatable, Sendable {
    public struct Fact: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var text: String
        public var savedAt: Date
        public init(id: UUID = UUID(), text: String, savedAt: Date = Date()) {
            self.id = id; self.text = text; self.savedAt = savedAt
        }
    }

    public var facts: [Fact] = []
    /// Off: no `remember` tool and no facts in the prompt. Saved facts are kept.
    public var enabled = true

    public static let maxFacts = 40
    public static let maxFactCharacters = 200
    /// Characters of facts put into one prompt. About 300 tokens.
    public static let promptBudget = 1_200

    public static let tool = #"{"type":"function","function":{"name":"remember","description":"Ask to save one short fact about the user for future chats, such as a lasting preference or detail they want remembered. Use it when the user asks you to remember something. One fact per call, under 200 characters, written about the user (\"The user is vegetarian\"). The user approves each fact before it is saved.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}}"#

    public enum Problem: LocalizedError, Equatable {
        case empty, tooLong, full, duplicate
        public var errorDescription: String? {
            switch self {
            case .empty: return "Expected fact: one short sentence about the user."
            case .tooLong: return "A fact is at most \(UserMemory.maxFactCharacters) characters. Shorten it to the one detail worth keeping."
            case .full: return "Memory is full (\(UserMemory.maxFacts) facts). The user can delete old ones in Customize."
            case .duplicate: return "That is already remembered."
            }
        }
    }

    public init(facts: [Fact] = [], enabled: Bool = true) { self.facts = facts; self.enabled = enabled }

    /// A fact as it would be saved: one line, defused, bounded.
    public static func clean(_ raw: String) throws -> String {
        let line = raw.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        guard !line.isEmpty else { throw Problem.empty }
        guard line.count <= maxFactCharacters else { throw Problem.tooLong }
        return CustomInstructions.sanitize(line)
    }

    /// Checks a fact before the user is asked, so a bad call is answered at once.
    public func validate(_ raw: String) throws -> String {
        let text = try Self.clean(raw)
        guard !facts.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { throw Problem.duplicate }
        guard facts.count < Self.maxFacts else { throw Problem.full }
        return text
    }

    public mutating func add(_ raw: String, at date: Date = Date()) throws {
        facts.append(Fact(text: try validate(raw), savedAt: date))
    }

    public mutating func remove(_ id: UUID) { facts.removeAll { $0.id == id } }

    /// Facts that fit the prompt budget, newest first.
    public var promptFacts: [Fact] {
        var used = 0
        var chosen: [Fact] = []
        for fact in facts.sorted(by: { $0.savedAt > $1.savedAt }) {
            guard used + fact.text.count + 3 <= Self.promptBudget else { break }
            used += fact.text.count + 3
            chosen.append(fact)
        }
        return chosen
    }

    /// The memory part of a system prompt. Unchanged prompt when off or empty.
    public func apply(to system: String) -> String {
        let shown = enabled ? promptFacts : []
        guard !shown.isEmpty else { return system }
        return system + "\n\nWhat you remember about the user from earlier chats (saved with their approval):\n"
            + shown.map { "- " + $0.text }.joined(separator: "\n")
    }

    public static func load(_ data: Data) -> UserMemory {
        (try? JSONDecoder().decode(UserMemory.self, from: data)) ?? UserMemory()
    }
}
