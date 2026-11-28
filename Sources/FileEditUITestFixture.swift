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
                var messages = [ChatMessage(role: "user", text: "Propose a new greeting"),
                                ChatMessage(role: "tool", text: record.observation, note: "Needs review", activity: "Propose edit · README", edit: record),
                                ChatMessage(role: "assistant", text: "Review the greeting change before applying.", note: "UI fixture · not inference")]
                if args.contains("--web-preview-fixture") {
                    messages = try webPreviewMessages(snapshot)
                }
                let fixture = Fixture(messages: messages, repository: snapshot)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(fixture).write(to: file, options: [.atomic, .completeFileProtection])
                var url = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch { return nil }
        }
        return file
    }

    // A page and its stylesheet, both proposed. The page reports what it could
    // do, so the UI test can read the result from the preview.
    private static func webPreviewMessages(_ snapshot: RepositorySnapshot) throws -> [ChatMessage] {
        let page = """
        <!doctype html><html><head><link rel="stylesheet" href="style.css"></head>
        <body><h1>Hello from Keel</h1><p id="style">checking</p><p id="network">checking</p>
        <script>
        document.getElementById('style').textContent = 'Heading color ' + getComputedStyle(document.querySelector('h1')).color;
        fetch('https://example.com').then(() => 'Network reachable', () => 'Network blocked')
          .then(text => { document.getElementById('network').textContent = text; });
        </script></body></html>
        """
        let edits = try [("site/index.html", page), ("site/style.css", "h1 { color: rgb(255, 0, 0); }\n")].map { path, text in
            TaskFileEdit(proposal: try ProposedFileEdit(snapshot: snapshot, path: path, originalBlobSHA: ProposedFileEdit.emptyBlobSHA,
                                                        before: "", oldText: "", newText: text, kind: .create))
        }
        return [ChatMessage(role: "user", text: "Make a small website")]
            + edits.map { ChatMessage(role: "tool", text: $0.observation, note: "Needs review",
                                      activity: "Propose edit · \($0.proposal.path)", edit: $0) }
            + [ChatMessage(role: "assistant", text: "Preview the page before applying.", note: "UI fixture · not inference")]
    }
}
#endif
