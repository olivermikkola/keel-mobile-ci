import Foundation

/// Flashcards and quiz questions written as plain Markdown, so the model needs
/// no special format and the file still reads well as a document:
///
///     # Photosynthesis
///     Q: What gas do plants take in?
///     A: Carbon dioxide
///
///     Q: Where does photosynthesis happen?
///     - [ ] Mitochondria
///     - [x] Chloroplasts
///
/// A question with an answer is a flashcard; one with checkbox choices, one
/// or more ticked, is a multiple-choice question.
public struct StudyDeck: Equatable, Sendable {
    public struct Card: Equatable, Sendable {
        public var question: String
        public var answer: String?
        public var choices: [String] = []
        public var correct: [Int] = []

        public var isQuiz: Bool { choices.count >= 2 && !correct.isEmpty }
    }

    public var title: String?
    public var cards: [Card]

    /// A file is shown as a deck when it holds at least this many cards.
    public static let minimumCards = 2

    public static func parse(_ text: String) -> StudyDeck {
        var title: String?
        var cards: [Card] = []
        var current: Card?
        var inAnswer = false
        func finish() {
            if let card = current, card.answer != nil || card.isQuiz { cards.append(card) }
            current = nil
            inAnswer = false
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let question = labelled(line, ["q", "question"]) {
                finish()
                current = Card(question: question)
            } else if let answer = labelled(line, ["a", "answer"]), current != nil {
                current?.answer = answer
                inAnswer = true
            } else if let choice = choice(line), var card = current, !inAnswer {
                if choice.ticked { card.correct.append(card.choices.count) }
                card.choices.append(choice.text)
                current = card
            } else if line.hasPrefix("#") {
                finish()
                if title == nil, line.hasPrefix("# ") { title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            } else if line.isEmpty {
                if inAnswer { inAnswer = false }
            } else if var card = current {
                // A line after Q: or A: continues it.
                if inAnswer, let answer = card.answer { card.answer = answer + "\n" + line }
                else if card.choices.isEmpty { card.question += "\n" + line }
                current = card
            }
        }
        finish()
        return StudyDeck(title: title, cards: cards.filter { !$0.question.isEmpty })
    }

    /// `Q: text`, `**Q:** text`, `Q1. text`, `1. Q: text`, `Question 2: text`.
    private static func labelled(_ line: String, _ labels: [String]) -> String? {
        let pattern = #"^(?:\d{1,3}[.)]\s*)?(?:\*\*)?(\#(labels.joined(separator: "|")))\s*\d{0,3}\s*[:.)](?:\*\*)?\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 2), in: line) else { return nil }
        let text = line[range].trimmingCharacters(in: .whitespaces)
        return text.replacingOccurrences(of: "**", with: "")
    }

    private static func choice(_ line: String) -> (ticked: Bool, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:[-*+]|\d{1,2}[.)]|[a-hA-H][.)])\s+\[([ xX])\]\s+(.+)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let mark = Range(match.range(at: 1), in: line), let text = Range(match.range(at: 2), in: line) else { return nil }
        return (line[mark] != " ", String(line[text]))
    }
}
