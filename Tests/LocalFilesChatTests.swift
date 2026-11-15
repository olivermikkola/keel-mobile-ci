import XCTest
@testable import KeelMobile

/// A chat with no repository works on its own files with the same tools and
/// review flow. Scripted model, real storage, workspace and tools.
@MainActor
final class LocalFilesChatTests: XCTestCase {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json") }
    private func create(_ path: String, _ text: String) -> String {
        "<tool_call>\n<function=create_file>\n<parameter=path>\n\(path)\n</parameter>\n<parameter=new_text>\n\(text)\n</parameter>\n</function>\n</tool_call>"
    }
    private let readPage = "<tool_call>\n<function=read_file>\n<parameter=path>\nsite/index.html\n</parameter>\n</function>\n</tool_call>"

    func testWithoutARepositoryTheChatProposesAppliesAndReadsItsOwnFiles() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = LocalFilesModel([create("site/index.html", "<h1>Hello from Keel</h1>"), "I made site/index.html.",
                                     readPage, "The page says Hello from Keel."])
        let chat = LocalChat(transcript: path, generator: model)
        XCTAssertNil(chat.repository)
        chat.send("Make me a page", model: LocalModel.catalog[0], path: path)
        try await finish(chat)

        let prompts = await model.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("This chat has its own private files"))
        XCTAssertTrue(prompts[0].contains("\"name\":\"create_file\""))
        XCTAssertFalse(prompts[0].contains("Repository"))
        XCTAssertTrue(prompts[1].contains("edit_proposal"))
        // The second turn starts with exactly the first prompt, so its prefill is reused.
        XCTAssertTrue(prompts[1].hasPrefix(prompts[0]))

        let record = try XCTUnwrap(chat.fileEdits.first)
        XCTAssertEqual(chat.fileEdits.count, 1)
        XCTAssertEqual(record.decision, .pending)
        XCTAssertTrue(record.proposal.snapshot.isLocalFiles)
        XCTAssertEqual(record.proposal.after, "<h1>Hello from Keel</h1>\n")
        XCTAssertTrue(chat.previewDocument(for: record.proposal).contains("Hello from Keel"))
        XCTAssertEqual(LocalChat(transcript: path).fileEdits.first?.decision, .pending, "Saved tasks accept a chat's own proposals")

        chat.applyEdit(record.id)
        try await finish(chat)
        XCTAssertEqual(chat.fileEdits.first?.decision, .applied)
        XCTAssertNil(chat.repository)

        chat.send("What does the page say?", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        let result = try XCTUnwrap(chat.messages.last(where: { $0.role == "tool" })).text
        XCTAssertTrue(result.contains("Hello from Keel"), result)
        XCTAssertEqual(chat.messages.last?.text, "The page says Hello from Keel.")
        XCTAssertEqual(LocalChat(transcript: path).fileEdits.first?.decision, .applied)
        print("Local files proof: no repository; create_file proposed in a new folder, persisted pending, applied after a freshness check, read back by read_file in the next turn, relaunch keeps the decision. Scripted model.")
    }

    func testPlainAnswerNeedsNoTool() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path, generator: LocalFilesModel(["Hi! How can I help?"]))
        chat.send("hi", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertEqual(chat.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(chat.messages.last?.text, "Hi! How can I help?")
    }

    func testASecondProposalForTheSamePathIsStaleOnceTheFirstIsApplied() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = LocalFilesModel([create("a.txt", "one"), create("a.txt", "two"), "Two versions proposed."])
        let chat = LocalChat(transcript: path, generator: model)
        chat.send("Write a.txt", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertEqual(chat.fileEdits.count, 2)
        chat.applyEdit(chat.fileEdits[0].id)
        try await finish(chat)
        chat.applyEdit(chat.fileEdits[1].id)
        for _ in 0..<500 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(chat.error)
        XCTAssertEqual(chat.fileEdits.map(\.decision), [.applied, .pending])
    }

    func testProposedDocumentsTablesAndDecksOpenInTheirViewers() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = LocalFilesModel([create("notes.md", "# Plan\n\n- [x] Pack"), create("sales.csv", "product,amount\nTea,12"),
                                     create("cards.md", "Q: One?\nA: 1\n\nQ: Two?\nA: 2"), "Made three files."])
        let chat = LocalChat(transcript: path, generator: model)
        chat.send("Make a plan, a table and flashcards", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        let pages = chat.fileEdits.map { chat.previewDocument(for: $0.proposal) }
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages[0].contains("<h1>Plan</h1>") && pages[0].contains("disabled checked"), pages[0])
        XCTAssertTrue(pages[1].contains("<td class=\"num\">12</td>"), pages[1])
        XCTAssertTrue(pages[2].contains("id=\"deck\"") && pages[2].contains("\"q\":\"Two?\""), pages[2])
        XCTAssertTrue(pages.allSatisfy { $0.contains("Content-Security-Policy") })
    }

    func testToolChatsConstrainCallsToTheToolsInTheirPrompt() async throws {
        for model in LocalModel.catalog where [.bonsai, .lfm3, .miniCPM5].contains(model.family) {
            let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            let generator = RequestRecorder()
            let chat = LocalChat(transcript: path, generator: generator)
            chat.send("hi", model: model, path: path)
            try await finish(chat)
            let requests = await generator.requests
            let request = try XCTUnwrap(requests.first)
            let grammar = try XCTUnwrap(request.grammar, model.id)
            // The grammar of exactly the tools in the prompt that was sent (LFM3's
            // template lists parameters in another order, so compare with the prompt).
            XCTAssertEqual(grammar, ToolCallGrammar.make(prompt: request.prompt, family: model.family), model.id)
            for tool in ["list_files", "read_file", "create_file", "propose_edit", "run_sql", "run_js"] {
                XCTAssertTrue(grammar.text.contains(model.family == .miniCPM5 ? "name=\\\"\(tool)\\\"" : "function=\(tool)>"), "\(model.id) \(tool)")
            }
            XCTAssertEqual(grammar.triggerPatterns, model.family == .miniCPM5 ? ["(<function)"] : ["(<tool_call>)"])
        }
    }

    func testEveryAppSendsOnlyItsOwnGrammarAcrossModelFamilies() async throws {
        for family in [ModelFamily.bonsai, .lfm3, .miniCPM5] {
            let model = try XCTUnwrap(LocalModel.catalog.first { $0.family == family })
            for app in AppPreset.allCases {
                let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
                let generator = RequestRecorder()
                let chat = LocalChat(transcript: path, generator: generator, searchKey: { "fixture-key" })
                XCTAssertTrue(chat.newChat(app: app))
                chat.send("hi", model: model, path: path)
                try await finish(chat)
                let requests = await generator.requests
                let request = try XCTUnwrap(requests.first)
                let grammar = try XCTUnwrap(request.grammar)
                XCTAssertTrue(request.prompt.contains(app.instructions))
                for tool in ["list_files", "read_file", "create_file", "propose_edit", "run_sql", "run_js", "read_url", "web_search"] {
                    let spelling = family == .miniCPM5 ? "name=\\\"\(tool)\\\"" : "function=\(tool)>"
                    XCTAssertEqual(grammar.text.contains(spelling), app.tools.contains(tool), "\(app.title) \(family.rawValue) \(tool)")
                }
            }
        }
    }

    func testAnAppChatSendsItsPresetAndKeepsIt() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = LocalFilesModel([create("planets.md", "# Planets\n\nQ: Largest?\nA: Jupiter\n\nQ: Hottest?\nA: Venus"), "Made two cards."])
        let chat = LocalChat(transcript: path, generator: model)
        XCTAssertTrue(chat.newChat(app: .study))
        XCTAssertEqual(chat.activeApp, .study)
        chat.send("Flashcards about planets", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        let prompts = await model.prompts
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("This chat is the Study app"))
        XCTAssertFalse(prompt.contains("\"name\":\"run_sql\""))
        XCTAssertEqual(chat.fileEdits.first?.proposal.afterPath, "planets.md")
        XCTAssertTrue(chat.previewDocument(for: try XCTUnwrap(chat.fileEdits.first).proposal).contains("id=\"deck\""))

        let reopened = LocalChat(transcript: path)
        XCTAssertEqual(reopened.activeApp, .study)
        XCTAssertTrue(reopened.newChat())
        XCTAssertNil(reopened.activeApp, "A plain new chat has no app")
    }

    func testAnAppRejectsAnUnofferedToolAndCanContinueWithAnAllowedOne() async throws {
        let forbidden = [
            "<tool_call><function=run_sql><parameter=sql>SELECT 'unoffered invocation';</parameter></function></tool_call>",
            "<tool_call><function=run_js><parameter=code>console.log('unoffered invocation')</parameter></function></tool_call>",
            "<tool_call><function=read_url><parameter=url>https://example.test/</parameter></function></tool_call>",
            "<tool_call><function=web_search><parameter=query>unoffered query</parameter></function></tool_call>"
        ]
        for call in forbidden {
            let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
            let model = LocalFilesModel([call, create("allowed.md", "# Study note"), "Made a note."])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            StubProtocol.handler = { _ in XCTFail("A preset's forbidden tool reached the network"); return (200, Data()) }
            defer { StubProtocol.handler = nil }
            let chat = LocalChat(transcript: path, generator: model, webConfiguration: configuration,
                                 searchKey: { "fixture-key" })
            XCTAssertTrue(chat.newChat(app: .study))
            chat.send("Make a study note", model: LocalModel.catalog[0], path: path)
            try await finish(chat)
            let rejection = try XCTUnwrap(chat.messages.first { $0.role == "tool" })
            XCTAssertEqual(rejection.note, "Error")
            XCTAssertTrue(rejection.text.contains("does not offer"), rejection.text)
            XCTAssertEqual(chat.fileEdits.count, 1)
            XCTAssertEqual(chat.fileEdits.first?.proposal.afterPath, "allowed.md")
            XCTAssertEqual(chat.messages.last?.text, "Made a note.")
            XCTAssertNil(chat.pendingWebSearch)
        }
    }

    func testFollowUpTurnAutoAppliesPendingLocalFilesAndAllowsLargeCreateAndRewrite() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let largeV1 = "<html>\n" + String(repeating: "<p>Cafe</p>\n", count: 500) + "</html>" // > 4 KB, < 16 KB
        let largeV2 = "<html>\n" + String(repeating: "<p>MoE</p>\n", count: 600) + "</html>"
        let model = LocalFilesModel([
            create("index.html", largeV1), "Created index.html.",
            "<tool_call>\n<function=read_file>\n<parameter=path>\nindex.html\n</parameter>\n</tool_call>",
            create("index.html", largeV2), "Updated index.html."
        ])
        let chat = LocalChat(transcript: path, generator: model)

        // Turn 1: create >4 KB index.html (stays pending if user does not tap Apply).
        chat.send("Make a cafe page", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertEqual(chat.fileEdits.count, 1)
        XCTAssertEqual(chat.fileEdits[0].decision, .pending)
        XCTAssertGreaterThan(chat.fileEdits[0].proposal.after.utf8.count, 4096)

        // Turn 2: follow-up turn without tapping Apply first. Should auto-apply Turn 1's file so
        // read_file finds index.html and create_file(index.html) cleanly produces a .replace rewrite.
        chat.send("Make it professional", model: LocalModel.catalog[0], path: path)
        try await finish(chat)

        XCTAssertEqual(chat.fileEdits.count, 2)
        XCTAssertEqual(chat.fileEdits[0].decision, .applied)
        XCTAssertEqual(chat.fileEdits[1].decision, .pending)
        XCTAssertEqual(chat.fileEdits[1].proposal.kind, .replace)
        XCTAssertTrue(chat.fileEdits[1].proposal.after.contains("<p>MoE</p>"))

        chat.applyAllLocalEdits()
        try await finish(chat)
        XCTAssertEqual(chat.fileEdits.map(\.decision), [.applied, .applied])
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<3000 {
            if !chat.running { XCTAssertNil(chat.error); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Chat did not stop")
    }
}

private actor LocalFilesModel: LocalGenerating {
    private var outputs: [String]
    private(set) var prompts = [String]()
    init(_ outputs: [String]) { self.outputs = outputs }
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try Task.checkCancellation()
        prompts.append(prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }
}

/// Keeps every request, so a test sees what the runtime would be given.
private actor RequestRecorder: LocalGenerating {
    private(set) var requests = [LocalGenerationRequest]()
    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        requests.append(request)
        onText("Hello."); return 2
    }
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        throw LocalModelError.decode
    }
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        throw LocalModelError.decode
    }
}
