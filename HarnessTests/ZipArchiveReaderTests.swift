import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ZipArchiveReaderTests: XCTestCase {
    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    /// Minimal pure-Swift ZIP builder for deterministic Linux + iOS unit tests.
    private struct ZipSpec {
        let name: String
        let rawPayload: Data
        let uncompressedSize: UInt32
        let crc32: UInt32
        let method: UInt16
        let flags: UInt16
        let versionMadeBy: UInt16
        let externalAttr: UInt32

        static func stored(_ name: String, data: Data, versionMadeBy: UInt16 = 0x031E, externalAttr: UInt32 = 0o100644 << 16, flags: UInt16 = 0) -> ZipSpec {
            ZipSpec(
                name: name,
                rawPayload: data,
                uncompressedSize: UInt32(data.count),
                crc32: ZipArchiveReaderTests.crc32(data),
                method: 0,
                flags: flags,
                versionMadeBy: versionMadeBy,
                externalAttr: externalAttr
            )
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var c = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            crc = c ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func buildZip(_ specs: [ZipSpec]) -> Data {
        var out = Data()
        var central = Data()
        func append16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        }
        func append32(_ d: inout Data, _ v: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) { d.append(UInt8((v >> shift) & 0xFF)) }
        }
        for spec in specs {
            let localOffset = UInt32(out.count)
            let nameBytes = Data(spec.name.utf8)
            append32(&out, 0x0403_4b50)
            append16(&out, 20)
            append16(&out, spec.flags)
            append16(&out, spec.method)
            append16(&out, 0); append16(&out, 0)
            append32(&out, spec.crc32)
            append32(&out, UInt32(spec.rawPayload.count))
            append32(&out, spec.uncompressedSize)
            append16(&out, UInt16(nameBytes.count))
            append16(&out, 0)
            out.append(nameBytes)
            out.append(spec.rawPayload)

            append32(&central, 0x0201_4b50)
            append16(&central, spec.versionMadeBy)
            append16(&central, 20)
            append16(&central, spec.flags)
            append16(&central, spec.method)
            append16(&central, 0); append16(&central, 0)
            append32(&central, spec.crc32)
            append32(&central, UInt32(spec.rawPayload.count))
            append32(&central, spec.uncompressedSize)
            append16(&central, UInt16(nameBytes.count))
            append16(&central, 0); append16(&central, 0)
            append16(&central, 0); append16(&central, 0)
            append32(&central, spec.externalAttr)
            append32(&central, localOffset)
            central.append(nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        append32(&out, 0x0605_4b50)
        append16(&out, 0); append16(&out, 0)
        append16(&out, UInt16(specs.count))
        append16(&out, UInt16(specs.count))
        append32(&out, UInt32(central.count))
        append32(&out, cdOffset)
        append16(&out, 0)
        return out
    }

    func testReadsStoredAndDeflatedEntriesAndVerifiesCRC() throws {
        // Raw RFC 1951 DEFLATE of "hello coreml world! hello coreml world!"
        // Built using stored DEFLATE block (BFINAL=1, BTYPE=00) + fixed Huffman test payload.
        let plain1 = Data("{\"hello\": 1}\n".utf8)
        let plain2 = Data("keel-mobile-coreml-deflate-test".utf8)
        // Raw DEFLATE stored block (BFINAL=1, BTYPE=00): 0x01, len_lo, len_hi, ~len_lo, ~len_hi, bytes
        var deflateBlock = Data([0x01, UInt8(plain2.count & 0xFF), UInt8((plain2.count >> 8) & 0xFF),
                                 UInt8((~plain2.count) & 0xFF), UInt8(((~plain2.count) >> 8) & 0xFF)])
        deflateBlock.append(plain2)

        let zip = Self.buildZip([
            .stored("pack/vocab.json", data: plain1),
            ZipSpec(
                name: "pack/merges.txt",
                rawPayload: deflateBlock,
                uncompressedSize: UInt32(plain2.count),
                crc32: Self.crc32(plain2),
                method: 8,
                flags: 0,
                versionMadeBy: 0x031E,
                externalAttr: 0o100644 << 16
            ),
        ])
        let url = try tempFile("pack.zip")
        try zip.write(to: url)

        let entries = try ZipArchiveReader.listEntries(at: url)
        XCTAssertEqual(entries.map(\.path), ["pack/vocab.json", "pack/merges.txt"])

        var extracted1 = Data()
        try ZipArchiveReader.extractEntry(entries[0], from: url, maxBytes: 1024) { extracted1.append(contentsOf: $0) }
        XCTAssertEqual(extracted1, plain1)

        var extracted2 = Data()
        try ZipArchiveReader.extractEntry(entries[1], from: url, maxBytes: 1024) { extracted2.append(contentsOf: $0) }
        XCTAssertEqual(extracted2, plain2)
    }

    func testRejectsPathTraversalSymlinksEncryptionAndBadCRC() throws {
        for badPath in ["../escape.bin", "/abs/path.bin", "pack/../../etc/passwd", "pack\\back.bin"] {
            let url = try tempFile("bad-\(UUID().uuidString).zip")
            try Self.buildZip([.stored(badPath, data: Data("x".utf8))]).write(to: url)
            XCTAssertThrowsError(try ZipArchiveReader.listEntries(at: url), badPath) { error in
                guard case ZipArchiveReader.Failure.unsafePath = error else {
                    XCTFail("Expected unsafePath for \(badPath), got \(error)")
                    return
                }
            }
        }

        // Symlink (0o120777 in Unix upper 16 bits)
        let symURL = try tempFile("symlink.zip")
        try Self.buildZip([.stored("pack/link", data: Data("/etc/passwd".utf8), externalAttr: 0o120777 << 16)]).write(to: symURL)
        XCTAssertThrowsError(try ZipArchiveReader.listEntries(at: symURL)) { error in
            guard case ZipArchiveReader.Failure.unsafePath = error else {
                XCTFail("Expected unsafePath for symlink, got \(error)")
                return
            }
        }

        // Encrypted entry
        let encURL = try tempFile("encrypted.zip")
        try Self.buildZip([.stored("pack/file.bin", data: Data("secret".utf8), flags: 0x0001)]).write(to: encURL)
        XCTAssertThrowsError(try ZipArchiveReader.listEntries(at: encURL)) { error in
            guard case ZipArchiveReader.Failure.unsupportedFeature = error else {
                XCTFail("Expected unsupportedFeature for encrypted zip, got \(error)")
                return
            }
        }

        // Bad CRC-32
        let badCRCURL = try tempFile("badcrc.zip")
        let payload = Data("hello world".utf8)
        let badSpec = ZipSpec(
            name: "pack/file.bin",
            rawPayload: payload,
            uncompressedSize: UInt32(payload.count),
            crc32: Self.crc32(payload) ^ 0xFF,
            method: 0,
            flags: 0,
            versionMadeBy: 0x031E,
            externalAttr: 0o100644 << 16
        )
        try Self.buildZip([badSpec]).write(to: badCRCURL)
        let entries = try ZipArchiveReader.listEntries(at: badCRCURL)
        XCTAssertThrowsError(try ZipArchiveReader.extractEntry(entries[0], from: badCRCURL, maxBytes: 1024) { _ in }) { error in
            XCTAssertEqual(error as? ZipArchiveReader.Failure, .checksumMismatch("pack/file.bin"))
        }
    }

    func testEnforcesSizeLimitsAndCancellation() throws {
        let big = Data(repeating: 0x41, count: 4096)
        let url = try tempFile("limit.zip")
        try Self.buildZip([.stored("pack/big.bin", data: big)]).write(to: url)

        XCTAssertThrowsError(try ZipArchiveReader.listEntries(at: url, maxTotalBytes: 2048)) { error in
            guard case ZipArchiveReader.Failure.limitExceeded = error else {
                XCTFail("Expected limitExceeded, got \(error)")
                return
            }
        }

        let entries = try ZipArchiveReader.listEntries(at: url, maxTotalBytes: 8192)
        XCTAssertThrowsError(
            try ZipArchiveReader.extractEntry(entries[0], from: url, maxBytes: 8192, shouldContinue: { false }) { _ in }
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReader.Failure, .cancelled)
        }
    }
}
