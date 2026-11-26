import AVFoundation
import Foundation
import FluidAudio
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Speaks narration lines with Kokoro-82M on the phone (FluidAudio's Core ML
/// pipeline). The models live in `NarrationVoiceStore.directory`; once they are
/// there, speaking needs no network. One line in, one AAC `.m4a` out, ready for
/// `ShortVideoRenderer`.
actor NarrationEngine {
    private var manager: KokoroAneManager?
    private let directory: URL

    init(directory: URL = NarrationVoiceStore.directory) {
        self.directory = directory
    }

    /// Downloads anything missing (first time only), checks it against
    /// FluidAudio's pinned hashes, compiles and loads it.
    func prepare() async throws {
        guard manager == nil else { return }
        let made: KokoroAneManager
        #if targetEnvironment(simulator)
        // No Neural Engine or GPU compute in the simulator: the older pipeline on the CPU.
        made = KokoroAneManager(directory: directory, computeUnits: .cpuOnly, version: .legacy)
        #else
        if #available(iOS 18, *) {
            made = KokoroAneManager(directory: directory, version: .v3)
        } else {
            made = KokoroAneManager(directory: directory, version: .legacy)
        }
        #endif
        try await made.initialize(preloadVoices: NarrationVoicePack.voiceIDs)
        manager = made
    }

    /// Speaks `text` in `voice` into an AAC file at `url` and returns its length in seconds.
    func speak(_ text: String, voice: String, to url: URL) async throws -> TimeInterval {
        try await prepare()
        guard let manager else { throw ShortVideoRequest.Problem.engineUnavailable(voice) }
        let wav = try await manager.synthesize(text: text, voice: voice)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("line-\(UUID().uuidString).wav")
        try wav.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try NarrationAudio.encodeAAC(from: scratch, to: url)
    }

    /// Frees the models' memory; the files stay.
    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// Audio file conversion for narration.
enum NarrationAudio {
    /// Re-encodes any audio file AVFoundation reads (Kokoro's 24 kHz WAV) as
    /// mono AAC in an `.m4a`, which the video exporter can pass straight
    /// through. Returns the length in seconds.
    static func encodeAAC(from source: URL, to destination: URL) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let chunk: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ShortVideoRequest.Problem.engineUnavailable("audio buffer")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(input.length - input.framePosition)))
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return Double(input.length) / format.sampleRate
    }
}

/// Download state of the narration voice, for the Models screen.
@MainActor
final class NarrationVoiceStore: ObservableObject {
    /// Where FluidAudio keeps the Kokoro models and voices for Keel.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NarrationVoice", isDirectory: true)
    }

    /// Written only after the pack has downloaded, loaded and spoken a test line.
    nonisolated static var marker: URL { directory.appendingPathComponent("ready.json") }

    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Nil when this phone can narrate; otherwise why not.
    nonisolated static var unsupportedReason: String? {
        NarrationVoicePack.fits(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            ? nil : ShortVideoRequest.Problem.memory.localizedDescription
    }

    @Published private(set) var installed = NarrationVoiceStore.isInstalled
    @Published private(set) var progress: Double?
    @Published var error: String?
    private var work: Task<Void, Never>?

    var downloading: Bool { work != nil }

    /// Bytes the pack uses on this phone.
    nonisolated static func bytesOnDisk() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func download() {
        guard work == nil, !installed else { return }
        error = nil
        progress = NarrationVoicePack.progress(bytesOnDisk: Self.bytesOnDisk())
        work = Task { [weak self] in
            let watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.progress = NarrationVoicePack.progress(bytesOnDisk: Self.bytesOnDisk())
                }
            }
            defer {
                watcher.cancel()
                self?.work = nil
                self?.progress = nil
                self?.installed = Self.isInstalled
            }
            do {
                try await Self.install()
            } catch is CancellationError {
            } catch {
                self?.error = "The narration voice could not be set up: \(error.localizedDescription)"
            }
        }
    }

    /// Downloads, loads and test-speaks the pack, then marks it ready.
    nonisolated static func install() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available > NarrationVoicePack.approximateBytes + 256_000_000 else { throw LocalModelError.storage }
        let engine = NarrationEngine()
        let check = FileManager.default.temporaryDirectory.appendingPathComponent("voice-check-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: check) }
        let seconds = try await engine.speak("Ready.", voice: NarrationVoicePack.defaultVoice, to: check)
        await engine.unload()
        guard seconds > 0.1 else { throw ShortVideoRequest.Problem.engineUnavailable(NarrationVoicePack.defaultVoice) }
        let note = ["fluidAudio": NarrationVoicePack.fluidAudioVersion, "bytes": String(bytesOnDisk())]
        try JSONSerialization.data(withJSONObject: note).write(to: marker, options: .atomic)
    }

    func cancel() { work?.cancel() }

    func remove() {
        guard work == nil else { return }
        try? FileManager.default.removeItem(at: Self.directory)
        installed = Self.isInstalled
    }
}
