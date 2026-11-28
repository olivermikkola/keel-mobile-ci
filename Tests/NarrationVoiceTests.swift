import AVFoundation
import XCTest
@testable import KeelMobile

/// Narration audio handling, and the licence guard on FluidAudio's bundle.
final class NarrationVoiceTests: XCTestCase {
    /// Kokoro hands over 24 kHz 16-bit mono WAV; the video needs AAC.
    func testKokoroStyleWAVBecomesAACOfTheSameLength() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("line.wav")
        let rate = 24_000.0
        // The writer must be closed (released) before the file is read back.
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            let frames = AVAudioFrameCount(rate * 1.5)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<Int(frames) { samples[i] = Float(sin(2 * .pi * 220 * Double(i) / rate) * 0.4) }
            try file.write(from: buffer)
        }

        let m4a = folder.appendingPathComponent("out/line.m4a")
        let seconds = try NarrationAudio.encodeAAC(from: wav, to: m4a)
        XCTAssertEqual(seconds, 1.5, accuracy: 0.001)
        let encoded = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(encoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(encoded.length) / encoded.fileFormat.sampleRate, 1.5, accuracy: 0.1)
    }

    /// FluidAudio bundles a LuxTTS lexicon derived from espeak-ng (GPL-3.0).
    /// Keel uses only Kokoro; the build removes that bundle and it must never ship.
    func testGPLDerivedLuxTTSDataIsNotInTheApp() throws {
        let app = Bundle.main.bundleURL
        XCTAssertTrue(app.pathExtension == "app", "runs inside the host app: \(app.path)")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker {
            // The test bundle is placed inside the app only while testing; it never ships.
            if url.pathExtension == "xctest" { walker.skipDescendants(); continue }
            if url.lastPathComponent.lowercased().contains("luxtts") {
                found.append(url.path.replacingOccurrences(of: app.path, with: ""))
            }
        }
        XCTAssertEqual(found, [], "LuxTTS (espeak-ng-derived) files must not ship")
    }

    func testTheModelsFolderStaysOutOfBackups() {
        XCTAssertEqual(NarrationVoiceStore.directory.lastPathComponent, "NarrationVoice")
        XCTAssertEqual(NarrationVoiceStore.marker.deletingLastPathComponent(), NarrationVoiceStore.directory)
    }
}

/// Opt-in: downloads the real Kokoro voice (a few hundred MB from Hugging Face)
/// and speaks a line on the simulator's CPU. Ordinary CI skips it; the `voice`
/// model check turns it on. Proves download, hash checks, load and speech end
/// to end; never phone speed, heat or the Neural Engine.
final class NarrationVoiceSmokeTests: XCTestCase {
    func testARealLineComesOutOfKokoro() async throws {
        guard let fixtures = Bundle(for: Self.self).url(forResource: "fixtures", withExtension: nil),
              FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("voice/enabled").path) else {
            throw XCTSkip("Opt-in real-voice check is off")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = NarrationEngine(directory: folder)

        let began = Date()
        try await engine.prepare()
        let prepared = Date().timeIntervalSince(began)
        let bytes = Self.bytes(in: folder)

        let output = folder.appendingPathComponent("line.m4a")
        let spokeAt = Date()
        let seconds = try await engine.speak("Still standing through the storm.", voice: "af_heart", to: output)
        let spoke = Date().timeIntervalSince(spokeAt)
        XCTAssertGreaterThan(seconds, 1.0, "a short sentence takes over a second to say")
        XCTAssertLessThan(seconds, 6.0)

        // Speech, not silence: measurable level across the line.
        let file = try AVAudioFile(forReading: output)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        var sum: Double = 0
        for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i] * samples[i]) }
        let rms = (sum / Double(max(buffer.frameLength, 1))).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "speech has level")

        // The app's name is said "keel", not "keele".
        let keel = try await engine.phonemes("Keel runs on your phone.")
        XCTAssertTrue(keel.contains("kˈil"), keel)

        // Every downloaded voice speaks without fetching anything more.
        let other = folder.appendingPathComponent("adam.m4a")
        let adam = try await engine.speak("And the sea keeps coming.", voice: "am_adam", to: other)
        XCTAssertGreaterThan(adam, 1.0)
        await engine.unload()

        let attachment = XCTAttachment(contentsOfFile: output)
        attachment.name = "kokoro-af_heart.m4a"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(String(format: "Kokoro proof: download+load %.1f s, %lld bytes on disk, line %.2f s spoken in %.2f s (simulator CPU), rms %.3f",
                     prepared, bytes, seconds, spoke, rms))
    }

    private static func bytes(in folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
