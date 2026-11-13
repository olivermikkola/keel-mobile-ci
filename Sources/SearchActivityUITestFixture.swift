#if DEBUG && targetEnvironment(simulator)
import Foundation

// Explicit visual fixture only. Separate from normal chat storage and absent
// from device builds. It does not run a model or claim real inference.
enum SearchActivityUITestFixture {
    static func transcript() -> URL? {
        guard ProcessInfo.processInfo.arguments.contains("--search-activity-fixture") else { return nil }
        struct Fixture: Encodable {
            let version = 1
            let messages: [ChatMessage]
            let repository: RepositorySnapshot
        }
        let repository = RepositorySnapshot(repository: try! RepositoryID("example/project"), branch: "main",
                                            commit: String(repeating: "a", count: 40), tree: String(repeating: "b", count: 40))
        let result = #"{"result_type":"file_search","path":"Sources/Parser.swift","query":"func parse","search_start_line":1,"matches":[{"line":4,"content":"func parse(_ input: String) {"}],"remaining_matches":2,"next_start_line":10}"#
        let fixture = Fixture(messages: [ChatMessage(role: "user", text: "Find the parser function"),
                                          ChatMessage(role: "tool", text: result, note: "Verified at aaaaaaa", activity: "Search Sources/Parser.swift · func parse"),
                                          ChatMessage(role: "assistant", text: "The match is at Sources/Parser.swift:4.", note: "UI fixture · not inference")],
                              repository: repository)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("search-activity-ui-fixture.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(fixture).write(to: url, options: [.atomic, .completeFileProtection])
            var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch { return nil }
        return url
    }
}
#endif
