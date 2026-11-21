import Foundation
import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

extension LocalModel {
    /// Approximate parameter scale and plain capability tags for built-in, system, and imported models.
    var fitInput: ModelFitInput {
        let bits = ModelFitInput.bitsPerWeight(fromQuantLabel: quantization)
        let kvQuantized = architecture.kvBlockBytes == 18 && architecture.kvBlockElements == 32
        let linearLayers = max(0, architecture.layerCount - architecture.fullAttentionLayerCount)
        let ssmBytesPerLayer: UInt64
        if linearLayers > 0 {
            let state = UInt64(max(0, architecture.ssmInnerSize)) * UInt64(max(0, architecture.ssmStateSize)) * 4
            let conv = UInt64(max(0, architecture.ssmConvKernel)) * UInt64(max(0, architecture.ssmInnerSize)) * 4
            ssmBytesPerLayer = state + conv
        } else {
            ssmBytesPerLayer = 0
        }

        let knownParams: Double?
        switch id {
        case "4B": knownParams = 4.0
        case "9B": knownParams = 9.0
        case "2B": knownParams = 2.0
        case "qwen3-06b": knownParams = 0.6
        case "lfm3": knownParams = 1.7
        case "lfm3-vl": knownParams = 2.0
        case "minicpm5": knownParams = 2.0
        case "apple": knownParams = 3.0
        default:
            knownParams = Double(max(1, bytes)) / ((bits / 8.0) * 1_000_000_000.0)
        }

        return ModelFitInput(
            id: id,
            name: name,
            totalParamBillions: knownParams,
            activeParamBillions: nil,
            bitsPerWeight: bits,
            exactWeightBytes: isSystem ? nil : UInt64(max(0, bytes)),
            auxiliaryWeightBytes: UInt64(max(0, visionFile?.bytes ?? 0)),
            layerCount: architecture.layerCount,
            attentionLayerCount: architecture.fullAttentionLayerCount,
            kvHeadCount: architecture.kvHeadCount,
            keyLength: architecture.keyLength,
            valueLength: architecture.valueLength,
            ssmStateBytesPerLinearLayer: ssmBytesPerLayer,
            maxContextLength: contextSize,
            quantizedKV: kvQuantized,
            quantLabel: quantization,
            preferredRuntime: isSystem ? .appleOnDevice : .llamaCpp,
            supportsMLXVariant: id == MLXModelPack.lfm3.ggufModelID,
            isSystemModel: isSystem
        )
    }

    var capabilities: [ModelCapabilityTag] {
        switch id {
        case "4B": return [.code, .tools]
        case "9B": return [.code, .tools, .reasoning]
        case "2B", "lfm3": return [.quickAnswers, .tools]
        case "qwen3-06b": return [.quickAnswers]
        case "lfm3-vl": return [.vision, .quickAnswers, .tools]
        case "minicpm5": return [.quickAnswers, .tools]
        case "apple": return [.quickAnswers]
        default: return ModelCapabilityTag.infer(fromName: name)
        }
    }
}

/// Manages the active hardware profile, self-calibrating speed measurements,
/// distilled plain-language recommendations, and Hugging Face trending results.
@MainActor
final class HardwareRecommendationStore: ObservableObject {
    static let selectedProfileDefaultsKey = "hardwareProfileID"

    @Published var selectedProfileID: String {
        didSet {
            defaults.set(selectedProfileID, forKey: Self.selectedProfileDefaultsKey)
            recomputeTrendingForCurrentProfile()
        }
    }
    @Published private(set) var calibration: SpeedCalibrationStore
    @Published private(set) var trending: [TrendingModelRecommendation] = []
    @Published private(set) var isLoadingTrending = false
    @Published var trendingError: String?
    @Published var onlyShowFitting = true {
        didSet { recomputeTrendingForCurrentProfile() }
    }

    let currentDevice: HardwareProfile
    private let presets: [HardwareProfile]
    private let defaults: UserDefaults
    private let calibrationURL: URL
    private let configuration: () -> URLSessionConfiguration
    private var lastRawPayloads: [Data] = []

    init(
        modelsDirectory: URL = ModelLibrary.defaultDirectory,
        defaults: UserDefaults = .standard,
        currentDevice: HardwareProfile = HardwareProfile.detectCurrent(appleIntelligenceAvailable: AppleModelRunner.isAvailable),
        presets: [HardwareProfile] = HardwareProfile.appleDevicePresets,
        configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.currentDevice = currentDevice
        self.presets = presets
        self.defaults = defaults
        self.calibrationURL = Self.calibrationFileURL(in: modelsDirectory)
        self.configuration = configuration
        self.selectedProfileID = defaults.string(forKey: Self.selectedProfileDefaultsKey) ?? currentDevice.id
        self.calibration = SpeedCalibrationStore.load(from: calibrationURL)
    }

    static func calibrationFileURL(in directory: URL = ModelLibrary.defaultDirectory) -> URL {
        directory.appendingPathComponent("speed-calibration.json")
    }

    var availableProfiles: [HardwareProfile] {
        [currentDevice] + presets
    }

    var activeProfile: HardwareProfile {
        availableProfiles.first { $0.id == selectedProfileID } ?? currentDevice
    }

    func reloadCalibration() {
        calibration = SpeedCalibrationStore.load(from: calibrationURL)
    }

    func resetCalibration() {
        calibration.reset()
        try? calibration.save(to: calibrationURL)
        recomputeTrendingForCurrentProfile()
    }

    func recordObservation(
        model: LocalModel,
        runtime: InferenceRuntimeKind,
        telemetry: InferenceTelemetry,
        thermal: ThermalLevel = .current
    ) {
        guard let actual = telemetry.decodeTokensPerSecond else { return }
        let predicted = ModelFitEstimator.predictTokensPerSecond(
            input: model.fitInput,
            on: currentDevice,
            runtime: runtime,
            thermal: thermal
        )
        let recorded = calibration.record(SpeedObservation(
            chipID: currentDevice.chipID,
            runtime: runtime,
            quantBucket: model.quantization,
            thermalLevel: thermal,
            predictedTokensPerSecond: predicted,
            actualTokensPerSecond: actual,
            decodedTokens: telemetry.decodedTokens,
            decodeDuration: telemetry.decodeDuration,
            footprintBytes: telemetry.footprintBytes
        ))
        if recorded {
            try? calibration.save(to: calibrationURL)
            recomputeTrendingForCurrentProfile()
        }
    }

    /// Downloads are selected for the device in hand. The comparison screen can
    /// preview a different profile without changing this choice.
    func setupModel(for models: ModelLibrary) -> LocalModel? {
        let candidates = models.catalog.filter { model in
            !model.isSystem && !model.isImported && !models.installed.contains(model.id)
                && ModelFitEstimator.evaluate(model.fitInput, on: currentDevice,
                                              targetContext: model.contextSize).fits
        }
        if let pending = candidates.first(where: { models.partialBytes[$0.id] != nil }) { return pending }
        return candidates.first(where: { $0.id == "qwen3-06b" })
            ?? candidates.min(by: { $0.downloadBytes < $1.downloadBytes })
    }

    /// Evaluates and ranks Keel's catalog models for this device and the active chat mode.
    func recommendations(for models: ModelLibrary, mode: ChatMode, usesMLXForLFM3: Bool = false) -> [ModelRecommendation] {
        let candidates = models.catalog.map { model -> CatalogModelCandidate in
            var input = model.fitInput
            if usesMLXForLFM3 && model.id == MLXModelPack.lfm3.ggufModelID && currentDevice.supportsMLX {
                input = ModelFitInput(
                    id: input.id,
                    name: input.name,
                    totalParamBillions: input.totalParamBillions,
                    activeParamBillions: input.activeParamBillions,
                    bitsPerWeight: input.bitsPerWeight,
                    exactWeightBytes: input.exactWeightBytes,
                    auxiliaryWeightBytes: input.auxiliaryWeightBytes,
                    layerCount: input.layerCount,
                    attentionLayerCount: input.attentionLayerCount,
                    kvHeadCount: input.kvHeadCount,
                    keyLength: input.keyLength,
                    valueLength: input.valueLength,
                    ssmStateBytesPerLinearLayer: input.ssmStateBytesPerLinearLayer,
                    maxContextLength: input.maxContextLength,
                    quantizedKV: input.quantizedKV,
                    quantLabel: input.quantLabel,
                    preferredRuntime: .mlx,
                    supportsMLXVariant: true,
                    isSystemModel: input.isSystemModel
                )
            }
            return CatalogModelCandidate(
                id: model.id,
                name: model.name,
                fitInput: input,
                capabilities: model.capabilities,
                isInstalled: models.installed.contains(model.id),
                isSelected: models.selected == model.id,
                isRecommendedForMode: models.isRecommended(model)
            )
        }
        return ModelRecommendationEngine.recommend(
            candidates: candidates,
            hardware: currentDevice,
            mode: mode,
            calibration: calibration,
            thermal: .current
        )
    }

    func refreshTrending() async {
        guard !isLoadingTrending else { return }
        isLoadingTrending = true
        trendingError = nil
        defer { isLoadingTrending = false }

        do {
            lastRawPayloads = try await HuggingFaceTrending.fetchPayloads(
                includeMLX: true,
                configuration: configuration()
            )
            recomputeTrendingForCurrentProfile()
        } catch is CancellationError {
        } catch {
            trendingError = (error as? HuggingFaceTrendingError)?.errorDescription
                ?? "Could not load trending models from Hugging Face right now."
        }
    }

    private func recomputeTrendingForCurrentProfile() {
        guard !lastRawPayloads.isEmpty else { return }
        if let ranked = try? HuggingFaceTrending.parseAndRank(
            payloads: lastRawPayloads,
            hardware: activeProfile,
            calibration: calibration,
            thermal: .current,
            onlyFitting: onlyShowFitting
        ) {
            trending = ranked
        }
    }
}
