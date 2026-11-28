import CryptoKit
import XCTest
@testable import KeelMobile

/// End-to-end tests for importing, syncing, persisting, and removing custom
/// Kokoro-82M voices (`.bin`, `.json`, `.npy`, and stubbed Hugging Face links)
/// through `NarrationVoiceStore`.
@MainActor
final class ImportedKokoroVoiceStoreTests: XCTestCase {
    private func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore(kokoroDir: URL, customDir: URL, stubbed: Bool = false) -> NarrationVoiceStore {
        NarrationVoiceStore(
            directory: kokoroDir,
            customVoicesDirectory: customDir,
            transferConfiguration: {
                let cfg = URLSessionConfiguration.ephemeral
                if stubbed { cfg.protocolClasses = [StubProtocol.self] }
                return cfg
            }
        )
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.responseHeaders = nil
        super.tearDown()
    }

    private func settle(_ store: NarrationVoiceStore) async throws {
        for _ in 0..<500 where store.isImportingVoice {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isImportingVoice)
    }

    private func sampleBinary() -> Data {
        var data = Data(capacity: ImportedKokoroVoice.binaryByteCount)
        for i in 0..<ImportedKokoroVoice.elementCount {
            let value = Float(i % 64) * 0.01 - 0.3
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func sampleNumPy(_ binary: Data) -> Data {
        let dict = "{'descr': '<f4', 'fortran_order': False, 'shape': (510, 1, 256), }"
        var header = Data(dict.utf8)
        while (10 + header.count + 1) % 16 != 0 { header.append(0x20) }
        header.append(0x0A)
        var out = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0])
        out.append(UInt8(header.count & 0xFF))
        out.append(UInt8((header.count >> 8) & 0xFF))
        out.append(header)
        out.append(binary)
        return out
    }

    func testLocalBinaryAndNumPyImportSyncsToFluidAudioCachesPersistsAndRemoves() async throws {
        let kokoroDir = tempDir("kokoro")
        let customDir = tempDir("custom-voices")
        let srcDir = tempDir("src-voices")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let binary = sampleBinary()
        let expectedSHA = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let npyURL = srcDir.appendingPathComponent("bf_emma.npy")
        try sampleNumPy(binary).write(to: npyURL)

        let store = makeStore(kokoroDir: kokoroDir, customDir: customDir)
        store.importVoice(from: npyURL)
        try await settle(store)

        XCTAssertNil(store.error)
        let record = try XCTUnwrap(store.customVoices.first)
        XCTAssertEqual(record.name, "Emma")
        XCTAssertTrue(record.id.hasPrefix("bf_custom_"), record.id)
        XCTAssertEqual(record.sourceFormat, "npy")
        XCTAssertEqual(record.sha256, expectedSHA)
        XCTAssertEqual(try Data(contentsOf: customDir.appendingPathComponent(record.fileName)), binary)

        // Synced into BOTH legacy and ANE-v3 FluidAudio cache paths!
        let legacyFile = kokoroDir.appendingPathComponent("kokoro-82m-coreml/ANE/\(record.fileName)")
        let v3File = kokoroDir.appendingPathComponent("kokoro-82m-coreml/ANE-v3/\(ImportedKokoroVoice.fluidAudioV3Revision)/en/\(record.fileName)")
        XCTAssertEqual(try Data(contentsOf: legacyFile), binary)
        XCTAssertEqual(try Data(contentsOf: v3File), binary)

        // Available voice IDs include built-in + imported voice.
        let available = NarrationVoiceStore.availableVoiceIDs(in: customDir)
        XCTAssertTrue(available.contains(record.id))
        XCTAssertTrue(available.contains(NarrationVoicePack.defaultVoice))

        // Removing Kokoro cache keeps master copy; sync restores it.
        store.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: customDir.appendingPathComponent(record.fileName).path))
        NarrationVoiceStore.syncCustomVoices(from: customDir, into: kokoroDir)
        XCTAssertEqual(try Data(contentsOf: legacyFile), binary)
        XCTAssertEqual(try Data(contentsOf: v3File), binary)

        // Relaunch finds it; removing custom voice deletes master and synced copies.
        let relaunched = makeStore(kokoroDir: kokoroDir, customDir: customDir)
        XCTAssertEqual(relaunched.customVoices, [record])
        relaunched.removeCustomVoice(record.id)
        XCTAssertTrue(relaunched.customVoices.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: customDir.appendingPathComponent(record.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3File.path))
    }

    func testHuggingFaceVoiceLinkDownloadsNormalizesAndRejectsBrokenFiles() async throws {
        let kokoroDir = tempDir("kokoro-hf")
        let customDir = tempDir("custom-hf")
        let binary = sampleBinary()

        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "huggingface.co")
            if request.url?.path.hasSuffix("/am_onyx.bin") == true {
                return (200, binary)
            }
            if request.url?.path.hasSuffix("/broken.bin") == true {
                return (200, Data(count: 128))
            }
            return (404, Data())
        }

        let store = makeStore(kokoroDir: kokoroDir, customDir: customDir, stubbed: true)
        store.importVoice(link: "https://huggingface.co/FluidInference/kokoro-82m-coreml/blob/main/voices/am_onyx.bin")
        try await settle(store)

        XCTAssertNil(store.error)
        let record = try XCTUnwrap(store.customVoices.first)
        XCTAssertEqual(record.name, "Onyx")
        XCTAssertTrue(record.id.hasPrefix("am_custom_"))
        XCTAssertEqual(record.sourceLabel, "FluidInference/kokoro-82m-coreml")

        // Corrupt file fails closed and leaves count unchanged.
        store.importVoice(link: "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/main/voices/broken.bin")
        try await settle(store)
        XCTAssertTrue(store.error?.contains("522240") == true, store.error ?? "expected size error")
        XCTAssertEqual(store.customVoices.count, 1)

        // 404 fails cleanly.
        store.importVoice(link: "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/main/voices/missing.bin")
        try await settle(store)
        XCTAssertTrue(store.error?.contains("no file") == true, store.error ?? "expected 404 error")
        XCTAssertEqual(store.customVoices.count, 1)
    }
}
