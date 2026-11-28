import AVFoundation
import XCTest
@testable import KeelMobile

/// An Apple voice speaks a line into a levelled AAC file, like Kokoro's.
final class AppleNarrationTests: XCTestCase {
    func testAnAppleVoiceSpeaksALineIntoAFile() async throws {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        guard let voice = english.first else { throw XCTSkip("This simulator has no English voice") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apple-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("line.m4a")
        let engine = AppleNarration(identifier: voice.identifier)
        let began = Date()
        let seconds = try await engine.speak("Keel makes this video on your phone.", voice: "apple:\(voice.identifier)", to: output)
        let took = Date().timeIntervalSince(began)
        XCTAssertGreaterThan(seconds, 0.5, "a sentence takes time to say")
        XCTAssertLessThan(seconds, 10)

        let file = try AVAudioFile(forReading: output)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
        XCTAssertGreaterThan(peak, 0.05, "speech, not silence")
        print(String(format: "Apple voice proof: %@ (%@) spoke a %.2f s line in %.2f s, peak %.2f",
                     voice.name, voice.identifier, seconds, took, peak))
    }

    func testVoiceIdsPickTheirEngine() {
        XCTAssertTrue(VideoMaker.engine(for: "apple:com.apple.voice.compact.en-US.Samantha") is AppleNarration)
        if !NarrationVoiceStore.isInstalled {
            XCTAssertNil(VideoMaker.engine(for: "af_heart"), "Kokoro needs its download")
        }
    }
}
