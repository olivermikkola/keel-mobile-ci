import Foundation
import UIKit
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Writes real measurements to a small log on this device and gathers the
/// facts for the phone report (`PhoneReport`). Nothing leaves the phone unless
/// the user shares the report.
enum PhoneMeasurements {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phone-measurements.json")
    }

    private static let lock = NSLock()

    static func record(_ kind: PhoneMeasurement.Kind, _ text: String, to url: URL = PhoneMeasurements.url) {
        lock.lock(); defer { lock.unlock() }
        var log = PhoneMeasurementLog.load(from: url)
        log.append(PhoneMeasurement(kind: kind, text: text))
        try? log.save(to: url)
    }

    static func clear(_ url: URL = PhoneMeasurements.url) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    @MainActor static func facts() -> PhoneFacts {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return PhoneFacts(machine: HardwareProfile.currentMachineIdentifier(),
                          system: "iOS \(UIDevice.current.systemVersion)",
                          memoryBytes: ProcessInfo.processInfo.physicalMemory,
                          freeDiskBytes: free,
                          thermal: thermal,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          appVersion: AboutView.appVersion())
    }

    @MainActor static func report(from url: URL = PhoneMeasurements.url) -> String {
        PhoneReport.text(facts: facts(), log: PhoneMeasurementLog.load(from: url))
    }
}
