import Foundation
#if canImport(Darwin)
import Darwin.Mach
#endif

/// Prefill/decode throughput, prompt-cache reuse, and memory footprint for a local inference turn.
public struct InferenceTelemetry: Equatable, Sendable {
    public let prefillTokens: Int
    public let reusedTokens: Int
    public let prefillDuration: TimeInterval
    public let decodedTokens: Int
    public let decodeDuration: TimeInterval
    public let footprintBytes: UInt64?

    public init(
        prefillTokens: Int,
        reusedTokens: Int,
        prefillDuration: TimeInterval,
        decodedTokens: Int,
        decodeDuration: TimeInterval,
        footprintBytes: UInt64? = nil
    ) {
        self.prefillTokens = max(0, prefillTokens)
        self.reusedTokens = max(0, reusedTokens)
        self.prefillDuration = max(0, prefillDuration)
        self.decodedTokens = max(0, decodedTokens)
        self.decodeDuration = max(0, decodeDuration)
        self.footprintBytes = footprintBytes
    }

    public var prefillTokensPerSecond: Double? {
        guard prefillTokens > 0, prefillDuration > 0 else { return nil }
        return Double(prefillTokens) / prefillDuration
    }

    public var decodeTokensPerSecond: Double? {
        guard decodedTokens > 0, decodeDuration > 0 else { return nil }
        return Double(decodedTokens) / decodeDuration
    }

    /// Combines multiple generation steps within a single assistant turn while keeping peak footprint.
    public func combined(with next: InferenceTelemetry?) -> InferenceTelemetry {
        guard let next else { return self }
        let peakMemory: UInt64?
        switch (footprintBytes, next.footprintBytes) {
        case (.some(let lhs), .some(let rhs)): peakMemory = max(lhs, rhs)
        case (.some(let lhs), .none): peakMemory = lhs
        case (.none, .some(let rhs)): peakMemory = rhs
        case (.none, .none): peakMemory = nil
        }
        return InferenceTelemetry(
            prefillTokens: prefillTokens + next.prefillTokens,
            reusedTokens: reusedTokens + next.reusedTokens,
            prefillDuration: prefillDuration + next.prefillDuration,
            decodedTokens: decodedTokens + next.decodedTokens,
            decodeDuration: decodeDuration + next.decodeDuration,
            footprintBytes: peakMemory
        )
    }

    /// Compact telemetry summary for assistant reply metadata.
    public var summary: String? {
        var parts: [String] = []
        if let prefillRate = prefillTokensPerSecond {
            parts.append("prefill \(Self.formatRate(prefillRate)) tok/s")
        } else if reusedTokens > 0 && prefillTokens == 0 {
            parts.append("cache hit")
        }
        if let decodeRate = decodeTokensPerSecond {
            parts.append("decode \(Self.formatRate(decodeRate)) tok/s")
        }
        if let footprintBytes, footprintBytes > 0 {
            parts.append(Self.formatMemory(footprintBytes))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    public static func formatRate(_ tokensPerSecond: Double) -> String {
        if tokensPerSecond >= 100 {
            return String(format: "%.0f", tokensPerSecond)
        }
        return String(format: "%.1f", tokensPerSecond)
    }

    public static func formatMemory(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        let megabytes = max(1, Int((Double(bytes) / 1_000_000).rounded()))
        return "\(megabytes) MB"
    }

    /// Physical memory footprint reported by the kernel on Apple platforms.
    public static func currentFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.phys_footprint
        #else
        return nil
        #endif
    }
}
