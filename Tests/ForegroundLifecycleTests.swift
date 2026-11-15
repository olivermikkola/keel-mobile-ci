import XCTest
import SwiftUI
@testable import KeelMobile

@MainActor
final class ForegroundLifecycleTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil; StubProtocol.responseHeaders = nil
        super.tearDown()
    }

    private func offlineRepository(_ id: RepositoryID) throws -> GitHubRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try GitHubRepository(repository: id, token: "fixture-token", configuration: configuration)
    }

    func testInactiveOverlayKeepsReplyAndBackgroundStopsBothModes() async throws {
        // This tests lifecycle cancellation, not GitHub availability. Fail repository
        // preparation immediately so both modes reach the scripted streaming model.
        StubProtocol.handler = { _ in (404, Data()) }
        for director in [false, true] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let chat = LocalChat(transcript: file, generator: SuspendedLifecycleModel(), repositoryClient: offlineRepository)
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

    func testModelDownloadAndPublishHoldThirtySecondBackgroundGraceUntilExpirationOrCompletion() async throws {
        var begun: [(String, @MainActor () -> Void)] = []
        var ended: [BackgroundAllowance.Token] = []
        let allowance = BackgroundAllowance(
            begin: { name, expire in
                let token = BackgroundAllowance.Token(rawValue: begun.count + 1)
                begun.append((name, expire))
                return token
            },
            end: { ended.append($0) }
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "bg-grace-\(UUID().uuidString)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let models = ModelLibrary(directory: directory, defaults: defaults,
                                  transferConfiguration: { cfg }, backgroundAllowance: allowance)

        let holdExpectation = expectation(description: "download started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        StubProtocol.handler = { _ in
            holdExpectation.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (404, Data())
        }
        models.install(LocalModel.catalog[0])
        await fulfillment(of: [holdExpectation], timeout: 2.0)

        models.sceneDidChange(.background)
        XCTAssertTrue(models.isHoldingBackgroundGrace)
        XCTAssertEqual(begun.last?.0, "KeelModelTransfer")

        // When iOS expires the ~30s grace window before completion, the token must be ended cleanly.
        begun.last?.1()
        XCTAssertFalse(models.isHoldingBackgroundGrace)
        XCTAssertEqual(ended.count, 1)

        // Cancel also leaves the library idle without leaking a token.
        models.cancel()
        gate.signal()
        for _ in 0..<500 {
            if !models.isTransferring { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(models.downloading)
        XCTAssertFalse(models.isHoldingBackgroundGrace)

        // Check KeelLiveActivitySnapshot reflects active download state & progress.
        let dummyChat = LocalChat(transcript: directory.appendingPathComponent("chat.json"))
        let snap = KeelLiveActivitySnapshot(kind: .modelDownload, title: "Test", subtitle: "Downloading · 42%",
                                            progress: 0.42, isBackgroundGraceActive: true)
        XCTAssertEqual(snap.continuedProcessingIdentifier, KeelLiveActivitySnapshot.modelTransferTaskIdentifier)
        XCTAssertEqual(snap.compactTrailingText, "42%")
        XCTAssertEqual(KeelLiveActivitySnapshot.parsedPercentage(from: "Importing · 87%").map { Int(($0 * 100).rounded()) }, 87)
        XCTAssertNil(KeelLiveActivitySnapshot.current(models: models, chat: dummyChat))
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
