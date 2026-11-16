import Foundation

/// Port of desktop Keel's repeat-tool reminder (`keel-agent/src/guard.rs`).
///
/// Small models get stuck calling the same tool with the same arguments.
/// When the same call repeats consecutively, the guard returns a reminder to
/// append to that tool's result: gentle at the first threshold, detailed after.
/// Desktop thresholds: 2, 4 and 7 consecutive calls.
public final class RepeatGuard {
    public static let desktopThresholds = [2, 4, 7]
    static let previewLimit = 500

    public let thresholds: [Int]
    private var lastKey = ""
    private(set) public var count = 0
    private var readRangesByPath: [String: [ClosedRange<Int>]] = [:]

    public init(thresholds: [Int] = RepeatGuard.desktopThresholds) {
        self.thresholds = Array(Set(thresholds.filter { $0 > 0 })).sorted()
    }

    /// Call at the start of each user turn.
    public func reset() {
        lastKey = ""
        count = 0
        readRangesByPath.removeAll()
    }

    /// Argument order never matters: keys are sorted.
    public static func canonical(_ arguments: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
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

    private func invalidateReadsIfMutated(name: String, arguments: [String: String]) {
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
        let lineCount = max(1, Int(arguments["count"] ?? "") ?? 30)
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
