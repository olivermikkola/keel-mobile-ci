import Foundation

/// Zero-RAM n-gram speculative token proposer over recent prompt and output tokens.
/// Requires no secondary draft model weights: it matches the trailing `minMatchLength`
/// tokens against an earlier occurrence in the same conversation and proposes up to
/// `maxDraftTokens` continuation tokens for a single Metal batch-verification pass.
///
/// Only use with pure-attention models whose KV cache supports suffix removal
/// (`llama_memory_seq_rm`). Hybrid/recurrent models cannot rewind rejected draft tokens.
public struct NGramSpeculator: Sendable, Equatable {
    public let minMatchLength: Int
    public let maxDraftTokens: Int
    public let maxSearchWindow: Int

    public init(minMatchLength: Int = 3, maxDraftTokens: Int = 4, maxSearchWindow: Int = 4_096) {
        self.minMatchLength = max(2, minMatchLength)
        self.maxDraftTokens = max(1, maxDraftTokens)
        self.maxSearchWindow = max(64, maxSearchWindow)
    }

    /// Searches backwards in `history` for the most recent prior occurrence of its
    /// trailing `minMatchLength` tokens and returns up to `min(maxDraftTokens, maxTokens)`
    /// tokens immediately following that match. Returns `[]` when no match exists.
    public func propose(from history: [Int32], maxTokens: Int? = nil) -> [Int32] {
        let limit = min(maxDraftTokens, maxTokens ?? maxDraftTokens)
        guard limit > 0, history.count > minMatchLength else { return [] }

        let needleStart = history.count - minMatchLength
        let lastSearchStart = needleStart - 1
        let earliestSearchStart = max(0, needleStart - maxSearchWindow)
        guard lastSearchStart >= earliestSearchStart else { return [] }

        // Scan backwards so the freshest repetition (e.g., an identifier, JSON key,
        // or code line from the current file) wins over stale older occurrences.
        let tailToken = history[history.count - 1]
        var candidate = lastSearchStart
        while candidate >= earliestSearchStart {
            if history[candidate + minMatchLength - 1] == tailToken {
                var matched = true
                for offset in 0..<(minMatchLength - 1) {
                    if history[candidate + offset] != history[needleStart + offset] {
                        matched = false
                        break
                    }
                }
                if matched {
                    let draftStart = candidate + minMatchLength
                    let available = needleStart - draftStart
                    guard available > 0 else {
                        candidate -= 1
                        continue
                    }
                    let count = min(limit, available)
                    return Array(history[draftStart..<(draftStart + count)])
                }
            }
            candidate -= 1
        }
        return []
    }

    /// Compares proposed `draft` tokens against the target model's `verified` tokens
    /// sampled at positions `0...draft.count`.
    ///
    /// - `verified[0]` is sampled from the last already-committed token (checking `draft[0]`).
    /// - `verified[i]` (for `i < draft.count`) checks `draft[i]`.
    /// - `verified[draft.count]` (when all `draft` tokens match) is the free bonus token.
    ///
    /// Returns the exact sequence of tokens to commit (`emitted`) and how many draft
    /// tokens were accepted (`acceptedDraftCount`). When `acceptedDraftCount == 0`,
    /// `emitted` is still `[verified[0]]`, matching non-speculative decoding identically.
    public static func verify(draft: [Int32], verified: [Int32]) -> (emitted: [Int32], acceptedDraftCount: Int) {
        guard !verified.isEmpty else { return ([], 0) }
        var emitted: [Int32] = []
        emitted.reserveCapacity(min(draft.count + 1, verified.count))
        var accepted = 0
        for index in 0..<draft.count {
            guard index < verified.count else { break }
            let targetToken = verified[index]
            emitted.append(targetToken)
            if targetToken == draft[index] {
                accepted += 1
            } else {
                return (emitted, accepted)
            }
        }
        if verified.count > draft.count {
            emitted.append(verified[draft.count])
        }
        return (emitted, accepted)
    }
}
