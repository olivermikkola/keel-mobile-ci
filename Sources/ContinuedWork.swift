import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// One piece of work the user started that iOS lets run on after they leave
/// the app (iOS 26 and later). The system shows its progress on the Lock
/// Screen and in the Dynamic Island, where the user can also cancel it.
///
/// This covers work that needs the network or the processor: downloads,
/// imports, and a reply that is being written. No iPhone may use its graphics
/// processor in the background, so a reply that carries on moves to the CPU
/// (`InferencePlacement`) and is slower there.
@MainActor
protocol ContinuedWorkSession: AnyObject {
    /// True once iOS has accepted the work and is keeping the app running for it.
    var isRunning: Bool { get }
    func update(fraction: Double, subtitle: String)
    func finish(success: Bool)
}

enum ContinuedWork {
    /// Starts a session. `onExpire` runs if iOS or the user ends it early.
    /// Returns nil when the system has no such feature or refuses the request;
    /// the caller then falls back to the ordinary ~30 second grace period.
    typealias Starter = @MainActor (_ kind: Kind, _ title: String, _ subtitle: String,
                                    _ onExpire: @escaping @MainActor () -> Void) -> ContinuedWorkSession?

    enum Kind: String {
        case transfer
        /// A reply the model is writing, with its tool steps.
        case reply
        /// Listed in Info.plist as `<prefix>.*`; each job adds its own ending.
        var identifierPrefix: String { "com.olivermikkola.keelmobile." + rawValue }
    }

    static let system: Starter = { kind, title, subtitle, onExpire in
        #if compiler(>=6.2) && canImport(BackgroundTasks) && !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            return SystemContinuedWork.start(kind: kind, title: title, subtitle: subtitle, onExpire: onExpire)
        }
        #endif
        return nil
    }
}

#if compiler(>=6.2) && canImport(BackgroundTasks) && !targetEnvironment(simulator)
@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedWork: ContinuedWorkSession {
    private static let units: Int64 = 1_000
    private let title: String
    private var task: BGContinuedProcessingTask?
    private var latest: (fraction: Double, subtitle: String)?
    private var shown: (percent: Int, subtitle: String)?
    private var outcome: Bool?

    var isRunning: Bool { task != nil }

    private init(title: String) { self.title = title }

    static func start(kind: ContinuedWork.Kind, title: String, subtitle: String,
                      onExpire: @escaping @MainActor () -> Void) -> ContinuedWorkSession? {
        // The handler is registered for this exact identifier, then the same
        // identifier is submitted. Info.plist permits it through its wildcard.
        let identifier = kind.identifierPrefix + "." + UUID().uuidString
        let session = SystemContinuedWork(title: title)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                session.attach(task, onExpire: onExpire)
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // If iOS cannot start it now, do without rather than start it late.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return nil }
        return session
    }

    private func attach(_ task: BGContinuedProcessingTask, onExpire: @escaping @MainActor () -> Void) {
        // The work may already be over by the time iOS starts the task.
        if let outcome { task.setTaskCompleted(success: outcome); return }
        self.task = task
        task.progress.totalUnitCount = Self.units
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                onExpire()
                self?.finish(success: false)
            }
        }
        if let latest { update(fraction: latest.fraction, subtitle: latest.subtitle) }
    }

    func update(fraction: Double, subtitle: String) {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        latest = (clamped, subtitle)
        guard let task else { return }
        // Leave the last unit for `finish`, so the bar never reads done early.
        task.progress.completedUnitCount = min(Self.units - 1, Int64(clamped * Double(Self.units)))
        let percent = Int(clamped * 100)
        if shown?.percent != percent || shown?.subtitle != subtitle {
            shown = (percent, subtitle)
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func finish(success: Bool) {
        guard outcome == nil else { return }
        outcome = success
        guard let task else { return }
        self.task = nil
        if success { task.progress.completedUnitCount = Self.units }
        task.setTaskCompleted(success: success)
    }
}
#endif
