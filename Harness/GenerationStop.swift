import Foundation

/// Streaming detector that says "stop generating" once tool calls are complete.
///
/// Small models keep talking after closing a tool call, which wastes phone time
/// and battery (especially on MLX or non-grammar runs). Feed this every generated
/// piece in order.
///
/// - When `maxCalls == 1` (default): stops immediately at the first complete call
///   closing tag (`</tool_call>`, bare `</function>`, or `<|tool_call_end|>`),
///   ignoring tags inside `<think>...</think>`.
/// - When `maxCalls > 1` (multi-tool turns): stops once `maxCalls` calls have
///   completed, OR as soon as non-whitespace text appears after a closed call
///   that cannot begin another tool call — trimming back to the end of the last
///   completed call.
public struct ToolCallStopDetector: Equatable, Sendable {
    /// Text kept so far. After a stop, this ends right after the last closed call.
    public private(set) var text = ""
    public private(set) var isStopped = false
    public private(set) var completedCalls = 0
    public let maxCalls: Int

    private var inThink = false
    private var activeCall: CallKind?
    /// Index right after the last completed call's closing tag.
    private var lastCallEnd: String.Index?
    /// Start of the first byte not yet scanned for tags. Advances only past complete tags.
    private var cursor: String.Index?

    private enum CallKind: Equatable, Sendable {
        case toolCallTag
        case bareFunction
        case lfmBlock
    }

    static let toolOpen = "<tool_call>"
    static let toolClose = "</tool_call>"
    static let bareFunctionOpenEq = "<function="
    static let bareFunctionOpenSpace = "<function "
    static let functionClose = "</function>"
    static let lfmOpen = "<|tool_call_start|>"
    static let lfmClose = "<|tool_call_end|>"
    static let thinkOpen = "<think>"
    static let thinkClose = "</think>"

    /// Next-call prefixes allowed after a closed call when `maxCalls > 1`.
    private static let continuationOpeners = [toolOpen, bareFunctionOpenEq, bareFunctionOpenSpace, lfmOpen]

    public init(maxCalls: Int = 1) {
        self.maxCalls = max(1, maxCalls)
    }

    /// Adds the next generated piece. Returns true when generation should stop now.
    @discardableResult
    public mutating func feed(_ piece: String) -> Bool {
        guard !isStopped else { return true }
        text += piece
        var position = cursor ?? text.startIndex

        while let tag = nextTag(from: position) {
            // If we already closed at least one call and are waiting to see if
            // another call follows, reject unexpected prose before the next tag.
            if activeCall == nil, let end = lastCallEnd, !inThink {
                let gap = text[end..<tag.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !gap.isEmpty {
                    text = String(text[..<end])
                    isStopped = true
                    return true
                }
            }

            position = tag.range.upperBound
            cursor = position

            switch tag.kind {
            case .thinkOpen:
                if activeCall == nil { inThink = true }
            case .thinkClose:
                if activeCall == nil { inThink = false }
            case .toolOpen where !inThink && activeCall == nil:
                activeCall = .toolCallTag
            case .bareFunctionOpen where !inThink && activeCall == nil:
                activeCall = .bareFunction
            case .lfmOpen where !inThink && activeCall == nil:
                activeCall = .lfmBlock
            case .toolClose where !inThink && activeCall == .toolCallTag:
                activeCall = nil
                completedCalls += 1
                lastCallEnd = tag.range.upperBound
                if completedCalls >= maxCalls {
                    text = String(text[..<tag.range.upperBound])
                    isStopped = true
                    return true
                }
            case .functionClose where !inThink && activeCall == .bareFunction:
                activeCall = nil
                completedCalls += 1
                lastCallEnd = tag.range.upperBound
                if completedCalls >= maxCalls {
                    text = String(text[..<tag.range.upperBound])
                    isStopped = true
                    return true
                }
            case .lfmClose where !inThink && activeCall == .lfmBlock:
                activeCall = nil
                completedCalls += 1
                lastCallEnd = tag.range.upperBound
                if completedCalls >= maxCalls {
                    text = String(text[..<tag.range.upperBound])
                    isStopped = true
                    return true
                }
            default:
                break
            }
        }

        // In multi-call mode, once at least one call closed, check trailing text
        // after `lastCallEnd`: if non-whitespace text has arrived that cannot
        // be a prefix of any next-call opener, stop immediately and trim it off.
        if activeCall == nil, let end = lastCallEnd, !inThink {
            let tail = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                let couldStartNext = Self.continuationOpeners.contains { opener in
                    opener.hasPrefix(tail) || tail.hasPrefix(opener)
                }
                if !couldStartNext {
                    text = String(text[..<end])
                    isStopped = true
                    return true
                }
            }
        }
        return false
    }

    private enum TagKind {
        case toolOpen, toolClose, bareFunctionOpen, functionClose, lfmOpen, lfmClose, thinkOpen, thinkClose
    }

    /// The earliest complete tag at or after `start`, or nil. An incomplete tag at the end is left for the next piece.
    private func nextTag(from start: String.Index) -> (kind: TagKind, range: Range<String.Index>)? {
        let candidates: [(TagKind, String)] = [
            (.toolOpen, Self.toolOpen),
            (.toolClose, Self.toolClose),
            (.bareFunctionOpen, Self.bareFunctionOpenEq),
            (.bareFunctionOpen, Self.bareFunctionOpenSpace),
            (.functionClose, Self.functionClose),
            (.lfmOpen, Self.lfmOpen),
            (.lfmClose, Self.lfmClose),
            (.thinkOpen, Self.thinkOpen),
            (.thinkClose, Self.thinkClose),
        ]
        var best: (kind: TagKind, range: Range<String.Index>)?
        for (kind, tag) in candidates {
            guard let range = text.range(of: tag, range: start..<text.endIndex) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound { best = (kind, range) }
        }
        return best
    }
}
