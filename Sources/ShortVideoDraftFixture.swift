import AVFoundation
import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

#if DEBUG && targetEnvironment(simulator)
/// UI-test fixture (`--short-video-draft-fixture`): draws four pictures,
/// renders them with the real renderer and a synthetic narration track, and
/// opens the draft screen. Recorded content, not inference or real speech.
enum ShortVideoDraftFixture {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("--short-video-draft-fixture") }

    static func make() async throws -> ShortVideoDraft {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("draft-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scenes: [(String, UIColor, UIColor, String, String?, String)] = [
            ("dusk.png", UIColor(red: 0.35, green: 0.45, blue: 0.7, alpha: 1), UIColor(red: 0.98, green: 0.7, blue: 0.55, alpha: 1),
             "At the edge of the island, one light still burns.", nil, "slow_zoom"),
            ("snow.png", UIColor(red: 0.55, green: 0.62, blue: 0.75, alpha: 1), UIColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1),
             "Snow buries the path.", nil, "pan_right"),
            ("storm.png", UIColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1), UIColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1),
             "Still standing through the storm.", "Still standing through the storm", "slow_zoom"),
            ("waves.png", UIColor(red: 0.1, green: 0.25, blue: 0.35, alpha: 1), UIColor(red: 0.6, green: 0.8, blue: 0.85, alpha: 1),
             "And the sea keeps coming.", nil, "pan_left"),
        ]
        var pictures: [String: URL] = [:]
        var lines: [URL?] = []
        var block: [String] = []
        for (index, scene) in scenes.enumerated() {
            let url = folder.appendingPathComponent(scene.0)
            try picture(top: scene.1, bottom: scene.2, tower: index != 1).pngData()?.write(to: url)
            pictures[scene.0] = url
            let line = folder.appendingPathComponent("line\(index).m4a")
            try speechLikeTone(seconds: Double(scene.3.count) / 15, to: line)
            lines.append(line)
            block.append("image: \(scene.0)\nsay: \(scene.3)\n" + (scene.4.map { "overlay: \($0)\n" } ?? "") + "motion: \(scene.5)")
        }
        let arguments = try ShortVideoRequest.arguments(["path": "lighthouse.mp4", "scenes": block.joined(separator: "\n\n"),
                                                         "title": "Draft"])
        let video = folder.appendingPathComponent("lighthouse.mp4")
        let plan = try await ShortVideoRenderer.render(plan: ShortVideoRequest.plan(arguments), picture: { pictures[$0] },
                                                       narration: lines, to: video)
        return ShortVideoDraft(video: video, plan: plan, voiceLabel: "af_heart",
                               pictures: plan.clips.map { pictures[$0.imagePath] })
    }

    /// Sky over sea with a lighthouse, in two colours.
    private static func picture(top: UIColor, bottom: UIColor, tower: Bool) -> UIImage {
        let size = CGSize(width: 768, height: 1024)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.62), options: [.drawsAfterEndLocation])
            UIColor(red: 0.12, green: 0.2, blue: 0.28, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))
            UIColor(white: 0.93, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: -120, y: size.height * 0.7, width: size.width + 240, height: size.height * 0.6))
            guard tower else { return }
            UIColor(white: 0.97, alpha: 1).setFill()
            cg.fill(CGRect(x: size.width * 0.55, y: size.height * 0.3, width: 70, height: size.height * 0.45))
            UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: size.width * 0.55 + 15, y: size.height * 0.27, width: 40, height: 40))
        }
    }

    /// A tone that rises and falls like speech, so the waveform has shape.
    private static func speechLikeTone(seconds: Double, to url: URL) throws {
        let rate = 24_000.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let syllables = max(0, sin(2 * .pi * 3.2 * t)) * (0.6 + 0.4 * sin(2 * .pi * 0.7 * t))
            samples[i] = Float(sin(2 * .pi * 180 * t) * 0.35 * syllables)
        }
        try file.write(from: buffer)
    }
}

/// Renders the fixture, then shows the draft screen.
struct ShortVideoDraftFixtureView: View {
    @State private var draft: ShortVideoDraft?
    @State private var problem: String?
    @State private var sent: String?

    var body: some View {
        Group {
            if let draft {
                ShortVideoDraftView(draft: draft) { sent = $0 }
            } else if let problem {
                Text(problem)
            } else {
                ProgressView("Rendering the fixture video…")
            }
        }
        .overlay(alignment: .top) {
            if let sent { Text("Sent: \(sent)").accessibilityIdentifier("draftFixtureSent").padding(.top, 60) }
        }
        .task {
            do { draft = try await ShortVideoDraftFixture.make() } catch { problem = "Fixture failed: \(error.localizedDescription)" }
        }
    }
}
#endif
