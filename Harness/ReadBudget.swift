import Foundation

/// How much of a file one `read_file` call returns.
///
/// Reads used to stop at 30 lines (60 at most), so a small model needed many
/// calls, and many re-read prompts, to see one file. Now a read returns as many
/// lines as fit, up to `maxLines`, within a byte budget that grows with the
/// model's context. A read that is cut says where to continue.
public enum ReadBudget {
    /// The most lines one read returns, and the default when no count is given.
    public static let maxLines = 400

    /// Bytes of one read result for a model with this context: about 6,000 at
    /// 8K tokens (a fifth of the context) and 12,000 from 16K. It stops there:
    /// the phone prefills every byte at a few hundred tokens a second, so a
    /// 12,000-byte read (about 3,500 tokens) already costs about ten seconds.
    public static func bytes(contextSize: UInt32) -> Int {
        min(12_000, max(6_000, Int(contextSize) * 3 / 4))
    }

    /// The exclusive end of the longest run of lines from `offset`, at most
    /// `count` and never past `total`, whose result `fits`. Nil when not even
    /// the first line fits. `fits` must be monotonic: fewer lines never fit worse.
    public static func end(offset: Int, count: Int, total: Int, fits: (Int) throws -> Bool) rethrows -> Int? {
        let last = min(total, offset + max(1, count))
        guard offset < last, try fits(offset + 1) else { return nil }
        if try fits(last) { return last }
        var low = offset + 1, high = last // fits(low), !fits(high)
        while high - low > 1 {
            let middle = (low + high) / 2
            if try fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}
