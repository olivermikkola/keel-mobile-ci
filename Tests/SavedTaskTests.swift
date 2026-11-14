import XCTest
@testable import KeelMobile

@MainActor
final class SavedTaskTests: XCTestCase {
    private func snapshot(_ name: String) throws -> RepositorySnapshot {
        RepositorySnapshot(repository: try RepositoryID(name), branch: "main",
                           commit: String(repeating: "a", count: 40), tree: String(repeating: "b", count: 40))
    }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
    }

    func testNewTaskRetainsConversationsAndPinnedRepositoriesAcrossRelaunch() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = TaskReplyModel()
        let chat = LocalChat(transcript: file, generator: model)
        let first = chat.activeTaskID
        chat.send("Explain this error", model: LocalModel.catalog[0], path: file)
        try await finish(chat)
        XCTAssertEqual(chat.activeTitle, "Explain this error")
        XCTAssertTrue(chat.newChat())
        let second = chat.activeTaskID
        XCTAssertTrue(chat.attach(try snapshot("other/project")))
        XCTAssertTrue(chat.renameTask(second, title: "Review the parser"))
        XCTAssertTrue(chat.selectTask(first))
        XCTAssertEqual(chat.messages.last?.text, "A saved answer")
        XCTAssertNil(chat.repository)
        let restored = LocalChat(transcript: file, generator: model)
        XCTAssertEqual(restored.activeTaskID, first)
        XCTAssertEqual(restored.tasks.count, 2)
        XCTAssertTrue(restored.selectTask(second))
        XCTAssertEqual(restored.activeTitle, "Review the parser")
        XCTAssertEqual(restored.repository, try snapshot("other/project"))
        XCTAssertTrue(restored.messages.isEmpty)
        let calls = await model.calls
        XCTAssertEqual(calls, 1, "Opening and restoring tasks must not replay inference")
        print("Saved tasks proof: real protected-file save, two independent tasks, pinned repository, rename, switch, relaunch; no replay. Model response is a control-flow fixture.")
    }

    func testDeleteOnlyChosenTaskAndKeepLastTaskUsable() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file)
        let first = chat.activeTaskID
        XCTAssertTrue(chat.attach(try snapshot("owner/first")))
        XCTAssertTrue(chat.newChat())
        let second = chat.activeTaskID
        XCTAssertTrue(chat.attach(try snapshot("owner/second")))
        XCTAssertTrue(chat.deleteTask(first))
        let restored = LocalChat(transcript: file)
        XCTAssertEqual(restored.tasks.map(\.id), [second])
        XCTAssertEqual(restored.repository, try snapshot("owner/second"))
        XCTAssertTrue(restored.deleteTask(second))
        let final = LocalChat(transcript: file)
        XCTAssertEqual(final.tasks.count, 1)
        XCTAssertNotEqual(final.activeTaskID, second)
        XCTAssertNil(final.repository)
    }

    func testEditProposalModeBelongsToTheTaskAndRestoresWithoutReplay() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = TaskReplyModel()
        let chat = LocalChat(transcript: file, generator: model)
        let first = chat.activeTaskID
        XCTAssertFalse(chat.setDirectorMode(true), "A repository is required for edit proposals")
        XCTAssertTrue(chat.attach(try snapshot("owner/first")))
        XCTAssertTrue(chat.setDirectorMode(true))
        XCTAssertTrue(chat.newChat())
        let second = chat.activeTaskID
        XCTAssertFalse(chat.directorMode)
        XCTAssertTrue(chat.attach(try snapshot("owner/second")))
        XCTAssertTrue(chat.selectTask(first))
        XCTAssertTrue(chat.directorMode)
        XCTAssertTrue(chat.selectTask(second))
        XCTAssertFalse(chat.directorMode)

        let restored = LocalChat(transcript: file, generator: model)
        XCTAssertFalse(restored.directorMode)
        XCTAssertTrue(restored.selectTask(first))
        XCTAssertTrue(restored.directorMode)
        XCTAssertTrue(restored.setDirectorMode(false))
        XCTAssertFalse(LocalChat(transcript: file).directorMode)
        XCTAssertTrue(restored.selectTask(second))
        XCTAssertTrue(restored.setDirectorMode(true))
        XCTAssertTrue(restored.deleteTask(first))
        XCTAssertTrue(restored.directorMode)
        XCTAssertTrue(restored.deleteTask(second))
        XCTAssertFalse(restored.directorMode)
        let calls = await model.calls
        XCTAssertEqual(calls, 0, "Restoring a mode cannot start inference or replay tools")
    }

    func testLegacyArchiveWithoutModeStaysOffAndIsNotRewrittenOnLoad() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let archive = SavedTasks(task: SavedTask(repository: try snapshot("owner/repo")))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var tasks = try XCTUnwrap(value["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "editProposalsEnabled"); value["tasks"] = tasks
        let original = try JSONSerialization.data(withJSONObject: value)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: file)
        let restored = LocalChat(transcript: file)
        XCTAssertFalse(restored.storageUnreadable)
        XCTAssertFalse(restored.directorMode)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedModeSaveKeepsVisibleModeAndTaskSettingUnchanged() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file)
        XCTAssertTrue(chat.attach(try snapshot("owner/repo")))
        // Replace only this test's archive with a directory to force the real
        // atomic write to fail. No permissions or production paths are changed.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(chat.setDirectorMode(true))
        XCTAssertFalse(chat.directorMode)
        XCTAssertEqual(chat.tasks[0].editProposalsEnabled, false)
        XCTAssertNotNil(chat.error)
    }

    func testVersionOneMigrationRetainsInterruptedToolContextAndOriginalUntilSave() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct Legacy: Encodable { let version = 1; let messages: [ChatMessage]; let repository: RepositorySnapshot }
        let legacy = Legacy(messages: [ChatMessage(role: "user", text: "Read the parser"),
                                       ChatMessage(role: "tool", text: "", note: "Reading…")], repository: try snapshot("owner/project"))
        let original = try JSONEncoder().encode(legacy); try original.write(to: file)
        let migrated = LocalChat(transcript: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(migrated.messages.last?.note, "Interrupted")
        XCTAssertFalse(migrated.running)
        XCTAssertTrue(migrated.newChat())
        let restored = LocalChat(transcript: file)
        XCTAssertEqual(restored.tasks.count, 2)
        XCTAssertTrue(restored.selectTask(migrated.tasks[0].id))
        XCTAssertEqual(restored.repository, legacy.repository)
        XCTAssertEqual(restored.messages.last?.text, "Request interrupted; no result was obtained.")
    }

    func testCorruptArchiveRequiresExplicitResetAndKeepsRecoveryBytes() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unreadable history".utf8); try original.write(to: file)
        let chat = LocalChat(transcript: file)
        XCTAssertTrue(chat.storageUnreadable)
        XCTAssertFalse(chat.newChat())
        XCTAssertFalse(chat.deleteTask(chat.activeTaskID))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(chat.resetUnreadableStorage())
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unreadable-tasks-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertFalse(LocalChat(transcript: file).storageUnreadable)
    }

    func testRejectedStorageAndInvalidArchiveCannotSilentlyDropTasks() throws {
        let folder = file().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a directory".utf8).write(to: folder)
        let chat = LocalChat(transcript: folder.appendingPathComponent("chat.json"))
        let originalID = chat.activeTaskID
        XCTAssertFalse(chat.newChat())
        XCTAssertEqual(chat.tasks.count, 1); XCTAssertEqual(chat.activeTaskID, originalID)
        var archive = SavedTasks()
        archive.tasks.append(archive.tasks[0])
        XCTAssertThrowsError(try SavedTasks.load(JSONEncoder().encode(archive)))
        archive.tasks.removeLast(); archive.activeID = UUID()
        XCTAssertThrowsError(try SavedTasks.load(JSONEncoder().encode(archive)))
    }

    func testCannotSwitchRenameOrDeleteDuringReply() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: file, generator: TaskReplyModel(wait: true))
        let first = chat.activeTaskID
        XCTAssertTrue(chat.newChat())
        let active = chat.activeTaskID
        XCTAssertTrue(chat.attach(try snapshot("owner/repo")))
        chat.send("Keep this task", model: LocalModel.catalog[0], path: file)
        XCTAssertTrue(chat.running)
        XCTAssertFalse(chat.newChat()); XCTAssertFalse(chat.selectTask(first))
        XCTAssertFalse(chat.renameTask(active, title: "Changed")); XCTAssertFalse(chat.deleteTask(active))
        XCTAssertFalse(chat.setDirectorMode(true)); XCTAssertFalse(chat.directorMode)
        chat.stop(); try await finish(chat)
        XCTAssertEqual(chat.activeTaskID, active)
        XCTAssertEqual(chat.messages.first?.text, "Keep this task")
    }

    func testInconsistentPublishRecordIsDroppedWithoutLosingTheTask() throws {
        let snapshot = try snapshot("owner/repo")
        let bad = PublishState(
            branch: "keel/task-12345678", baseCommit: snapshot.commit, baseTree: snapshot.tree,
            workflowID: 1, workflowName: "CI", paths: ["README.md"],
            commit: String(repeating: "c", count: 40), runID: 9,
            runURL: "https://github.com/owner/repo/actions/runs/9",
            conclusion: "failure", prURL: "https://github.com/owner/repo/pull/9",
            updatedAt: Date())
        var task = SavedTask(title: "Keep this task", messages: [], repository: snapshot)
        task.publish = bad
        let restored = try SavedTasks.load(JSONEncoder().encode(SavedTasks(task: task)))
        XCTAssertEqual(restored.tasks.count, 1)
        XCTAssertNil(restored.tasks[0].publish, "A PR URL must never survive without a green exact-commit run")
        XCTAssertEqual(restored.tasks[0].repository, snapshot)
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<500 {
            if !chat.running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Reply did not finish")
    }
}

private actor TaskReplyModel: LocalGenerating {
    let wait: Bool
    private(set) var calls = 0
    init(wait: Bool = false) { self.wait = wait }
    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        calls += 1
        if wait { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        onText("A saved answer"); return 4
    }
}
