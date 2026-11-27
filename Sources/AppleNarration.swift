import AVFoundation
import Foundation
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Reads narration with one of Apple's built-in voices or the user's own
/// Personal Voice: no download, instant, and light enough for any iPhone.
/// Each line is written to a file by `AVSpeechSynthesizer` and then levelled
/// and encoded like Kokoro's (`NarrationAudio.encodeAAC`).
final class AppleNarration: NSObject, NarrationSpeaking, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case silent, timeout
        var errorDescription: String? {
            switch self {
            case .silent: return "The Apple voice produced no sound. Pick another voice."
            case .timeout: return "The Apple voice did not finish speaking. Pick another voice."
            }
        }
    }

    /// A line that has not finished by then counts as failed.
    static let timeout: TimeInterval = 30

    private let identifier: String
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var current: LineRecorder?

    init(identifier: String) {
        self.identifier = identifier
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String, to url: URL) async throws -> TimeInterval {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("apple-line-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice(language: "en-US")
        let recorder = LineRecorder(url: scratch)
        lock.withLock { current = recorder }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.start(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { recorder.finish(Failure.timeout) }
            synthesizer.write(utterance) { buffer in recorder.take(buffer) }
        }
        lock.withLock { current = nil }
        // The recorder has closed its file by now, so it can be read back.
        return try NarrationAudio.encodeAAC(from: scratch, to: url)
    }

    func unload() async {}

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The final empty buffer is the real end. This is a fallback, late
        // enough that trailing buffers are written first.
        let recorder = lock.withLock { current }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { recorder?.finish(nil) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let recorder = lock.withLock { current }
        recorder?.finish(Failure.silent)
    }
}

/// Collects one line's audio buffers into a file and resumes the waiting
/// task exactly once: at the final empty buffer, at the delegate's finish,
/// or at the timeout, whichever comes first. Callbacks arrive on any thread.
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    init(url: URL) { self.url = url }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func take(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { finish(nil); return }
        var failure: Error?
        lock.withLock {
            guard !done else { return }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch {
                failure = error
            }
        }
        if let failure { finish(failure) }
    }

    func finish(_ error: Error?) {
        let (waiting, wrote) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
            guard !done else { return (nil, false) }
            done = true
            file = nil  // closes the file before anyone reads it
            let waiting = continuation
            continuation = nil
            return (waiting, frames > 0)
        }
        guard let waiting else { return }
        if let error { waiting.resume(throwing: error) }
        else if wrote { waiting.resume() }
        else { waiting.resume(throwing: AppleNarration.Failure.silent) }
    }
}

/// Apple's voices for the Videos screen, as the picker offers them.
enum AppleVoices {
    static func offered() -> [NarrationVoiceChoice.AppleVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                NarrationVoiceChoice.AppleVoice(
                    identifier: voice.identifier, name: voice.name, language: voice.language,
                    quality: voice.quality == .premium ? .premium : voice.quality == .enhanced ? .enhanced : .standard,
                    isPersonal: voice.voiceTraits.contains(.isPersonalVoice))
            }
        return NarrationVoiceChoice.offered(all)
    }

    /// Whether iOS should still be asked about the user's Personal Voice.
    static var canAskForPersonalVoice: Bool {
        AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .notDetermined
    }

    static func askForPersonalVoice() async {
        _ = await withCheckedContinuation { (done: CheckedContinuation<AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus, Never>) in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { done.resume(returning: $0) }
        }
    }
}
