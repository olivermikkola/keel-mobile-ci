import Foundation

/// Streaming detector that says "stop generating" once a tool call is complete.
///
/// Small models keep talking after `</tool_call>`, which wastes phone time and
/// can add a second call. Feed this every generated piece in order. It returns
/// true at the first `</tool_call>` that closes a `<tool_call>` opened outside a
/// `<think>...</think>` block. Tags are matched exactly as `ToolCallText` and the
/// app's strict parser expect them. A tag may be split across pieces.
///
/// A `</tool_call>` before any opening tag, or inside a think block, does not stop
/// generation. An unclosed think block never stops it, so the reply limit still applies.
public struct ToolCallStopDetector: Equatable {
    /// Text kept so far. After a stop, this ends right after `</tool_call>`.
    public private(set) var text = ""
    public private(set) var isStopped = false

    private var inThink = false
    private var inCall = false
    /// Start of the first byte not yet scanned for tags. Advances only past complete tags.
    private var cursor: String.Index?

    static let toolOpen = "<tool_call>"
    static let toolClose = "</tool_call>"
    static let thinkOpen = "<think>"
    static let thinkClose = "</think>"

    public init() {}

    /// Adds the next generated piece. Returns true when generation should stop now.
    @discardableResult
    public mutating func feed(_ piece: String) -> Bool {
        guard !isStopped else { return true }
        text += piece
        var position = cursor ?? text.startIndex
        while let tag = nextTag(from: position) {
            position = tag.range.upperBound
            cursor = position
            switch tag.kind {
            case .thinkOpen: inThink = true
            case .thinkClose: inThink = false
            case .toolOpen where !inThink: inCall = true
            case .toolClose where !inThink && inCall:
                // Everything after the closing tag in this piece is dropped.
                text = String(text[..<tag.range.upperBound])
                isStopped = true
                return true
            default: break
            }
        }
        return false
    }

    private enum Kind { case toolOpen, toolClose, thinkOpen, thinkClose }

    /// The earliest complete tag at or after `start`, or nil. An incomplete tag at the end is left for the next piece.
    private func nextTag(from start: String.Index) -> (kind: Kind, range: Range<String.Index>)? {
        let candidates: [(Kind, String)] = [(.toolOpen, Self.toolOpen), (.toolClose, Self.toolClose),
                                            (.thinkOpen, Self.thinkOpen), (.thinkClose, Self.thinkClose)]
        var best: (kind: Kind, range: Range<String.Index>)?
        for (kind, tag) in candidates {
            guard let range = text.range(of: tag, range: start..<text.endIndex) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound { best = (kind, range) }
        }
        return best
    }
}
