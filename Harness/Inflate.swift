import Foundation

public enum ArchiveError: Error, Equatable {
    /// Not a gzip stream, or a gzip feature this reader does not accept.
    case gzip
    /// The compressed stream is damaged or ends early.
    case corrupt
    /// The tar structure is damaged or uses an unsupported entry layout.
    case tar
    /// More entries or bytes than the caller's bound.
    case tooLarge
}

/// Gzip (RFC 1952) and DEFLATE (RFC 1951) in plain Swift, so the repository
/// archive is unpacked by the same code on the phone and in Linux tests.
/// Output is pushed to `sink` in chunks; nothing is ever held beyond the
/// 32 KB back-reference window and one chunk.
enum Gunzip {
    /// Inflates one gzip member. `limit` bounds the total output bytes.
    static func inflate(_ input: Data, limit: Int, sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try input.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw ArchiveError.gzip }
            let flags = bytes[3]
            guard flags & 0xE0 == 0 else { throw ArchiveError.gzip }
            var offset = 10
            if flags & 0x04 != 0 {
                guard offset + 2 <= bytes.count else { throw ArchiveError.gzip }
                offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
            }
            for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
                while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
                offset += 1
            }
            if flags & 0x02 != 0 { offset += 2 }
            guard offset < bytes.count else { throw ArchiveError.gzip }
            var inflater = Inflater(input: bytes, offset: offset, limit: limit)
            try inflater.run(sink: sink)
        }
    }
}

private struct HuffmanTable {
    static let fastBits = 10
    /// Indexed by the next `fastBits` stream bits. `(symbol << 4) | length`, or 0
    /// when the code is longer than `fastBits` and needs the canonical walk.
    var fast = [UInt16](repeating: 0, count: 1 << HuffmanTable.fastBits)
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16] = []

    init(lengths: [UInt8]) throws {
        for length in lengths { counts[Int(length)] += 1 }
        counts[0] = 0
        var left = 1
        for length in 1...15 {
            left <<= 1
            left -= Int(counts[length])
            guard left >= 0 else { throw ArchiveError.corrupt }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + Int(counts[length]) }
        symbols = [UInt16](repeating: 0, count: lengths.count)
        var codes = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + Int(counts[length - 1])) << 1
            codes[length] = code
        }
        for (symbol, length) in lengths.enumerated() where length != 0 {
            let length = Int(length)
            symbols[offsets[length]] = UInt16(symbol)
            offsets[length] += 1
            let canonical = codes[length]
            codes[length] += 1
            guard length <= HuffmanTable.fastBits else { continue }
            // Stream bits arrive least-significant first; a Huffman code is
            // read most-significant first. Reverse it to index by raw bits.
            var reversed = 0
            for bit in 0..<length where canonical & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
            let entry = UInt16(symbol << 4 | length)
            var index = reversed
            while index < fast.count {
                fast[index] = entry
                index += 1 << length
            }
        }
    }
}

private struct Inflater {
    private let input: UnsafeBufferPointer<UInt8>
    private var position: Int
    private var bits: UInt64 = 0
    private var bitCount = 0
    private var remaining: Int
    private var window: UnsafeMutablePointer<UInt8>
    private var filled = 0
    private var flushed = 0
    private static let windowSize = 32_768
    private static let capacity = 262_144

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    init(input: UnsafeBufferPointer<UInt8>, offset: Int, limit: Int) {
        self.input = input
        position = offset
        remaining = limit
        window = UnsafeMutablePointer<UInt8>.allocate(capacity: Inflater.capacity)
    }

    mutating func run(sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        defer { window.deallocate() }
        var final = false
        while !final {
            final = try take(1) == 1
            switch try take(2) {
            case 0: try stored(sink)
            case 1:
                var lengths = [UInt8](repeating: 8, count: 288)
                for index in 144..<256 { lengths[index] = 9 }
                for index in 256..<280 { lengths[index] = 7 }
                try block(literals: HuffmanTable(lengths: lengths),
                          distances: HuffmanTable(lengths: [UInt8](repeating: 5, count: 30)), sink)
            case 2: try dynamic(sink)
            default: throw ArchiveError.corrupt
            }
        }
        try flush(sink, all: true)
    }

    private mutating func refill() {
        while bitCount <= 56, position < input.count {
            bits |= UInt64(input[position]) << UInt64(bitCount)
            position += 1
            bitCount += 8
        }
    }

    private mutating func take(_ count: Int) throws -> Int {
        if count == 0 { return 0 }
        if bitCount < count { refill() }
        guard bitCount >= count else { throw ArchiveError.corrupt }
        let value = Int(bits & ((1 << UInt64(count)) - 1))
        bits >>= UInt64(count)
        bitCount -= count
        return value
    }

    private mutating func symbol(_ table: HuffmanTable) throws -> Int {
        if bitCount < 15 { refill() }
        let entry = table.fast[Int(bits & UInt64((1 << HuffmanTable.fastBits) - 1))]
        if entry != 0 {
            let length = Int(entry & 15)
            guard bitCount >= length else { throw ArchiveError.corrupt }
            bits >>= UInt64(length)
            bitCount -= length
            return Int(entry >> 4)
        }
        var code = 0, first = 0, index = 0
        for length in 1...15 {
            guard bitCount >= 1 else { throw ArchiveError.corrupt }
            code |= Int(bits & 1)
            bits >>= 1
            bitCount -= 1
            let count = Int(table.counts[length])
            if code - count < first { return Int(table.symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw ArchiveError.corrupt
    }

    private mutating func emit(_ count: Int, _ sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        guard count <= remaining else { throw ArchiveError.tooLarge }
        remaining -= count
        if filled + count > Inflater.capacity { try flush(sink, all: false) }
    }

    private mutating func flush(_ sink: (UnsafeBufferPointer<UInt8>) throws -> Void, all: Bool) throws {
        if filled > flushed {
            try sink(UnsafeBufferPointer(start: window + flushed, count: filled - flushed))
        }
        flushed = filled
        guard !all, filled > Inflater.windowSize else { return }
        // Keep only what a back-reference can still reach.
        memmove(window, window + (filled - Inflater.windowSize), Inflater.windowSize)
        filled = Inflater.windowSize
        flushed = filled
    }

    private mutating func stored(_ sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        // Return whole unread bytes to the input and drop the partial byte.
        position -= bitCount / 8
        bits = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw ArchiveError.corrupt }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        let check = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard length == (~check & 0xFFFF) else { throw ArchiveError.corrupt }
        position += 4
        guard position + length <= input.count else { throw ArchiveError.corrupt }
        var copied = 0
        while copied < length {
            let part = min(length - copied, Inflater.capacity - Inflater.windowSize)
            try emit(part, sink)
            memcpy(window + filled, input.baseAddress! + position + copied, part)
            filled += part
            copied += part
        }
        position += length
    }

    private mutating func dynamic(_ sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let literalCount = try take(5) + 257
        let distanceCount = try take(5) + 1
        let codeCount = try take(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw ArchiveError.corrupt }
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<codeCount { codeLengths[Inflater.codeLengthOrder[index]] = UInt8(try take(3)) }
        let codeTable = try HuffmanTable(lengths: codeLengths)
        var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let value = try symbol(codeTable)
            if value < 16 {
                lengths[index] = UInt8(value)
                index += 1
                continue
            }
            var previous: UInt8 = 0
            var repeatCount: Int
            switch value {
            case 16:
                guard index > 0 else { throw ArchiveError.corrupt }
                previous = lengths[index - 1]
                repeatCount = 3 + (try take(2))
            case 17: repeatCount = 3 + (try take(3))
            default: repeatCount = 11 + (try take(7))
            }
            guard index + repeatCount <= lengths.count else { throw ArchiveError.corrupt }
            while repeatCount > 0 {
                lengths[index] = previous
                index += 1
                repeatCount -= 1
            }
        }
        guard lengths[256] != 0 else { throw ArchiveError.corrupt }
        try block(literals: HuffmanTable(lengths: Array(lengths[0..<literalCount])),
                  distances: HuffmanTable(lengths: Array(lengths[literalCount...])), sink)
    }

    private mutating func block(literals: HuffmanTable, distances: HuffmanTable,
                                _ sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        while true {
            let value = try symbol(literals)
            if value < 256 {
                try emit(1, sink)
                window[filled] = UInt8(value)
                filled += 1
                continue
            }
            if value == 256 { return }
            let lengthIndex = value - 257
            guard lengthIndex < 29 else { throw ArchiveError.corrupt }
            let length = Inflater.lengthBase[lengthIndex] + (try take(Inflater.lengthExtra[lengthIndex]))
            let distanceIndex = try symbol(distances)
            guard distanceIndex < 30 else { throw ArchiveError.corrupt }
            let distance = Inflater.distanceBase[distanceIndex] + (try take(Inflater.distanceExtra[distanceIndex]))
            try emit(length, sink)
            guard distance <= filled else { throw ArchiveError.corrupt }
            // Byte by byte on purpose: an overlapping copy repeats its own output.
            var source = filled - distance
            for _ in 0..<length {
                window[filled] = window[source]
                filled += 1
                source += 1
            }
        }
    }
}
