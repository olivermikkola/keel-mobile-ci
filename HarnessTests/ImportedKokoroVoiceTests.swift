import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ImportedKokoroVoiceTests: XCTestCase {
    private func sampleFloats() -> [Float] {
        (0..<ImportedKokoroVoice.elementCount).map { Float($0 % 97) * 0.01 - 0.5 }
    }

    private func littleEndianBinary(_ floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 4)
        for value in floats {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func buildNumPy(descr: String, shape: String, fortranOrder: Bool = false, payload: Data) -> Data {
        let dict = "{'descr': '\(descr)', 'fortran_order': \(fortranOrder ? "True" : "False"), 'shape': \(shape), }"
        var header = Data(dict.utf8)
        while (10 + header.count + 1) % 16 != 0 { header.append(0x20) }
        header.append(0x0A)
        var out = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0])
        out.append(UInt8(header.count & 0xFF))
        out.append(UInt8((header.count >> 8) & 0xFF))
        out.append(header)
        out.append(payload)
        return out
    }

    func testValidatesFlatBinaryAndRejectsWrongSizeOrNaN() throws {
        let floats = sampleFloats()
        let bin = littleEndianBinary(floats)
        XCTAssertEqual(bin.count, 522_240)
        let normalized = try KokoroVoiceCodec.normalize(bin, fileExtension: "bin")
        XCTAssertEqual(normalized.format, .bin)
        XCTAssertEqual(normalized.binary, bin)

        XCTAssertThrowsError(try KokoroVoiceCodec.normalize(Data(count: 100), fileExtension: "bin")) { error in
            XCTAssertEqual(error as? KokoroVoiceCodec.Problem, .invalidBinarySize(100))
        }

        var broken = floats
        broken[42] = .nan
        XCTAssertThrowsError(try KokoroVoiceCodec.normalize(littleEndianBinary(broken), fileExtension: "bin")) { error in
            XCTAssertEqual(error as? KokoroVoiceCodec.Problem, .nonFiniteValues)
        }
    }

    func testParsesNumberedAndNestedJSONVoiceFiles() throws {
        let floats = sampleFloats()
        let expected = littleEndianBinary(floats)

        // Format A: FluidAudio / kokoro-82m-coreml numbered dictionary ("1"..."510")
        var numbered: [String: [Float]] = [:]
        for row in 0..<ImportedKokoroVoice.rows {
            let start = row * ImportedKokoroVoice.cols
            numbered[String(row + 1)] = Array(floats[start..<(start + ImportedKokoroVoice.cols)])
        }
        let numberedJSON = try JSONSerialization.data(withJSONObject: numbered)
        let fromNumbered = try KokoroVoiceCodec.normalize(numberedJSON, fileExtension: "json")
        XCTAssertEqual(fromNumbered.format, .json)
        XCTAssertEqual(fromNumbered.binary, expected)

        // Format B: 3D nested array [510][1][256]
        let nested3D: [[[Float]]] = (0..<ImportedKokoroVoice.rows).map { row in
            let start = row * ImportedKokoroVoice.cols
            return [Array(floats[start..<(start + ImportedKokoroVoice.cols)])]
        }
        let nestedJSON = try JSONSerialization.data(withJSONObject: nested3D)
        let fromNested = try KokoroVoiceCodec.normalize(nestedJSON, fileExtension: "json")
        XCTAssertEqual(fromNested.binary, expected)

        // Truncated dictionary fails closed.
        numbered.removeValue(forKey: "510")
        let incompleteJSON = try JSONSerialization.data(withJSONObject: numbered)
        XCTAssertThrowsError(try KokoroVoiceCodec.normalize(incompleteJSON, fileExtension: "json")) { error in
            guard case KokoroVoiceCodec.Problem.invalidJSON = error else {
                XCTFail("Expected invalidJSON, got \(error)")
                return
            }
        }
    }

    func testParsesNumPyFloat32Float16AndBigEndianShapes() throws {
        let floats = sampleFloats()
        let expected = littleEndianBinary(floats)

        // <f4 with shape (510, 1, 256)
        let npy3D = buildNumPy(descr: "<f4", shape: "(510, 1, 256)", payload: expected)
        let parsed3D = try KokoroVoiceCodec.normalize(npy3D, fileExtension: "npy")
        XCTAssertEqual(parsed3D.format, .npy)
        XCTAssertEqual(parsed3D.binary, expected)

        // >f4 big-endian with shape (510, 256)
        var bigEndian = Data(capacity: expected.count)
        for f in floats {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { bigEndian.append(contentsOf: $0) }
        }
        let npyBE = buildNumPy(descr: ">f4", shape: "(510, 256)", payload: bigEndian)
        XCTAssertEqual(try KokoroVoiceCodec.normalize(npyBE, fileExtension: "npy").binary, expected)

        // <f2 float16 (0x3C00 = 1.0, 0xC000 = -2.0, 0x0000 = 0.0)
        var f16Payload = Data(capacity: ImportedKokoroVoice.elementCount * 2)
        for i in 0..<ImportedKokoroVoice.elementCount {
            let bits: UInt16 = i % 3 == 0 ? 0x3C00 : (i % 3 == 1 ? 0xC000 : 0x0000)
            var le = bits.littleEndian
            withUnsafeBytes(of: &le) { f16Payload.append(contentsOf: $0) }
        }
        let npy16 = buildNumPy(descr: "<f2", shape: "(510, 256)", payload: f16Payload)
        let parsed16 = try KokoroVoiceCodec.normalize(npy16, fileExtension: "npy").binary
        XCTAssertEqual(parsed16.count, ImportedKokoroVoice.binaryByteCount)
        XCTAssertEqual(KokoroVoiceCodec.float16ToFloat32(0x3C00), 1.0)
        XCTAssertEqual(KokoroVoiceCodec.float16ToFloat32(0xC000), -2.0)
        XCTAssertEqual(KokoroVoiceCodec.float16ToFloat32(0x0000), 0.0)
        XCTAssertTrue(KokoroVoiceCodec.float16ToFloat32(0x7C00).isInfinite)

        // Reject wrong shape and Fortran order
        let badShape = buildNumPy(descr: "<f4", shape: "(100, 256)", payload: Data(count: 100 * 256 * 4))
        XCTAssertThrowsError(try KokoroVoiceCodec.normalize(badShape, fileExtension: "npy"))
        let fortran = buildNumPy(descr: "<f4", shape: "(510, 256)", fortranOrder: true, payload: expected)
        XCTAssertThrowsError(try KokoroVoiceCodec.normalize(fortran, fileExtension: "npy"))
    }

    func testVoiceIDsNamesValidationAndToolCompatibility() throws {
        let british = ImportedKokoroVoice.newID(hint: "bf_emma.json", suffix: "deadbeef")
        XCTAssertEqual(british, "bf_custom_deadbeef")
        XCTAssertNoThrow(try ShortVideoRequest.parseVoice(british))

        let defaultPrefix = ImportedKokoroVoice.newID(hint: "Warm_Narrator.npy", suffix: "1234abcd")
        XCTAssertEqual(defaultPrefix, "af_custom_1234abcd")
        XCTAssertNoThrow(try ShortVideoRequest.parseVoice(defaultPrefix))

        XCTAssertEqual(ImportedKokoroVoice.cleanName("bf_emma.json"), "Emma")
        XCTAssertEqual(ImportedKokoroVoice.cleanName("am_onyx.bin"), "Onyx")
        XCTAssertEqual(ImportedKokoroVoice.cleanName("My_Custom_Voice.npy"), "My Custom Voice")

        let valid = ImportedKokoroVoice(
            id: british,
            name: "bf_emma.json",
            sha256: String(repeating: "b", count: 64),
            sourceFormat: "json",
            sourceLabel: "FluidInference/kokoro-82m-coreml"
        )
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.name, "Emma")
        XCTAssertEqual(valid.pickerLabel, "Emma · British English · custom")

        let tampered = ImportedKokoroVoice(
            id: "../evil",
            name: "Evil",
            sha256: String(repeating: "b", count: 64),
            sourceFormat: "bin",
            sourceLabel: "Files"
        )
        XCTAssertFalse(tampered.isValid)
        let encoded = try JSONEncoder().encode([valid, tampered, valid])
        XCTAssertEqual(ImportedKokoroVoice.load(encoded), [valid])

        // Draft label uses custom voice name.
        XCTAssertEqual(
            NarrationVoiceChoice.draftLabel(id: valid.id, appleVoices: [], customVoices: [valid]),
            "Kokoro · Emma"
        )
    }

    func testHuggingFaceKokoroVoiceLinkValidation() throws {
        let blob = try HuggingFaceKokoroVoiceLink.parse(
            "https://huggingface.co/FluidInference/kokoro-82m-coreml/blob/main/voices/bf_emma.json?download=true"
        )
        XCTAssertEqual(blob.repository, "FluidInference/kokoro-82m-coreml")
        XCTAssertEqual(blob.fileName, "bf_emma.json")
        XCTAssertEqual(blob.fileExtension, "json")
        XCTAssertEqual(
            blob.resolveURL.absoluteString,
            "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/main/voices/bf_emma.json"
        )

        let npy = try HuggingFaceKokoroVoiceLink.parse(
            "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/af_sky.npy"
        )
        XCTAssertEqual(npy.fileExtension, "npy")

        for bad in [
            "http://huggingface.co/a/b/resolve/main/v.bin",
            "https://example.test/a/b/resolve/main/v.bin",
            "https://user:pass@huggingface.co/a/b/resolve/main/v.bin",
            "https://huggingface.co/a/b/resolve/main/v.bin?token=abc",
            "https://huggingface.co/a/b/resolve/main/v.pt",
            "https://huggingface.co/a/b/resolve/main/../v.bin",
        ] {
            XCTAssertThrowsError(try HuggingFaceKokoroVoiceLink.parse(bad), bad)
        }
    }
}
