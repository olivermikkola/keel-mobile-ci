import Foundation

/// One real measurement taken on this device: a chat reply's speed, a video's
/// step times, a picture's time or a benchmark result. Text only, no content
/// from the user's chats or photos.
public struct PhoneMeasurement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case chat, video, image, decide, benchmark

        public var heading: String {
            switch self {
            case .chat: return "Chat replies"
            case .video: return "Videos"
            case .image: return "Images"
            case .decide: return "Decide"
            case .benchmark: return "Benchmarks"
            }
        }
    }

    public let date: Date
    public let kind: Kind
    public let text: String

    public init(date: Date = Date(), kind: Kind, text: String) {
        self.date = date
        self.kind = kind
        self.text = text
    }
}

/// The last measurements, newest last, capped so the file stays small.
public struct PhoneMeasurementLog: Codable, Equatable, Sendable {
    public static let limit = 200
    /// Lines per kind in a report.
    public static let perKind = 12
    public private(set) var entries: [PhoneMeasurement] = []

    public init(entries: [PhoneMeasurement] = []) { self.entries = entries }

    public mutating func append(_ measurement: PhoneMeasurement) {
        let text = measurement.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        entries.append(PhoneMeasurement(date: measurement.date, kind: measurement.kind, text: String(text.prefix(300))))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    public static func load(from url: URL) -> PhoneMeasurementLog {
        guard let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder.phoneReport.decode(PhoneMeasurementLog.self, from: data) else { return PhoneMeasurementLog() }
        return log
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.phoneReport.encode(self).write(to: url, options: .atomic)
    }
}

/// What the report says about the device itself.
public struct PhoneFacts: Equatable, Sendable {
    public var machine: String
    public var system: String
    public var memoryBytes: UInt64
    public var freeDiskBytes: Int64?
    public var thermal: String
    public var lowPower: Bool
    public var appVersion: String

    public init(machine: String, system: String, memoryBytes: UInt64, freeDiskBytes: Int64?,
                thermal: String, lowPower: Bool, appVersion: String) {
        self.machine = machine
        self.system = system
        self.memoryBytes = memoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.thermal = thermal
        self.lowPower = lowPower
        self.appVersion = appVersion
    }
}

/// A plain-text report of the device and its latest measurements, made to be
/// pasted into a message so speed, memory and heat questions get real numbers.
public enum PhoneReport {
    public static func text(facts: PhoneFacts, log: PhoneMeasurementLog, made: Date = Date()) -> String {
        let gb = Double(facts.memoryBytes) / 1_073_741_824
        var lines = [
            "Keel phone report · \(stamp(made))",
            "Device: \(facts.machine) · \(facts.system) · \(String(format: "%.1f", gb)) GB memory",
            "App: \(facts.appVersion)",
            "Now: thermal \(facts.thermal)\(facts.lowPower ? " · Low Power Mode on" : "")"
                + (facts.freeDiskBytes.map { " · \(String(format: "%.1f", Double($0) / 1_000_000_000)) GB free" } ?? ""),
        ]
        for kind in PhoneMeasurement.Kind.allCases {
            let found = log.entries.filter { $0.kind == kind }.suffix(PhoneMeasurementLog.perKind)
            lines.append("")
            lines.append("\(kind.heading) (\(found.isEmpty ? "none yet" : "latest \(found.count)"))")
            for entry in found.reversed() { lines.append("- \(stamp(entry.date)) · \(entry.text)") }
        }
        return lines.joined(separator: "\n")
    }

    /// One line for a chat reply: model, runtime and its measured speeds.
    public static func chatLine(model: String, runtime: String, telemetry: InferenceTelemetry, thermal: String) -> String {
        var parts = ["\(model) · \(runtime)"]
        if let prefill = telemetry.prefillTokensPerSecond {
            parts.append("read \(telemetry.prefillTokens) tok at \(InferenceTelemetry.formatRate(prefill)) tok/s")
        }
        if telemetry.reusedTokens > 0 { parts.append("\(telemetry.reusedTokens) reused") }
        if let decode = telemetry.decodeTokensPerSecond {
            parts.append("wrote \(telemetry.decodedTokens) tok at \(InferenceTelemetry.formatRate(decode)) tok/s")
        }
        if let footprint = telemetry.footprintBytes { parts.append("memory \(InferenceTelemetry.formatMemory(footprint))") }
        parts.append("thermal \(thermal)")
        return parts.joined(separator: " · ")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension JSONEncoder {
    static var phoneReport: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

extension JSONDecoder {
    static var phoneReport: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
