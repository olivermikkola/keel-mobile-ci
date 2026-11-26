import Foundation

/// Key identifying a speed calibration bucket: per-chip, per-runtime, per-quant, per-thermal-state.
public struct SpeedCalibrationKey: Codable, Equatable, Hashable, Sendable {
    public let chipID: String
    public let runtime: InferenceRuntimeKind
    public let quantBucket: String
    public let thermalLevel: ThermalLevel

    public init(
        chipID: String,
        runtime: InferenceRuntimeKind,
        quantBucket: String,
        thermalLevel: ThermalLevel
    ) {
        self.chipID = chipID.lowercased()
        self.runtime = runtime
        self.quantBucket = Self.normalizeQuantBucket(quantBucket)
        self.thermalLevel = thermalLevel
    }

    public static func normalizeQuantBucket(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper.contains("SYSTEM") || upper.contains("APPLE") || upper.contains("BUILT INTO") { return "system" }
        if upper.contains("Q2") || upper.contains("IQ2") || upper.contains("2BIT") || upper.contains("2-BIT") { return "2bit" }
        if upper.contains("Q3") || upper.contains("IQ3") || upper.contains("3BIT") || upper.contains("3-BIT") { return "3bit" }
        if upper.contains("Q4") || upper.contains("IQ4") || upper.contains("4BIT") || upper.contains("4-BIT") { return "4bit" }
        if upper.contains("Q5") || upper.contains("5BIT") || upper.contains("5-BIT") { return "5bit" }
        if upper.contains("Q6") || upper.contains("6BIT") || upper.contains("6-BIT") { return "6bit" }
        if upper.contains("Q8") || upper.contains("8BIT") || upper.contains("8-BIT") { return "8bit" }
        if upper.contains("F16") || upper.contains("FP16") || upper.contains("BF16") { return "16bit" }
        return "4bit"
    }
}

/// Learned correction coefficient for a calibration bucket.
public struct SpeedCalibrationEntry: Codable, Equatable, Sendable {
    public let key: SpeedCalibrationKey
    public var multiplier: Double
    public var sampleCount: Int
    public var lastObservedTokensPerSecond: Double
    public var peakFootprintBytes: UInt64?
    public var lastUpdated: Date
}

/// A real measured inference run logged to refine future estimates.
public struct SpeedObservation: Equatable, Sendable {
    public let chipID: String
    public let runtime: InferenceRuntimeKind
    public let quantBucket: String
    public let thermalLevel: ThermalLevel
    public let predictedTokensPerSecond: Double
    public let actualTokensPerSecond: Double
    public let decodedTokens: Int
    public let decodeDuration: TimeInterval
    public let footprintBytes: UInt64?
    public let timestamp: Date

    public init(
        chipID: String,
        runtime: InferenceRuntimeKind,
        quantBucket: String,
        thermalLevel: ThermalLevel,
        predictedTokensPerSecond: Double,
        actualTokensPerSecond: Double,
        decodedTokens: Int = 16,
        decodeDuration: TimeInterval = 1.0,
        footprintBytes: UInt64? = nil,
        timestamp: Date = Date()
    ) {
        self.chipID = chipID
        self.runtime = runtime
        self.quantBucket = quantBucket
        self.thermalLevel = thermalLevel
        self.predictedTokensPerSecond = predictedTokensPerSecond
        self.actualTokensPerSecond = actualTokensPerSecond
        self.decodedTokens = decodedTokens
        self.decodeDuration = decodeDuration
        self.footprintBytes = footprintBytes
        self.timestamp = timestamp
    }
}

/// Speed prediction after applying any learned per-device correction coefficient.
public struct CalibratedSpeed: Equatable, Sendable {
    public let tokensPerSecond: Double
    public let isMeasured: Bool
    public let sampleCount: Int
    public let multiplier: Double
}

/// Self-calibrating speed correction store that learns per-chip, per-runtime,
/// per-quant, and per-thermal-state correction multipliers from real runs.
public struct SpeedCalibrationStore: Codable, Equatable, Sendable {
    public static let minMultiplier = 0.20
    public static let maxMultiplier = 2.50
    public static let emaAlpha = 0.35
    public static let minimumSampleTokens = 4
    public static let minimumSampleDuration: TimeInterval = 0.05

    public private(set) var entries: [SpeedCalibrationEntry] = []

    public init(entries: [SpeedCalibrationEntry] = []) {
        self.entries = entries
    }

    public var totalSamples: Int {
        entries.reduce(0) { $0 + $1.sampleCount }
    }

    /// Records a real inference run and updates the matching calibration coefficient.
    @discardableResult
    public mutating func record(_ observation: SpeedObservation) -> Bool {
        guard observation.decodedTokens >= Self.minimumSampleTokens,
              observation.decodeDuration >= Self.minimumSampleDuration,
              observation.predictedTokensPerSecond.isFinite, observation.predictedTokensPerSecond > 0.1,
              observation.actualTokensPerSecond.isFinite, observation.actualTokensPerSecond > 0.1 else {
            return false
        }

        let rawRatio = observation.actualTokensPerSecond / observation.predictedTokensPerSecond
        let clampedRatio = min(Self.maxMultiplier, max(Self.minMultiplier, rawRatio))
        let key = SpeedCalibrationKey(
            chipID: observation.chipID,
            runtime: observation.runtime,
            quantBucket: observation.quantBucket,
            thermalLevel: observation.thermalLevel
        )

        if let index = entries.firstIndex(where: { $0.key == key }) {
            var entry = entries[index]
            entry.multiplier = (1.0 - Self.emaAlpha) * entry.multiplier + Self.emaAlpha * clampedRatio
            entry.multiplier = min(Self.maxMultiplier, max(Self.minMultiplier, entry.multiplier))
            entry.sampleCount += 1
            entry.lastObservedTokensPerSecond = observation.actualTokensPerSecond
            if let footprint = observation.footprintBytes {
                entry.peakFootprintBytes = max(entry.peakFootprintBytes ?? 0, footprint)
            }
            entry.lastUpdated = observation.timestamp
            entries[index] = entry
        } else {
            entries.append(SpeedCalibrationEntry(
                key: key,
                multiplier: clampedRatio,
                sampleCount: 1,
                lastObservedTokensPerSecond: observation.actualTokensPerSecond,
                peakFootprintBytes: observation.footprintBytes,
                lastUpdated: observation.timestamp
            ))
        }
        return true
    }

    /// Applies the most specific learned multiplier available for this device, runtime, quant, and thermal state.
    public func calibratedSpeed(
        predicted: Double,
        chipID: String,
        runtime: InferenceRuntimeKind,
        quantBucket: String,
        thermalLevel: ThermalLevel = .nominal
    ) -> CalibratedSpeed {
        guard predicted.isFinite, predicted > 0 else {
            return CalibratedSpeed(tokensPerSecond: 0, isMeasured: false, sampleCount: 0, multiplier: 1.0)
        }
        let targetKey = SpeedCalibrationKey(
            chipID: chipID,
            runtime: runtime,
            quantBucket: quantBucket,
            thermalLevel: thermalLevel
        )

        if let exact = entries.first(where: { $0.key == targetKey }) {
            return CalibratedSpeed(
                tokensPerSecond: max(0.5, predicted * exact.multiplier),
                isMeasured: true,
                sampleCount: exact.sampleCount,
                multiplier: exact.multiplier
            )
        }

        let sameQuant = entries.filter {
            $0.key.chipID == targetKey.chipID
                && $0.key.runtime == targetKey.runtime
                && $0.key.quantBucket == targetKey.quantBucket
        }
        if let aggregated = aggregate(sameQuant) {
            return CalibratedSpeed(
                tokensPerSecond: max(0.5, predicted * aggregated.multiplier),
                isMeasured: true,
                sampleCount: aggregated.samples,
                multiplier: aggregated.multiplier
            )
        }

        let sameRuntime = entries.filter {
            $0.key.chipID == targetKey.chipID && $0.key.runtime == targetKey.runtime
        }
        if let aggregated = aggregate(sameRuntime) {
            return CalibratedSpeed(
                tokensPerSecond: max(0.5, predicted * aggregated.multiplier),
                isMeasured: true,
                sampleCount: aggregated.samples,
                multiplier: aggregated.multiplier
            )
        }

        let sameChip = entries.filter { $0.key.chipID == targetKey.chipID }
        if let aggregated = aggregate(sameChip) {
            return CalibratedSpeed(
                tokensPerSecond: max(0.5, predicted * aggregated.multiplier),
                isMeasured: true,
                sampleCount: aggregated.samples,
                multiplier: aggregated.multiplier
            )
        }

        return CalibratedSpeed(
            tokensPerSecond: max(0.5, predicted),
            isMeasured: false,
            sampleCount: 0,
            multiplier: 1.0
        )
    }

    private func aggregate(_ matching: [SpeedCalibrationEntry]) -> (multiplier: Double, samples: Int)? {
        guard !matching.isEmpty else { return nil }
        let total = matching.reduce(0) { $0 + $1.sampleCount }
        guard total > 0 else { return nil }
        let weighted = matching.reduce(0.0) { $0 + $1.multiplier * Double($1.sampleCount) } / Double(total)
        return (weighted, total)
    }

    public mutating func reset() {
        entries.removeAll()
    }

    public static func load(from url: URL) -> SpeedCalibrationStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(SpeedCalibrationStore.self, from: data) else {
            return SpeedCalibrationStore()
        }
        return store
    }

    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        #if os(Linux)
        try data.write(to: url, options: [.atomic])
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }
}
