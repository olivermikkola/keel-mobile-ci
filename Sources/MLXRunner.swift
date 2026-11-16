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
    let promptTokens: Int
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

    var isLoaded: Bool { container != nil }

    func load(directory: URL) async throws {
        guard container == nil else { return }
        // Keep MLX's reusable buffer cache small on a phone.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
    }

    func unload() {
        // Clearing the cache starts MLX's Metal backend; with nothing loaded
        // there is nothing to free (and the simulator has no GPU to start).
        guard container != nil else { return }
        container = nil
        MLX.Memory.clearCache()
    }

    /// `onText` receives the reply piece by piece as it is written; `contextSize`
    /// refuses a prompt that would not fit, as llama.cpp's context does.
    func generate(prompt: String, limit: Int, temperature: Float, topK: Int, topP: Float, contextSize: Int? = nil,
                  cancelled: @escaping @Sendable () -> Bool,
                  onText: (@Sendable (String) -> Void)? = nil) async throws -> MLXGeneration {
        guard let container else { throw CocoaError(.fileReadNoSuchFile) }
        return try await container.perform { context in
            // The rendered text already carries the beginning-of-text token.
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            if let contextSize, ids.count + limit >= contextSize { throw MLXRunnerError.tooLong }
            let parameters = GenerateParameters(maxTokens: limit, temperature: temperature, topP: topP, topK: topK)
            MLX.Memory.peakMemory = 0
            var generated: [Int] = []
            var detokenizer = context.tokenizer.makeStreamingDetokenizer()
            let info = try MLXLMCommon.generate(input: LMInput(tokens: MLXArray(ids)), parameters: parameters, context: context) { (token: Int) -> GenerateDisposition in
                generated.append(token)
                if let onText {
                    detokenizer.append(token: token)
                    if let piece = detokenizer.next() { onText(piece) }
                }
                return generated.count >= limit || cancelled() ? .stop : .more
            }
            if let onText, let rest = detokenizer.finish(), !rest.isEmpty { onText(rest) }
            return MLXGeneration(promptTokens: info.promptTokenCount, promptSeconds: info.promptTime,
                                 generatedTokens: info.generationTokenCount, generateSeconds: info.generateTime,
                                 text: context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: false),
                                 peakBytes: UInt64(max(0, MLX.Memory.peakMemory)))
        }
    }
}
