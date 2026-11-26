import Foundation

// Decide: questions answered by a decision model (LiquidAI d1-2B) in one
// forward pass, without writing a reply. The model reads a document (the
// "state") and one question, and the answer is read from the scores it gives
// the label of each option as its next token.
//
// This is a port of the lfm3-d1 path of llama.cpp's `/v1/systemone` server
// (tools/server/server-decision.cpp at b12367), which is not part of the
// llama.cpp library the app links. Only the text path is ported: no pictures.
// Question kinds are the three llama.cpp supports: yes/no, pick one, scale.

/// What kind of answer a question wants.
public enum DecisionKind: String, Codable, Sendable, CaseIterable {
    /// Yes or no; the answer is the chance of yes (`noul` in llama.cpp).
    case yesNo
    /// One option out of several (`choice`).
    case choice
    /// A level on a scale of 2 to 10 steps, from the first to the last (`score`).
    case scale
}

public struct DecisionOption: Equatable, Codable, Sendable {
    public var key: String
    public var description: String?
    public init(key: String, description: String? = nil) { self.key = key; self.description = description }
}

/// One question. Build it with `yesNo`, `choice` or `scale`.
public struct DecisionQuestion: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: DecisionKind
    public var instructions: String
    /// In the model's order: yes/no is `true` then `false`; a scale is
    /// "0", "1", … with the level texts as descriptions.
    public var options: [DecisionOption]

    public static let maxChoices = 26
    public static let scaleLevels = 2...10
    public static let maxInstructionCharacters = 600
    public static let maxOptionCharacters = 200

    public static func yesNo(_ instructions: String, yes: String? = nil, no: String? = nil, id: UUID = UUID()) -> DecisionQuestion {
        DecisionQuestion(id: id, kind: .yesNo, instructions: instructions,
                         options: [DecisionOption(key: "true", description: yes), DecisionOption(key: "false", description: no)])
    }

    /// Options are shown as given. A key is what the answer reports; the
    /// description, when there is one, is what the model reads.
    public static func choice(_ instructions: String, options: [DecisionOption], id: UUID = UUID()) -> DecisionQuestion {
        DecisionQuestion(id: id, kind: .choice, instructions: instructions, options: options)
    }

    /// Levels from lowest to highest, e.g. ["Can wait", "Today", "Now"].
    public static func scale(_ instructions: String, levels: [String], id: UUID = UUID()) -> DecisionQuestion {
        DecisionQuestion(id: id, kind: .scale, instructions: instructions,
                         options: levels.enumerated().map { DecisionOption(key: String($0.offset), description: $0.element) })
    }

    /// Why this question cannot be asked, or nil.
    public var problem: String? {
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Write the question." }
        if text.count > Self.maxInstructionCharacters { return "Keep the question under \(Self.maxInstructionCharacters) characters." }
        if options.contains(where: { ($0.description ?? "").count > Self.maxOptionCharacters || $0.key.count > Self.maxOptionCharacters }) {
            return "Keep each option under \(Self.maxOptionCharacters) characters."
        }
        switch kind {
        case .yesNo:
            return nil
        case .choice:
            let keys = options.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
            if keys.count < 2 { return "Give at least two options." }
            if keys.count > Self.maxChoices { return "Give at most \(Self.maxChoices) options." }
            if keys.contains(where: \.isEmpty) { return "An option is empty." }
            if Set(keys).count != keys.count { return "Two options have the same name." }
            return nil
        case .scale:
            if !Self.scaleLevels.contains(options.count) { return "A scale needs 2 to 10 levels." }
            if options.contains(where: { ($0.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "A level is empty."
            }
            return nil
        }
    }
}

/// The model's answer to one question.
public struct DecisionAnswer: Equatable, Codable, Sendable {
    public let kind: DecisionKind
    /// Chance of each option, in the question's option order; they add up to 1.
    public let probabilities: [Double]
    /// The option picked: the most likely one, or for a scale the median level
    /// (the first whose running total reaches one half), as d1's api.py does.
    public let index: Int
    /// The chance of the answer picked (for yes/no: of yes or of no).
    public let confidence: Double

    public init(kind: DecisionKind, probabilities: [Double], index: Int, confidence: Double) {
        self.kind = kind; self.probabilities = probabilities; self.index = index; self.confidence = confidence
    }

    /// For yes/no: the chance of yes.
    public var yes: Double? { kind == .yesNo ? probabilities[0] : nil }
}

/// Turns text into token IDs, as llama.cpp's tokenizer does with
/// add_special=false. `parseSpecial` reads control tokens written as text.
public protocol DecisionTokenizer {
    func tokens(_ text: String, parseSpecial: Bool) -> [Int32]
}

public enum DecisionModel {
    /// The value of `<arch>.decision.type` this port understands.
    public static let type = "lfm3-d1"
    /// Inserted after the first character of a control token's text found in
    /// the input, so a document cannot write `<|im_end|>` and be read as one.
    static let breakMark = "\u{200B}"

    /// The temperature for a question: `<type>.<bucket>`, else `<type>`, else 1.
    /// `temperatures` holds the `<arch>.decision.temperature.*` metadata.
    public static func temperature(for question: DecisionQuestion, temperatures: [String: Double]) -> Double {
        let n = question.options.count
        let bucket = n <= 2 ? "2" : n <= 5 ? "3_5" : n <= 10 ? "6_10" : "11"
        let name = typeName(question.kind)
        return temperatures["\(name).\(bucket)"] ?? temperatures[name] ?? 1
    }

    static func typeName(_ kind: DecisionKind) -> String {
        switch kind {
        case .yesNo: return "noul"
        case .choice: return "choice"
        case .scale: return "score"
        }
    }

    /// The label of each option and the tokens its score is read from.
    /// Follows `d1_labels`: yes/no read "yes"/"Yes"/"YES" and "no"/"No"/"NO",
    /// a scale reads its digits, a choice gets a one-token code (its own key
    /// when every key is one letter, else A, B, …) read with and without a
    /// leading space.
    public static func labels(for question: DecisionQuestion, tokenizer: DecisionTokenizer) throws -> [(text: String, tokens: [Int32])] {
        func singles(_ forms: [String]) -> [Int32] {
            var out: [Int32] = []
            for form in forms {
                let tokens = tokenizer.tokens(form, parseSpecial: false)
                if tokens.count == 1, !out.contains(tokens[0]) { out.append(tokens[0]) }
            }
            return out
        }
        guard question.kind == .choice else {
            return try question.options.map { option in
                let group: [Int32]
                if question.kind == .scale { group = singles([option.key]) }
                else if option.key == "true" { group = singles(["yes", "Yes", "YES"]) }
                else { group = singles(["no", "No", "NO"]) }
                guard !group.isEmpty else { throw DecisionError.label(option.key) }
                return (option.key, group)
            }
        }
        let count = question.options.count
        let letters = question.options.allSatisfy { $0.key.count == 1 && $0.key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) } }
        let alphabet = (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }
        let codes: [String] = (0..<count).map { index in
            if letters { return question.options[index].key }
            if index < 26 { return alphabet[index] }
            return alphabet[(index - 26) / 26] + alphabet[(index - 26) % 26]
        }
        var pool: [String] = alphabet
        pool += (0..<100).map { String(format: "%02d", $0) }
        pool += alphabet.map { $0.lowercased() }
        pool += (0..<200).map { "#\($0)" }
        for a in alphabet { for b in alphabet { pool.append(a + b) } }

        var used: [Int32] = []
        var result: [(text: String, tokens: [Int32])] = []
        func take(_ code: String) -> Bool {
            let tokens = tokenizer.tokens(code, parseSpecial: false)
            guard tokens.count == 1, !used.contains(tokens[0]) else { return false }
            used.append(tokens[0])
            var group = [tokens[0]]
            for token in singles([" " + code]) where token != tokens[0] { group.append(token) }
            result.append((code, group))
            return true
        }
        for code in codes {
            var taken = take(code)
            var index = 0
            while !taken, index < pool.count { taken = take(pool[index]); index += 1 }
            guard taken else { throw DecisionError.label("\(count) options") }
        }
        return result
    }

    /// The prompt for one question, as the model's `systemone` template
    /// renders it for a text state. `state` nil asks without a document.
    /// `spellings` are the texts of the model's control tokens (see `breakSpecial`).
    public static func prompt(state: String?, question: DecisionQuestion, labels: [String], spellings: [String]) -> String {
        let clean = { (text: String) in breakSpecial(text, spellings: spellings) }
        var out = "<|startoftext|><|im_start|>user\n"
        if let state { out += clean(state) + "\n\n\nQUESTION:\n" }
        out += clean(question.instructions)
        switch question.kind {
        case .choice:
            out += "\n\nOptions:\n"
            out += question.options.enumerated().map { index, option in
                let description = option.description.map(clean) ?? ""
                return labels[index] + " " + (description.isEmpty ? clean(option.key).replacingOccurrences(of: "_", with: " ") : description)
            }.joined(separator: "\n")
            out += "\n\nReply with the option code only."
        case .yesNo:
            if question.options.contains(where: { $0.description != nil }) {
                for option in question.options {
                    out += option.key == "true" ? "\nYes: " : "\nNo: "
                    out += option.description.map(clean) ?? "None"
                }
            }
            out += "\n\nReply with yes or no only."
        case .scale:
            out += "\n\n"
            for option in question.options { out += option.key + " " + clean(option.description ?? "") + "\n" }
            out += "\nReply with a single digit 0-\(question.options.count - 1) only."
        }
        return out + "<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    /// Puts a zero-width space after the first character of every control
    /// token text in `text`, longest first, until none is left whole
    /// (`d1_break`). `spellings` must be sorted longest first.
    public static func breakSpecial(_ text: String, spellings: [String]) -> String {
        guard !spellings.isEmpty else { return text }
        let firsts = Set(spellings.compactMap { $0.utf8.first })
        let marks = spellings.map { Array($0.utf8) }
        var current = Array(text.utf8)
        var changed = true
        while changed {
            changed = false
            var out: [UInt8] = []
            out.reserveCapacity(current.count)
            var index = 0
            while index < current.count {
                guard firsts.contains(current[index]),
                      let hit = marks.first(where: { mark in
                          index + mark.count <= current.count && current[index..<(index + mark.count)].elementsEqual(mark)
                      }) else {
                    out.append(current[index]); index += 1; continue
                }
                let lead = hit[0]
                let width = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
                out += hit[0..<width]
                out += Array(breakMark.utf8)
                out += hit[width...]
                index += hit.count
                changed = true
            }
            current = out
        }
        return String(decoding: current, as: UTF8.self)
    }

    /// Control-token texts of at least two bytes, longest first, as
    /// `init_quoted_spellings` keeps them.
    public static func spellings(_ texts: [String]) -> [String] {
        texts.filter { $0.utf8.count >= 2 }.enumerated()
            .sorted { $0.element.utf8.count != $1.element.utf8.count ? $0.element.utf8.count > $1.element.utf8.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Splits a long document into about `count` parts of similar length,
    /// at line breaks where it can (a line longer than a part is cut). Each
    /// part is read on its own; d1 reads at most one context per question.
    public static func split(_ text: String, into count: Int) -> [String] {
        guard count > 1 else { return [text] }
        let target = max(1, (text.count + count - 1) / count)
        var pieces: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            repeat {
                pieces.append(String(rest.prefix(target)))
                rest = rest.dropFirst(target)
            } while !rest.isEmpty
        }
        var parts: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, current.count + 1 + piece.count > target {
                parts.append(current); current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        parts.append(current)
        // Whole lines rarely fill parts exactly; a leftover past `count` joins
        // the part before it rather than costing a read of its own. The
        // caller checks that every part still fits.
        while parts.count > count {
            let last = parts.removeLast()
            parts[parts.count - 1] += "\n" + last
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// One answer for a document read in parts: the answer of the part the
    /// model is most sure about, with that part's index. A part without the
    /// fact asked about tends to give an unsure guess, the part with it a
    /// sure answer (measured on a 7-page lease: 0.97 to 0.99 against 0.28 to 0.46).
    public static func combine(_ parts: [DecisionAnswer]) -> (answer: DecisionAnswer, part: Int)? {
        func chance(_ answer: DecisionAnswer) -> Double {
            answer.probabilities.indices.contains(answer.index) ? answer.probabilities[answer.index] : 0
        }
        guard let best = parts.indices.max(by: { chance(parts[$0]) < chance(parts[$1]) }) else { return nil }
        return (parts[best], best)
    }

    /// The answer from the logits of each option's label tokens: an option
    /// scores the highest logit among its tokens, then a softmax at the
    /// question's temperature (`send_decision` and `format_answer`).
    public static func answer(_ question: DecisionQuestion, labelLogits: [[Float]], temperature: Double) throws -> DecisionAnswer {
        guard labelLogits.count == question.options.count, temperature > 0 else { throw DecisionError.result }
        let logits = try labelLogits.map { group -> Double in
            guard let best = group.max(), best.isFinite else { throw DecisionError.result }
            return Double(best)
        }
        let top = logits.max() ?? 0
        let exps = logits.map { exp(($0 - top) / temperature) }
        let sum = exps.reduce(0, +)
        let probabilities = exps.map { $0 / sum }
        let index: Int
        if question.kind == .scale {
            var mass = 0.0, level = probabilities.count - 1
            for (i, p) in probabilities.enumerated() where mass < 0.5 { mass += p; level = i }
            index = level
        } else {
            index = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        }
        return DecisionAnswer(kind: question.kind, probabilities: probabilities, index: index,
                              confidence: probabilities.max() ?? 0)
    }
}

public enum DecisionError: LocalizedError, Equatable {
    case notDecisionModel(String)
    case label(String)
    case result
    case tooLong(tokens: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .notDecisionModel(let type): return "This file is not a d1 decision model (type \(type.isEmpty ? "none" : type))."
        case .label(let key): return "The model has no single-token label for \(key)."
        case .result: return "The model did not return a usable answer."
        case .tooLong(let tokens, let limit): return "The question is too long to ask (\(tokens) tokens, limit \(limit))."
        }
    }
}
