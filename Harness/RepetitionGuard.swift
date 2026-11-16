import Foundation

/// Notices a reply stuck repeating itself, so generation can stop early
/// instead of running to the reply limit.
///
/// Small fine-tunes sometimes fall into a loop such as `&amp;count&amp;limit…`
/// and write it until the limit. Feed this every generated piece in order. It
/// reports a loop once the last `span` characters repeat with a period of at
/// most `maxPeriod` characters, and the span covers at least three periods.
/// Ordinary prose and code almost never repeat 400 characters exactly.
public struct RepetitionGuard: Equatable, Sendable {
    public static let span = 400
    public static let maxPeriod = 200

    public private(set) var isLooping = false
    /// Length in characters of the repeating unit, once looping.
    public private(set) var period = 0
    private var tail: [Unicode.Scalar] = []

    public init() {}

    /// Adds the next piece. Returns true when the reply is looping.
    @discardableResult
    public mutating func feed(_ piece: String) -> Bool {
        guard !isLooping else { return true }
        tail.append(contentsOf: piece.unicodeScalars)
        let keep = Self.span + Self.maxPeriod
        if tail.count > keep { tail.removeFirst(tail.count - keep) }
        if let found = Self.period(of: tail) {
            isLooping = true
            period = found
        }
        return isLooping
    }

    /// The smallest period whose repetition covers the last `span` scalars.
    static func period(of scalars: [Unicode.Scalar]) -> Int? {
        let count = scalars.count
        guard count > span else { return nil }
        for candidate in 1...maxPeriod {
            let needed = max(span, 3 * candidate)
            guard count >= needed + candidate else { break }
            var index = count - 1
            let stop = count - needed
            while index >= stop, scalars[index] == scalars[index - candidate] { index -= 1 }
            if index < stop { return candidate }
        }
        return nil
    }

    /// `text` with its repeating end cut back to a single copy of the unit.
    public static func collapse(_ text: String, period: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard period > 0, scalars.count > period else { return text }
        var start = scalars.count - 1
        while start - period >= 0, scalars[start] == scalars[start - period] { start -= 1 }
        // Everything after `start` repeats the unit that ends at `start`.
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[...start])
        return String(result)
    }
}
