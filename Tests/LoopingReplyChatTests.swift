import XCTest
@testable import KeelMobile

/// What an imported fine-tune did in a real chat: a reply that repeats one
/// phrase until the limit, and leftover `<function>` / `</think>` text.
@MainActor
final class LoopingReplyChatTests: XCTestCase {
    /// Each reply is a start plus a unit repeated until the step is cancelled
    /// (or 2,000 times). Counts the steps and how many pieces each wrote.
    private actor Looping: LocalGenerating {
        var replies: [(start: String, unit: String)]
        var written: [Int] = []
        init(_ replies: [(String, String)]) { self.replies = replies.map { (start: $0.0, unit: $0.1) } }
        func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                      onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
            let reply = replies.isEmpty ? (start: "Done.", unit: "") : replies.removeFirst()
            onText(reply.start)
            var pieces = 0
            while !reply.unit.isEmpty, pieces < 2000, !cancellation.isCancelled {
                onText(reply.unit); pieces += 1
                if pieces % 20 == 0 { await Task.yield() }
            }
            written.append(pieces)
            if cancellation.isCancelled { throw CancellationError() }
            return pieces + 1
        }
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<1500 {
            if !chat.running { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Chat did not finish")
    }

    private func transcript() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
    }

    func testALoopInsideACallStopsTheStepAndTheModelGetsAnotherTry() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let generator = Looping([("<function=run_js>\n<parameter=code>\n", "&amp;count&amp;limit"), ("The scene is ready.", "")])
        let chat = LocalChat(transcript: path, generator: generator)
        chat.send("Make a GLB scene", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertNil(chat.error)
        let written = await generator.written
        XCTAssertEqual(written.count, 2, "The loop ended one step; the turn went on")
        XCTAssertLessThan(written[0], 2000, "Stopped well before the reply limit")
        XCTAssertTrue(chat.messages.contains { $0.role == "tool" && $0.text.hasPrefix("Not executed") })
        XCTAssertEqual(chat.messages.last?.text, "The scene is ready.")
    }

    func testALoopingAnswerIsCutToOneCopyAndSaysWhy() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path, generator: Looping([("Sure! ", "ha ha ")]))
        chat.send("Tell me a joke", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertNil(chat.error)
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertLessThan(last.text.count, 40, last.text)
        XCTAssertTrue(last.note?.contains("stopped: the model was repeating itself") == true, last.note ?? "")
    }

    func testBrokenToolTextIsHiddenFromTheAnswer() async throws {
        let path = transcript(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let chat = LocalChat(transcript: path, generator: Looping([("I will build it.\n<function>run_html</function>\n</think>\nHere is your scene.", "")]))
        chat.send("Make a GLB scene", model: LocalModel.catalog[0], path: path)
        try await finish(chat)
        XCTAssertNil(chat.error)
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(last.text, "Here is your scene.")
        XCTAssertTrue(last.note?.contains("broken tool text hidden") == true, last.note ?? "")
    }
}
