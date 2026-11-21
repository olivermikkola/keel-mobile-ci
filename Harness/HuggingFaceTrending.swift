import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A model entry returned by Hugging Face's `/api/models` endpoint.
public struct TrendingHubModel: Decodable, Equatable, Sendable {
    public struct Sibling: Decodable, Equatable, Sendable {
        public let rfilename: String
        public let size: UInt64?

        public init(rfilename: String, size: UInt64? = nil) {
            self.rfilename = rfilename
            self.size = size
        }
    }

    public struct GGUFSummary: Decodable, Equatable, Sendable {
        public let total: UInt64?
        public let architecture: String?
        public let contextLength: UInt32?

        enum CodingKeys: String, CodingKey {
            case total
            case architecture
            case contextLength = "context_length"
        }
    }

    public struct SafetensorsSummary: Decodable, Equatable, Sendable {
        public let total: UInt64?
    }

    public struct ConfigSummary: Decodable, Equatable, Sendable {
        public let modelType: String?
        public let numHiddenLayers: Int?
        public let numKeyValueHeads: Int?
        public let numAttentionHeads: Int?
        public let headDim: Int?
        public let hiddenSize: Int?
        public let maxPositionEmbeddings: UInt32?
        public let numLocalExperts: Int?
        public let numExpertsPerTok: Int?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case numHiddenLayers = "num_hidden_layers"
            case numKeyValueHeads = "num_key_value_heads"
            case numAttentionHeads = "num_attention_heads"
            case headDim = "head_dim"
            case hiddenSize = "hidden_size"
            case maxPositionEmbeddings = "max_position_embeddings"
            case numLocalExperts = "num_local_experts"
            case numExpertsPerTok = "num_experts_per_tok"
        }
    }

    public let id: String
    public let likes: Int?
    public let downloads: Int?
    public let trendingScore: Double?
    public let pipelineTag: String?
    public let tags: [String]?
    public let siblings: [Sibling]?
    public let gguf: GGUFSummary?
    public let safetensors: SafetensorsSummary?
    public let config: ConfigSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case likes
        case downloads
        case trendingScore
        case pipelineTag = "pipeline_tag"
        case tags
        case siblings
        case gguf
        case safetensors
        case config
    }
}

/// A trending Hugging Face model evaluated for a specific hardware profile and runtime.
public struct TrendingModelRecommendation: Equatable, Identifiable, Sendable {
    public let id: String
    public let repoID: String
    public let displayName: String
    public let author: String
    public let likes: Int
    public let downloads: Int
    public let trendingScore: Double
    public let selectedFileName: String?
    public let ggufLink: HuggingFaceGGUFLink?
    public let repoURL: URL
    public let quantLabel: String
    public let parameterBillions: Double?
    public let capabilities: [ModelCapabilityTag]
    public let fit: ModelFitResult
    public let calibratedSpeed: CalibratedSpeed
    public let keelTemplateSupported: Bool
    public let keelCompatibilityNote: String?

    public var plainCapabilitySummary: String {
        capabilities.map(\.plainPhrase).joined(separator: " · ")
    }
}

/// Errors from fetching or parsing the Hugging Face trending feed.
public enum HuggingFaceTrendingError: LocalizedError, Equatable {
    case unreachable(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable(let code):
            return code == 0
                ? "Could not reach Hugging Face right now. Check your connection and try again."
                : "Hugging Face returned HTTP \(code) while loading trending models."
        case .invalidResponse:
            return "Hugging Face returned an unexpected trending payload."
        }
    }
}

/// Hardware-aware Hugging Face trending discovery client and ranker.
public enum HuggingFaceTrending {
    public static func apiURL(limit: Int = 30, filter: String = "gguf") -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"
        components.queryItems = [
            URLQueryItem(name: "sort", value: "trendingScore"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(max(1, min(100, limit)))),
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "full", value: "true"),
        ]
        return components.url!
    }

    /// Maximum Hugging Face `/api/models` JSON response size (`2 MB`).
    public static let maxPayloadBytes = 2 * 1024 * 1024

    /// Fetches raw trending JSON payloads from Hugging Face Hub (`gguf`, plus `mlx` when requested).
    public static func fetchPayloads(
        includeMLX: Bool,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> [Data] {
        var request = URLRequest(url: apiURL(limit: 30, filter: "gguf"), timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (ggufData, ggufResponse) = try await ReadURLTransfer.fetch(request, configuration: configuration, limit: maxPayloadBytes)
        guard (200..<300).contains(ggufResponse.statusCode) else {
            throw HuggingFaceTrendingError.unreachable(ggufResponse.statusCode)
        }

        var combinedData = [ggufData]
        if includeMLX {
            var mlxReq = URLRequest(url: apiURL(limit: 15, filter: "mlx"), timeoutInterval: 15)
            mlxReq.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (mlxData, mlxResponse) = try? await ReadURLTransfer.fetch(mlxReq, configuration: configuration, limit: maxPayloadBytes),
               (200..<300).contains(mlxResponse.statusCode) {
                combinedData.append(mlxData)
            }
        }
        return combinedData
    }

    /// Fetches trending GGUF (and MLX when supported by hardware) models from Hugging Face,
    /// then filters and ranks them for `hardware`.
    public static func fetch(
        hardware: HardwareProfile,
        calibration: SpeedCalibrationStore,
        thermal: ThermalLevel = .nominal,
        onlyFitting: Bool = true,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> [TrendingModelRecommendation] {
        let combinedData = try await fetchPayloads(includeMLX: hardware.supportsMLX, configuration: configuration)
        return try parseAndRank(
            payloads: combinedData,
            hardware: hardware,
            calibration: calibration,
            thermal: thermal,
            onlyFitting: onlyFitting
        )
    }

    public static func parseAndRank(
        data: Data,
        hardware: HardwareProfile,
        calibration: SpeedCalibrationStore,
        thermal: ThermalLevel = .nominal,
        onlyFitting: Bool = true
    ) throws -> [TrendingModelRecommendation] {
        try parseAndRank(
            payloads: [data],
            hardware: hardware,
            calibration: calibration,
            thermal: thermal,
            onlyFitting: onlyFitting
        )
    }

    public static func parseAndRank(
        payloads: [Data],
        hardware: HardwareProfile,
        calibration: SpeedCalibrationStore,
        thermal: ThermalLevel = .nominal,
        onlyFitting: Bool = true
    ) throws -> [TrendingModelRecommendation] {
        let decoder = JSONDecoder()
        var seenRepos = Set<String>()
        var hubModels: [TrendingHubModel] = []
        for payload in payloads {
            guard let decoded = try? decoder.decode([TrendingHubModel].self, from: payload) else {
                throw HuggingFaceTrendingError.invalidResponse
            }
            for model in decoded where seenRepos.insert(model.id).inserted {
                hubModels.append(model)
            }
        }

        var recommendations: [TrendingModelRecommendation] = []
        recommendations.reserveCapacity(hubModels.count)

        for model in hubModels {
            guard let rec = evaluate(model, hardware: hardware, calibration: calibration, thermal: thermal) else {
                continue
            }
            if onlyFitting && !rec.fit.fits {
                continue
            }
            recommendations.append(rec)
        }

        return recommendations.sorted { lhs, rhs in
            if lhs.fit.fits != rhs.fit.fits { return lhs.fit.fits && !rhs.fit.fits }
            if lhs.keelTemplateSupported != rhs.keelTemplateSupported {
                return lhs.keelTemplateSupported && !rhs.keelTemplateSupported
            }
            if lhs.trendingScore != rhs.trendingScore { return lhs.trendingScore > rhs.trendingScore }
            return lhs.calibratedSpeed.tokensPerSecond > rhs.calibratedSpeed.tokensPerSecond
        }
    }

    public static func evaluate(
        _ model: TrendingHubModel,
        hardware: HardwareProfile,
        calibration: SpeedCalibrationStore,
        thermal: ThermalLevel = .nominal
    ) -> TrendingModelRecommendation? {
        let parts = model.id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let author = parts[0]
        let displayName = parts[1]
        let tags = model.tags ?? []

        // Skip obvious non-chat / embedding / diffusion repos when pipelineTag is set.
        if let pipeline = model.pipelineTag?.lowercased(),
           ["feature-extraction", "text-to-image", "automatic-speech-recognition", "text-to-speech"].contains(pipeline) {
            return nil
        }

        let isMLXRepo = tags.contains { $0.lowercased() == "mlx" } || displayName.lowercased().contains("-mlx")
        let ggufSiblings = (model.siblings ?? []).filter {
            let lower = $0.rfilename.lowercased()
            return lower.hasSuffix(".gguf") && !lower.contains("mmproj") && !lower.contains("-of-0")
        }

        let (totalParams, activeParamsFromName) = extractParameterBillions(from: model.id)
        let activeParams = activeParamsFromName ?? deriveActiveMoEParams(total: totalParams, config: model.config)

        let chosenVariant = pickBestVariant(
            repoID: model.id,
            ggufSiblings: ggufSiblings,
            siblings: model.siblings ?? [],
            isMLXRepo: isMLXRepo,
            model: model,
            totalParams: totalParams,
            activeParams: activeParams,
            hardware: hardware,
            thermal: thermal
        )

        guard let variant = chosenVariant else { return nil }

        let calibrated = calibration.calibratedSpeed(
            predicted: variant.fit.predictedTokensPerSecond,
            chipID: hardware.chipID,
            runtime: variant.fit.recommendedRuntime,
            quantBucket: variant.quantLabel,
            thermalLevel: thermal
        )

        let link: HuggingFaceGGUFLink?
        if let fileName = variant.fileName, fileName.lowercased().hasSuffix(".gguf") {
            link = try? HuggingFaceGGUFLink.parse("https://huggingface.co/\(model.id)/resolve/main/\(fileName)")
        } else {
            link = nil
        }

        let compat = assessKeelCompatibility(model: model, isMLX: variant.fit.recommendedRuntime == .mlx)
        let capabilities = ModelCapabilityTag.infer(fromName: displayName, tags: tags, pipelineTag: model.pipelineTag)
        let repoURL = URL(string: "https://huggingface.co/\(model.id)")!

        return TrendingModelRecommendation(
            id: model.id,
            repoID: model.id,
            displayName: displayName,
            author: author,
            likes: model.likes ?? 0,
            downloads: model.downloads ?? 0,
            trendingScore: model.trendingScore ?? Double(model.likes ?? 0),
            selectedFileName: variant.fileName,
            ggufLink: link,
            repoURL: repoURL,
            quantLabel: variant.quantLabel,
            parameterBillions: totalParams ?? inferParamBillions(weightBytes: variant.fit.weightsWithOverheadBytes, bits: variant.bits),
            capabilities: capabilities,
            fit: variant.fit,
            calibratedSpeed: calibrated,
            keelTemplateSupported: compat.supported,
            keelCompatibilityNote: compat.note
        )
    }

    private struct VariantChoice {
        let fileName: String?
        let quantLabel: String
        let bits: Double
        let fit: ModelFitResult
    }

    private static let quantPreferenceOrder = [
        "Q4_K_M", "Q4_0", "Q4_K_S", "IQ4_XS", "Q5_K_M", "Q3_K_M", "Q3_K_S", "Q2_K", "Q2_0", "Q6_K", "Q8_0"
    ]

    private static func pickBestVariant(
        repoID: String,
        ggufSiblings: [TrendingHubModel.Sibling],
        siblings: [TrendingHubModel.Sibling],
        isMLXRepo: Bool,
        model: TrendingHubModel,
        totalParams: Double?,
        activeParams: Double?,
        hardware: HardwareProfile,
        thermal: ThermalLevel
    ) -> VariantChoice? {
        if !ggufSiblings.isEmpty {
            let sorted = ggufSiblings.sorted { lhs, rhs in
                let lRank = quantRank(lhs.rfilename)
                let rRank = quantRank(rhs.rfilename)
                if lRank != rRank { return lRank < rRank }
                return (lhs.size ?? UInt64.max) < (rhs.size ?? UInt64.max)
            }

            var fallbackChoice: VariantChoice?
            for sibling in sorted {
                let quant = extractQuantLabel(from: sibling.rfilename) ?? "Q4_K_M"
                let bits = ModelFitInput.bitsPerWeight(fromQuantLabel: quant)
                let input = buildFitInput(
                    id: "\(repoID)/\(sibling.rfilename)",
                    name: repoID,
                    exactWeightBytes: sibling.size ?? model.gguf?.total,
                    quantLabel: quant,
                    bits: bits,
                    runtime: .llamaCpp,
                    supportsMLXVariant: isMLXRepo,
                    totalParams: totalParams,
                    activeParams: activeParams,
                    model: model
                )
                let fit = ModelFitEstimator.evaluate(input, on: hardware, targetContext: min(8_192, input.maxContextLength), thermal: thermal)
                let choice = VariantChoice(fileName: sibling.rfilename, quantLabel: quant, bits: bits, fit: fit)
                if fallbackChoice == nil { fallbackChoice = choice }
                if fit.fits { return choice }
            }
            return fallbackChoice
        }

        // MLX or summary-only repo (no .gguf sibling listed).
        if isMLXRepo {
            let quant = extractQuantLabel(from: repoID) ?? "4-bit"
            let bits = ModelFitInput.bitsPerWeight(fromQuantLabel: quant)
            let safetensorBytes = siblings
                .filter { $0.rfilename.lowercased().hasSuffix(".safetensors") }
                .compactMap(\.size)
                .reduce(0, +)
            let exactBytes: UInt64? = safetensorBytes > 0 ? safetensorBytes : model.safetensors?.total
            let input = buildFitInput(
                id: repoID,
                name: repoID,
                exactWeightBytes: exactBytes,
                quantLabel: quant,
                bits: bits,
                runtime: .mlx,
                supportsMLXVariant: true,
                totalParams: totalParams,
                activeParams: activeParams,
                model: model
            )
            let fit = ModelFitEstimator.evaluate(input, on: hardware, targetContext: min(8_192, input.maxContextLength), thermal: thermal)
            if !hardware.supportsMLX {
                let rejected = ModelFitResult(
                    fits: false,
                    tier: .tooLarge,
                    selectedContext: fit.selectedContext,
                    weightsWithOverheadBytes: fit.weightsWithOverheadBytes,
                    kvCacheBytes: fit.kvCacheBytes,
                    requiredBytes: fit.requiredBytes,
                    budgetBytes: fit.budgetBytes,
                    predictedTokensPerSecond: 0,
                    recommendedRuntime: .mlx,
                    alternativeRuntime: nil,
                    isApproximate: fit.isApproximate,
                    reasonNotFitting: "\(hardware.shortDeviceName) does not support MLX."
                )
                return VariantChoice(fileName: nil, quantLabel: quant, bits: bits, fit: rejected)
            }
            return VariantChoice(fileName: nil, quantLabel: quant, bits: bits, fit: fit)
        }

        // GGUF-tagged repo without siblings expanded: estimate from repo name / gguf summary.
        let quant = extractQuantLabel(from: repoID) ?? "Q4_K_M"
        let bits = ModelFitInput.bitsPerWeight(fromQuantLabel: quant)
        let input = buildFitInput(
            id: repoID,
            name: repoID,
            exactWeightBytes: model.gguf?.total,
            quantLabel: quant,
            bits: bits,
            runtime: .llamaCpp,
            supportsMLXVariant: false,
            totalParams: totalParams,
            activeParams: activeParams,
            model: model
        )
        let fit = ModelFitEstimator.evaluate(input, on: hardware, targetContext: min(8_192, input.maxContextLength), thermal: thermal)
        return VariantChoice(fileName: nil, quantLabel: quant, bits: bits, fit: fit)
    }

    private static func buildFitInput(
        id: String,
        name: String,
        exactWeightBytes: UInt64?,
        quantLabel: String,
        bits: Double,
        runtime: InferenceRuntimeKind,
        supportsMLXVariant: Bool,
        totalParams: Double?,
        activeParams: Double?,
        model: TrendingHubModel
    ) -> ModelFitInput {
        let cfg = model.config
        let headDim = cfg?.headDim ?? {
            guard let hidden = cfg?.hiddenSize, let qHeads = cfg?.numAttentionHeads, qHeads > 0 else { return nil }
            return hidden / qHeads
        }()
        let maxCtx = model.gguf?.contextLength ?? cfg?.maxPositionEmbeddings ?? 8_192
        return ModelFitInput(
            id: id,
            name: name,
            totalParamBillions: totalParams,
            activeParamBillions: activeParams,
            bitsPerWeight: bits,
            exactWeightBytes: exactWeightBytes,
            auxiliaryWeightBytes: 0,
            layerCount: cfg?.numHiddenLayers,
            attentionLayerCount: cfg?.numHiddenLayers,
            kvHeadCount: cfg?.numKeyValueHeads ?? cfg?.numAttentionHeads,
            keyLength: headDim,
            valueLength: headDim,
            ssmStateBytesPerLinearLayer: 0,
            maxContextLength: max(DeviceMemoryGate.minimumAgentContext, min(maxCtx, 32_768)),
            quantizedKV: quantLabel.uppercased().contains("Q2_0"),
            quantLabel: quantLabel,
            preferredRuntime: runtime,
            supportsMLXVariant: supportsMLXVariant,
            isSystemModel: false
        )
    }

    private static func quantRank(_ filename: String) -> Int {
        let upper = filename.uppercased()
        if let idx = quantPreferenceOrder.firstIndex(where: { upper.contains($0) }) {
            return idx
        }
        return quantPreferenceOrder.count + 1
    }

    public static func extractQuantLabel(from text: String) -> String? {
        let upper = text.uppercased()
        let known = [
            "Q4_K_M", "Q4_K_S", "Q4_0", "IQ4_XS", "IQ4_NL",
            "Q5_K_M", "Q5_K_S", "Q3_K_M", "Q3_K_S", "Q3_K_L",
            "Q2_K", "Q2_0", "Q6_K", "Q8_0", "4BIT", "4-BIT", "8BIT", "8-BIT", "2BIT"
        ]
        for token in known where upper.contains(token) {
            return token
        }
        return nil
    }

    /// Parses parameter counts such as `3B`, `1.7B`, `300M`, or MoE `30B-A3B` from a repo/file name.
    public static func extractParameterBillions(from text: String) -> (total: Double?, active: Double?) {
        let lower = text.lowercased()
        // Check MoE `30b-a3b` or `30b_a3.5b`
        if let moeRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)b[-_ ]a(\d+(?:\.\d+)?)b"#),
           let match = moeRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let totalRange = Range(match.range(at: 1), in: lower),
           let activeRange = Range(match.range(at: 2), in: lower),
           let total = Double(lower[totalRange]),
           let active = Double(lower[activeRange]) {
            return (total, active)
        }

        if let bRegex = try? NSRegularExpression(pattern: #"(?:^|[-_/ ])(\d+(?:\.\d+)?)b(?:[-_. ]|$)"#),
           let match = bRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower),
           let value = Double(lower[range]) {
            return (value, nil)
        }

        if let mRegex = try? NSRegularExpression(pattern: #"(?:^|[-_/ ])(\d+(?:\.\d+)?)m(?:[-_. ]|$)"#),
           let match = mRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower),
           let millions = Double(lower[range]) {
            return (millions / 1000.0, nil)
        }

        return (nil, nil)
    }

    private static func deriveActiveMoEParams(total: Double?, config: TrendingHubModel.ConfigSummary?) -> Double? {
        guard let total, let experts = config?.numLocalExperts, let activeExperts = config?.numExpertsPerTok,
              experts > 1, activeExperts > 0, activeExperts < experts else {
            return nil
        }
        // Roughly ~15% shared (embeddings/attention/norms) + active fraction of expert FFN weights.
        let activeFraction = 0.15 + 0.85 * (Double(activeExperts) / Double(experts))
        return total * activeFraction
    }

    private static func inferParamBillions(weightBytes: UInt64, bits: Double) -> Double? {
        guard weightBytes > 0, bits > 0 else { return nil }
        return Double(weightBytes) / (1.1 * (bits / 8.0) * 1_000_000_000.0)
    }

    private static func assessKeelCompatibility(model: TrendingHubModel, isMLX: Bool) -> (supported: Bool, note: String?) {
        if isMLX {
            return (false, "MLX discovery only right now; Keel imports GGUF links directly.")
        }
        let arch = (model.gguf?.architecture ?? model.config?.modelType ?? "").lowercased()
        let lowerID = model.id.lowercased()
        let isSupportedArch = arch.hasPrefix("qwen") || arch.hasPrefix("lfm") || arch.hasPrefix("minicpm")
            || lowerID.contains("qwen") || lowerID.contains("bonsai") || lowerID.contains("lfm") || lowerID.contains("minicpm")
        if isSupportedArch {
            return (true, nil)
        }
        if !arch.isEmpty {
            return (false, "Uses \(arch) chat format; Keel currently runs Qwen, LFM and MiniCPM GGUFs.")
        }
        return (false, "Check header on import; Keel currently runs Qwen, LFM and MiniCPM GGUFs.")
    }
}
