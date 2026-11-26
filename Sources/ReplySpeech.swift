import SwiftUI
import AVFoundation
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Speaks assistant replies on the device with `AVSpeechSynthesizer` without
/// loading a second model weight file or sending audio off the phone.
@MainActor
final class ReplySpeech: ObservableObject {
    typealias Finish = () -> Void
    @Published private(set) var speakingMessageID: UUID?
    @Published private(set) var spokenText = ""
    private var generation = UUID()
    private let begin: (String, @escaping Finish) -> () -> Void
    private var end: (() -> Void)?

    init(begin: ((String, @escaping Finish) -> () -> Void)? = nil) {
        if let begin {
            self.begin = begin
        } else {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--chat-appearance-fixture") {
                self.begin = { _, _ in return {} }
                return
            }
            #endif
            self.begin = { text, finish in
                let output = SystemSpeechOutput()
                output.start(text: text, finish: finish)
                return { output.stop() }
            }
        }
    }

    func toggle(messageID: UUID, text: String) {
        if speakingMessageID == messageID {
            stop()
        } else {
            speak(messageID: messageID, text: text)
        }
    }

    func speak(messageID: UUID, text: String) {
        stop()
        let spoken = SpeechText.spoken(from: text)
        guard !spoken.isEmpty else { return }
        let token = UUID()
        generation = token
        speakingMessageID = messageID
        spokenText = spoken
        let stopCurrent = begin(spoken) { [weak self] in
            guard let self, self.generation == token else { return }
            self.stop()
        }
        guard generation == token else { stopCurrent(); return }
        end = stopCurrent
    }

    @discardableResult
    func sceneDidChange(_ phase: ScenePhase) -> Bool {
        guard phase != .active, speakingMessageID != nil else { return false }
        stop()
        return true
    }

    func stop() {
        generation = UUID()
        speakingMessageID = nil
        spokenText = ""
        let stopCurrent = end
        end = nil
        stopCurrent?()
    }
}

@MainActor
final class SystemSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finish: ReplySpeech.Finish?
    private var sessionOwned = false
    private var oldCategory: AVAudioSession.Category?
    private var oldMode: AVAudioSession.Mode?
    private var oldOptions: AVAudioSession.CategoryOptions = []
    private var interruption: NSObjectProtocol?

    static func makeUtterance(_ text: String, locale: Locale = .current) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: String(text.prefix(SpeechText.maxCharacters)))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: locale.identifier) {
            utterance.voice = voice
        }
        return utterance
    }

    func start(text: String, finish: @escaping ReplySpeech.Finish) {
        self.finish = finish
        synthesizer.delegate = self
        let session = AVAudioSession.sharedInstance()
        oldCategory = session.category
        oldMode = session.mode
        oldOptions = session.categoryOptions
        if (try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])) != nil {
            sessionOwned = true
            try? session.setActive(true)
        }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.complete() }
        }
        synthesizer.speak(Self.makeUtterance(text))
    }

    func stop() {
        finish = nil
        synthesizer.delegate = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        cleanupSession()
    }

    private func complete() {
        let callback = finish
        finish = nil
        synthesizer.delegate = nil
        cleanupSession()
        callback?()
    }

    private func cleanupSession() {
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
            self.interruption = nil
        }
        if sessionOwned {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let oldCategory, let oldMode {
                try? session.setCategory(oldCategory, mode: oldMode, options: oldOptions)
            }
            sessionOwned = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }
}
