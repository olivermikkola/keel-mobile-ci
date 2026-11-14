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

    public init(thresholds: [Int] = RepeatGuard.desktopThresholds) {
        self.thresholds = Array(Set(thresholds.filter { $0 > 0 })).sorted()
    }

    /// Call at the start of each user turn.
    public func reset() {
        lastKey = ""
        count = 0
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
        let canonical = Self.canonical(arguments)
        let key = name + ":" + canonical
        if key == lastKey { count += 1 } else { lastKey = key; count = 1 }
        guard thresholds.contains(count) else { return nil }
        if count == thresholds.first { return Self.gentle }
        return Self.detailed(name: name, count: count, canonical: canonical)
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
