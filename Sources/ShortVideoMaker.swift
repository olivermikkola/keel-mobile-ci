import Foundation
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Speaks a storyboard with the narration voice and renders the video. Used by
/// the chat's `create_short_video` and by the Videos screen. The caller frees
/// the chat model first: the voice and the renderer need the memory.
@MainActor
enum ShortVideoMaker {
    struct Made {
        let name: String
        let manifest: ShortVideoManifest
        let plan: ShortVideoRequest.RenderPlan
        /// Seconds the voice took for all lines, and the renderer for the video.
        let speakSeconds: TimeInterval
        let renderSeconds: TimeInterval
    }

    /// `stopped` is checked between steps and while rendering; `phase` shows
    /// progress. Throws `CancellationError` when stopped, `LocalModelError.thermal`
    /// when the phone is too hot, and `ShortVideoRequest.Problem.slow` past the time limit.
    static func make(_ arguments: ShortVideoRequest.Arguments, picture: @escaping (String) -> URL?,
                     engine: any NarrationSpeaking, music: URL? = nil, stopped: @escaping () -> Bool,
                     phase: @escaping (String) -> Void) async throws -> Made {
        let began = Date()
        let inTime = { Date().timeIntervalSince(began) < ShortVideoRequest.timeLimit }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var lines: [URL?] = []
        do {
            for (index, scene) in arguments.scenes.enumerated() {
                try Task.checkCancellation()
                if stopped() { throw CancellationError() }
                guard inTime() else { throw ShortVideoRequest.Problem.slow }
                if case .stop = ThermalPolicy.currentDecision() { throw LocalModelError.thermal }
                phase("Speaking scene \(index + 1) of \(arguments.scenes.count)…")
                let line = scratch.appendingPathComponent("line\(index).m4a")
                _ = try await engine.speak(scene.narration, voice: arguments.voice.id, to: line)
                lines.append(line)
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
        let spoke = Date()
        phase("Making the video…")
        try ShortVideoStore.prepareDirectory()
        let name = ShortVideoStore.newName()
        let rendered: ShortVideoRequest.RenderPlan
        do {
            rendered = try await ShortVideoRenderer.render(
                plan: ShortVideoRequest.plan(arguments),
                picture: picture,
                narration: lines,
                music: music,
                to: ShortVideoStore.url(name),
                shouldContinue: {
                    if case .stop = ThermalPolicy.currentDecision() { return false }
                    return !stopped() && inTime()
                },
                progress: { done in
                    Task { @MainActor in phase("Making the video · \(Int(done * 100))%") }
                })
        } catch ShortVideoRenderer.Failure.stopped {
            if stopped() { throw CancellationError() }
            if case .stop = ThermalPolicy.currentDecision() { throw LocalModelError.thermal }
            throw ShortVideoRequest.Problem.slow
        }
        let manifest = ShortVideoManifest(plan: rendered)
        try ShortVideoStore.save(manifest, for: name)
        return Made(name: name, manifest: manifest, plan: rendered, speakSeconds: spoke.timeIntervalSince(began),
                    renderSeconds: Date().timeIntervalSince(spoke))
    }
}
