import Foundation
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Sends each reply to llama.cpp, or to MLX when the user switched on
/// "Use MLX for LFM3 chats" and the pinned MLX model is downloaded. Only one
/// runtime holds a model at a time: switching unloads the other first.
///
/// MLX in chats is experimental: no tool-call grammar and no photos. A step
/// that extends the last prompt reads only the new part (`MLXRunner`'s cache).
final class RuntimeRouter: LocalGenerating, @unchecked Sendable {
    static let useMLXKey = "useMLXForLFM3"
    let llama: LocalInference
    let mlx = MLXRunner()
    private let modelsDirectory: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var lastTelemetry: InferenceTelemetry?
    private var lastWasMLX = false
    private var lastWasApple = false
    private var onLlama = false

    init(llama: LocalInference, modelsDirectory: URL = ModelLibrary.defaultDirectory, defaults: UserDefaults = .standard) {
        self.llama = llama
        self.modelsDirectory = modelsDirectory
        self.defaults = defaults
    }

    /// The model's own sampler, as llama.cpp uses for it (LFM3: temperature
    /// 0.1, top-k 50, repetition penalty 1.1). MLX chats used the app default
    /// (0.6, top-k 40), and LFM3 rambled instead of calling tools.
    static func sampling(for model: LocalModel?) -> SamplingProfile {
        model?.family.sampling ?? SamplingProfile.app
    }

    /// Whether this model's replies go to MLX right now.
    func usesMLX(_ model: LocalModel?) -> Bool {
        let pack = MLXModelPack.lfm3
        return defaults.bool(forKey: Self.useMLXKey) && model?.id == pack.ggufModelID
            && pack.missing(in: pack.directory(in: modelsDirectory)).isEmpty
    }

    /// llama.cpp can move a reply to the CPU when the app leaves the
    /// foreground; MLX and Apple's model need the graphics processor.
    var canContinueInBackground: Bool { lock.withLock { onLlama } }

    /// True when the last reply was written by MLX, for the note under it.
    var lastReplyUsedMLX: Bool { lock.withLock { lastWasMLX } }

    func latestTelemetry() async -> InferenceTelemetry? {
        if lock.withLock({ lastWasMLX || lastWasApple }) { return lock.withLock { lastTelemetry } }
        return await llama.latestTelemetry()
    }

    func unloadAll() async {
        await llama.unload()
        await mlx.unload()
    }

    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        if request.model?.isSystem == true {
            // Apple runs its own model; free the memory ours would hold.
            guard request.images.isEmpty else { throw LocalModelError.vision }
            lock.withLock { onLlama = false }
            await llama.unload(); await mlx.unload()
            onPrefill(0, 1)
            var started = false
            let telemetry = try await AppleModelRunner.generate(prompt: request.prompt, limit: request.limit,
                                                                temperature: SamplingProfile.app.temperature,
                                                                tools: request.grammar == nil ? nil : AppleToolPlan.make(prompt: request.prompt),
                                                                cancellation: cancellation) { piece in
                if !started { onPrefill(1, 1); started = true }
                onText(piece)
            }
            lock.withLock { lastWasMLX = false; lastWasApple = true; lastTelemetry = telemetry }
            return telemetry.decodedTokens
        }
        lock.withLock { lastWasApple = false }
        guard usesMLX(request.model) else {
            await mlx.unload()
            lock.withLock { lastWasMLX = false; onLlama = request.images.isEmpty }
            return try await llama.generate(request, cancellation: cancellation, onPrefill: onPrefill, onText: onText)
        }
        guard request.images.isEmpty else { throw LocalModelError.vision }
        lock.withLock { onLlama = false }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw LocalModelError.thermal }
        await llama.unload()
        let pack = MLXModelPack.lfm3
        try await mlx.load(directory: pack.directory(in: modelsDirectory))
        let sampling = Self.sampling(for: request.model)
        onPrefill(0, 1)
        // The runner's text callback outlives this call's non-escaping onText,
        // so the pieces travel through a stream and are handed on here.
        let (pieces, continuation) = AsyncStream<String>.makeStream()
        let mlx = self.mlx
        let run = Task { () throws -> MLXGeneration in
            defer { continuation.finish() }
            return try await mlx.generate(prompt: request.prompt, limit: request.limit, temperature: Float(sampling.temperature),
                                          topK: sampling.topK, topP: Float(sampling.topP), minP: Float(sampling.minP ?? 0),
                                          repetitionPenalty: sampling.repeatPenalty.map(Float.init), contextSize: Int(request.contextSize),
                                          cancelled: { cancellation.isCancelled },
                                          onText: { continuation.yield($0) })
        }
        var started = false
        await withTaskCancellationHandler {
            for await piece in pieces {
                if !started { onPrefill(1, 1); started = true }
                onText(piece)
            }
        } onCancel: { cancellation.cancel(); run.cancel() }
        let generation = try await run.value
        if cancellation.isCancelled { throw CancellationError() }
        let telemetry = InferenceTelemetry(prefillTokens: generation.promptTokens, reusedTokens: generation.reusedTokens,
                                           prefillDuration: generation.promptSeconds, decodedTokens: generation.generatedTokens,
                                           decodeDuration: generation.generateSeconds, footprintBytes: InferenceTelemetry.currentFootprintBytes())
        lock.withLock { lastWasMLX = true; lastTelemetry = telemetry }
        return generation.generatedTokens
    }
}
