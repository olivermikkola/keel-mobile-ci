import Foundation

/// Thermal headroom tier mapped cleanly across platforms.
public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    #if !os(Linux)
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
    #endif
}

/// Thermal control action during prefill and token generation.
public enum ThermalDecision: Equatable, Sendable {
    case proceed
    /// Brief duty-cycle pause so the device cools at `.serious` without aborting the turn.
    case throttle(pauseNanoseconds: UInt64)
    case stop
}

/// Decides whether inference should run at full speed, throttle, or stop for critical heat.
public enum ThermalPolicy {
    public static let seriousPauseNanoseconds: UInt64 = 50_000_000
    public static let decodeThrottleInterval = 2

    public static func decision(for level: ThermalLevel, step: Int = 0) -> ThermalDecision {
        switch level {
        case .nominal, .fair:
            return .proceed
        case .serious:
            if step % decodeThrottleInterval == 0 {
                return .throttle(pauseNanoseconds: seriousPauseNanoseconds)
            }
            return .proceed
        case .critical:
            return .stop
        }
    }

    public static func currentDecision(step: Int = 0) -> ThermalDecision {
        #if !os(Linux)
        return decision(for: ThermalLevel(ProcessInfo.processInfo.thermalState), step: step)
        #else
        return .proceed
        #endif
    }
}
