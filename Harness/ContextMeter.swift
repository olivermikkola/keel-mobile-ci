import Foundation

/// Compact context-window usage and thermal status summary for the chat screen.
public struct ContextMeter: Equatable, Sendable {
    public enum ThermalLevel: String, Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical

        /// Plain-language badge shown only when the device is noticeably warm or hotter.
        public var badge: String? {
            switch self {
            case .nominal: return nil
            case .fair: return "Warm"
            case .serious: return "Hot"
            case .critical: return "Overheated"
            }
        }

        public var isElevated: Bool { self != .nominal }
    }

    public let usedTokens: Int
    public let contextSize: Int
    public let thermal: ThermalLevel

    public init(usedTokens: Int, contextSize: Int, thermal: ThermalLevel = .nominal) {
        self.usedTokens = max(0, usedTokens)
        self.contextSize = max(0, contextSize)
        self.thermal = thermal
    }

    /// Fraction of the active context window used, clamped to `0...1`.
    public var fraction: Double {
        guard contextSize > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedTokens) / Double(contextSize)))
    }

    public var percentUsed: Int {
        Int((fraction * 100.0).rounded())
    }

    /// True when the conversation is nearing compaction (75% of context or higher).
    public var isHigh: Bool {
        contextSize > 0 && fraction >= 0.75
    }

    /// Compact label such as `"2.4K / 8K (30%)"`, or `nil` before any tokens have been read.
    public var contextLabel: String? {
        guard usedTokens > 0, contextSize > 0 else { return nil }
        return "\(Self.formatTokens(usedTokens)) / \(Self.formatTokens(contextSize)) (\(percentUsed)%)"
    }

    /// Combined status text for a subtle pill, or `nil` when nothing needs surfacing.
    public var pillText: String? {
        var parts: [String] = []
        if let contextLabel { parts.append(contextLabel) }
        if let thermalBadge = thermal.badge { parts.append(thermalBadge) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    public static func formatTokens(_ count: Int) -> String {
        if count >= 1_000 {
            let k = Double(count) / 1_000.0
            if k >= 10 || abs(k - k.rounded()) < 0.05 {
                return "\(Int(k.rounded()))K"
            }
            return String(format: "%.1fK", k)
        }
        return "\(max(0, count))"
    }
}
