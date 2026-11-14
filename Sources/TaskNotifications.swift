import SwiftUI
import UserNotifications

struct ScheduledTaskLaunch: Equatable {
    let taskID: UUID
    let prompt: String

    init(taskID: UUID, prompt: String) throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384 else { throw ScheduleError.prompt }
        self.taskID = taskID; self.prompt = text
    }

    static func decode(identifier: String, userInfo: [AnyHashable: Any]) -> Self? {
        guard let raw = userInfo["task"] as? String, let id = UUID(uuidString: raw),
              identifier == "keel.task." + id.uuidString, let prompt = userInfo["prompt"] as? String else { return nil }
        return try? Self(taskID: id, prompt: prompt)
    }

    func request(at date: Date, now: Date = Date()) throws -> UNNotificationRequest {
        guard date.timeIntervalSince(now) >= 1 else { throw ScheduleError.date }
        let content = UNMutableNotificationContent()
        content.title = "Your Keel task is ready"
        content.body = "Tap to open Keel and start your task."
        content.sound = .default
        content.userInfo = ["task": taskID.uuidString, "prompt": prompt]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSince(now), repeats: false)
        return UNNotificationRequest(identifier: "keel.task." + taskID.uuidString, content: content, trigger: trigger)
    }
}

enum ScheduleError: LocalizedError {
    case prompt, date, denied
    var errorDescription: String? {
        switch self {
        case .prompt: return "Enter a task of up to 16,384 bytes."
        case .date: return "Choose a future time."
        case .denied: return "Allow notifications for Keel in Settings to schedule a task."
        }
    }
}

@MainActor
final class TaskNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = TaskNotifications()
    @Published var pending: ScheduledTaskLaunch?
    private let authorize: () async throws -> Bool
    private let add: (UNNotificationRequest) async throws -> Void
    private let remove: ([String]) -> Void

    init(authorize: @escaping () async throws -> Bool = {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }, add: @escaping (UNNotificationRequest) async throws -> Void = {
        let center = UNUserNotificationCenter.current()
        try await center.add($0)
        center.removeDeliveredNotifications(withIdentifiers: [$0.identifier])
    }, remove: @escaping ([String]) -> Void = {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: $0)
        center.removeDeliveredNotifications(withIdentifiers: $0)
    }) {
        self.authorize = authorize; self.add = add; self.remove = remove
        super.init()
    }

    func schedule(task: UUID, prompt: String, at date: Date) async throws {
        let launch = try ScheduledTaskLaunch(taskID: task, prompt: prompt)
        _ = try launch.request(at: date)
        guard try await authorize() else { throw ScheduleError.denied }
        // Recheck after the permission sheet, which can stay open past the chosen time.
        try await add(launch.request(at: date))
    }

    func receive(action: String, identifier: String, userInfo: [AnyHashable: Any]) {
        guard action == UNNotificationDefaultActionIdentifier,
              let launch = ScheduledTaskLaunch.decode(identifier: identifier, userInfo: userInfo) else { return }
        pending = launch
    }

    func startPending(in chat: LocalChat, model: LocalModel, path: URL, active: Bool) {
        guard active, !chat.running, let launch = pending else { return }
        guard chat.tasks.contains(where: { $0.id == launch.taskID }) else {
            pending = nil; chat.error = "This scheduled chat no longer exists."; return
        }
        guard chat.selectTask(launch.taskID) else { return }
        pending = nil
        chat.send(launch.prompt, model: model, path: path)
    }

    func cancel(task: UUID) { remove(["keel.task." + task.uuidString]) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        Task { @MainActor in
            self.receive(action: action, identifier: identifier, userInfo: info)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Delivery only presents a banner. Only a default tap can enqueue a launch.
        completionHandler([.banner, .sound, .list])
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = TaskNotifications.shared
        return true
    }
}

struct ScheduleTaskView: View {
    let taskID: UUID
    let prompt: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var notifications: TaskNotifications
    @EnvironmentObject private var chat: LocalChat
    @State private var date = Date().addingTimeInterval(3600)
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt)
                    DatePicker("When", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("Keel will notify you at this time. Tap the notification to start while the app is open. One reminder per chat; scheduling again replaces it.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Schedule") {
                    guard chat.prepareForScheduling(taskID) else {
                        error = chat.error ?? "This chat could not be saved. Try again when it is idle."
                        return
                    }
                    saving = true
                    Task {
                        do {
                            try await notifications.schedule(task: taskID, prompt: prompt, at: date)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.disabled(saving).accessibilityIdentifier("confirmScheduleTask")
                Button("Cancel this chat’s reminder", role: .destructive) {
                    notifications.cancel(task: taskID); dismiss()
                }
            }
            .navigationTitle("Schedule task")
            .toolbar { Button("Close") { dismiss() }.disabled(saving) }
        }
    }
}
