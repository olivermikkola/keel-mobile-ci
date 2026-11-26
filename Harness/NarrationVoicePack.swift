import Foundation

/// The on-device narration voice for `create_short_video`: Kokoro-82M through
/// FluidAudio's Core ML pipeline (`Sources/NarrationVoice.swift`). Downloaded
/// once from Hugging Face; speaking needs no network. Apache-2.0 weights.
public enum NarrationVoicePack {
    public static let name = "Kokoro narration voice"
    public static let engine = "Kokoro 82M · Core ML"
    /// FluidAudio release the app is built against (project.yml); its model
    /// files are pinned to fixed Hugging Face revisions and hash-checked.
    public static let fluidAudioVersion = "0.18.4"

    /// Voices downloaded with the pack, so a render never fetches one.
    public static let voices: [(id: String, label: String)] = [
        ("af_heart", "Heart · US English, warm"),
        ("af_bella", "Bella · US English, bright"),
        ("am_adam", "Adam · US English, deep"),
        ("am_michael", "Michael · US English, calm"),
    ]
    public static var voiceIDs: Set<String> { Set(voices.map(\.id)) }
    public static let defaultVoice = "af_heart"

    /// Rough size of the English download, for the Models screen and the
    /// progress bar (the folder is measured while it fills). Measured by the
    /// real-voice CI check; update it from that run's printout when FluidAudio moves.
    public static let approximateBytes: Int64 = 330_000_000
    /// Working memory while speaking, on top of the files. FluidAudio's Core ML
    /// Kokoro measured about 676 MB peak in total; the chat model steps aside first.
    public static let workingBytes: UInt64 = 450_000_000

    /// Whether this phone has the memory to speak with the chat model unloaded.
    public static func fits(physicalMemoryBytes: UInt64) -> Bool {
        ShortVideoRequest.neuralFits(modelBytes: UInt64(approximateBytes), workingBytes: workingBytes,
                                     physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Download progress from the folder's size so far, kept below 1 until the
    /// pack has also loaded and spoken its test line.
    public static func progress(bytesOnDisk: Int64) -> Double {
        min(0.95, max(0, Double(bytesOnDisk) / Double(approximateBytes)))
    }
}
