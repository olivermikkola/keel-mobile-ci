import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class SamplingProfileTests: XCTestCase {
    func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The presets must match the values the app and the eval actually send.
    /// These checks read the sources, so a change there fails here first.
    func testAppPresetMatchesTheAppSampler() throws {
        let app = try source("Sources/LocalInference.swift")
        XCTAssertTrue(app.contains("llama_sampler_init_top_k(40)"))
        XCTAssertTrue(app.contains("llama_sampler_init_top_p(0.9, 1)"))
        XCTAssertTrue(app.contains("llama_sampler_init_temp(0.6)"))
        XCTAssertTrue(app.contains("llama_sampler_init_dist(LLAMA_DEFAULT_SEED)"))
        XCTAssertFalse(app.contains("llama_sampler_init_min_p"), "min-p is not in the app chain; the preset has none")
        XCTAssertEqual(SamplingProfile.app, SamplingProfile(name: "app", temperature: 0.6, topK: 40, topP: 0.9))
    }

    func testEvalPresetMatchesTheEvalServer() throws {
        let server = try source("tools/harness-eval/agent/Server.swift")
        XCTAssertTrue(server.contains("var topK = 40"))
        XCTAssertTrue(server.contains("var topP = 0.9"))
        XCTAssertTrue(server.contains("var temperature = 0.6"))
        XCTAssertTrue(server.contains("var presencePenalty = 0.0"))
        XCTAssertEqual(SamplingProfile.eval, SamplingProfile(name: "eval", temperature: 0.6, topK: 40, topP: 0.9, presencePenalty: 0.0))
        XCTAssertNil(SamplingProfile.eval.seed, "the eval sets a seed per sample")
        XCTAssertEqual(SamplingProfile.evalSeeded(1010).seed, 1010)
    }

    func testReplyLimitMatchesTheApp() throws {
        let chat = try source("Sources/LocalChat.swift")
        XCTAssertTrue(chat.contains("limit: 512"))
        XCTAssertEqual(SamplingProfile.app.replyTokenLimit, 512)
    }
}
