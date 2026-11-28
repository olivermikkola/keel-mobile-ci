import Foundation

/// Port of desktop Keel's repeat-tool reminder (`keel-agent/src/guard.rs`),
/// extended with hard loop-stop detection so small on-device models can never
/// burn infinite retries or overheat the phone.
///
/// When the same call repeats consecutively, `observe` returns an advisory
/// reminder (thresholds 2, 4, 7). In addition, `evaluateStop` and
/// `recordMalformedCall` return a `LoopStop` when retries are provably stuck
/// (repeated identical failure, consecutive failures, ping-pong failure loops,
/// or repeated identical calls), allowing the runtime to lock out tools and
/// force a clean plain-text final answer.
public final class RepeatGuard {
    public static let desktopThresholds = [2, 4, 7]
    public static let defaultMaxIdenticalFailures = 2
    public static let defaultMaxTotalFailures = 4
    public static let defaultMaxIdenticalRepeats = 3
    public static let defaultMaxConsecutiveMalformed = 3
    static let previewLimit = 500

    public enum LoopStop: Equatable, Sendable {
        case repeatedFailedCall(tool: String, attempts: Int)
        case consecutiveFailures(count: Int)
        case tooManyFailures(count: Int)
        case repeatedIdenticalCall(tool: String, attempts: Int)
        case repeatedMalformedCalls(count: Int)

        /// Concise cue appended to the prompt on the forced final plain-text step.
        public var modelInstruction: String {
            switch self {
            case .repeatedFailedCall(let tool, _):
                return "Tool calls are paused for this turn because \(tool) failed repeatedly with the same arguments. Do not call any tools. Answer the user directly in plain language."
            case .consecutiveFailures, .tooManyFailures:
                return "Tool calls are paused for this turn because repeated tool requests failed. Do not call any tools. Answer the user directly in plain language and explain what could not be done."
            case .repeatedIdenticalCall(let tool, _):
                return "Tool calls are paused for this turn because \(tool) was already called repeatedly with the same arguments. Do not call any tools. Answer the user directly using the results you already have."
            case .repeatedMalformedCalls:
                return "Tool calls are paused for this turn because the previous tool requests were malformed. Do not call any tools. Answer the user directly in plain language."
            }
        }

        /// Clean fallback message if a small model still emits empty/tag-only output on the forced final step.
        public var fallbackUserMessage: String {
            switch self {
            case .repeatedFailedCall(let tool, _):
                return "I stopped retrying \(tool) because it kept failing with the same request. Let me know what you'd like me to do instead."
            case .consecutiveFailures, .tooManyFailures:
                return "I stopped calling tools because several tool requests failed in a row. Try rephrasing what you want, or switch to Chat mode for a plain reply."
            case .repeatedIdenticalCall(let tool, _):
                return "I stopped repeating \(tool) because it wasn't making new progress. Let me know how you'd like to proceed."
            case .repeatedMalformedCalls:
                return "I couldn't format a valid tool request for that step. Try rephrasing, or switch to a larger model for tool tasks."
            }
        }
    }

    public let thresholds: [Int]
    public let maxIdenticalFailures: Int
    public let maxTotalFailures: Int
    public let maxIdenticalRepeats: Int
    public let maxConsecutiveMalformed: Int

    private var lastKey = ""
    private(set) public var count = 0
    private var readRangesByPath: [String: [ClosedRange<Int>]] = [:]
    private var failedCallsByKey: [String: Int] = [:]
    private(set) public var totalFailures = 0
    private(set) public var consecutiveMalformed = 0

    public init(
        thresholds: [Int] = RepeatGuard.desktopThresholds,
        maxIdenticalFailures: Int = RepeatGuard.defaultMaxIdenticalFailures,
        maxTotalFailures: Int = RepeatGuard.defaultMaxTotalFailures,
        maxIdenticalRepeats: Int = RepeatGuard.defaultMaxIdenticalRepeats,
        maxConsecutiveMalformed: Int = RepeatGuard.defaultMaxConsecutiveMalformed
    ) {
        self.thresholds = Array(Set(thresholds.filter { $0 > 0 })).sorted()
        self.maxIdenticalFailures = max(1, maxIdenticalFailures)
        self.maxTotalFailures = max(1, maxTotalFailures)
        self.maxIdenticalRepeats = max(2, maxIdenticalRepeats)
        self.maxConsecutiveMalformed = max(1, maxConsecutiveMalformed)
    }

    /// Call at the start of each user turn.
    public func reset() {
        lastKey = ""
        count = 0
        readRangesByPath.removeAll()
        failedCallsByKey.removeAll()
        totalFailures = 0
        consecutiveMalformed = 0
    }

    /// Argument order never matters: keys are sorted.
    public static func canonical(_ arguments: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Strips internal harness steering annotations (`[repeat-tool-reminder]`,
    /// `[circuit-breaker]`, `[tool-loop-stopped]`) before showing tool output to users.
    public static func stripInternalNotes(_ text: String) -> String {
        let markers = ["\n\n[repeat-tool-reminder]", "\n\n[circuit-breaker]", "\n\n[tool-loop-stopped]",
                       "[repeat-tool-reminder]", "[circuit-breaker]", "[tool-loop-stopped]"]
        var cutoff = text.endIndex
        for marker in markers {
            if let range = text.range(of: marker), range.lowerBound < cutoff {
                cutoff = range.lowerBound
            }
        }
        return String(text[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Observe a call that is about to run. Returns a reminder, or nil.
    public func observe(name: String, arguments: [String: String]) -> String? {
        invalidateReadsIfMutated(name: name, arguments: arguments)
        let canonical = Self.canonical(arguments)
        let key = name + ":" + canonical
        let isConsecutiveRepeat = key == lastKey
        if isConsecutiveRepeat { count += 1 } else { lastKey = key; count = 1 }
        if thresholds.contains(count) {
            recordReadRangeIfNeeded(name: name, arguments: arguments)
            if count == thresholds.first { return Self.gentle }
            return Self.detailed(name: name, count: count, canonical: canonical)
        }
        // Detect non-identical overlapping line slices on the same file so small models
        // don't re-read overlapping ranges (exact repeats are handled above).
        if !isConsecutiveRepeat, name == "read_file", let (path, range) = Self.readRange(from: arguments) {
            let previous = readRangesByPath[path, default: []]
            let overlapped = previous.contains(range) ? nil : previous.first { $0.overlaps(range) }
            if !previous.contains(range) { readRangesByPath[path, default: []].append(range) }
            if let overlapped {
                return Self.overlappingRead(path: path, requested: range, previous: overlapped)
            }
        } else {
            recordReadRangeIfNeeded(name: name, arguments: arguments)
        }
        return nil
    }

    /// Records the execution outcome of a parsed tool call and returns a hard stop
    /// when the model is stuck repeating failures or identical no-progress calls.
    public func evaluateStop(
        name: String,
        arguments: [String: String],
        succeeded: Bool,
        breaker: CircuitBreaker
    ) -> LoopStop? {
        consecutiveMalformed = 0
        if !succeeded {
            let key = name + ":" + Self.canonical(arguments)
            let attempts = failedCallsByKey[key, default: 0] + 1
            failedCallsByKey[key] = attempts
            totalFailures += 1
            if attempts >= maxIdenticalFailures {
                return .repeatedFailedCall(tool: name, attempts: attempts)
            }
            if breaker.consecutiveFailures >= breaker.tripThreshold {
                return .consecutiveFailures(count: breaker.consecutiveFailures)
            }
            if totalFailures >= maxTotalFailures {
                return .tooManyFailures(count: totalFailures)
            }
            return nil
        }
        if count >= maxIdenticalRepeats {
            return .repeatedIdenticalCall(tool: name, attempts: count)
        }
        return nil
    }

    /// Records a malformed / rejected tool call and returns a hard stop when
    /// consecutive rejections hit the limit.
    public func recordMalformedCall() -> LoopStop? {
        consecutiveMalformed += 1
        totalFailures += 1
        if consecutiveMalformed >= maxConsecutiveMalformed {
            return .repeatedMalformedCalls(count: consecutiveMalformed)
        }
        if totalFailures >= maxTotalFailures {
            return .tooManyFailures(count: totalFailures)
        }
        return nil
    }

    private func invalidateReadsIfMutated(name: String, arguments: [String: String]) {
        if name == ShellTool.name || name == "run_js" {
            readRangesByPath.removeAll()
            return
        }
        guard ["propose_edit", "create_file", "delete_file", "rename_file"].contains(name) else { return }
        if let path = arguments["path"] { readRangesByPath.removeValue(forKey: path) }
        if let destination = arguments["destination_path"] { readRangesByPath.removeValue(forKey: destination) }
    }

    private func recordReadRangeIfNeeded(name: String, arguments: [String: String]) {
        guard name == "read_file", let (path, range) = Self.readRange(from: arguments) else { return }
        if !(readRangesByPath[path]?.contains(range) ?? false) {
            readRangesByPath[path, default: []].append(range)
        }
    }

    private static func readRange(from arguments: [String: String]) -> (String, ClosedRange<Int>)? {
        guard let path = arguments["path"], !path.isEmpty else { return nil }
        let start: Int
        if let startLine = arguments["start_line"], let parsed = Int(startLine) {
            start = max(1, parsed)
        } else if let offset = arguments["offset"], let parsed = Int(offset) {
            start = max(1, parsed + 1)
        } else {
            start = 1
        }
        // Without a count a read returns as many lines as fit, unknown in
        // advance, so only its first line counts towards an overlap.
        let lineCount = max(1, Int(arguments["count"] ?? "") ?? 1)
        return (path, start...(start + lineCount - 1))
    }

    static func overlappingRead(path: String, requested: ClosedRange<Int>, previous: ClosedRange<Int>) -> String {
        "\n\n[repeat-tool-reminder] You already read lines \(previous.lowerBound)–\(previous.upperBound) of \(path) in this turn (overlaps requested \(requested.lowerBound)–\(requested.upperBound)). Inspect that earlier result or read a non-overlapping range."
    }

    static let gentle = "\n\n[repeat-tool-reminder] You are repeating the exact same tool call with identical arguments. Carefully analyze the previous result before calling again: if the task is not complete, try a different approach or different arguments instead of repeating the call."

    static func detailed(name: String, count: Int, canonical: String) -> String {
        let scalars = canonical.unicodeScalars
        var preview = canonical
        if scalars.count > previewLimit {
            var head = String.UnicodeScalarView()
            head.append(contentsOf: scalars.prefix(previewLimit))
            preview = String(head) + "… (+\(scalars.count - previewLimit) more chars)"
        }
        return "\n\n[repeat-tool-reminder] Repeated tool call detected:\n- tool: \(name)\n- consecutive_calls: \(count)\n- arguments: \(preview)\nThe repeated calls are not making progress. Do not call this tool with these exact arguments again. Inspect the latest result and choose a different action, different arguments, or finish the task if enough evidence has been gathered."
    }
}
