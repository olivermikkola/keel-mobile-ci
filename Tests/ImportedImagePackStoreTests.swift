import CryptoKit
import XCTest
@testable import KeelMobile

/// End-to-end tests for importing, selecting, toggling, and removing BYO Core ML
/// Stable Diffusion packs through `ImageModelStore` (local folders, `.zip`
/// archives, and stubbed Hugging Face repositories). Synthetic Core ML files;
/// no diffusion model is executed here.
@MainActor
final class ImportedImagePackStoreTests: XCTestCase {
    private func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore(modelsDir: URL, defaults: UserDefaults, stubbed: Bool = false) -> ImageModelStore {
        ImageModelStore(
            modelsDirectory: modelsDir,
            defaults: defaults,
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

    private func settle(_ store: ImageModelStore) async throws {
        for _ in 0..<500 where store.downloading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.downloading)
    }

    /// Creates a minimal synthetic compiled Core ML Stable Diffusion folder.
    private func syntheticPackFiles(openCLIP: Bool = false, sdxl: Bool = false, chunked: Bool = false) -> [String: Data] {
        let textMeta = openCLIP
            ? "{\"outputs\": [{\"shape\": \"[1, 77, 1024]\"}]}"
            : "{\"outputs\": [{\"shape\": \"[1, 77, 768]\"}]}"
        let unetMeta = sdxl
            ? "{\"inputs\": [\"sample\", \"timestep\", \"encoder_hidden_states\", \"time_ids\"]}"
            : "{\"inputs\": [\"sample\", \"timestep\", \"encoder_hidden_states\"]}"
        var files: [String: Data] = [
            "TextEncoder.mlmodelc/coremldata.bin": Data("text-coreml".utf8),
            "TextEncoder.mlmodelc/metadata.json": Data(textMeta.utf8),
            "TextEncoder.mlmodelc/weights/weight.bin": Data(repeating: 1, count: 4096),
            "VAEDecoder.mlmodelc/coremldata.bin": Data("vae-coreml".utf8),
            "VAEDecoder.mlmodelc/weights/weight.bin": Data(repeating: 2, count: 2048),
            "vocab.json": Data("{\"<|startoftext|>\": 49406, \"<|endoftext|>\": 49407}".utf8),
            "merges.txt": Data("#version: 0.2\na b\nc d\n".utf8),
        ]
        if chunked {
            files["UnetChunk1.mlmodelc/coremldata.bin"] = Data("chunk1-coreml".utf8)
            files["UnetChunk1.mlmodelc/metadata.json"] = Data(unetMeta.utf8)
            files["UnetChunk1.mlmodelc/weights/weight.bin"] = Data(repeating: 3, count: 4096)
            files["UnetChunk2.mlmodelc/coremldata.bin"] = Data("chunk2-coreml".utf8)
            files["UnetChunk2.mlmodelc/weights/weight.bin"] = Data(repeating: 4, count: 4096)
        } else {
            files["Unet.mlmodelc/coremldata.bin"] = Data("unet-coreml".utf8)
            files["Unet.mlmodelc/metadata.json"] = Data(unetMeta.utf8)
            files["Unet.mlmodelc/weights/weight.bin"] = Data(repeating: 3, count: 8192)
        }
        return files
    }

    private func writeFolder(_ files: [String: Data], at root: URL) throws {
        for (rel, data) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func buildStoredZip(_ files: [String: Data]) -> Data {
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                var c = (crc ^ UInt32(byte)) & 0xFF
                for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
                crc = c ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }
        func a16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func a32(_ d: inout Data, _ v: UInt32) {
            for s in stride(from: 0, through: 24, by: 8) { d.append(UInt8((v >> s) & 0xFF)) }
        }
        var out = Data(), central = Data()
        let ordered = files.sorted { $0.key < $1.key }
        for (name, data) in ordered {
            let offset = UInt32(out.count), crc = crc32(data), nb = Data(name.utf8)
            a32(&out, 0x0403_4b50); a16(&out, 20); a16(&out, 0); a16(&out, 0); a16(&out, 0); a16(&out, 0)
            a32(&out, crc); a32(&out, UInt32(data.count)); a32(&out, UInt32(data.count))
            a16(&out, UInt16(nb.count)); a16(&out, 0); out.append(nb); out.append(data)

            a32(&central, 0x0201_4b50); a16(&central, 0x031E); a16(&central, 20); a16(&central, 0); a16(&central, 0)
            a16(&central, 0); a16(&central, 0); a32(&central, crc); a32(&central, UInt32(data.count)); a32(&central, UInt32(data.count))
            a16(&central, UInt16(nb.count)); a16(&central, 0); a16(&central, 0); a16(&central, 0); a16(&central, 0)
            a32(&central, 0o100644 << 16); a32(&central, offset); central.append(nb)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        a32(&out, 0x0605_4b50); a16(&out, 0); a16(&out, 0)
        a16(&out, UInt16(ordered.count)); a16(&out, UInt16(ordered.count))
        a32(&out, UInt32(central.count)); a32(&out, cdOffset); a16(&out, 0)
        return out
    }

    func testLocalFolderImportSelectsToggleEnginePersistsAndRemoves() async throws {
        let modelsDir = tempDir("models")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let source = tempDir("src").appendingPathComponent("My-DreamShaper-LCM", isDirectory: true)
        var files = syntheticPackFiles(openCLIP: false, chunked: true)
        files["SafetyChecker.mlmodelc/coremldata.bin"] = Data("unused".utf8)
        try writeFolder(files, at: source)

        let store = makeStore(modelsDir: modelsDir, defaults: defaults)
        store.importPack(from: source)
        try await settle(store)

        XCTAssertNil(store.error)
        XCTAssertTrue(store.installed)
        let record = try XCTUnwrap(store.importedPacks.first)
        XCTAssertEqual(record.name, "My-DreamShaper-LCM")
        XCTAssertEqual(record.engine, .lcm)
        XCTAssertEqual(record.padToken, "<|endoftext|>")
        XCTAssertTrue(record.chunkedUnet)
        XCTAssertEqual(store.activePack?.id, record.id)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: record.directory(in: modelsDir).appendingPathComponent("SafetyChecker.mlmodelc").path),
            "Unused SafetyChecker bundle must not be copied"
        )

        // Switching engine persists across relaunch.
        store.setImportedEngine(record.id, engine: .standard)
        XCTAssertEqual(store.activePack?.engine, .standard)
        XCTAssertEqual(store.activePack?.defaultSteps, 20)

        let relaunched = makeStore(modelsDir: modelsDir, defaults: defaults)
        XCTAssertEqual(relaunched.importedPacks.first?.engine, .standard)
        XCTAssertEqual(relaunched.activePack?.id, record.id)

        // Removing deletes files and clears active pack.
        relaunched.removeImported(record.id)
        XCTAssertTrue(relaunched.importedPacks.isEmpty)
        XCTAssertFalse(relaunched.installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.directory(in: modelsDir).path))
    }

    func testZipArchiveImportExtractsSD21AndRejectsSDXL() async throws {
        let modelsDir = tempDir("models-zip")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))

        // Valid SD 2.1 zip nested under split_einsum_v2/compiled
        let sd21Files = Dictionary(uniqueKeysWithValues: syntheticPackFiles(openCLIP: true).map {
            ("split_einsum_v2/compiled/\($0.key)", $0.value)
        })
        let zipURL = tempDir("zips").appendingPathComponent("SD21-Anime.zip")
        try FileManager.default.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try buildStoredZip(sd21Files).write(to: zipURL)

        let store = makeStore(modelsDir: modelsDir, defaults: defaults)
        store.importPack(from: zipURL)
        try await settle(store)
        XCTAssertNil(store.error)
        let imported = try XCTUnwrap(store.importedPacks.first)
        XCTAssertEqual(imported.name, "SD21-Anime")
        XCTAssertEqual(imported.padToken, "!")
        XCTAssertEqual(imported.engine, .standard)

        // SDXL zip must be rejected cleanly and leave no staging folder.
        let sdxlZip = tempDir("zips-sdxl").appendingPathComponent("SDXL-Turbo.zip")
        try FileManager.default.createDirectory(at: sdxlZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try buildStoredZip(syntheticPackFiles(sdxl: true)).write(to: sdxlZip)
        store.importPack(from: sdxlZip)
        try await settle(store)
        XCTAssertTrue(store.error?.contains("SDXL") == true, store.error ?? "expected SDXL error")
        XCTAssertEqual(store.importedPacks.count, 1)
    }

    func testHuggingFaceLinkImportInspectsDownloadsVerifiesAndSelects() async throws {
        let modelsDir = tempDir("models-hf")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let packFiles = syntheticPackFiles(openCLIP: false)
        let prefixed = Dictionary(uniqueKeysWithValues: packFiles.map { ("split_einsum_v2/compiled/\($0.key)", $0.value) })

        let treePayload: [[String: Any]] = prefixed.map { path, data in
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return [
                "type": "file",
                "path": path,
                "size": data.count,
                "lfs": ["oid": sha, "size": data.count],
            ]
        }
        let treeJSON = try JSONSerialization.data(withJSONObject: treePayload)

        StubProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "huggingface.co")
            if url.path.hasPrefix("/api/models/") {
                return (200, treeJSON)
            }
            let prefix = "/acme/coreml-demo-lcm/resolve/main/"
            if url.path.hasPrefix(prefix) {
                let rel = String(url.path.dropFirst(prefix.count))
                if let body = prefixed[rel] {
                    return (200, body)
                }
            }
            return (404, Data())
        }

        let store = makeStore(modelsDir: modelsDir, defaults: defaults, stubbed: true)
        store.importPack(link: "https://huggingface.co/acme/coreml-demo-lcm")
        try await settle(store)

        XCTAssertNil(store.error)
        let record = try XCTUnwrap(store.importedPacks.first)
        XCTAssertEqual(record.name, "coreml-demo-lcm")
        XCTAssertEqual(record.engine, .lcm)
        XCTAssertEqual(record.sourceLabel, "acme/coreml-demo-lcm")
        XCTAssertEqual(store.activePack?.id, record.id)
    }
}
