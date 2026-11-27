import Foundation

/// Answers a whole, single-operation request without asking the language model.
enum QuickArithmetic {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?i)\A\s*(?:(?:what is|what['’]s|how much is|calculate|compute)\s+)?([+-]?[0-9]{1,9}(?:\.[0-9]{1,6})?)\s*(\+|-|−|\*|×|x|/|÷|plus|minus|times|multiplied by|divided by)\s*([+-]?[0-9]{1,9}(?:\.[0-9]{1,6})?)\s*[?!.=]?(?:\s+reply with (?:just |only )?the number[.!]?)?\s*\z"#
    )

    static func answer(_ text: String) -> String? {
        guard text.utf8.count <= 180,
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let leftRange = Range(match.range(at: 1), in: text),
              let operatorRange = Range(match.range(at: 2), in: text),
              let rightRange = Range(match.range(at: 3), in: text) else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        guard let left = Decimal(string: String(text[leftRange]), locale: locale),
              let right = Decimal(string: String(text[rightRange]), locale: locale) else { return nil }

        switch text[operatorRange].lowercased() {
        case "+", "plus": return canonical(left + right)
        case "-", "−", "minus": return canonical(left - right)
        case "*", "×", "x", "times", "multiplied by": return canonical(left * right)
        case "/", "÷", "divided by":
            guard right != 0 else { return "Cannot divide by zero." }
            var result = left / right
            var rounded = Decimal()
            NSDecimalRound(&rounded, &result, 10, .plain)
            // Check the reverse operation since division of a recurring decimal
            // can lose precision before it reaches the explicit rounding step.
            return rounded * right == left ? canonical(rounded) : "≈ " + canonical(rounded)
        default: return nil
        }
    }

    private static func canonical(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
