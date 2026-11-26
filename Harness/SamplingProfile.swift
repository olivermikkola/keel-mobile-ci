import Foundation

/// Sampler settings for one generation. Presets hold only values the repo uses today.
///
/// A `nil` min-p, penalty or seed means that setting is not used: the app's sampler
/// chain has no such step, and the eval request leaves the field out. A nil `seed`
/// means a random seed on each call.
public struct SamplingProfile: Equatable {
    public var name: String
    public var temperature: Double
    public var topK: Int
    public var topP: Double
    public var minP: Double?
    public var repeatPenalty: Double?
    public var presencePenalty: Double?
    public var seed: UInt32?
    /// Reply limit for reading. Chats that write files use AgentPrompt.writingReplyTokens.
    public var replyTokenLimit: Int

    public init(name: String, temperature: Double, topK: Int, topP: Double, minP: Double? = nil,
                repeatPenalty: Double? = nil, presencePenalty: Double? = nil, seed: UInt32? = nil,
                replyTokenLimit: Int = 512) {
        self.name = name
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.replyTokenLimit = replyTokenLimit
    }

    /// The phone app today: `Sources/LocalInference.swift` lines 232-235 build top-k 40, top-p 0.9, temperature 0.6,
    /// then a dist sampler with the library's default (random) seed. The reply limit is
    /// `LocalChat.swift` passing `limit: 512`.
    public static let app = SamplingProfile(name: "app", temperature: 0.6, topK: 40, topP: 0.9)

    /// The eval today: `tools/harness-eval/agent/Server.swift` (`Sampling`, lines 15-21) sends
    /// top-k 40, top-p 0.9, temperature 0.6 and presence penalty 0.0, with the reply limit
    /// 512 from `agent/main.swift`. Its seed is set per sample. `tools/harness-eval/collect.py`
    /// (line 65) sends the same top-k, top-p and temperature. `.evalSeeded(_:)` adds a seed.
    public static let eval = SamplingProfile(name: "eval", temperature: 0.6, topK: 40, topP: 0.9, presencePenalty: 0.0)

    /// `eval` with a fixed seed, as `collect.py` sends for each sample.
    public static func evalSeeded(_ seed: UInt32) -> SamplingProfile {
        var profile = eval
        profile.seed = seed
        return profile
    }
}
