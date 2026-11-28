import AVFoundation
import CryptoKit
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
    private let customVoicesDirectory: URL

    init(directory: URL = NarrationVoiceStore.directory,
         customVoicesDirectory: URL = NarrationVoiceStore.customVoicesDirectory) {
        self.directory = directory
        self.customVoicesDirectory = customVoicesDirectory
    }

    /// Downloads anything missing (first time only), checks it against
    /// FluidAudio's pinned hashes, compiles and loads it.
    func prepare() async throws {
        guard manager == nil else { return }
        NarrationVoiceStore.syncCustomVoices(from: customVoicesDirectory, into: directory)
        let made: KokoroAneManager
        #if targetEnvironment(simulator)
        // No Neural Engine or GPU compute in the simulator: the older pipeline on the CPU.
        made = KokoroAneManager(directory: directory, computeUnits: .cpuOnly, version: .legacy)
        #else
        if NarrationVoicePack.pipeline(machineIdentifier: HardwareProfile.currentMachineIdentifier()) == .legacyCPU {
            // Older Neural Engines cannot hold v3 (see `NarrationVoicePack.pipeline`).
            made = KokoroAneManager(directory: directory, computeUnits: .cpuOnly, version: .legacy)
        } else if #available(iOS 18, *) {
            made = KokoroAneManager(directory: directory, version: .v3)
        } else {
            made = KokoroAneManager(directory: directory, version: .legacy)
        }
        #endif
        try await made.initialize(preloadVoices: NarrationVoicePack.voiceIDs)
        // Re-sync after initial setup so any newly created v3/legacy cache dirs hold custom voices.
        NarrationVoiceStore.syncCustomVoices(from: customVoicesDirectory, into: directory)
        await made.setEnglishCustomLexicon(NarrationVoicePack.pronunciations)
        manager = made
    }

    /// Speaks `text` in `voice` into an AAC file at `url` and returns its length in seconds.
    func speak(_ text: String, voice: String, to url: URL) async throws -> TimeInterval {
        try await prepare()
        guard let manager else { throw ShortVideoRequest.Problem.engineUnavailable(voice) }
        let result = try await manager.synthesizeDetailed(text: text, voice: voice)
        // The padding frames carry the burst heard before every line on the
        // phone's Neural Engine ("That's", "Test"); they are never speech.
        var samples = result.samples
        NarrationLevels.mute(&samples, NarrationLevels.paddingRanges(
            inputIds: result.inputIds, durations: result.predictedDurations, sampleCount: samples.count))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("line-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try NarrationAudio.writeFloat(samples, sampleRate: Double(result.sampleRate), to: scratch)
        return try NarrationAudio.encodeAAC(from: scratch, to: url)
    }

    /// How Kokoro will pronounce `text`, as phonemes (for checks).
    func phonemes(_ text: String) async throws -> String {
        try await prepare()
        guard let manager else { throw ShortVideoRequest.Problem.engineUnavailable("narration") }
        return try await manager.englishPhonemes(for: text)
    }

    /// Frees the models' memory; the files stay.
    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// Audio file conversion for narration.
enum NarrationAudio {
    /// Mono 32-bit float samples to an uncompressed file `encodeAAC` reads.
    static func writeFloat(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let channel = buffer.floatChannelData?[0] else {
            throw ShortVideoRequest.Problem.engineUnavailable("audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard !samples.isEmpty else { throw ShortVideoRequest.Problem.engineUnavailable("empty narration") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        // Closed when `file` goes out of scope, before anyone reads it.
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

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
        // One spoken line is a few seconds: read it whole, cut the silence at
        // its ends and even out its loudness (`NarrationLevels`).
        let total = AVAudioFrameCount(input.length)
        guard total > 0, let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            throw ShortVideoRequest.Problem.engineUnavailable("audio buffer")
        }
        try input.read(into: whole, frameCount: total)
        guard let channels = whole.floatChannelData, format.commonFormat == .pcmFormatFloat32 else {
            try output.write(from: whole)
            return Double(whole.frameLength) / format.sampleRate
        }
        let count = Int(whole.frameLength)
        let plan = NarrationLevels.plan(samples: Array(UnsafeBufferPointer(start: channels[0], count: count)), sampleRate: format.sampleRate)
        let kept = AVAudioFrameCount(plan.end - plan.start)
        guard kept > 0, let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: kept), let into = trimmed.floatChannelData else {
            throw ShortVideoRequest.Problem.engineUnavailable("audio buffer")
        }
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<Int(kept) {
                into[channel][index] = max(-1, min(1, channels[channel][plan.start + index] * plan.gain))
            }
        }
        trimmed.frameLength = kept
        try output.write(from: trimmed)
        return Double(kept) / format.sampleRate
    }
}

/// Download state of the narration voice and user-imported custom Kokoro voices.
@MainActor
final class NarrationVoiceStore: ObservableObject {
    /// Where FluidAudio keeps the Kokoro models and voices for Keel.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NarrationVoice", isDirectory: true)
    }

    /// Canonical storage for user-imported custom Kokoro voices, kept separate
    /// from the Kokoro download cache so progress measurement stays exact and
    /// re-downloading Kokoro preserves custom voices.
    nonisolated static var customVoicesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomKokoroVoices", isDirectory: true)
    }

    /// Written only after the pack has downloaded, loaded and spoken a test line.
    nonisolated static var marker: URL { directory.appendingPathComponent("ready.json") }

    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Nil when this phone can narrate; otherwise why not.
    nonisolated static var unsupportedReason: String? {
        NarrationVoicePack.fits(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            ? nil : ShortVideoRequest.Problem.memory.localizedDescription
    }

    @Published private(set) var installed = false
    @Published private(set) var progress: Double?
    @Published private(set) var customVoices: [ImportedKokoroVoice] = []
    @Published private(set) var importingVoice: String?
    @Published var error: String?

    private let storeDirectory: URL
    private let customDir: URL
    private let transferConfiguration: () -> URLSessionConfiguration
    private var work: Task<Void, Never>?
    private var importWork: Task<Void, Never>?

    var downloading: Bool { work != nil }
    var isImportingVoice: Bool { importWork != nil }

    init(directory: URL = NarrationVoiceStore.directory,
         customVoicesDirectory: URL = NarrationVoiceStore.customVoicesDirectory,
         transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.storeDirectory = directory
        self.customDir = customVoicesDirectory
        self.transferConfiguration = transferConfiguration
        installed = FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready.json").path)
        refreshCustomVoices()
    }

    nonisolated static func customManifestURL(in customDir: URL = customVoicesDirectory) -> URL {
        customDir.appendingPathComponent("voices.json")
    }

    nonisolated static func loadCustomVoices(in customDir: URL = customVoicesDirectory) -> [ImportedKokoroVoice] {
        guard let data = try? Data(contentsOf: customManifestURL(in: customDir)) else { return [] }
        return ImportedKokoroVoice.load(data).filter {
            FileManager.default.fileExists(atPath: customDir.appendingPathComponent($0.fileName).path)
        }
    }

    nonisolated static func availableVoiceIDs(in customDir: URL = customVoicesDirectory) -> Set<String> {
        NarrationVoicePack.voiceIDs.union(loadCustomVoices(in: customDir).map(\.id))
    }

    /// Directories inside FluidAudio's Kokoro cache where `<voice>.bin` files are resolved.
    nonisolated static func fluidAudioVoiceDirectories(in kokoroRoot: URL) -> [URL] {
        var dirs: [URL] = [
            kokoroRoot.appendingPathComponent("kokoro-82m-coreml/ANE", isDirectory: true),
            kokoroRoot.appendingPathComponent("kokoro-82m-coreml/ANE-v3/\(ImportedKokoroVoice.fluidAudioV3Revision)/en", isDirectory: true),
        ]
        // Also mirror into any other ANE-v3/<rev>/en folder present on disk.
        let v3Root = kokoroRoot.appendingPathComponent("kokoro-82m-coreml/ANE-v3", isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(at: v3Root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children {
                let candidate = child.appendingPathComponent("en", isDirectory: true)
                if !dirs.contains(candidate) { dirs.append(candidate) }
            }
        }
        return dirs
    }

    /// Ensures every valid custom voice `.bin` is present in FluidAudio's local
    /// cache directories so speaking needs no network.
    nonisolated static func syncCustomVoices(from customDir: URL = customVoicesDirectory, into kokoroRoot: URL = directory) {
        let voices = loadCustomVoices(in: customDir)
        guard !voices.isEmpty else { return }
        let targets = fluidAudioVoiceDirectories(in: kokoroRoot)
        for target in targets {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for voice in voices {
                let source = customDir.appendingPathComponent(voice.fileName)
                let destination = target.appendingPathComponent(voice.fileName)
                let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                if existingSize == ImportedKokoroVoice.binaryByteCount { continue }
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    func refreshCustomVoices() {
        customVoices = Self.loadCustomVoices(in: customDir)
    }

    /// Bytes the pack uses on this phone.
    nonisolated static func bytesOnDisk(in directory: URL = NarrationVoiceStore.directory) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// `freeMemory` runs first: setting up loads Kokoro and speaks a test line
    /// (about 676 MB at peak), which must not sit on top of the chat model.
    func download(freeMemory: @escaping @MainActor () async -> Void = {}) {
        guard work == nil, !installed else { return }
        error = nil
        let targetDir = storeDirectory
        let targetCustomDir = customDir
        progress = NarrationVoicePack.progress(bytesOnDisk: Self.bytesOnDisk(in: targetDir))
        work = Task { [weak self] in
            let watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.progress = NarrationVoicePack.progress(bytesOnDisk: Self.bytesOnDisk(in: targetDir))
                }
            }
            defer {
                watcher.cancel()
                self?.work = nil
                self?.progress = nil
                self?.installed = FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("ready.json").path)
            }
            do {
                await freeMemory()
                try Task.checkCancellation()
                try await Self.install(in: targetDir, customDir: targetCustomDir)
            } catch is CancellationError {
            } catch {
                self?.error = "The narration voice could not be set up: \(error.localizedDescription)"
            }
        }
    }

    /// Downloads, loads and test-speaks the pack, then marks it ready.
    nonisolated static func install(
        in directory: URL = NarrationVoiceStore.directory,
        customDir: URL = NarrationVoiceStore.customVoicesDirectory
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available > NarrationVoicePack.approximateBytes + 256_000_000 else { throw LocalModelError.storage }
        let engine = NarrationEngine(directory: directory, customVoicesDirectory: customDir)
        let check = FileManager.default.temporaryDirectory.appendingPathComponent("voice-check-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: check) }
        let seconds = try await engine.speak("Ready.", voice: NarrationVoicePack.defaultVoice, to: check)
        await engine.unload()
        guard seconds > 0.1 else { throw ShortVideoRequest.Problem.engineUnavailable(NarrationVoicePack.defaultVoice) }
        let note = ["fluidAudio": NarrationVoicePack.fluidAudioVersion, "bytes": String(bytesOnDisk(in: directory))]
        try JSONSerialization.data(withJSONObject: note).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
    }

    /// Imports a custom Kokoro voice file (`.bin`, `.json`, or `.npy`) from Files.
    func importVoice(from source: URL) {
        guard importWork == nil else { return }
        guard customVoices.count < ImportedKokoroVoice.limit else {
            error = "You have \(ImportedKokoroVoice.limit) custom Kokoro voices. Remove one before importing another."
            return
        }
        error = nil
        importingVoice = "Checking voice file…"
        let destCustomDir = customDir
        let kokoroRoot = storeDirectory
        importWork = Task {
            defer {
                importWork = nil
                importingVoice = nil
                refreshCustomVoices()
            }
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try Self.importLocalVoice(from: source, customDir: destCustomDir, kokoroRoot: kokoroRoot)
                }.value
                try Task.checkCancellation()
                customVoices.append(record)
                do {
                    try saveCustomVoices()
                } catch {
                    customVoices.removeLast()
                    Self.deleteVoiceFiles(fileName: record.fileName, customDir: destCustomDir, kokoroRoot: kokoroRoot)
                    throw error
                }
            } catch is CancellationError {
            } catch {
                self.error = Self.userMessage(for: error, fallback: "The voice file could not be imported. Choose a Kokoro .bin, .json or .npy file.")
            }
        }
    }

    /// Downloads and imports a custom Kokoro voice (`.bin`, `.json`, or `.npy`)
    /// from a public Hugging Face link.
    func importVoice(link text: String) {
        guard importWork == nil else { return }
        guard customVoices.count < ImportedKokoroVoice.limit else {
            error = "You have \(ImportedKokoroVoice.limit) custom Kokoro voices. Remove one before importing another."
            return
        }
        let link: HuggingFaceKokoroVoiceLink
        do { link = try HuggingFaceKokoroVoiceLink.parse(text) } catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        importingVoice = "Downloading \(ImportedKokoroVoice.cleanName(link.fileName))…"
        let destCustomDir = customDir
        let kokoroRoot = storeDirectory
        let configuration = transferConfiguration
        importWork = Task {
            defer {
                importWork = nil
                importingVoice = nil
                refreshCustomVoices()
            }
            do {
                let data = try await Self.fetchBoundedVoice(from: link.resolveURL, configuration: configuration())
                try Task.checkCancellation()
                importingVoice = "Validating voice embedding…"
                let record = try await Task.detached(priority: .userInitiated) {
                    try Self.storeNormalizedVoice(
                        rawData: data,
                        fileName: link.fileName,
                        fileExtension: link.fileExtension,
                        sourceLabel: link.repository,
                        customDir: destCustomDir,
                        kokoroRoot: kokoroRoot
                    )
                }.value
                try Task.checkCancellation()
                customVoices.append(record)
                do {
                    try saveCustomVoices()
                } catch {
                    customVoices.removeLast()
                    Self.deleteVoiceFiles(fileName: record.fileName, customDir: destCustomDir, kokoroRoot: kokoroRoot)
                    throw error
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = Self.userMessage(for: error, fallback: "The voice file could not be downloaded. Check your connection and link, then try again.")
            }
        }
    }

    func cancelVoiceImport() {
        importWork?.cancel()
    }

    func removeCustomVoice(_ id: String) {
        guard importWork == nil, let idx = customVoices.firstIndex(where: { $0.id == id }) else { return }
        let removed = customVoices.remove(at: idx)
        do {
            try saveCustomVoices()
        } catch {
            customVoices.insert(removed, at: idx)
            self.error = "Could not remove this custom voice. Try again."
            return
        }
        Self.deleteVoiceFiles(fileName: removed.fileName, customDir: customDir, kokoroRoot: storeDirectory)
        refreshCustomVoices()
    }

    func cancel() { work?.cancel() }

    func remove() {
        guard work == nil else { return }
        try? FileManager.default.removeItem(at: storeDirectory)
        installed = FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("ready.json").path)
    }

    // MARK: - Private helpers

    private func saveCustomVoices() throws {
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        var folder = customDir
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let data = try JSONEncoder().encode(customVoices)
        try data.write(to: Self.customManifestURL(in: customDir), options: [.atomic, .completeFileProtection])
    }

    nonisolated private static func importLocalVoice(
        from source: URL,
        customDir: URL,
        kokoroRoot: URL
    ) throws -> ImportedKokoroVoice {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw KokoroVoiceCodec.Problem.unsupportedFormat(source.pathExtension)
        }
        let size = values.fileSize ?? 0
        guard size > 0 else {
            throw KokoroVoiceCodec.Problem.invalidBinarySize(0)
        }
        guard size <= ImportedKokoroVoice.maxInputBytes else {
            throw KokoroVoiceCodec.Problem.fileTooLarge
        }
        let rawData = try Data(contentsOf: source)
        return try storeNormalizedVoice(
            rawData: rawData,
            fileName: source.lastPathComponent,
            fileExtension: source.pathExtension,
            sourceLabel: "Files",
            customDir: customDir,
            kokoroRoot: kokoroRoot
        )
    }

    nonisolated private static func storeNormalizedVoice(
        rawData: Data,
        fileName: String,
        fileExtension: String,
        sourceLabel: String,
        customDir: URL,
        kokoroRoot: URL
    ) throws -> ImportedKokoroVoice {
        try Task.checkCancellation()
        let (binary, format) = try KokoroVoiceCodec.normalize(rawData, fileExtension: fileExtension)
        let sha256 = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let id = ImportedKokoroVoice.newID(hint: fileName)
        let record = ImportedKokoroVoice(
            id: id,
            name: fileName,
            sha256: sha256,
            sourceFormat: format.rawValue,
            sourceLabel: sourceLabel
        )
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        var folder = customDir
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let masterURL = customDir.appendingPathComponent(record.fileName)
        try binary.write(to: masterURL, options: [.atomic, .completeFileProtection])

        // Sync straight into FluidAudio's voice cache folders.
        for target in fluidAudioVoiceDirectories(in: kokoroRoot) {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let dest = target.appendingPathComponent(record.fileName)
            try? binary.write(to: dest, options: [.atomic, .completeFileProtection])
        }
        return record
    }

    nonisolated private static func deleteVoiceFiles(fileName: String, customDir: URL, kokoroRoot: URL) {
        try? FileManager.default.removeItem(at: customDir.appendingPathComponent(fileName))
        for target in fluidAudioVoiceDirectories(in: kokoroRoot) {
            try? FileManager.default.removeItem(at: target.appendingPathComponent(fileName))
        }
    }

    nonisolated private static func fetchBoundedVoice(
        from url: URL,
        configuration: URLSessionConfiguration
    ) async throws -> Data {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, timeoutInterval: 60)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HuggingFaceImport.Failure.unreachable(0)
        }
        guard http.statusCode == 200 else {
            throw HuggingFaceImport.Failure.unreachable(http.statusCode)
        }
        if http.expectedContentLength > Int64(ImportedKokoroVoice.maxInputBytes) {
            throw KokoroVoiceCodec.Problem.fileTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(ImportedKokoroVoice.maxInputBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > ImportedKokoroVoice.maxInputBytes {
                throw KokoroVoiceCodec.Problem.fileTooLarge
            }
        }
        return data
    }

    nonisolated private static func userMessage(for error: Error, fallback: String) -> String {
        if error is KokoroVoiceCodec.Problem || error is CustomModelError
            || error is HuggingFaceImport.Failure || error is LocalModelError {
            return error.localizedDescription
        }
        return fallback
    }
}
