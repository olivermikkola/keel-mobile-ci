import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ShortVideoTests: XCTestCase {
    private let block = """
        image: lighthouse.png
        say: Still standing through the storm.
        overlay: STILL STANDING
        motion: slow_zoom

        image: waves.jpg
        say: The sea keeps coming in.
        """

    func testBlockScenesParseAndPlan() throws {
        let args = try ShortVideoRequest.arguments([
            "path": "storm.mp4",
            "scenes": block,
            "voice": "af_heart",
            "aspect_ratio": "9:16",
            "title": "Storm",
        ])
        XCTAssertEqual(args.scenes.count, 2)
        XCTAssertEqual(args.scenes[0].imagePath, "lighthouse.png")
        XCTAssertEqual(args.scenes[0].motion, .slowZoom)
        XCTAssertEqual(args.scenes[0].overlay, "STILL STANDING")
        XCTAssertEqual(args.scenes[1].imagePath, "waves.jpg")
        XCTAssertEqual(args.voice.id, "af_heart")
        XCTAssertEqual(args.aspectRatio, .vertical)

        let plan = ShortVideoRequest.plan(args)
        XCTAssertEqual(plan.width, 1080)
        XCTAssertEqual(plan.height, 1920)
        XCTAssertEqual(plan.clips.count, 2)
        XCTAssertEqual(plan.clips[0].start, 0, accuracy: 0.001)
        XCTAssertGreaterThan(plan.clips[1].start, 0)
        XCTAssertEqual(plan.totalSeconds, plan.clips.reduce(0) { $0 + $1.duration }, accuracy: 0.001)
        XCTAssertTrue(ShortVideoRequest.result(args, seconds: 4.2).contains("storm.mp4"))
    }

    func testJSONScenesAndDefaultVoice() throws {
        let json = #"[{"image":"a.png","say":"One.","motion":"pan_left"},{"photo":"b.HEIC","narration":"Two lines here.","overlay":"TWO"}]"#
        let args = try ShortVideoRequest.arguments([
            "path": "clips/out.mp4",
            "scenes": json,
        ])
        XCTAssertEqual(args.scenes.count, 2)
        XCTAssertEqual(args.scenes[0].motion, .panLeft)
        XCTAssertEqual(args.scenes[1].imagePath, "b.HEIC")
        XCTAssertEqual(args.voice.id, ShortVideoRequest.defaultVoiceID)
        XCTAssertEqual(args.aspectRatio, .vertical)
    }

    func testVoiceIdsAreOnDeviceOnly() throws {
        XCTAssertEqual(try ShortVideoRequest.parseVoice("kokoro").id, ShortVideoRequest.defaultVoiceID)
        XCTAssertEqual(try ShortVideoRequest.parseVoice("neural:bf_emma").id, "bf_emma")
        XCTAssertEqual(try ShortVideoRequest.parseVoice("af_heart").id, "af_heart")

        for rejected in ["system", "avspeech", "siri", "elevenlabs", "eleven", "cloud", "elevenlabs:Rachel"] {
            XCTAssertThrowsError(try ShortVideoRequest.parseVoice(rejected), rejected) {
                XCTAssertEqual($0 as? ShortVideoRequest.Problem, .voice)
            }
        }

        XCTAssertThrowsError(try ShortVideoRequest.arguments([
            "path": "x.mp4",
            "scenes": "image: a.png\nsay: Hi.",
            "voice": "af_heart",
        ], availableVoices: ["bf_emma"])) { error in
            XCTAssertEqual(error as? ShortVideoRequest.Problem, .engineUnavailable("af_heart"))
        }
    }

    func testArgumentRejections() {
        let okScenes = "image: a.png\nsay: Hello there."
        for (raw, problem) in [
            (["scenes": okScenes], ShortVideoRequest.Problem.arguments),
            (["path": "clip.mov", "scenes": okScenes], .path),
            (["path": "../x.mp4", "scenes": okScenes], .path),
            (["path": "x.mp4", "scenes": ""], .scenes),
            (["path": "x.mp4", "scenes": "image: a.png\nsay: "], .narration),
            (["path": "x.mp4", "scenes": "image: a.txt\nsay: Hi"], .imagePath),
            (["path": "x.mp4", "scenes": "image: a.png\nsay: Hi\nmotion: spin"], .motion),
            (["path": "x.mp4", "scenes": "image: a.png\nsay: \(String(repeating: "a", count: 281))"], .narration),
            (["path": "x.mp4", "scenes": okScenes, "aspect_ratio": "4:5"], .aspect),
            (["path": "x.mp4", "scenes": okScenes, "voice": "???"] , .voice),
            (["path": "x.mp4", "scenes": okScenes, "voice": "elevenlabs"] , .voice),
            (["path": "x.mp4", "scenes": okScenes, "title": String(repeating: "t", count: 81)], .title),
        ] as [([String: String], ShortVideoRequest.Problem)] {
            XCTAssertThrowsError(try ShortVideoRequest.arguments(raw), "\(raw)") {
                XCTAssertEqual($0 as? ShortVideoRequest.Problem, problem)
            }
        }
    }

    func testTooManyOrTooLongScenes() throws {
        let many = (0..<ShortVideoRequest.maxScenes + 1).map { "image: \($0).png\nsay: Line \($0)." }.joined(separator: "\n\n")
        XCTAssertThrowsError(try ShortVideoRequest.arguments(["path": "x.mp4", "scenes": many])) {
            XCTAssertEqual($0 as? ShortVideoRequest.Problem, .sceneCount)
        }

        let longLine = String(repeating: "word ", count: 40)
        let longScenes = (0..<10).map { "image: \($0).png\nsay: \(longLine)\($0)." }.joined(separator: "\n\n")
        XCTAssertThrowsError(try ShortVideoRequest.arguments(["path": "x.mp4", "scenes": longScenes])) {
            XCTAssertEqual($0 as? ShortVideoRequest.Problem, .duration)
        }
    }

    func testToolSchemaAndCatalogGating() throws {
        let line = ShortVideoRequest.tool
        XCTAssertEqual(AgentPrompt.toolName(line), "create_short_video")
        XCTAssertFalse(line.lowercased().contains("eleven"))
        XCTAssertFalse(line.lowercased().contains("system"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let fn = try XCTUnwrap(obj["function"] as? [String: Any])
        let params = try XCTUnwrap(fn["parameters"] as? [String: Any])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertNotNil(props["path"])
        XCTAssertNotNil(props["scenes"])
        XCTAssertNotNil(props["voice"])

        XCTAssertTrue(ToolRegistry.builtInAllowedTools.contains("create_short_video"))
        XCTAssertEqual(ToolRegistry.category(for: "create_short_video"), .media)
        XCTAssertEqual(ToolRegistry.safety(for: "create_short_video"), .localProposal)
        XCTAssertEqual(ToolRegistry.commonAliases["make_reel"], "create_short_video")

        let without = AgentPrompt.localCatalog()
        XCTAssertFalse(without.contains(where: { AgentPrompt.toolName($0) == "create_short_video" }))
        let with = AgentPrompt.localCatalog(shortVideo: true)
        XCTAssertTrue(with.contains(where: { AgentPrompt.toolName($0) == "create_short_video" }))
        let chatMode = AgentPrompt.localCatalog(mode: .chat, shortVideo: true)
        XCTAssertFalse(chatMode.contains(where: { AgentPrompt.toolName($0) == "create_short_video" }),
                       "Chat mode stays read-oriented; shorts stay in Work")

        let prompt = AgentPrompt.local(shortVideo: true)
        XCTAssertTrue(prompt.contains("create_short_video"))
        let chatPrompt = AgentPrompt.local(mode: .chat, shortVideo: true)
        XCTAssertFalse(chatPrompt.contains("create_short_video"),
                       "Chat mode prompt must not mention create_short_video when the tool is not offered")
    }

    func testRoutingBoostsVideoKeywords() {
        let plan = ToolRouter.plan(
            availableToolLines: [
                #"{"type":"function","function":{"name":"read_file","description":"Read a file.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}"#,
                #"{"type":"function","function":{"name":"create_file","description":"Create a file.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}"#,
                #"{"type":"function","function":{"name":"list_files","description":"List files.","parameters":{"type":"object","properties":{},"required":[]}}}"#,
                #"{"type":"function","function":{"name":"search_repo","description":"Search.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}"#,
                #"{"type":"function","function":{"name":"propose_edit","description":"Edit.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}"#,
                #"{"type":"function","function":{"name":"run_js","description":"JS.","parameters":{"type":"object","properties":{"code":{"type":"string"}},"required":["code"]}}}"#,
                ShortVideoRequest.tool,
                ImageRequest.tool,
            ],
            initialQuery: "make a short reel with narration from my photos",
            mode: .work,
            budget: 5
        )
        let active = Set(plan.activeToolLines.map(AgentPrompt.toolName))
        XCTAssertTrue(active.contains("create_short_video"))
    }

    func testNeuralMemoryGate() {
        let phone: UInt64 = 8_000_000_000
        XCTAssertTrue(ShortVideoRequest.neuralFits(modelBytes: 350_000_000, physicalMemoryBytes: phone))
        XCTAssertFalse(ShortVideoRequest.neuralFits(modelBytes: 4_500_000_000, physicalMemoryBytes: phone))
    }

    func testGrammarAcceptsCreateShortVideo() throws {
        let grammar = try XCTUnwrap(ToolCallGrammar.make(tools: [ShortVideoRequest.tool], family: .bonsai))
        XCTAssertTrue(grammar.text.contains("create_short_video"))
        let call = """
            <tool_call><function=create_short_video><parameter=path>storm.mp4</parameter><parameter=scenes>
            image: lighthouse.png
            say: Still standing.
            </parameter><parameter=voice>af_heart</parameter></function></tool_call>
            """
        let parsed = try XCTUnwrap(DirectorCall.parse(call))
        XCTAssertEqual(parsed.name, "create_short_video")
        let args = try ShortVideoRequest.arguments(parsed.arguments)
        XCTAssertEqual(args.path, "storm.mp4")
        XCTAssertEqual(args.scenes.count, 1)
        XCTAssertEqual(args.voice.id, "af_heart")
    }
}
