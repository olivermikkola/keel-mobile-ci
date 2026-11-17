import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads swift-transformers tokenizers for mlx-swift-lm (what its
/// `#huggingFaceTokenizerLoader` macro expands to, without the macro).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

enum MLXRunnerError: LocalizedError {
    case tooLong
    var errorDescription: String? { "This conversation is too long for the model's context. Start a new chat." }
}

/// One generation as MLX ran it.
struct MLXGeneration: Sendable {
    /// Prompt tokens read this time; `reusedTokens` more came from the cache.
    let promptTokens: Int
    var reusedTokens = 0
    let promptSeconds: Double
    let generatedTokens: Int
    let generateSeconds: Double
    let text: String
    let peakBytes: UInt64
}

/// MLX as a second runtime, for the runtime benchmark only. The prompt is
/// sent as already-rendered text, exactly as llama.cpp gets it, so the chat
/// template in the model folder is never used.
actor MLXRunner {
    private var container: ModelContainer?
    /// The cache from the last reply and the exact tokens it holds. An agent's
    /// next step is the same prompt plus the reply and a tool result, so only
    /// that new part needs reading. LFM3's short-conv state cannot be rewound,
    /// so the cache is reused only when the new prompt starts with all of it.
    private let promptCache = PromptCache()

    final class PromptCache: @unchecked Sendable {
        var cache: [KVCache] = []
        var tokens: [Int] = []
        var state: LMOutput.State?
        /// The last reply's cache position against the tokens known to be in it, for the probe.
        var lastPosition = (cache: 0, known: 0)
        func clear() { cache = []; tokens = []; state = nil }
    }

    var isLoaded: Bool { container != nil }

    func load(directory: URL) async throws {
        guard container == nil else { return }
        // Keep MLX's reusable buffer cache small on a phone.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
    }

    /// Why a prompt would or would not reuse the cache, for the probe.
    func reuseDiagnosis(prompt: String) async -> String {
        guard let container else { return "not loaded" }
        let saved = promptCache
        return await container.perform { context in
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let offsets = saved.cache.map(\.offset)
            guard !saved.tokens.isEmpty else {
                return "nothing cached (last reply: cache at \(saved.lastPosition.cache), \(saved.lastPosition.known) tokens known)"
            }
            let common = zip(saved.tokens, ids).prefix { $0 == $1 }.count
            func text(_ tokens: ArraySlice<Int>) -> String {
                context.tokenizer.decode(tokenIds: Array(tokens), skipSpecialTokens: false).replacingOccurrences(of: "\n", with: "⏎")
            }
            return "cached \(saved.tokens.count) tokens (offsets \(offsets)), prompt \(ids.count), same for the first \(common)"
                + (common < saved.tokens.count
                   ? " · cached continues «\(text(saved.tokens[common..<min(saved.tokens.count, common + 12)]))» · prompt continues «\(text(ids[common..<min(ids.count, common + 12)]))»"
                   : "")
        }
    }

    func unload() {
        // Clearing the cache starts MLX's Metal backend; with nothing loaded
        // there is nothing to free (and the simulator has no GPU to start).
        guard container != nil else { return }
        promptCache.clear()
        container = nil
        MLX.Memory.clearCache()
    }

    /// `onText` receives the reply piece by piece as it is written; `contextSize`
    /// refuses a prompt that would not fit, as llama.cpp's context does.
    func generate(prompt: String, limit: Int, temperature: Float, topK: Int, topP: Float, minP: Float = 0,
                  repetitionPenalty: Float? = nil, contextSize: Int? = nil, reuseCache: Bool = true,
                  cancelled: @escaping @Sendable () -> Bool,
                  onText: (@Sendable (String) -> Void)? = nil) async throws -> MLXGeneration {
        guard let container else { throw CocoaError(.fileReadNoSuchFile) }
        let saved = promptCache
        return try await container.perform { context in
            // The rendered text already carries the beginning-of-text token.
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            if let contextSize, ids.count + limit >= contextSize { throw MLXRunnerError.tooLong }
            // Penalty window as llama.cpp's sampler in LocalInference (last 64 tokens).
            let parameters = GenerateParameters(maxTokens: limit, temperature: temperature, topP: topP, topK: topK, minP: minP,
                                                repetitionPenalty: repetitionPenalty, repetitionContextSize: 64)
            MLX.Memory.peakMemory = 0
            var generated: [Int] = []
            var detokenizer = context.tokenizer.makeStreamingDetokenizer()
            let reuse = reuseCache && !saved.tokens.isEmpty && ids.count > saved.tokens.count && ids.starts(with: saved.tokens)
            let cache: [KVCache]
            if reuse { cache = saved.cache } else { cache = try context.model.newCache(parameters: parameters) }
            let reused = reuse ? saved.tokens.count : 0
            let state = reuse ? saved.state : nil
            let input = LMInput(tokens: MLXArray(Array(ids[reused...])))
            saved.clear() // Rebuilt below once this reply has finished cleanly.
            let iterator = try TokenIterator(input: input, model: context.model, cache: cache, state: state, parameters: parameters)
            var stopped = false
            let info = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (token: Int) -> GenerateDisposition in
                generated.append(token)
                if let onText {
                    detokenizer.append(token: token)
                    if let piece = detokenizer.next() { onText(piece) }
                }
                if cancelled() { stopped = true; return .stop }
                return generated.count >= limit ? .stop : .more
            }
            // What the cache now holds: the prompt and the reply tokens it has
            // read (the last sampled token is never fed back). Keep it only
            // when that can be proven from the cache's own position.
            let processed = cache.map(\.offset).max() ?? 0
            var held = ids + generated
            // MLX reads one token ahead: a reply that ended on end-of-turn has
            // already fed that token, which never reaches `generated`. The next
            // prompt continues with the same token after the reply.
            if processed == held.count + 1, let end = context.tokenizer.eosToken.flatMap(context.tokenizer.convertTokenToId) {
                held.append(end)
            }
            saved.lastPosition = (processed, held.count)
            if reuseCache, !stopped, processed >= ids.count, processed <= held.count {
                saved.cache = cache
                saved.tokens = Array(held.prefix(processed))
                saved.state = iterator.state
            }
            if let onText, let rest = detokenizer.finish(), !rest.isEmpty { onText(rest) }
            return MLXGeneration(promptTokens: info.promptTokenCount, reusedTokens: reused, promptSeconds: info.promptTime,
                                 generatedTokens: info.generationTokenCount, generateSeconds: info.generateTime,
                                 text: context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: false),
                                 peakBytes: UInt64(max(0, MLX.Memory.peakMemory)))
        }
    }
}
