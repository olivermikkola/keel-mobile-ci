import AVFoundation
import UIKit
import XCTest
@testable import KeelMobile

/// A chat asks for a short video from an attached photo: the scripted model
/// calls `create_short_video`, a stand-in voice speaks (real Kokoro needs a
/// download), the real renderer makes the `.mp4`, and the chat shows it.
@MainActor
final class ShortVideoChatTests: XCTestCase {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json") }

    private func photo() throws -> Attachment {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        return try PhotoAttachment.make(try XCTUnwrap(image.jpegData(compressionQuality: 0.9)), filename: "Photo.jpg")
    }

    private func call(_ scenes: String) -> String {
        "<tool_call>\n<function=create_short_video>\n<parameter=path>\nsea.mp4\n</parameter>\n<parameter=scenes>\n\(scenes)\n</parameter>\n</function>\n</tool_call>"
    }

    private var visionModel: LocalModel {
        get throws { try XCTUnwrap(LocalModel.catalog.first { $0.visionFile != nil }, "a vision model takes photos") }
    }

    func testAPhotoBecomesANarratedVideoTheChatCanOpen() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let voice = StandInVoice()
        let model = ScriptedVisionModel([
            call("image: photo.jpg\nsay: The sea keeps coming.\noverlay: STILL HERE\nmotion: slow_zoom"),
            "I made sea.mp4.",
        ])
        let chat = LocalChat(transcript: path, generator: model, narration: { voice })
        let attachment = try photo()
        XCTAssertTrue(chat.send("Make a short video from this", attachments: [attachment], model: try visionModel, path: path))
        try await finish(chat)

        let prompts = await model.prompts
        XCTAssertTrue(prompts[0].contains(#""name":"create_short_video""#), "offered once a voice is there")
        let message = try XCTUnwrap(chat.messages.first { $0.video != nil }, chat.messages.map(\.text).joined(separator: "\n---\n"))
        XCTAssertTrue(message.text.hasPrefix("Saved sea.mp4"), message.text)
        XCTAssertTrue(message.text.contains("image: photo.jpg"), "the storyboard comes back for changes")
        let spoken = await voice.lines
        XCTAssertEqual(spoken, ["The sea keeps coming."])
        let unloaded = await voice.unloaded
        XCTAssertTrue(unloaded, "the voice frees its memory")

        let draft = try XCTUnwrap(chat.shortVideoDraft(for: try XCTUnwrap(message.video)))
        XCTAssertEqual(draft.plan.clips.count, 1)
        XCTAssertEqual(draft.plan.clips[0].duration, 1.2 + 0.35, accuracy: 0.05, "as long as the line plus a pause")
        XCTAssertNotNil(draft.pictures[0], "the photo shows in the clip strip")
        let duration = try await AVURLAsset(url: draft.video).load(.duration).seconds
        XCTAssertEqual(duration, draft.plan.totalSeconds, accuracy: 0.1)
        XCTAssertEqual(chat.messages.last?.text, "I made sea.mp4.")
        print("Short video chat proof: photo -> create_short_video -> stand-in voice -> real renderer -> \(String(format: "%.2f", duration)) s mp4 in the chat; scripted model.")
    }

    func testAMissingPictureNamesThePicturesTheChatHas() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ScriptedVisionModel([call("image: lighthouse.png\nsay: Hello."), "Sorry."])
        let chat = LocalChat(transcript: path, generator: model, narration: { StandInVoice() })
        XCTAssertTrue(chat.send("Make a video", attachments: [try photo()], model: try visionModel, path: path))
        try await finish(chat)
        let result = try XCTUnwrap(chat.messages.first { $0.role == "tool" && $0.text.contains("lighthouse.png") }).text
        XCTAssertTrue(result.contains("Pictures in this chat: photo.jpg."), result)
        XCTAssertNil(chat.messages.first { $0.video != nil })
    }

    func testWithoutAVoiceTheToolIsNotOffered() async throws {
        let path = file(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ScriptedVisionModel(["Hi."])
        let chat = LocalChat(transcript: path, generator: model, narration: { nil })
        XCTAssertTrue(chat.send("hi", model: LocalModel.catalog[0], path: path))
        try await finish(chat)
        let prompts = await model.prompts
        XCTAssertFalse(prompts[0].contains("create_short_video"))
    }

    private func finish(_ chat: LocalChat) async throws {
        for _ in 0..<6000 {
            if !chat.running { XCTAssertNil(chat.error); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stop(); XCTFail("Chat did not stop")
    }
}

/// Speaks every line as 1.2 s of tone.
private actor StandInVoice: NarrationSpeaking {
    private(set) var lines: [String] = []
    private(set) var unloaded = false

    func speak(_ text: String, voice: String, to url: URL) async throws -> TimeInterval {
        lines.append(text)
        let rate = 24_000.0
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(rate * 1.2)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.3) }
        try file.write(from: buffer)
        return 1.2
    }

    func unload() async { unloaded = true }
}

/// Scripted replies; accepts photos as a vision model would.
/// The Videos screen without its UI: four photos and a sentence go in; the
/// scripted model writes the lines, a stand-in voice speaks them, the real
/// renderer makes the video, and the screen's own gallery keeps it.
@MainActor
final class VideosScreenTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("videos-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func photos(_ count: Int) -> [Data] {
        let colors: [UIColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return (0..<count).map { index in
            UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1600), format: format).image { context in
                colors[index % colors.count].setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1600))
            }.jpegData(compressionQuality: 0.9)!
        }
    }

    private func chat(_ outputs: [String]) -> (LocalChat, ScriptedVisionModel) {
        let model = ScriptedVisionModel(outputs)
        let transcript = folder.appendingPathComponent("chat").appendingPathComponent("chat.json")
        return (LocalChat(transcript: transcript, generator: model, narration: { nil }), model)
    }

    func testFourPhotosAndASentenceBecomeANarratedVideo() async throws {
        let gallery = VideoGallery(directory: folder.appendingPathComponent("studio"))
        let names = try gallery.addPhotos(photos(4))
        XCTAssertEqual(names.count, 4)
        let (chat, model) = chat(["1. The road opened at sunrise. | MORNING\n2. The sea was calm.\n3. Lunch by the harbour.\n4. Home before dark.",
                                  "1. Sunrise, coffee, go. | MORNING\n2. The sea said hi.\n3. Fish, obviously.\n4. Home, tired, happy."])
        let voice = StandInVoice()
        let looks = LookCounter()
        let maker = VideoMaker(narration: { voice }, look: { urls in
            looks.count += 1
            return urls.indices.map { "harbour, boat; text: \"Porvoo \($0 + 1)\"" }
        })
        let textModel = try XCTUnwrap(LocalModel.catalog.first { $0.visionFile == nil })
        maker.make(description: "Our day trip to Porvoo", photos: names, voice: "af_heart", chat: chat, model: textModel,
                   modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)

        let item = try XCTUnwrap(gallery.items.first)
        let spoken = await voice.lines
        XCTAssertEqual(spoken, ["The road opened at sunrise.", "The sea was calm.", "Lunch by the harbour.", "Home before dark."])
        let prompts = await model.prompts
        XCTAssertTrue(prompts[0].contains("exactly 4 lines"))
        XCTAssertTrue(prompts[0].contains("Our day trip to Porvoo"))
        XCTAssertTrue(prompts[0].contains("Photo 1: harbour, boat; text: \"Porvoo 1\""), "the model is told what each photo shows")
        XCTAssertTrue(prompts[0].contains("Photo 4: harbour, boat"))
        XCTAssertEqual(item.notes?.count, 4)
        let timings = try XCTUnwrap(item.timings)
        XCTAssertGreaterThan(timings.voice + timings.video, 0)
        let draft = try XCTUnwrap(gallery.draft(item))
        XCTAssertEqual(draft.plan.clips.map(\.imagePath), names, "photos stay in the order picked")
        XCTAssertEqual(draft.plan.clips.first?.overlay, "MORNING")
        XCTAssertTrue(draft.pictures.allSatisfy { $0 != nil })
        let duration = try await AVURLAsset(url: draft.video).load(.duration).seconds
        XCTAssertEqual(duration, draft.plan.totalSeconds, accuracy: 0.1)

        // Kept across launches and by the chats' clean-up.
        XCTAssertEqual(VideoGallery(directory: gallery.directory).items, gallery.items)
        XCTAssertTrue(VideoGallery.savedVideoNames(directory: gallery.directory).contains(item.video))

        // A change rewrites the lines from the ones already there.
        maker.make(description: item.description, photos: item.photos, voice: item.voice, from: item, change: "make it funnier",
                   chat: chat, model: textModel, modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)
        let changePrompt = await model.prompts[1]
        XCTAssertTrue(changePrompt.contains("1. The road opened at sunrise. | MORNING"))
        XCTAssertTrue(changePrompt.contains("Change: make it funnier"))
        XCTAssertEqual(gallery.items.count, 2)
        XCTAssertEqual(gallery.items.first?.lines.first?.narration, "Sunrise, coffee, go.")
        XCTAssertEqual(looks.count, 1, "the same photos keep their notes")
        XCTAssertTrue(changePrompt.contains("Photo 2: harbour, boat"))
        print("Videos screen proof: 4 photos + sentence -> scripted lines -> stand-in voice -> real renderer -> \(String(format: "%.2f", duration)) s mp4; change -> second video.")
        for made in gallery.items { gallery.delete(made) }
        XCTAssertTrue(gallery.items.isEmpty)
    }

    func testAReplyMissingALineIsTriedOnceMore() async throws {
        let gallery = VideoGallery(directory: folder.appendingPathComponent("studio"))
        let names = try gallery.addPhotos(photos(2))
        let (chat, model) = chat(["Sure! Here is a lovely script about your trip.", "1. First.\n2. Second."])
        let maker = VideoMaker(narration: { StandInVoice() }, look: { $0.map { _ in "" } })
        maker.make(description: "trip", photos: names, voice: "af_heart", chat: chat,
                   model: try XCTUnwrap(LocalModel.catalog.first { $0.visionFile == nil }),
                   modelPath: folder.appendingPathComponent("model.gguf"), gallery: gallery)
        await maker.finish()
        XCTAssertNil(maker.error)
        let prompts = await model.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(gallery.items.first?.lines.map(\.narration), ["First.", "Second."])
        for made in gallery.items { gallery.delete(made) }
    }
}

private final class LookCounter: @unchecked Sendable { var count = 0 }

/// A spoken line comes out of encoding trimmed of the voice's silent ends
/// and brought up to speaking level (`NarrationLevels`).
final class NarrationAudioTests: XCTestCase {
    func testAQuietLineWithSilentEndsIsTrimmedAndRaised() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 24_000.0
        let source = folder.appendingPathComponent("line.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        // In its own scope: the file is finished only once its writer is gone.
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let frames = AVAudioFrameCount(rate * 2)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                let speaking = index >= Int(rate * 0.5) && index < Int(rate * 1.5)
                buffer.floatChannelData![0][index] = speaking ? Float(sin(Double(index) * 0.05) * 0.05) : 0.0005
            }
            try file.write(from: buffer)
        }

        let output = folder.appendingPathComponent("line.m4a")
        let seconds = try NarrationAudio.encodeAAC(from: source, to: output)
        XCTAssertEqual(seconds, 1 + NarrationLevels.leadSeconds + NarrationLevels.tailSeconds, accuracy: 0.03, "the silent ends are gone")
        let encoded = try AVAudioFile(forReading: output)
        let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: encoded.processingFormat, frameCapacity: AVAudioFrameCount(encoded.length)))
        try encoded.read(into: read)
        let samples = UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength))
        let peak = samples.map(abs).max() ?? 0
        // A sine brought to the target loudness peaks at targetRMS × √2 ≈ 0.18.
        XCTAssertEqual(peak, NarrationLevels.targetRMS * Float(2).squareRoot(), accuracy: 0.03, "raised from 0.05 to speaking level")
        XCTAssertLessThanOrEqual(peak, 1)
        print("Narration level proof: 2.0 s line with 0.5 s silent ends -> \(String(format: "%.2f", seconds)) s, peak 0.05 -> \(String(format: "%.2f", peak)).")
    }
}

private actor ScriptedVisionModel: LocalGenerating {
    private var outputs: [String]
    private(set) var prompts = [String]()
    init(_ outputs: [String]) { self.outputs = outputs }

    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        prompts.append(request.prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }

    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        prompts.append(prompt)
        guard !outputs.isEmpty else { throw LocalModelError.decode }
        onText(outputs.removeFirst()); return 30
    }
}
