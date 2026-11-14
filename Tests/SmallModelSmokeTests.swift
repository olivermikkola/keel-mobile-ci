import XCTest
import UIKit
@testable import KeelMobile

/// Real model integration gates. Ordinary CI skips these large downloads.
/// They prove CPU simulator behavior, never phone Metal speed or heat. A 3-core
/// CI simulator reads prompts at ~3 tok/s, so one request may take 10+ minutes.
final class SmallModelSmokeTests: XCTestCase {
    @MainActor private var probe: RealModelProbe?

    private func fixture() throws -> (LocalModel, URL) {
        let bundle = Bundle(for: Self.self)
        for model in LocalModel.catalog {
            if let url = bundle.url(forResource: model.fileName, withExtension: nil, subdirectory: "fixtures") {
                try ModelLibrary.verify(url, model: model)
                for asset in model.assets.dropFirst() {
                    let file = try XCTUnwrap(bundle.url(forResource: asset.fileName, withExtension: nil, subdirectory: "fixtures"))
                    try ModelLibrary.verify(file, model: asset.transferModel)
                }
                return (model, url)
            }
        }
        throw XCTSkip("Opt-in real model fixture is absent")
    }

    @MainActor
    func testRealModelUsesSQLAndReportsItsResult() async throws {
        let (model, path) = try fixture()
        let values = (0..<5).map { _ in Int.random(in: 101...999) }
        let expected = values.reduce(0, +)
        let csv = "amount\n" + values.map(String.init).joined(separator: "\n") + "\n"
        let data = Attachment(filename: "numbers.csv", mimeType: "text/csv", extractedText: csv, byteSize: csv.utf8.count)
        let chat = try makeChat()
        chat.send("Use run_sql to calculate SUM(amount) AS total from the attached numbers.csv table. Report the total from the tool result. You must run the query.",
                  attachments: [data], model: model, path: path)
        try await finish(chat, model: model)
        let results = chat.messages.filter { $0.role == "tool" && $0.activity == "Run SQL" }
        XCTAssertTrue(results.contains { $0.text.contains(String(expected)) }, "A computed answer without executing the tool does not pass")
        let answer = chat.messages.last { $0.role == "assistant" && $0.isToolCall != true }?.text ?? ""
        XCTAssertTrue(answer.replacingOccurrences(of: ",", with: "").contains(String(expected)), "The final answer must agree with the tool")
        let rejected = chat.messages.filter { $0.note == "Rejected" }.count
        let constrained = probe?.grammarRequests ?? 0
        XCTAssertGreaterThan(constrained, 0, "Tool chats give the runtime the tool-call grammar")
        print("REAL_MODEL_TOOL \(model.id): expected=\(expected) calls=\(results.count) rejected=\(rejected) grammar_requests=\(constrained) answer=\(answer)")
    }

    @MainActor
    func testVisionModelSeesPixelsThroughTheChat() async throws {
        let (model, path) = try fixture()
        guard model.visionFile != nil else { throw XCTSkip("This model is text only") }
        let chat = try makeChat()
        for (color, expected) in [(UIColor.blue, "blue"), (UIColor.red, "red")] {
            XCTAssertTrue(chat.newChat())
            let pixels = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }.pngData()!
            let photo = try PhotoAttachment.make(pixels)
            defer {
                if let id = photo.imageID { try? FileManager.default.removeItem(at: PhotoAttachment.storageDirectory.appendingPathComponent(id.uuidString + ".jpg")) }
            }
            chat.send("What is the dominant color of the attached image? Answer with the color name.", attachments: [photo], model: model, path: path)
            try await finish(chat, model: model)
            let answer = chat.messages.last { $0.role == "assistant" && $0.isToolCall != true }?.text ?? ""
            XCTAssertTrue(answer.lowercased().contains(expected), "The prompt has pixels, not OCR/color labels; changing pixels must change the answer")
            print("REAL_MODEL_VISION \(model.id): expected=\(expected) answer=\(answer)")
        }
    }

    @MainActor
    private func makeChat() throws -> LocalChat {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("model-smoke-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let probe = RealModelProbe()
        self.probe = probe
        return LocalChat(transcript: file, generator: probe)
    }

    @MainActor
    private func finish(_ chat: LocalChat, model: LocalModel) async throws {
        for second in 0..<1200 {
            if !chat.running { break }
            if second % 60 == 0 { print("REAL_MODEL_PROGRESS \(model.id): \(second)s \(chat.phase)") }
            try await Task.sleep(for: .seconds(1))
        }
        if chat.running {
            print("REAL_MODEL_TIMEOUT \(model.id): \(chat.phase)")
            chat.stop(); XCTFail("Real-model request exceeded twenty minutes")
        }
        for message in chat.messages { print("SMOKE \(model.id) \(message.role) \(message.note ?? ""): \(message.text.prefix(3000))") }
        XCTAssertNil(chat.error)
        await probe?.runtime.unload()
    }
}

/// Observes actual inference, including tool XML held out of the visible bubble.
/// No request, generated output, timing or success result is substituted.
private final class RealModelProbe: LocalGenerating, @unchecked Sendable {
    let runtime = LocalInference()
    private let counter = Capture()
    /// Requests that carried a tool-call grammar.
    var grammarRequests: Int { counter.count }
    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        let capture = Capture()
        if request.grammar != nil { counter.increment() }
        print("REAL_MODEL_SYSTEM cores=\(ProcessInfo.processInfo.activeProcessorCount) \(LocalInference.systemInfo)")
        let started = Date()
        defer { print("REAL_MODEL_RAW \(request.model?.id ?? "unknown"): seconds=\(Date().timeIntervalSince(started)) output=\(capture.snapshot())") }
        return try await runtime.generate(request, cancellation: cancellation, onPrefill: { done, total in
            print("REAL_MODEL_PREFILL \(request.model?.id ?? "unknown"): \(done)/\(total)")
            onPrefill(done, total)
        }, onText: { text in
            capture.append(text)
            onText(text)
        })
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var increments = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return increments }
        func increment() { lock.lock(); increments += 1; lock.unlock() }
        func append(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            if text.utf8.count < 4096 { text += chunk }
        }
        func snapshot() -> String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }
}
