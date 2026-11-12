#if DEBUG && targetEnvironment(simulator)
import Foundation

// An explicit, isolated pending proposal for native review UI tests. Approval
// still runs the real branch/blob checks using the recorded HTTP transport.
// It is absent from device builds and never claims real model generation.
enum FileEditUITestFixture {
    static func transcript() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--edit-review-fixture") else { return nil }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("edit-review-ui-fixture.json")
        if args.contains("--reset-edit-review-fixture") {
            struct Fixture: Encodable {
                let version = 1
                let messages: [ChatMessage]
                let repository: RepositorySnapshot
            }
            do {
                let snapshot = RepositorySnapshot(repository: try RepositoryID("octocat/Hello-World"), branch: "master",
                                                  commit: "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d",
                                                  tree: "b4eecafa9be2f2006ce1b709d6857b07069b4608")
                let proposal = try ProposedFileEdit(snapshot: snapshot, path: "README",
                                                    originalBlobSHA: "980a0d5f19a64b4b30a87d4206aade58726b60e3",
                                                    before: "Hello World!\n", oldText: "Hello World!", newText: "Hello Keel!")
                let record = TaskFileEdit(proposal: proposal)
                let fixture = Fixture(messages: [ChatMessage(role: "user", text: "Propose a new greeting"),
                                                 ChatMessage(role: "tool", text: record.observation, note: "Needs review", activity: "Propose edit · README", edit: record),
                                                 ChatMessage(role: "assistant", text: "Review the greeting change before applying.", note: "UI fixture · not inference")],
                                      repository: snapshot)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(fixture).write(to: file, options: [.atomic, .completeFileProtection])
                var url = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch { return nil }
        }
        return file
    }
}
#endif
