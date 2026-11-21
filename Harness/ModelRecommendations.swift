import Foundation

/// Plain-English capability tags used across Hugging Face discovery and the
/// distilled "My recommendations" shelf.
public enum ModelCapabilityTag: String, Codable, Equatable, Hashable, Sendable {
    case code
    case vision
    case reasoning
    case quickAnswers
    case tools
    case general

    public var plainPhrase: String {
        switch self {
        case .code: return "Good at code"
        case .vision: return "Reads photos"
        case .reasoning: return "Strong reasoning"
        case .quickAnswers: return "Quick answers"
        case .tools: return "Good with tools"
        case .general: return "Everyday tasks"
        }
    }

    /// Infers plain capabilities from model tags and names without exposing Hub jargon.
    public static func infer(fromName name: String, tags: [String] = [], pipelineTag: String? = nil) -> [ModelCapabilityTag] {
        let lowerName = name.lowercased()
        let lowerTags = tags.map { $0.lowercased() }
        let combined = ([lowerName, pipelineTag?.lowercased() ?? ""] + lowerTags).joined(separator: " ")

        var result: [ModelCapabilityTag] = []
        if combined.contains("vision") || combined.contains("-vl") || combined.contains("_vl") || combined.contains("image-text") || combined.contains("multimodal") {
            result.append(.vision)
        }
        if combined.contains("coder") || combined.contains("code") {
            result.append(.code)
        }
        if combined.contains("reason") || combined.contains("thinking") || combined.contains("r1") {
            result.append(.reasoning)
        }
        if combined.contains("tool") || combined.contains("function") || combined.contains("agent") {
            result.append(.tools)
        }
        if result.isEmpty {
            result.append(.quickAnswers)
        }
        return result
    }
}

/// Candidate model handed to `ModelRecommendationEngine` for ranking and plain-English presentation.
public struct CatalogModelCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let fitInput: ModelFitInput
    public let capabilities: [ModelCapabilityTag]
    public let isInstalled: Bool
    public let isSelected: Bool
    public let isRecommendedForMode: Bool

    public init(
        id: String,
        name: String,
        fitInput: ModelFitInput,
        capabilities: [ModelCapabilityTag],
        isInstalled: Bool = false,
        isSelected: Bool = false,
        isRecommendedForMode: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fitInput = fitInput
        self.capabilities = capabilities
        self.isInstalled = isInstalled
        self.isSelected = isSelected
        self.isRecommendedForMode = isRecommendedForMode
    }
}

/// Jargon-free recommendation card for a model evaluated against the current hardware and calibration store.
public struct ModelRecommendation: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let fits: Bool
    public let fit: ModelFitResult
    public let calibratedSpeed: CalibratedSpeed
    public let recommendedRuntime: InferenceRuntimeKind
    public let speedLabel: String
    public let capabilityLabel: String
    public let plainHeadline: String
    public let plainBadges: [String]
    public let rankScore: Double
}

/// Produces the distilled "My recommendations" shelf: filter by fit, sort by
/// mode fit + calibrated speed, and describe everything in plain language with
/// zero Hugging Face vocabulary.
public enum ModelRecommendationEngine {
    /// Forbidden Hub/quantization jargon that must never leak into "My recommendations" copy.
    public static let forbiddenJargon: [String] = [
        "quantized", "gguf", "q4_k_m", "q4_0", "q2_0", "q3_k", "q5_k", "q8_0",
        "context length", "kv cache", "safetensors", "fp16"
    ]

    public static func recommend(
        candidates: [CatalogModelCandidate],
        hardware: HardwareProfile,
        mode: ChatMode,
        calibration: SpeedCalibrationStore,
        thermal: ThermalLevel = .nominal
    ) -> [ModelRecommendation] {
        let evaluated = candidates.map { candidate -> ModelRecommendation in
            let fit = ModelFitEstimator.evaluate(candidate.fitInput, on: hardware, targetContext: candidate.fitInput.maxContextLength, thermal: thermal)
            let calibrated = calibration.calibratedSpeed(
                predicted: fit.predictedTokensPerSecond,
                chipID: hardware.chipID,
                runtime: fit.recommendedRuntime,
                quantBucket: candidate.fitInput.quantLabel,
                thermalLevel: thermal
            )
            let speed = speedDescription(for: calibrated.tokensPerSecond, isSystem: candidate.fitInput.isSystemModel)
            let primaryCap = primaryCapability(for: candidate.capabilities, mode: mode)
            let devicePhrase = "Fits your \(hardware.shortDeviceName)"
            let ratePhrase = formattedRate(calibrated.tokensPerSecond, measured: calibrated.isMeasured)

            let badges: [String]
            let headline: String
            if fit.fits {
                if candidate.fitInput.isSystemModel {
                    badges = ["Built into iOS", primaryCap.plainPhrase, devicePhrase]
                } else {
                    badges = [speed, primaryCap.plainPhrase, devicePhrase, ratePhrase]
                }
                headline = badges.joined(separator: " · ")
            } else {
                badges = ["Needs more memory", "Too large for this \(hardware.shortDeviceName)"]
                headline = "Too large for your \(hardware.shortDeviceName) · Needs about \(ModelFitEstimator.formatGB(fit.requiredBytes))"
            }

            let score = rankingScore(
                candidate: candidate,
                fit: fit,
                calibratedSpeed: calibrated,
                mode: mode
            )

            return ModelRecommendation(
                id: candidate.id,
                name: candidate.name,
                fits: fit.fits,
                fit: fit,
                calibratedSpeed: calibrated,
                recommendedRuntime: fit.recommendedRuntime,
                speedLabel: speed,
                capabilityLabel: primaryCap.plainPhrase,
                plainHeadline: headline,
                plainBadges: badges,
                rankScore: score
            )
        }

        return evaluated.sorted { lhs, rhs in
            if lhs.fits != rhs.fits { return lhs.fits && !rhs.fits }
            if lhs.rankScore != rhs.rankScore { return lhs.rankScore > rhs.rankScore }
            return lhs.calibratedSpeed.tokensPerSecond > rhs.calibratedSpeed.tokensPerSecond
        }
    }

    private static func speedDescription(for tokensPerSecond: Double, isSystem: Bool) -> String {
        if isSystem { return "Instant" }
        switch tokensPerSecond {
        case 45...: return "Very fast"
        case 22..<45: return "Fast"
        case 10..<22: return "Steady"
        default: return "Measured pace"
        }
    }

    private static func formattedRate(_ tokensPerSecond: Double, measured: Bool) -> String {
        let rounded = Int(tokensPerSecond.rounded())
        let base = "~\(max(1, rounded)) tok/s"
        return measured ? "\(base) · measured" : base
    }

    private static func primaryCapability(for capabilities: [ModelCapabilityTag], mode: ChatMode) -> ModelCapabilityTag {
        if mode == .work {
            if capabilities.contains(.code) { return .code }
            if capabilities.contains(.tools) { return .tools }
            if capabilities.contains(.reasoning) { return .reasoning }
        } else {
            if capabilities.contains(.quickAnswers) { return .quickAnswers }
            if capabilities.contains(.vision) { return .vision }
        }
        return capabilities.first ?? .general
    }

    private static func rankingScore(
        candidate: CatalogModelCandidate,
        fit: ModelFitResult,
        calibratedSpeed: CalibratedSpeed,
        mode: ChatMode
    ) -> Double {
        guard fit.fits else { return -1000.0 }
        var score = min(120.0, calibratedSpeed.tokensPerSecond)
        if candidate.isRecommendedForMode {
            score += 200.0
        }
        if fit.tier == .comfortable {
            score += 40.0
        }
        if mode == .chat && candidate.capabilities.contains(.quickAnswers) {
            score += 25.0
        }
        if mode == .work && (candidate.capabilities.contains(.code) || candidate.capabilities.contains(.tools)) {
            score += 25.0
        }
        if candidate.fitInput.isSystemModel {
            // Keep downloadable high-context models ahead of the 4K system fallback in Work mode.
            score += (mode == .chat ? 15.0 : -40.0)
        }
        return score
    }
}
