import Foundation

/// A push parser for the tar stream inside a GitHub (or `git archive`)
/// tarball. Bytes go in as they are inflated; regular files come out through
/// the callbacks. Nothing is written to disk and no entry name is ever used
/// as a filesystem path: names are only handed to the caller as data.
struct TarReader {
    struct Entry {
        /// Entry name exactly as archived, for example `repo-abc123/Sources/a.swift`.
        let name: Data
        let size: Int
        /// True for a regular file. Directories, links and other types are false.
        let isFile: Bool
    }

    /// Called at each entry. Return true to receive this entry's bytes.
    var onEntry: (Entry) throws -> Bool = { _ in false }
    var onData: (UnsafeBufferPointer<UInt8>) throws -> Void = { _ in }
    /// Called after the last byte of an entry whose bytes were requested.
    var onEntryEnd: () throws -> Void = {}

    private(set) var finished = false
    private(set) var entries = 0
    private let maxEntries: Int
    private var header = [UInt8]()
    private var bodyRemaining = 0
    private var paddingRemaining = 0
    private var wantsBody = false
    private var inEntry = false
    private var collecting: [UInt8]?
    private var collectingKind: UInt8 = 0
    private var pendingName: Data?
    private var zeroBlocks = 0

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
        header.reserveCapacity(512)
    }

    mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        var offset = 0
        while offset < bytes.count, !finished {
            if bodyRemaining > 0 {
                let take = min(bodyRemaining, bytes.count - offset)
                let part = UnsafeBufferPointer(rebasing: bytes[offset..<(offset + take)])
                if collecting != nil {
                    guard collecting!.count + take <= 65_536 else { throw ArchiveError.tar }
                    collecting!.append(contentsOf: part)
                } else if wantsBody {
                    try onData(part)
                }
                bodyRemaining -= take
                offset += take
                if bodyRemaining == 0 { try endBody() }
                continue
            }
            if paddingRemaining > 0 {
                let take = min(paddingRemaining, bytes.count - offset)
                paddingRemaining -= take
                offset += take
                continue
            }
            let take = min(512 - header.count, bytes.count - offset)
            header.append(contentsOf: bytes[offset..<(offset + take)])
            offset += take
            if header.count == 512 {
                try startEntry()
                header.removeAll(keepingCapacity: true)
            }
        }
    }

    private mutating func endBody() throws {
        if let data = collecting {
            collecting = nil
            if collectingKind == UInt8(ascii: "x") {
                pendingName = TarReader.paxPath(data) ?? pendingName
            } else if collectingKind == UInt8(ascii: "L") {
                pendingName = Data(data.prefix(while: { $0 != 0 }))
            }
        } else if inEntry {
            try onEntryEnd()
        }
        inEntry = false
    }

    private mutating func startEntry() throws {
        if header.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks == 2 { finished = true }
            return
        }
        zeroBlocks = 0
        guard let size = TarReader.number(header[124..<136]),
              let expected = TarReader.number(header[148..<156]) else { throw ArchiveError.tar }
        var sum = 0
        for (index, byte) in header.enumerated() { sum += (148..<156).contains(index) ? 32 : Int(byte) }
        guard sum == expected, size >= 0 else { throw ArchiveError.tar }
        bodyRemaining = size
        paddingRemaining = (512 - size % 512) % 512
        let kind = header[156]
        switch kind {
        case UInt8(ascii: "x"), UInt8(ascii: "L"):
            collecting = []
            collecting!.reserveCapacity(min(size, 65_536))
            collectingKind = kind
            wantsBody = false
        case UInt8(ascii: "g"):
            wantsBody = false
        default:
            entries += 1
            guard entries <= maxEntries else { throw ArchiveError.tooLarge }
            var name = pendingName ?? Data()
            if pendingName == nil {
                let prefix = header[345..<500].prefix(while: { $0 != 0 })
                if !prefix.isEmpty {
                    name.append(contentsOf: prefix)
                    name.append(UInt8(ascii: "/"))
                }
                name.append(contentsOf: header[0..<100].prefix(while: { $0 != 0 }))
            }
            pendingName = nil
            let isFile = kind == UInt8(ascii: "0") || kind == 0
            wantsBody = try onEntry(Entry(name: name, size: size, isFile: isFile)) && isFile
            inEntry = wantsBody
            if size == 0 { try endBody() }
        }
        if size == 0, collecting != nil { try endBody() }
    }

    /// Octal text, or GNU base-256 when the high bit of the first byte is set.
    private static func number(_ field: ArraySlice<UInt8>) -> Int? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value = Int(first & 0x7F)
            for byte in field.dropFirst() {
                guard value < 1 << 40 else { return nil }
                value = value << 8 | Int(byte)
            }
            return value
        }
        var value = 0
        var seen = false
        for byte in field {
            if byte == 0 || byte == 32 {
                if seen { break }
                continue
            }
            guard (48...55).contains(byte), value < 1 << 40 else { return nil }
            value = value << 3 | Int(byte - 48)
            seen = true
        }
        return value
    }

    /// The `path` record of a pax extended header: `<length> path=<value>\n`.
    private static func paxPath(_ data: [UInt8]) -> Data? {
        var offset = 0
        var result: Data?
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32),
                  let length = Int(String(decoding: data[offset..<space], as: UTF8.self)),
                  length > space - offset + 1, offset + length <= data.count else { return result }
            let record = data[(space + 1)..<(offset + length - 1)]
            let key = Array("path=".utf8)
            if record.starts(with: key) { result = Data(record.dropFirst(key.count)) }
            offset += length
        }
        return result
    }
}
