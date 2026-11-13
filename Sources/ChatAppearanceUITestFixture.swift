#if DEBUG && targetEnvironment(simulator)
import Foundation

// Explicit recorded UI content only. Isolated from normal history, with no
// model, network, credential, approval or publishing operation.
enum ChatAppearanceUITestFixture {
    static func transcript() -> URL? {
        guard ProcessInfo.processInfo.arguments.contains("--chat-appearance-fixture") else { return nil }
        let reply = """
        Keep the optional value explicit, then handle the empty case before using it.

        ```swift
        guard let name = user.name else {
            return "Hello, there"
        }
        return "Hello, \\(name)"
        ```

        This gives each path a clear result. Nothing has been changed in your repository.
        """
        let task = SavedTask(title: "Handle an optional value", automaticTitle: false,
                             messages: [ChatMessage(role: "user", text: "How can I make this Swift greeting clearer?"),
                                        ChatMessage(role: "assistant", text: reply, note: "Recorded UI example · not inference")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-appearance-fixture.json")
        do { try SavedTasks(task: task).write(to: url); return url }
        catch { return nil }
    }
}
#endif
