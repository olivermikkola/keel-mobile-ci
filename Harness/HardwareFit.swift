import Foundation

/// Inference engine that can run a model on the target device.
public enum InferenceRuntimeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case llamaCpp
    case mlx
    case appleOnDevice

    public var displayName: String {
        switch self {
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        case .appleOnDevice: return "Apple on-device"
        }
    }

    /// Baseline decode memory-bandwidth utilization before per-device calibration.
    public var baselineBandwidthEfficiency: Double {
        switch self {
        case .llamaCpp: return 0.65
        case .mlx: return 0.72
        case .appleOnDevice: return 0.80
        }
    }
}

/// Target hardware profile used for memory-headroom and bandwidth-ceiling estimates.
public struct HardwareProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let shortDeviceName: String
    public let chipID: String
    public let chipName: String
    public let physicalMemoryBytes: UInt64
    public let usableMemoryBytes: UInt64
    public let memoryBandwidthGBps: Double
    public let supportsMLX: Bool
    public let supportsAppleIntelligence: Bool
    public let isCurrentDevice: Bool

    public init(
        id: String,
        name: String,
        shortDeviceName: String,
        chipID: String,
        chipName: String,
        physicalMemoryBytes: UInt64,
        usableMemoryBytes: UInt64,
        memoryBandwidthGBps: Double,
        supportsMLX: Bool,
        supportsAppleIntelligence: Bool,
        isCurrentDevice: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortDeviceName = shortDeviceName
        self.chipID = chipID
        self.chipName = chipName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.usableMemoryBytes = usableMemoryBytes
        self.memoryBandwidthGBps = max(1, memoryBandwidthGBps)
        self.supportsMLX = supportsMLX
        self.supportsAppleIntelligence = supportsAppleIntelligence
        self.isCurrentDevice = isCurrentDevice
    }

    /// Curated presets representing the devices Keel users target and compare.
    public static let iphone15ProA17 = HardwareProfile(
        id: "iphone-15-pro-a17",
        name: "iPhone 15 Pro (A17 Pro · 8 GB)",
        shortDeviceName: "iPhone",
        chipID: "a17-pro",
        chipName: "A17 Pro",
        physicalMemoryBytes: 8_000_000_000,
        usableMemoryBytes: 4_500_000_000,
        memoryBandwidthGBps: 34.1,
        supportsMLX: true,
        supportsAppleIntelligence: true
    )

    public static let iphone16ProA18 = HardwareProfile(
        id: "iphone-16-pro-a18",
        name: "iPhone 16 Pro (A18 Pro · 8 GB)",
        shortDeviceName: "iPhone",
        chipID: "a18-pro",
        chipName: "A18 Pro",
        physicalMemoryBytes: 8_000_000_000,
        usableMemoryBytes: 4_800_000_000,
        memoryBandwidthGBps: 60.0,
        supportsMLX: true,
        supportsAppleIntelligence: true
    )

    public static let iphoneA20 = HardwareProfile(
        id: "iphone-a20-12gb",
        name: "iPhone (A20 · 12 GB)",
        shortDeviceName: "iPhone",
        chipID: "a20",
        chipName: "A20",
        physicalMemoryBytes: 12_000_000_000,
        usableMemoryBytes: 7_500_000_000,
        memoryBandwidthGBps: 85.0,
        supportsMLX: true,
        supportsAppleIntelligence: true
    )

    public static let ipadProM416GB = HardwareProfile(
        id: "ipad-pro-m4-16gb",
        name: "16GB iPad Pro (M4)",
        shortDeviceName: "iPad Pro",
        chipID: "m4",
        chipName: "M4",
        physicalMemoryBytes: 16_000_000_000,
        usableMemoryBytes: 10_500_000_000,
        memoryBandwidthGBps: 120.0,
        supportsMLX: true,
        supportsAppleIntelligence: true
    )

    public static let xboxSeriesS = HardwareProfile(
        id: "xbox-series-s",
        name: "Xbox Series S (10 GB)",
        shortDeviceName: "Xbox Series S",
        chipID: "xbox-series-s",
        chipName: "Custom Zen 2 / RDNA 2",
        physicalMemoryBytes: 10_000_000_000,
        usableMemoryBytes: 8_000_000_000,
        memoryBandwidthGBps: 224.0,
        supportsMLX: false,
        supportsAppleIntelligence: false
    )

    public static let presets: [HardwareProfile] = [
        iphone15ProA17,
        iphone16ProA18,
        iphoneA20,
        ipadProM416GB,
        xboxSeriesS,
    ]

    /// Detects the active Apple device profile (or falls back cleanly on simulator / unknown chips).
    public static func detectCurrent(
        machineIdentifier: String = currentMachineIdentifier(),
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        appleIntelligenceAvailable: Bool = false
    ) -> HardwareProfile {
        let lower = machineIdentifier.lowercased()
        let isPad = lower.hasPrefix("ipad")

        if lower == "iphone16,1" || lower == "iphone16,2" {
            return HardwareProfile(
                id: "current",
                name: "This iPhone (A17 Pro)",
                shortDeviceName: "iPhone",
                chipID: "a17-pro",
                chipName: "A17 Pro",
                physicalMemoryBytes: physicalMemoryBytes,
                usableMemoryBytes: DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes),
                memoryBandwidthGBps: 34.1,
                supportsMLX: true,
                supportsAppleIntelligence: appleIntelligenceAvailable,
                isCurrentDevice: true
            )
        }

        if lower.hasPrefix("iphone17,") {
            let isPro = lower == "iphone17,1" || lower == "iphone17,2"
            return HardwareProfile(
                id: "current",
                name: isPro ? "This iPhone (A18 Pro)" : "This iPhone (A18)",
                shortDeviceName: "iPhone",
                chipID: isPro ? "a18-pro" : "a18",
                chipName: isPro ? "A18 Pro" : "A18",
                physicalMemoryBytes: physicalMemoryBytes,
                usableMemoryBytes: isPro ? 4_800_000_000 : DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes),
                memoryBandwidthGBps: 60.0,
                supportsMLX: true,
                supportsAppleIntelligence: appleIntelligenceAvailable,
                isCurrentDevice: true
            )
        }

        if lower.hasPrefix("iphone18,") || lower.hasPrefix("iphone19,") {
            let gb = physicalMemoryBytes / 1_000_000_000
            let chip = lower.hasPrefix("iphone19,") ? "A20" : "A19 Pro"
            let chipID = lower.hasPrefix("iphone19,") ? "a20" : "a19-pro"
            let bandwidth = lower.hasPrefix("iphone19,") ? 85.0 : 75.0
            let usable = gb >= 12 ? 7_500_000_000 : DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
            return HardwareProfile(
                id: "current",
                name: "This iPhone (\(chip))",
                shortDeviceName: "iPhone",
                chipID: chipID,
                chipName: chip,
                physicalMemoryBytes: physicalMemoryBytes,
                usableMemoryBytes: usable,
                memoryBandwidthGBps: bandwidth,
                supportsMLX: true,
                supportsAppleIntelligence: appleIntelligenceAvailable,
                isCurrentDevice: true
            )
        }

        if lower.hasPrefix("ipad16,3") || lower.hasPrefix("ipad16,4") || lower.hasPrefix("ipad16,5") || lower.hasPrefix("ipad16,6") {
            let gb = physicalMemoryBytes / 1_000_000_000
            let usable: UInt64 = gb >= 16 ? 10_500_000_000 : DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
            return HardwareProfile(
                id: "current",
                name: "This iPad Pro (M4)",
                shortDeviceName: "iPad Pro",
                chipID: "m4",
                chipName: "M4",
                physicalMemoryBytes: physicalMemoryBytes,
                usableMemoryBytes: usable,
                memoryBandwidthGBps: 120.0,
                supportsMLX: true,
                supportsAppleIntelligence: appleIntelligenceAvailable,
                isCurrentDevice: true
            )
        }

        // Simulator or newer/unmapped hardware: derive sensible headroom & bandwidth from physical RAM.
        let gb = max(1, Int(physicalMemoryBytes / 1_000_000_000))
        let usable: UInt64 = gb >= 16
            ? max(10_500_000_000, DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes))
            : DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
        let bandwidth: Double
        if isPad || gb >= 16 {
            bandwidth = 110.0
        } else if gb >= 12 {
            bandwidth = 80.0
        } else if gb >= 8 {
            bandwidth = 50.0
        } else {
            bandwidth = 30.0
        }
        let deviceNoun = isPad ? "iPad" : "iPhone"
        return HardwareProfile(
            id: "current",
            name: "This \(deviceNoun) (\(gb) GB)",
            shortDeviceName: deviceNoun,
            chipID: sanitizeChipID(machineIdentifier.isEmpty ? "\(deviceNoun.lowercased())-\(gb)gb" : machineIdentifier),
            chipName: "\(gb) GB Apple Silicon",
            physicalMemoryBytes: physicalMemoryBytes,
            usableMemoryBytes: usable,
            memoryBandwidthGBps: bandwidth,
            supportsMLX: true,
            supportsAppleIntelligence: appleIntelligenceAvailable,
            isCurrentDevice: true
        )
    }

    public static func currentMachineIdentifier() -> String {
        #if canImport(Darwin)
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        #else
        return "x86_64"
        #endif
    }

    private static func sanitizeChipID(_ raw: String) -> String {
        let lower = raw.lowercased()
        let cleaned = lower.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Model architectural and weight parameters needed for hardware fit and speed estimation.
public struct ModelFitInput: Equatable, Sendable {
    public let id: String
    public let name: String
    public let totalParamBillions: Double?
    public let activeParamBillions: Double?
    public let bitsPerWeight: Double
    public let exactWeightBytes: UInt64?
    public let auxiliaryWeightBytes: UInt64
    public let layerCount: Int?
    public let attentionLayerCount: Int?
    public let kvHeadCount: Int?
    public let keyLength: Int?
    public let valueLength: Int?
    public let ssmStateBytesPerLinearLayer: UInt64
    public let maxContextLength: UInt32
    public let quantizedKV: Bool
    public let quantLabel: String
    public let preferredRuntime: InferenceRuntimeKind
    public let supportsMLXVariant: Bool
    public let isSystemModel: Bool

    public init(
        id: String,
        name: String,
        totalParamBillions: Double? = nil,
        activeParamBillions: Double? = nil,
        bitsPerWeight: Double = 4.0,
        exactWeightBytes: UInt64? = nil,
        auxiliaryWeightBytes: UInt64 = 0,
        layerCount: Int? = nil,
        attentionLayerCount: Int? = nil,
        kvHeadCount: Int? = nil,
        keyLength: Int? = nil,
        valueLength: Int? = nil,
        ssmStateBytesPerLinearLayer: UInt64 = 0,
        maxContextLength: UInt32 = 8_192,
        quantizedKV: Bool = false,
        quantLabel: String = "4-bit",
        preferredRuntime: InferenceRuntimeKind = .llamaCpp,
        supportsMLXVariant: Bool = false,
        isSystemModel: Bool = false
    ) {
        self.id = id
        self.name = name
        self.totalParamBillions = totalParamBillions
        self.activeParamBillions = activeParamBillions
        self.bitsPerWeight = max(1.0, bitsPerWeight)
        self.exactWeightBytes = exactWeightBytes
        self.auxiliaryWeightBytes = auxiliaryWeightBytes
        self.layerCount = layerCount
        self.attentionLayerCount = attentionLayerCount
        self.kvHeadCount = kvHeadCount
        self.keyLength = keyLength
        self.valueLength = valueLength
        self.ssmStateBytesPerLinearLayer = ssmStateBytesPerLinearLayer
        self.maxContextLength = max(DeviceMemoryGate.minimumAgentContext, maxContextLength)
        self.quantizedKV = quantizedKV
        self.quantLabel = quantLabel
        self.preferredRuntime = preferredRuntime
        self.supportsMLXVariant = supportsMLXVariant
        self.isSystemModel = isSystemModel
    }

    /// Rough raw weights size: exact file size if known, otherwise `params * (bits / 8)`.
    public var rawWeightBytes: UInt64 {
        if let exactWeightBytes {
            return exactWeightBytes
        }
        let params = max(0.1, totalParamBillions ?? 2.0)
        let bytes = params * (bitsPerWeight / 8.0) * 1_000_000_000.0
        return UInt64(max(0, bytes.rounded()))
    }

    /// Weights fit budget: `params * (bits / 8) * 1.1` (includes 10% load/tensor overhead).
    public var weightsWithOverheadBytes: UInt64 {
        if isSystemModel { return 0 }
        let scaled = Double(rawWeightBytes) * 1.1 + Double(auxiliaryWeightBytes)
        return UInt64(max(0, scaled.rounded()))
    }

    /// Active bytes read from unified memory per generated token (handles MoE active vs total params).
    public var activeWeightBytesPerStep: UInt64 {
        if isSystemModel { return 1_200_000_000 }
        guard let total = totalParamBillions, total > 0,
              let active = activeParamBillions, active > 0, active < total else {
            return rawWeightBytes
        }
        let ratio = min(1.0, max(0.05, active / total))
        return UInt64(max(1, (Double(rawWeightBytes) * ratio).rounded()))
    }

    /// True when exact attention layer / KV head / head dimension metadata is present.
    public var hasExactKVMetadata: Bool {
        attentionLayerCount != nil && kvHeadCount != nil && keyLength != nil
    }

    /// KV cache bytes per token: `2 * layers * kv_heads * head_dim * bytes_per_element`
    /// (supports asymmetric `key_length` + `value_length`, FP16 = 2B or Q4_0 = 18/32B).
    public var kvBytesPerToken: UInt64 {
        if isSystemModel { return 0 }
        let resolved: (layers: Int, heads: Int, keyDim: Int, valDim: Int)
        if let layers = attentionLayerCount, let heads = kvHeadCount, let keyDim = keyLength {
            resolved = (max(0, layers), max(0, heads), max(0, keyDim), max(0, valueLength ?? keyDim))
        } else {
            resolved = Self.heuristicKVDimensions(paramBillions: totalParamBillions ?? 2.0)
        }
        let values = UInt64(resolved.layers) * UInt64(resolved.heads) * UInt64(resolved.keyDim + resolved.valDim)
        if quantizedKV {
            return (values * 18 + 31) / 32
        }
        return values * 2
    }

    public var recurrentStateTotalBytes: UInt64 {
        guard let layerCount, let attentionLayerCount, layerCount > attentionLayerCount else { return 0 }
        return UInt64(layerCount - attentionLayerCount) * ssmStateBytesPerLinearLayer
    }

    /// Reasonable fallback KV geometry when only parameter scale is known (e.g., HF trending summary).
    private static func heuristicKVDimensions(paramBillions: Double) -> (Int, Int, Int, Int) {
        switch paramBillions {
        case ..<1.5: return (24, 2, 64, 64)
        case ..<3.5: return (28, 4, 128, 128)
        case ..<6.0: return (36, 4, 128, 128)
        case ..<12.0: return (36, 8, 128, 128)
        default: return (48, 8, 128, 128)
        }
    }

    public static func from(header: GGUFHeader, id: String, name: String, weightBytes: UInt64, quantLabel: String = "GGUF") -> ModelFitInput {
        let bits = bitsPerWeight(fromQuantLabel: quantLabel, fileType: header.fileType)
        let linearLayers = max(0, header.layerCount - header.attentionLayerCount)
        let ssmBytes: UInt64
        if linearLayers > 0 {
            let state = UInt64(max(0, header.ssmInnerSize)) * UInt64(max(0, header.ssmStateSize)) * 4
            let conv = UInt64(max(0, header.ssmConvKernel)) * UInt64(max(0, header.ssmInnerSize)) * 4
            ssmBytes = state + conv
        } else {
            ssmBytes = 0
        }
        let estimatedParams = Double(weightBytes) / ((bits / 8.0) * 1_000_000_000.0)
        return ModelFitInput(
            id: id,
            name: name,
            totalParamBillions: max(0.1, estimatedParams),
            activeParamBillions: nil,
            bitsPerWeight: bits,
            exactWeightBytes: weightBytes,
            auxiliaryWeightBytes: 0,
            layerCount: header.layerCount,
            attentionLayerCount: header.attentionLayerCount,
            kvHeadCount: header.kvHeadCount,
            keyLength: header.keyLength,
            valueLength: header.valueLength,
            ssmStateBytesPerLinearLayer: ssmBytes,
            maxContextLength: header.contextLength,
            quantizedKV: false,
            quantLabel: quantLabel,
            preferredRuntime: .llamaCpp,
            supportsMLXVariant: false,
            isSystemModel: false
        )
    }

    public static func bitsPerWeight(fromQuantLabel label: String, fileType: UInt32? = nil) -> Double {
        let upper = label.uppercased()
        if upper.contains("Q2") || upper.contains("IQ2") || upper.contains("2BIT") { return 2.5 }
        if upper.contains("Q3") || upper.contains("IQ3") || upper.contains("3BIT") { return 3.4 }
        if upper.contains("Q4") || upper.contains("IQ4") || upper.contains("4BIT") { return 4.5 }
        if upper.contains("Q5") { return 5.5 }
        if upper.contains("Q6") { return 6.5 }
        if upper.contains("Q8") || upper.contains("8BIT") { return 8.5 }
        if upper.contains("F16") || upper.contains("FP16") || upper.contains("BF16") { return 16.0 }
        if let fileType {
            switch fileType {
            case 1: return 16.0
            case 7: return 8.5
            case 10, 11, 12: return 3.4
            case 15, 2: return 4.5
            default: break
            }
        }
        return 4.5
    }
}

public enum ModelFitTier: String, Equatable, Sendable {
    case comfortable
    case tight
    case tooLarge
}

/// Output of the 4-part hardware fit & speed estimator.
public struct ModelFitResult: Equatable, Sendable {
    public let fits: Bool
    public let tier: ModelFitTier
    public let selectedContext: UInt32
    public let weightsWithOverheadBytes: UInt64
    public let kvCacheBytes: UInt64
    public let requiredBytes: UInt64
    public let budgetBytes: UInt64
    public let predictedTokensPerSecond: Double
    public let recommendedRuntime: InferenceRuntimeKind
    public let alternativeRuntime: InferenceRuntimeKind?
    public let isApproximate: Bool
    public let reasonNotFitting: String?
}

/// Estimates memory fit, KV cache footprint, runtime choice, and bandwidth-bound decode speed.
public enum ModelFitEstimator {
    private static let candidateContexts: [UInt32] = [32_768, 16_384, 8_192, 4_096, 2_048]
    /// Conservative runtime compute-graph & scratch headroom outside the 10% weight margin.
    public static let runtimeScratchBytes: UInt64 = 256_000_000
    /// Assumed warm context tokens read during decode speed estimation.
    private static let assumedDecodeContextTokens: UInt64 = 1_024

    public static func evaluate(
        _ input: ModelFitInput,
        on hardware: HardwareProfile,
        targetContext: UInt32 = 8_192,
        thermal: ThermalLevel = .nominal
    ) -> ModelFitResult {
        let runtime = chooseRuntime(for: input, on: hardware)
        let altRuntime: InferenceRuntimeKind? = (runtime == .llamaCpp && input.supportsMLXVariant && hardware.supportsMLX)
            ? .mlx
            : (runtime == .mlx ? .llamaCpp : nil)

        if input.isSystemModel {
            let speed = predictTokensPerSecond(input: input, on: hardware, runtime: .appleOnDevice, thermal: thermal)
            let available = hardware.supportsAppleIntelligence
            return ModelFitResult(
                fits: available,
                tier: available ? .comfortable : .tooLarge,
                selectedContext: 4_096,
                weightsWithOverheadBytes: 0,
                kvCacheBytes: 0,
                requiredBytes: 0,
                budgetBytes: hardware.usableMemoryBytes,
                predictedTokensPerSecond: available ? speed : 0,
                recommendedRuntime: .appleOnDevice,
                alternativeRuntime: nil,
                isApproximate: true,
                reasonNotFitting: available ? nil : "Apple on-device intelligence is unavailable on this device."
            )
        }

        let budget = hardware.usableMemoryBytes
        let cappedTarget = min(max(DeviceMemoryGate.minimumAgentContext, targetContext), input.maxContextLength)
        let weightsOverhead = input.weightsWithOverheadBytes
        let recurrent = input.recurrentStateTotalBytes
        let kvPerToken = input.kvBytesPerToken

        func totalRequired(context: UInt32) -> (total: UInt64, kv: UInt64) {
            let kv = UInt64(context) * kvPerToken
            let total = weightsOverhead + kv + recurrent + runtimeScratchBytes
            return (total, kv)
        }

        var chosenContext: UInt32?
        var chosenTotal: UInt64 = 0
        var chosenKV: UInt64 = 0

        let targetReq = totalRequired(context: cappedTarget)
        if targetReq.total <= budget {
            chosenContext = cappedTarget
            chosenTotal = targetReq.total
            chosenKV = targetReq.kv
        } else {
            for candidate in candidateContexts where candidate < cappedTarget && candidate >= DeviceMemoryGate.minimumAgentContext {
                let req = totalRequired(context: candidate)
                if req.total <= budget {
                    chosenContext = candidate
                    chosenTotal = req.total
                    chosenKV = req.kv
                    break
                }
            }
        }

        let speed = predictTokensPerSecond(input: input, on: hardware, runtime: runtime, thermal: thermal)

        if let context = chosenContext {
            let headroomRatio = Double(budget - chosenTotal) / Double(max(1, budget))
            let tier: ModelFitTier = headroomRatio >= 0.12 && context >= min(8_192, cappedTarget) ? .comfortable : .tight
            return ModelFitResult(
                fits: true,
                tier: tier,
                selectedContext: context,
                weightsWithOverheadBytes: weightsOverhead,
                kvCacheBytes: chosenKV,
                requiredBytes: chosenTotal,
                budgetBytes: budget,
                predictedTokensPerSecond: speed,
                recommendedRuntime: runtime,
                alternativeRuntime: altRuntime,
                isApproximate: !input.hasExactKVMetadata,
                reasonNotFitting: nil
            )
        }

        let minReq = totalRequired(context: DeviceMemoryGate.minimumAgentContext)
        let reason = "Needs about \(formatGB(minReq.total)) at minimum conversation room; \(hardware.shortDeviceName) gives apps about \(formatGB(budget))."
        return ModelFitResult(
            fits: false,
            tier: .tooLarge,
            selectedContext: DeviceMemoryGate.minimumAgentContext,
            weightsWithOverheadBytes: weightsOverhead,
            kvCacheBytes: minReq.kv,
            requiredBytes: minReq.total,
            budgetBytes: budget,
            predictedTokensPerSecond: 0,
            recommendedRuntime: runtime,
            alternativeRuntime: altRuntime,
            isApproximate: !input.hasExactKVMetadata,
            reasonNotFitting: reason
        )
    }

    public static func chooseRuntime(for input: ModelFitInput, on hardware: HardwareProfile) -> InferenceRuntimeKind {
        if input.isSystemModel { return .appleOnDevice }
        if input.preferredRuntime == .mlx && hardware.supportsMLX { return .mlx }
        if input.preferredRuntime == .appleOnDevice && hardware.supportsAppleIntelligence { return .appleOnDevice }
        return .llamaCpp
    }

    /// Memory-bandwidth ceiling: `tok/s ≈ (bandwidth * efficiency * thermalFactor) / bytesPerTokenRead`.
    public static func predictTokensPerSecond(
        input: ModelFitInput,
        on hardware: HardwareProfile,
        runtime: InferenceRuntimeKind,
        thermal: ThermalLevel = .nominal
    ) -> Double {
        let thermalFactor: Double
        switch thermal {
        case .nominal: thermalFactor = 1.0
        case .fair: thermalFactor = 0.90
        case .serious: thermalFactor = 0.65
        case .critical: return 0.0
        }

        let bandwidthBytesPerSec = hardware.memoryBandwidthGBps * 1_000_000_000.0
        let kvReadBytes = Double(input.kvBytesPerToken) * Double(assumedDecodeContextTokens)
        let bytesPerTokenRead = max(50_000_000.0, Double(input.activeWeightBytesPerStep) + kvReadBytes)
        let raw = (bandwidthBytesPerSec * runtime.baselineBandwidthEfficiency * thermalFactor) / bytesPerTokenRead
        return max(0.5, raw)
    }

    public static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
    }
}
