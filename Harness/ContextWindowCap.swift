import Foundation

/// Optional user-selected ceiling on the active model's context window.
/// Stepping context down on tighter-RAM phones reduces KV-cache memory and heat
/// without switching models; the effective window never exceeds what the model supports.
public enum ContextWindowCap: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case k4
    case k8
    case k16

    public var id: String { rawValue }

    /// Maximum token window for this cap, or `nil` for `.auto` (use the model's full default).
    public var maxTokens: UInt32? {
        switch self {
        case .auto: return nil
        case .k4: return 4_096
        case .k8: return 8_192
        case .k16: return 16_384
        }
    }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .k4: return "4K"
        case .k8: return "8K"
        case .k16: return "16K"
        }
    }

    public var detail: String {
        switch self {
        case .auto: return "Use each model's default context window."
        case .k4: return "Smallest memory footprint and coolest replies (4,096 tokens)."
        case .k8: return "Balanced memory and chat length (8,192 tokens)."
        case .k16: return "Longer conversations on devices with headroom (16,384 tokens)."
        }
    }

    /// Resolves the effective context size for a model whose default is `modelDefault`.
    /// Never enlarges a model past its own safe default.
    public func effectiveContextSize(modelDefault: UInt32) -> UInt32 {
        guard modelDefault > 0 else { return 0 }
        guard let cap = maxTokens else { return modelDefault }
        return min(modelDefault, cap)
    }

    /// Returns only the caps that meaningfully apply to a model of size `modelDefault`
    /// (`.auto` plus any strictly smaller cap).
    public static func selectableOptions(forModelDefault modelDefault: UInt32) -> [ContextWindowCap] {
        [.auto] + allCases.filter { cap in
            guard let tokens = cap.maxTokens else { return false }
            return tokens < modelDefault
        }
    }

    /// Compact badge text when a cap is actively trimming the model's default window, or `nil` when unchanged.
    public func activeBadge(forModelDefault modelDefault: UInt32) -> String? {
        let effective = effectiveContextSize(modelDefault: modelDefault)
        guard effective < modelDefault else { return nil }
        return "\(effective / 1024)K cap"
    }
}
