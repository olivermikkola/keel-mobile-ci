import XCTest
import SwiftUI
import UserNotifications
@testable import KeelMobile

@MainActor
final class TaskNotificationTests: XCTestCase {
    func testScheduleBuildsSystemRequestAndReplacesOnlySameChat() async throws {
        var requests: [UNNotificationRequest] = []
        var removed: [String] = []
        let notifications = TaskNotifications(authorize: { true }, add: { requests.append($0) }, remove: { removed = $0 })
        let id = UUID()
        try await notifications.schedule(task: id, prompt: "Summarize my notes", at: Date().addingTimeInterval(3600))
        try await notifications.schedule(task: id, prompt: "Review my notes", at: Date().addingTimeInterval(7200))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].identifier, requests[1].identifier)
        XCTAssertEqual((requests[0].trigger as? UNTimeIntervalNotificationTrigger)?.repeats, false)
        XCTAssertEqual(try XCTUnwrap(requests[0].trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 3600, accuracy: 3)
        XCTAssertEqual(ScheduledTaskLaunch.decode(identifier: requests[1].identifier, userInfo: requests[1].content.userInfo)?.prompt, "Review my notes")
        XCTAssertNil(notifications.pending, "Scheduling must never start inference")
        notifications.cancel(task: id)
        XCTAssertEqual(removed, [requests[0].identifier])
    }

    func testDeniedInvalidAndExpiredDoNotAdd() async throws {
        var added = false
        let notifications = TaskNotifications(authorize: { false }, add: { _ in added = true })
        do { try await notifications.schedule(task: UUID(), prompt: "Task", at: Date().addingTimeInterval(60)); XCTFail() } catch { }
        XCTAssertFalse(added)
        XCTAssertThrowsError(try ScheduledTaskLaunch(taskID: UUID(), prompt: "   "))
        XCTAssertThrowsError(try ScheduledTaskLaunch(taskID: UUID(), prompt: String(repeating: "x", count: 16_385)))
        let launch = try ScheduledTaskLaunch(taskID: UUID(), prompt: "Task")
        XCTAssertThrowsError(try launch.request(at: Date().addingTimeInterval(-1)))
        XCTAssertNil(ScheduledTaskLaunch.decode(identifier: "unrelated", userInfo: ["task": launch.taskID.uuidString, "prompt": "Task"]))
    }

    func testTapWaitsForForegroundThenStartsCorrectSavedChatOnlyOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file, generator: NotificationTestModel())
        let target = chat.activeTaskID
        XCTAssertTrue(chat.newChat())
        let notifications = TaskNotifications()
        let request = try ScheduledTaskLaunch(taskID: target, prompt: "Scheduled prompt").request(at: Date().addingTimeInterval(60))
        notifications.receive(action: UNNotificationDismissActionIdentifier, identifier: request.identifier, userInfo: request.content.userInfo)
        XCTAssertNil(notifications.pending)
        notifications.receive(action: UNNotificationDefaultActionIdentifier, identifier: request.identifier, userInfo: request.content.userInfo)
        notifications.startPending(in: chat, model: LocalModel.catalog[0], path: file, active: false)
        XCTAssertFalse(chat.running)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNotNil(notifications.pending)
        notifications.startPending(in: chat, model: LocalModel.catalog[0], path: file, active: true)
        XCTAssertEqual(chat.activeTaskID, target)
        XCTAssertTrue(chat.running)
        XCTAssertEqual(chat.messages.first?.text, "Scheduled prompt")
        XCTAssertNil(notifications.pending)
        let count = chat.messages.count
        notifications.startPending(in: chat, model: LocalModel.catalog[0], path: file, active: true)
        XCTAssertEqual(chat.messages.count, count)
        chat.stop()
        print("Scheduled tap proof: real LocalChat selects persisted target, stays idle before foreground, sends once after activation. Scripted model; system delivery not simulated.")
    }

    func testFreshChatIdentityIsPersistedBeforeScheduling() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file)
        XCTAssertTrue(chat.prepareForScheduling(chat.activeTaskID))
        let restored = LocalChat(transcript: file)
        XCTAssertEqual(restored.activeTaskID, chat.activeTaskID)
        XCTAssertFalse(chat.prepareForScheduling(UUID()))
    }

    func testDeletedChatDoesNotLaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file, generator: NotificationTestModel())
        let notifications = TaskNotifications()
        notifications.pending = try ScheduledTaskLaunch(taskID: UUID(), prompt: "Task")
        notifications.startPending(in: chat, model: LocalModel.catalog[0], path: file, active: true)
        XCTAssertNil(notifications.pending)
        XCTAssertFalse(chat.running)
    }
}

private actor NotificationTestModel: LocalGenerating {
    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try await Task.sleep(for: .seconds(30)); return 0
    }
}
