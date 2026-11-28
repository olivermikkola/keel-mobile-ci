import XCTest
@testable import KeelMobile

/// `run_shortcut` in a real chat turn: offered only with allowed shortcuts,
/// asks first, opens Shortcuts, and feeds the returned text to the model.
@MainActor
final class ShortcutChatTests: XCTestCase {
    private actor Scripted: LocalGenerating {
        var requests: [LocalGenerationRequest] = []
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            requests.append(request)
            onText(replies.isEmpty ? "Done." : replies.removeFirst())
            return 12
        }
    }

    /// Plays the Shortcuts app: records each link and answers through Keel's return link.
    private final class FakeShortcuts {
        weak var chat: LocalChat?
        var opened: [URL] = []
        var answer: (String) -> String = { "keelmobile://shortcut/\($0)/success?result=18%C2%B0C%20and%20sunny" }
        var opens = true

        func open(_ url: URL) async -> Bool {
            opened.append(url)
            guard opens else { return false }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let success = URL(string: items.first { $0.name == "x-success" }?.value ?? "")
            let token = success.flatMap(ShortcutRun.token(of:)) ?? ""
            let back = URL(string: answer(token))!
            Task { @MainActor [weak chat] in
                // Someone else's link first: it must not answer this run.
                chat?.receiveShortcutReturn(URL(string: "keelmobile://shortcut/stale/success?result=wrong")!)
                chat?.receiveShortcutReturn(back)
            }
            return true
        }
    }

    private func tempTranscript() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-shortcut-tests-\(UUID().uuidString)")
            .appendingPathComponent("chat.json")
    }

    private let call = "<tool_call>\n<function=run_shortcut>\n<parameter=name>\nget weather\n</parameter>\n<parameter=input>\nTurku\n</parameter>\n</function>\n</tool_call>"

    private func run(_ chat: LocalChat, answer: Bool?) async throws {
        for _ in 0..<300 {
            if let answer, chat.pendingShortcut != nil { chat.decideShortcut(answer) }
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Chat did not finish")
    }

    func testAnApprovedRunOpensShortcutsAndReturnsItsOutput() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted([call, "It is 18°C and sunny in Turku."])
        let shortcuts = FakeShortcuts()
        let chat = LocalChat(transcript: path, generator: model, openShortcut: { await shortcuts.open($0) })
        shortcuts.chat = chat
        XCTAssertNil(chat.allowShortcut("Get Weather"))

        chat.send("What's the weather?", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: true)

        let link = try XCTUnwrap(shortcuts.opened.first)
        let items = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Get Weather", "The saved name, not the model's spelling")
        XCTAssertEqual(items.first { $0.name == "text" }?.value, "Turku")
        let result = try XCTUnwrap(chat.messages.last { $0.role == "tool" })
        XCTAssertTrue(result.text.contains("18°C and sunny"), result.text)
        XCTAssertFalse(result.text.contains("wrong"))
        XCTAssertEqual(result.note, "Completed")
        XCTAssertFalse(chat.waitingForShortcut)
        let requests = await model.requests
        XCTAssertTrue(try XCTUnwrap(requests.first).prompt.contains(#""name":"run_shortcut""#))
        XCTAssertTrue(try XCTUnwrap(requests.last).prompt.contains("18°C and sunny"))
    }

    func testDeclinedRunsAndUnknownShortcutsOpenNothing() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let other = "<tool_call>\n<function=run_shortcut>\n<parameter=name>\nDelete everything\n</parameter>\n</function>\n</tool_call>"
        let model = Scripted([call, "OK.", other, "OK."])
        let shortcuts = FakeShortcuts()
        let chat = LocalChat(transcript: path, generator: model, openShortcut: { await shortcuts.open($0) })
        shortcuts.chat = chat
        XCTAssertNil(chat.allowShortcut("Get weather"))

        chat.send("Weather?", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: false)
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.hasPrefix("Not run: the user declined") })

        chat.send("Clean up", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: true)
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.contains("has not allowed that shortcut") })
        XCTAssertTrue(shortcuts.opened.isEmpty)
    }

    func testFailuresFromShortcutsReachTheModel() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted([call, "That shortcut failed."])
        let shortcuts = FakeShortcuts()
        shortcuts.answer = { "keelmobile://shortcut/\($0)/error?errorMessage=No%20shortcut%20named%20that" }
        let chat = LocalChat(transcript: path, generator: model, openShortcut: { await shortcuts.open($0) })
        shortcuts.chat = chat
        XCTAssertNil(chat.allowShortcut("Get weather"))
        chat.send("Weather?", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: true)
        let result = try XCTUnwrap(chat.messages.last { $0.role == "tool" })
        XCTAssertTrue(result.text.contains("failed in the Shortcuts app: No shortcut named that"), result.text)
        XCTAssertEqual(result.note, "Error")
    }

    func testNoShortcutsMeansNoToolAndTheListPersists() async throws {
        let path = tempTranscript()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = Scripted(["Hi."])
        let chat = LocalChat(transcript: path, generator: model, openShortcut: { _ in XCTFail("opened"); return false })
        chat.send("Hello", model: LocalModel.catalog[0], path: path)
        try await run(chat, answer: nil)
        let requests = await model.requests
        let first = try XCTUnwrap(requests.first)
        XCTAssertFalse(first.prompt.contains("run_shortcut"))

        XCTAssertNil(chat.allowShortcut("Lights off"))
        XCTAssertNotNil(chat.allowShortcut("lights OFF"), "Duplicate refused")
        XCTAssertEqual(LocalChat(transcript: path, generator: model).allowedShortcuts, ["Lights off"])
        XCTAssertTrue(chat.removeShortcut("Lights off"))
        XCTAssertEqual(LocalChat(transcript: path, generator: model).allowedShortcuts, [])
    }
}
