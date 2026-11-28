import SwiftUI
import Speech
import AVFoundation

/// Session state is separate from microphone access so cancellation and stale callbacks are testable.
@MainActor
final class OfflineDictation: ObservableObject {
    typealias Update = (String?, Bool, String?) -> Void
    @Published private(set) var text = ""
    @Published private(set) var recording = false
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private let begin: (@escaping Update) async throws -> () -> Void
    private var end: (() -> Void)?

    init(begin: ((@escaping Update) async throws -> () -> Void)? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        // UI tests: words arrive without a microphone or a permission alert.
        if begin == nil, ProcessInfo.processInfo.arguments.contains("--chat-appearance-fixture") {
            self.begin = { update in
                Task { @MainActor in update("Hello from dictation", false, nil) }
                return {}
            }
            return
        }
        #endif
        self.begin = begin ?? { update in
            let capture = SpeechCapture()
            try await capture.start(update: update)
            return { capture.stop() }
        }
    }

    var active: Bool { recording || preparing }

    /// The message box while dictating: what was typed before, then the words so far.
    nonisolated static func merged(base: String, spoken: String) -> String {
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        return base + (base.last?.isWhitespace == true ? "" : " ") + spoken
    }

    func start() async {
        guard !preparing, !recording else { return }
        let token = UUID(); generation = token
        preparing = true; error = nil; text = ""
        do {
            let stop = try await begin { [weak self] text, final, error in
                guard let self, self.generation == token else { return }
                if let text { self.text = String(text.prefix(16_384)) }
                if let error { self.error = error }
                if final || error != nil { self.stop() }
            }
            guard generation == token else { stop(); return }
            end = stop; preparing = false; recording = true
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.stop()
            }
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription; preparing = false
        }
    }

    @discardableResult
    func sceneDidChange(_ phase: ScenePhase) -> Bool {
        // System permission alerts make the scene inactive while preparing.
        // Keep that permission flow alive; backgrounding always cancels it.
        guard phase == .background || (phase == .inactive && recording) else { return false }
        stop()
        return true
    }

    func stop() {
        generation = UUID(); preparing = false; recording = false
        deadline?.cancel(); deadline = nil
        end?(); end = nil
    }
}

enum DictationError: LocalizedError {
    case unavailable, permission
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Offline dictation is unavailable for your current language on this device. Check the downloaded dictation languages in Settings."
        case .permission: return "Allow Microphone and Speech Recognition for Keel in Settings to dictate."
        }
    }
}

@MainActor
final class SpeechCapture {
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var tapped = false
    private var sessionOwned = false
    private var oldCategory: AVAudioSession.Category?
    private var oldMode: AVAudioSession.Mode?
    private var oldOptions: AVAudioSession.CategoryOptions = []
    private var interruption: NSObjectProtocol?

    static func offlineRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return request
    }

    func start(update: @escaping OfflineDictation.Update) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { throw DictationError.unavailable }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw DictationError.permission }
        try Task.checkCancellation()
        let microphone = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        guard microphone else { throw DictationError.permission }
        try Task.checkCancellation()
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw DictationError.unavailable }
        let request = Self.offlineRequest()
        self.request = request; self.recognizer = recognizer
        let session = AVAudioSession.sharedInstance()
        oldCategory = session.category; oldMode = session.mode; oldOptions = session.categoryOptions
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            sessionOwned = true
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.unavailable }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            task = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let message = error?.localizedDescription
                Task { @MainActor in update(text, final, message) }
            }
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                   object: nil, queue: .main) { _ in
                Task { @MainActor in update(nil, true, "Dictation was interrupted. Your text is kept.") }
            }
            engine.prepare(); try engine.start()
        } catch { stop(); throw error }
    }

    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption); self.interruption = nil }
        if sessionOwned {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let oldCategory, let oldMode { try? session.setCategory(oldCategory, mode: oldMode, options: oldOptions) }
            sessionOwned = false
        }
    }
}
