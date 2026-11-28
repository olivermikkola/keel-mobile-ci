import Foundation
#if canImport(Compression)
import Compression
#endif

/// Streaming, file-backed reader for `.zip` archives (stored and DEFLATE entries).
///
/// Designed for large Core ML model bundles on iPhone: reads only the central
/// directory into memory and streams each entry directly from disk in bounded
/// chunks, verifying CRC-32 and rejecting symlinks, encryption, path traversal,
/// and zip bombs before writing anything outside the destination directory.
public enum ZipArchiveReader {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case invalidArchive(String)
        case unsupportedFeature(String)
        case unsafePath(String)
        case limitExceeded(String)
        case checksumMismatch(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidArchive(let detail): return "This zip archive could not be read: \(detail)"
            case .unsupportedFeature(let detail): return "This zip archive uses an unsupported feature: \(detail)"
            case .unsafePath(let path): return "The zip archive contains an unsafe file path (\(path))."
            case .limitExceeded(let detail): return "The zip archive exceeds Keel's safety limits: \(detail)"
            case .checksumMismatch(let path): return "The zip archive is damaged (checksum mismatch for \(path))."
            case .cancelled: return "Import cancelled."
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public let path: String
        public let compressionMethod: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        public let isDirectory: Bool
    }

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EOCDSignature: UInt32 = 0x0606_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let maxCentralDirectoryBytes: UInt64 = 16 * 1024 * 1024
    private static let chunkBytes = 262_144

    /// Reads and validates the central directory of a `.zip` file without
    /// unpacking any file bodies.
    public static func listEntries(
        at archiveURL: URL,
        maxEntries: Int = 2_000,
        maxTotalBytes: UInt64 = UInt64(ImportedImagePack.maxPackBytes)
    ) throws -> [Entry] {
        let file = try FileHandle(forReadingFrom: archiveURL)
        defer { try? file.close() }

        let fileSize = try file.seekToEnd()
        guard fileSize >= 22 else {
            throw Failure.invalidArchive("file is too small.")
        }

        let tailSize = min(fileSize, 65_557)
        try file.seek(toOffset: fileSize - tailSize)
        let tail = try readExact(from: file, count: Int(tailSize))

        guard let eocdOffsetInTail = findEOCD(in: tail) else {
            throw Failure.invalidArchive("missing end-of-central-directory record.")
        }
        let eocdAbsoluteOffset = (fileSize - tailSize) + UInt64(eocdOffsetInTail)

        let diskNumber = readUInt16(tail, at: eocdOffsetInTail + 4)
        let startDisk = readUInt16(tail, at: eocdOffsetInTail + 6)
        guard diskNumber == 0 && startDisk == 0 else {
            throw Failure.unsupportedFeature("multi-disk zip archives are not supported.")
        }

        var entryCount = UInt64(readUInt16(tail, at: eocdOffsetInTail + 10))
        var centralSize = UInt64(readUInt32(tail, at: eocdOffsetInTail + 12))
        var centralOffset = UInt64(readUInt32(tail, at: eocdOffsetInTail + 16))

        if entryCount == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            guard eocdAbsoluteOffset >= 20 else {
                throw Failure.invalidArchive("missing ZIP64 locator.")
            }
            try file.seek(toOffset: eocdAbsoluteOffset - 20)
            let locator = try readExact(from: file, count: 20)
            guard readUInt32(locator, at: 0) == zip64LocatorSignature else {
                throw Failure.invalidArchive("invalid ZIP64 locator signature.")
            }
            let zip64EOCDOffset = readUInt64(locator, at: 8)
            guard zip64EOCDOffset + 56 <= fileSize else {
                throw Failure.invalidArchive("ZIP64 record out of bounds.")
            }
            try file.seek(toOffset: zip64EOCDOffset)
            let z64 = try readExact(from: file, count: 56)
            guard readUInt32(z64, at: 0) == zip64EOCDSignature else {
                throw Failure.invalidArchive("invalid ZIP64 header signature.")
            }
            entryCount = readUInt64(z64, at: 32)
            centralSize = readUInt64(z64, at: 40)
            centralOffset = readUInt64(z64, at: 48)
        }

        guard entryCount <= UInt64(maxEntries) else {
            throw Failure.limitExceeded("too many entries (\(entryCount) > \(maxEntries)).")
        }
        guard centralSize <= maxCentralDirectoryBytes else {
            throw Failure.limitExceeded("central directory is too large.")
        }
        guard centralOffset <= fileSize, centralSize <= fileSize - centralOffset else {
            throw Failure.invalidArchive("central directory lies outside the file.")
        }

        try file.seek(toOffset: centralOffset)
        let directory = try readExact(from: file, count: Int(centralSize))

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var cursor = 0
        var declaredTotalBytes: UInt64 = 0

        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count else {
                throw Failure.invalidArchive("truncated central directory entry.")
            }
            guard readUInt32(directory, at: cursor) == centralHeaderSignature else {
                throw Failure.invalidArchive("corrupt central directory signature.")
            }
            let versionMadeBy = readUInt16(directory, at: cursor + 4)
            let flags = readUInt16(directory, at: cursor + 8)
            let method = readUInt16(directory, at: cursor + 10)
            let crc32 = readUInt32(directory, at: cursor + 16)
            var compressed = UInt64(readUInt32(directory, at: cursor + 20))
            var uncompressed = UInt64(readUInt32(directory, at: cursor + 24))
            let nameLen = Int(readUInt16(directory, at: cursor + 28))
            let extraLen = Int(readUInt16(directory, at: cursor + 30))
            let commentLen = Int(readUInt16(directory, at: cursor + 32))
            let externalAttr = readUInt32(directory, at: cursor + 38)
            var localOffset = UInt64(readUInt32(directory, at: cursor + 42))

            let headerEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard headerEnd <= directory.count else {
                throw Failure.invalidArchive("central directory entry overflows buffer.")
            }

            guard (flags & 0x0001) == 0 else {
                throw Failure.unsupportedFeature("encrypted zip archives are not supported.")
            }
            guard method == 0 || method == 8 else {
                throw Failure.unsupportedFeature("compression method \(method) is not supported (use stored or deflate).")
            }

            // Reject symbolic links (Unix mode 0o120000 in upper 16 bits of external attributes).
            let hostOS = versionMadeBy >> 8
            if hostOS == 3 || hostOS == 19 {
                let fileType = (externalAttr >> 16) & 0o170000
                if fileType == 0o120000 {
                    throw Failure.unsafePath("symbolic link")
                }
            }

            let nameStart = cursor + 46
            let nameSlice = directory[nameStart..<(nameStart + nameLen)]
            guard let rawPath = String(data: nameSlice, encoding: .utf8), !rawPath.isEmpty else {
                throw Failure.invalidArchive("non-UTF8 or empty entry path.")
            }
            let extraStart = nameStart + nameLen
            let extraSlice = directory[extraStart..<(extraStart + extraLen)]
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                try parseZip64Extra(
                    extraSlice,
                    uncompressed: &uncompressed,
                    compressed: &compressed,
                    localOffset: &localOffset
                )
            }

            let isDirectory = rawPath.hasSuffix("/")
            let normalized = try sanitizePath(rawPath, allowTrailingSlash: isDirectory)

            if !isDirectory {
                let (sum, overflow) = declaredTotalBytes.addingReportingOverflow(uncompressed)
                guard !overflow, sum <= maxTotalBytes else {
                    throw Failure.limitExceeded("uncompressed size exceeds \(maxTotalBytes) bytes.")
                }
                declaredTotalBytes = sum
            }

            entries.append(Entry(
                path: normalized,
                compressionMethod: method,
                crc32: crc32,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                isDirectory: isDirectory
            ))
            cursor = headerEnd
        }

        return entries
    }

    /// Streams one entry's uncompressed bytes into `sink`, verifying exact byte
    /// count and CRC-32 while respecting `maxBytes` and `shouldContinue`.
    public static func extractEntry(
        _ entry: Entry,
        from archiveURL: URL,
        maxBytes: UInt64,
        shouldContinue: () -> Bool = { true },
        sink: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        guard !entry.isDirectory else { return }
        guard entry.uncompressedSize <= maxBytes else {
            throw Failure.limitExceeded("entry \(entry.path) exceeds \(maxBytes) bytes.")
        }

        let file = try FileHandle(forReadingFrom: archiveURL)
        defer { try? file.close() }
        let fileSize = try file.seekToEnd()

        guard entry.localHeaderOffset + 30 <= fileSize else {
            throw Failure.invalidArchive("local header offset out of bounds for \(entry.path).")
        }
        try file.seek(toOffset: entry.localHeaderOffset)
        let local = try readExact(from: file, count: 30)
        guard readUInt32(local, at: 0) == localHeaderSignature else {
            throw Failure.invalidArchive("bad local header signature for \(entry.path).")
        }
        let localNameLen = UInt64(readUInt16(local, at: 26))
        let localExtraLen = UInt64(readUInt16(local, at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + localNameLen + localExtraLen
        guard dataOffset <= fileSize, entry.compressedSize <= fileSize - dataOffset else {
            throw Failure.invalidArchive("compressed payload out of bounds for \(entry.path).")
        }
        try file.seek(toOffset: dataOffset)

        var crc = CRC32()
        var emitted: UInt64 = 0
        func checkedSink(_ buffer: UnsafeBufferPointer<UInt8>) throws {
            guard shouldContinue() else { throw Failure.cancelled }
            let count = UInt64(buffer.count)
            let (next, overflow) = emitted.addingReportingOverflow(count)
            guard !overflow, next <= entry.uncompressedSize, next <= maxBytes else {
                throw Failure.limitExceeded("decompressed stream exceeded declared size for \(entry.path).")
            }
            emitted = next
            crc.update(buffer)
            try sink(buffer)
        }

        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw Failure.invalidArchive("stored entry size mismatch for \(entry.path).")
            }
            var remaining = entry.compressedSize
            while remaining > 0 {
                guard shouldContinue() else { throw Failure.cancelled }
                let toRead = Int(min(remaining, UInt64(chunkBytes)))
                let chunk = try readExact(from: file, count: toRead)
                try chunk.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    try checkedSink(bytes)
                }
                remaining -= UInt64(toRead)
            }

        case 8:
            try inflateStream(
                from: file,
                compressedBytes: entry.compressedSize,
                expectedOutputBytes: entry.uncompressedSize,
                shouldContinue: shouldContinue,
                sink: checkedSink
            )

        default:
            throw Failure.unsupportedFeature("compression method \(entry.compressionMethod).")
        }

        guard emitted == entry.uncompressedSize else {
            throw Failure.invalidArchive("truncated payload for \(entry.path) (expected \(entry.uncompressedSize), got \(emitted)).")
        }
        guard crc.value == entry.crc32 else {
            throw Failure.checksumMismatch(entry.path)
        }
    }

    // MARK: - DEFLATE streaming

    private static func inflateStream(
        from file: FileHandle,
        compressedBytes: UInt64,
        expectedOutputBytes: UInt64,
        shouldContinue: () -> Bool,
        sink: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
        #if canImport(Compression)
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw Failure.invalidArchive("could not initialize DEFLATE decoder.")
        }
        defer { compression_stream_destroy(&stream) }

        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
        defer { dstBuffer.deallocate() }

        var remaining = compressedBytes
        var status = COMPRESSION_STATUS_OK

        while status != COMPRESSION_STATUS_END {
            guard shouldContinue() else { throw Failure.cancelled }
            let inputChunk: Data
            if remaining > 0 {
                let toRead = Int(min(remaining, UInt64(chunkBytes)))
                inputChunk = try readExact(from: file, count: toRead)
                remaining -= UInt64(toRead)
            } else {
                inputChunk = Data()
            }
            let flags: Int32 = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            try inputChunk.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = inputChunk.count

                while true {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = chunkBytes
                    status = compression_stream_process(&stream, flags)
                    let produced = chunkBytes - stream.dst_size
                    if produced > 0 {
                        try sink(UnsafeBufferPointer(start: dstBuffer, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        break
                    }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw Failure.invalidArchive("corrupt DEFLATE stream.")
                    }
                    if stream.src_size == 0 && stream.dst_size > 0 {
                        if flags != 0 && produced == 0 {
                            throw Failure.invalidArchive("incomplete DEFLATE stream.")
                        }
                        break
                    }
                }
            }
        }
        #else
        guard compressedBytes <= UInt64(Int.max), expectedOutputBytes <= UInt64(Int.max) else {
            throw Failure.limitExceeded("entry too large for non-Apple DEFLATE decoder.")
        }
        let compressed = try readExact(from: file, count: Int(compressedBytes))
        do {
            try RawDeflate.inflate(compressed, limit: Int(expectedOutputBytes), sink: sink)
        } catch ArchiveError.tooLarge {
            throw Failure.limitExceeded("decompressed stream exceeded declared size.")
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalidArchive("corrupt DEFLATE stream.")
        }
        #endif
    }

    // MARK: - Helpers

    static func sanitizePath(_ raw: String, allowTrailingSlash: Bool) throws -> String {
        guard raw.utf8.count <= 512 else { throw Failure.unsafePath(String(raw.prefix(64))) }
        guard !raw.hasPrefix("/"), !raw.contains("\\") else { throw Failure.unsafePath(raw) }
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw Failure.unsafePath(raw)
        }
        let trimmed = allowTrailingSlash && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if trimmed.isEmpty { throw Failure.unsafePath(raw) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else {
                throw Failure.unsafePath(raw)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func findEOCD(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if readUInt32(tail, at: offset) == eocdSignature {
                let commentLength = Int(readUInt16(tail, at: offset + 20))
                if offset + 22 + commentLength == tail.count {
                    return offset
                }
            }
        }
        return nil
    }

    private static func parseZip64Extra(
        _ slice: Data,
        uncompressed: inout UInt64,
        compressed: inout UInt64,
        localOffset: inout UInt64
    ) throws {
        var index = slice.startIndex
        while index + 4 <= slice.endIndex {
            let headerID = readUInt16(slice, at: index)
            let dataSize = Int(readUInt16(slice, at: index + 2))
            let fieldStart = index + 4
            let fieldEnd = fieldStart + dataSize
            guard fieldEnd <= slice.endIndex else {
                throw Failure.invalidArchive("truncated extra field.")
            }
            if headerID == 0x0001 {
                var pos = fieldStart
                if uncompressed == 0xFFFF_FFFF {
                    guard pos + 8 <= fieldEnd else { throw Failure.invalidArchive("truncated ZIP64 uncompressed size.") }
                    uncompressed = readUInt64(slice, at: pos); pos += 8
                }
                if compressed == 0xFFFF_FFFF {
                    guard pos + 8 <= fieldEnd else { throw Failure.invalidArchive("truncated ZIP64 compressed size.") }
                    compressed = readUInt64(slice, at: pos); pos += 8
                }
                if localOffset == 0xFFFF_FFFF {
                    guard pos + 8 <= fieldEnd else { throw Failure.invalidArchive("truncated ZIP64 local offset.") }
                    localOffset = readUInt64(slice, at: pos)
                }
                return
            }
            index = fieldEnd
        }
        throw Failure.invalidArchive("missing ZIP64 extra field.")
    }

    private static func readExact(from file: FileHandle, count: Int) throws -> Data {
        if count == 0 { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = try file.read(upToCount: count - out.count), !chunk.isEmpty else {
                throw Failure.invalidArchive("unexpected end of file.")
            }
            out.append(chunk)
        }
        return out
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(data, at: offset)) | (UInt64(readUInt32(data, at: offset + 4)) << 32)
    }

    /// Standard IEEE 802.3 CRC-32 used by ZIP.
    private struct CRC32 {
        private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }

        private var crc: UInt32 = 0xFFFF_FFFF

        mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
            for byte in bytes {
                crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }

        var value: UInt32 { crc ^ 0xFFFF_FFFF }
    }
}
