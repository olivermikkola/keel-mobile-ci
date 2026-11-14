import Foundation

/// One message in an agent task, as the harness sees it.
public struct HarnessMessage: Equatable {
    public enum Role: String { case user, assistant, tool, summary }
    public var role: Role
    public var text: String
    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

/// Port of desktop Keel's `ToolResultPruner` (`keel-agent/src/compaction.rs`).
/// Long tool results keep their head and tail, and the middle is cut.
/// Counts Unicode scalars, as Rust's `chars()` does.
public struct ToolResultPruner: Equatable {
    public var thresholdChars: Int
    public var headChars: Int
    public var tailChars: Int

    /// Desktop defaults: 8192 / 4096 / 1024.
    public static let desktop = ToolResultPruner(thresholdChars: 8192, headChars: 4096, tailChars: 1024)

    public init(thresholdChars: Int, headChars: Int, tailChars: Int) {
        self.thresholdChars = thresholdChars
        self.headChars = headChars
        self.tailChars = tailChars
    }

    public func prune(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > thresholdChars else { return text }
        let head = String(String.UnicodeScalarView(scalars.prefix(headChars)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(tailChars)))
        let omitted = max(0, scalars.count - headChars - tailChars)
        return "\(head)\n…[\(omitted) chars middle-pruned by keel compaction]…\n\(tail)"
    }
}

/// Port of desktop Keel's `ContextBudget` and a deterministic compactor.
///
/// Compaction starts at 75% of the real context window and aims for 50%, as
/// on desktop. It never touches the first user message (the task) or the most
/// recent `keepRecentSteps` model steps. It works in two stages:
/// 1. prune old long tool results;
/// 2. replace the oldest tool steps with one summary note that lists the calls
///    made, so the model knows the work happened. User messages and plain
///    answers are never folded;
/// 3. if the recent steps alone are still too big, prune their results too,
///    except the newest, which only gets the desktop limit.
public struct ContextBudget: Equatable {
    /// How compaction trades prompt-cache reuse against how much it trims.
    /// llama.cpp reuses its KV cache only up to the first changed token, so any
    /// edit to an early message re-evaluates everything after it.
    public enum CompactionStyle: Equatable {
        /// Desktop behaviour: prune old results and fold steps whenever over the
        /// threshold, down to `targetTokens`. Early messages change often.
        case eager
        /// Prefix-friendly: no in-place pruning of old results. When over the
        /// threshold, fold the oldest steps in one block down to `lowWaterTokens`,
        /// so the next fold is far away. Appends between folds keep the prefix byte-identical.
        case stablePrefix
    }

    public var maxContextTokens: Int
    public var compactionThresholdTokens: Int
    public var targetTokens: Int
    /// Stable-prefix fold goal: 30% of the window, below the 75% threshold, so about
    /// 45% of the window fills before the next fold. Not a desktop value; the
    /// simulation in PrefixStableCompactionTests measured it, and it is not a recommendation.
    public var lowWaterTokens: Int
    public var style: CompactionStyle
    public var keepRecentSteps: Int
    public var charsPerToken: Double
    /// Per-message chat-template overhead in tokens (role markers).
    public var messageOverheadTokens: Int
    public var oldResultPruner: ToolResultPruner

    /// Desktop ratios: threshold 75%, target 50%, keep 3 recent steps, 3.8 chars/token.
    public init(maxContextTokens: Int) {
        self.init(maxContextTokens: maxContextTokens, style: .eager)
    }

    public init(maxContextTokens: Int, style: CompactionStyle) {
        self.maxContextTokens = maxContextTokens
        compactionThresholdTokens = Int(Double(maxContextTokens) * 0.75)
        targetTokens = Int(Double(maxContextTokens) * 0.50)
        lowWaterTokens = Int(Double(maxContextTokens) * 0.30)
        self.style = style
        keepRecentSteps = 3
        charsPerToken = 3.8
        messageOverheadTokens = 4
        // Older results only need their gist on a small phone window.
        oldResultPruner = ToolResultPruner(thresholdChars: 1200, headChars: 800, tailChars: 200)
    }

    public func estimate(_ message: HarnessMessage) -> Int {
        Int((Double(message.text.unicodeScalars.count) / charsPerToken).rounded(.up)) + messageOverheadTokens
    }

    public func estimate(_ messages: [HarnessMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    public func shouldCompact(_ messages: [HarnessMessage], reservedTokens: Int = 0) -> Bool {
        estimate(messages) + reservedTokens > compactionThresholdTokens
    }

    public struct Report: Equatable {
        public let beforeTokens: Int
        public let afterTokens: Int
        public let prunedResults: Int
        public let summarizedMessages: Int
    }

    /// Compacts in place when over the threshold. `reservedTokens` covers the
    /// system prompt and the reply that has to fit after the history.
    @discardableResult
    public func compact(_ messages: inout [HarnessMessage], reservedTokens: Int = 0) -> Report? {
        let before = estimate(messages)
        guard before + reservedTokens > compactionThresholdTokens else { return nil }
        let goal = style == .stablePrefix ? lowWaterTokens : targetTokens
        let target = max(0, goal - reservedTokens)
        guard let taskIndex = messages.firstIndex(where: { $0.role == .user }) else { return nil }

        // Protected tail: the last `keepRecentSteps` assistant messages and everything after the first of them.
        let assistantIndices = messages.indices.filter { messages[$0].role == .assistant && $0 > taskIndex }
        let tailStart = assistantIndices.count > keepRecentSteps
            ? assistantIndices[assistantIndices.count - keepRecentSteps] : messages.count
        let middle = (taskIndex + 1)..<max(taskIndex + 1, tailStart)

        // Stage 1: prune old tool results. Skipped in stable-prefix mode, where
        // old results are only ever dropped in a fold, never rewritten in place.
        var pruned = 0
        for i in middle where style == .eager && messages[i].role == .tool {
            let shorter = oldResultPruner.prune(messages[i].text)
            if shorter != messages[i].text { messages[i].text = shorter; pruned += 1 }
        }

        // Stage 2: fold the oldest tool steps (a call and its results, or an
        // earlier summary) into one note. User messages and plain answers stay.
        var summarized = 0
        if estimate(messages) > target, !middle.isEmpty {
            var remaining = estimate(messages)
            var foldIndices: [Int] = []
            var i = middle.lowerBound
            while i < middle.upperBound, remaining > target {
                let isCall = messages[i].role == .assistant && Self.callLine(messages[i].text) != nil
                guard isCall || messages[i].role == .summary else { i += 1; continue }
                var j = i + 1
                if isCall { while j < middle.upperBound, messages[j].role == .tool { j += 1 } }
                for k in i..<j { foldIndices.append(k); remaining -= estimate(messages[k]) }
                i = j
            }
            if let first = foldIndices.first {
                let folded = foldIndices.map { messages[$0] }
                let note = HarnessMessage(.summary, Self.summary(of: folded))
                let skip = Set(foldIndices)
                var rebuilt: [HarnessMessage] = []
                for index in messages.indices {
                    if index == first { rebuilt.append(note) }
                    if !skip.contains(index) { rebuilt.append(messages[index]) }
                }
                messages = rebuilt
                summarized = folded.count
            }
        }

        // Stage 3: the protected recent steps are too big on their own.
        if estimate(messages) > target, let newest = messages.lastIndex(where: { $0.role == .tool }) {
            for i in messages.indices where messages[i].role == .tool {
                let shorter = i == newest ? ToolResultPruner.desktop.prune(messages[i].text) : oldResultPruner.prune(messages[i].text)
                if shorter != messages[i].text { messages[i].text = shorter; pruned += 1 }
            }
        }
        return Report(beforeTokens: before, afterTokens: estimate(messages), prunedResults: pruned, summarizedMessages: summarized)
    }

    /// Deterministic and data-safe: lists only the calls that were made, never
    /// tool-result content, so repository text cannot move out of the data zone.
    static func summary(of folded: [HarnessMessage]) -> String {
        // Earlier notes contribute their call lines, so repeated compaction keeps one note.
        let calls = folded.flatMap { message -> [String] in
            switch message.role {
            case .assistant: return callLine(message.text).map { [$0] } ?? []
            case .summary: return message.text.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            default: return []
            }
        }
        let results = folded.filter { $0.role == .tool }.count
        var lines = ["[keel compaction] Earlier steps were removed to fit the context window: \(calls.count) tool calls and \(results) results."]
        if !calls.isEmpty { lines.append("Calls already made:") }
        lines += calls.map { "- " + $0 }
        lines.append("Do not repeat these calls unless their results are needed again.")
        return lines.joined(separator: "\n")
    }

    /// `read_file path=README.md start_line=1` from a Qwen XML call, or nil.
    static func callLine(_ text: String) -> String? {
        guard let name = text.range(of: #"<function=([a-z_]+)>"#, options: .regularExpression) else { return nil }
        var line = String(text[name]).dropFirst("<function=".count).dropLast().description
        let parameter = try! NSRegularExpression(pattern: #"<parameter=([a-z_]+)>([^<]{0,80})"#)
        for match in parameter.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            let clean = text[value].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            line += " \(text[key])=\(clean)"
        }
        return line
    }

    /// Role-string form for the app's chat history (`user`, `assistant`, `tool`).
    /// Returns nil when nothing needed compacting. The summary note comes back as
    /// a `tool` message so the prompt builder wraps it as data, not as the user.
    public func compactPrompt(_ history: [(role: String, text: String)], reservedTokens: Int) -> [(role: String, text: String)]? {
        var messages = history.map { HarnessMessage(HarnessMessage.Role(rawValue: $0.role) ?? .user, $0.text) }
        guard compact(&messages, reservedTokens: reservedTokens) != nil else { return nil }
        return messages.map { ($0.role == .summary ? "tool" : $0.role.rawValue, $0.text) }
    }
}
