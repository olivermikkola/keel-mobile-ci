import XCTest
import SwiftUI
@testable import KeelMobile

@MainActor
final class ForegroundLifecycleTests: XCTestCase {
    func testInactiveOverlayKeepsReplyAndBackgroundStopsBothModes() async throws {
        for director in [false, true] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let chat = LocalChat(transcript: file, generator: SuspendedLifecycleModel())
            let snapshot = RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main",
                                              commit: String(repeating: "a", count: 40), tree: String(repeating: "b", count: 40))
            XCTAssertTrue(chat.attach(snapshot))
            XCTAssertTrue(chat.setDirectorMode(director))
            chat.send("Keep my reply", model: LocalModel.catalog[0], path: file)
            XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
            for _ in 0..<500 {
                if chat.messages.last?.text == "Saved partial" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(chat.messages.last?.text, "Saved partial")
            chat.sceneDidChange(.inactive)
            XCTAssertTrue(chat.running, "Control Center must not cancel either mode")
            XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
            chat.sceneDidChange(.active)
            XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
            chat.sceneDidChange(.background)
            XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
            for _ in 0..<500 {
                if !chat.running { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(chat.running, "Director must stop too; there is no background scheduler")
            XCTAssertTrue(chat.error?.contains("stops when you leave") == true)
            let restored = LocalChat(transcript: file)
            XCTAssertFalse(restored.running)
            XCTAssertEqual(restored.messages.last?.text, "Saved partial")
            XCTAssertTrue(restored.messages.last?.note?.contains("partial reply") == true)
        }
        print("Foreground lifecycle proof: real LocalChat cancellation, inactive/active transitions, idle timer restoration, saved partial reply and relaunch in both modes. Scripted model; no device suspension claim.")
    }

    func testCompletionAndExplicitStopRestoreIdleTimer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file, generator: SuspendedLifecycleModel(finish: true))
        chat.send("Reply", model: LocalModel.catalog[0], path: file)
        for _ in 0..<500 {
            if !chat.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(chat.running)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        let stopped = LocalChat(transcript: file, generator: SuspendedLifecycleModel())
        stopped.send("Stop", model: LocalModel.catalog[0], path: file)
        stopped.stop()
        for _ in 0..<500 {
            if !stopped.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(stopped.running)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func testRelaunchMarksRequestedAndExecutingAsInterruptedWithoutReplay() throws {
        let snapshot = RepositorySnapshot(repository: try RepositoryID("owner/repo"), branch: "main",
                                          commit: String(repeating: "a", count: 40), tree: String(repeating: "b", count: 40))
        let archive = SavedTasks(task: SavedTask(messages: [
            ChatMessage(role: "assistant", text: "<tool_call>", note: "Requested", isToolCall: true),
            ChatMessage(role: "tool", text: "", note: "Executing…")
        ], repository: snapshot))
        let restored = try SavedTasks.load(JSONEncoder().encode(archive))
        XCTAssertEqual(restored.tasks[0].messages.map(\.note), ["Interrupted", "Interrupted"])
        XCTAssertEqual(restored.tasks[0].messages.last?.text, "Request interrupted; no result was obtained.")
        XCTAssertEqual(restored.tasks[0].status, "Stopped")
    }
}

private actor SuspendedLifecycleModel: LocalGenerating {
    let finish: Bool
    init(finish: Bool = false) { self.finish = finish }
    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        onText("Saved partial")
        if !finish { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        return 2
    }
}
