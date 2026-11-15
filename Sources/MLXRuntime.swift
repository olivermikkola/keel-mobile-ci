import Foundation
#if canImport(MLXLLM) && !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration
import Tokenizers
#endif

/// MLX, Apple's machine-learning framework, as a candidate second runtime.
/// Used only by the runtime benchmark (`RuntimeBenchmarkView`) until the
/// benchmark shows it is worth more. MLX needs a real GPU: the simulator
/// cannot run it, so there every call throws `MLXRuntimeError.unsupported`.
enum MLXRuntimeError: LocalizedError {
    case unsupported, missingFiles, grammar(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "MLX needs a real iPhone; the simulator cannot run it."
        case .missingFiles: return "The MLX model is not downloaded yet."
        case .grammar(let detail): return "MLX could not prepare the tool-call format: \(detail)"
        }
    }
}

/// A model stored as MLX files in its own folder, pinned by revision and hash.
struct MLXModelFiles: Sendable {
    let name: String
    let folder: String
    let files: [ModelAsset]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// LFM3 1.7B in 4-bit, Liquid's own MLX build: the same model as the
    /// catalog's GGUF (`LFM3-1.7B-Q4_K_M.gguf`), so only the runtime differs.
    static let lfm3: MLXModelFiles = {
        let repository = "LiquidAI/LFM3-1.7B-MLX-4bit", revision = "91f34088d6946482cbcae11b85d4657093618c34"
        func file(_ name: String, _ bytes: Int64, _ sha256: String) -> ModelAsset {
            ModelAsset(fileName: name, repository: repository, revision: revision, bytes: bytes, sha256: sha256)
        }
        return MLXModelFiles(name: "LFM3 · 1.7B (MLX 4-bit)", folder: "LFM3-1.7B-MLX-4bit", files: [
            file("config.json", 2_423, "7df2ea819f9a31b770192a0a9dc1b7953a7dd8c41b816cc3905bbec99ef332bd"),
            file("generation_config.json", 328, "0095ba7158e938b1e2d3082d412f00d8be85e42cbbd7608b63866f7a081cf270"),
            file("special_tokens_map.json", 92, "7946f864cbfb62a1b041bda937244210a1a87f4a6cab3a48b791131b2cd57f88"),
            file("tokenizer_config.json", 1_859, "b77214b9f12be74b9e5e1dab35d7dace077a31be969314bf38866fd6c8163853"),
            file("chat_template.jinja", 12_143, "306497f109439afcfa248f4ef5800601de24942e2981d632ae63fc5c070ceb12"),
            file("tokenizer.json", 17_908_634, "41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44"),
            file("model.safetensors", 973_083_386, "1be5bf672013cd91aa62148f77c5eea8d2784a95845d5fe826e08c7b84823815"),
        ])
    }()

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXModels", isDirectory: true)
    }
    var directory: URL { Self.root.appendingPathComponent(folder, isDirectory: true) }

    /// True when every file is present at its pinned size. Hashes are checked when downloading.
    var isDownloaded: Bool {
        files.allSatisfy { file in
            let size = try? directory.appendingPathComponent(file.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == file.bytes
        }
    }

    /// Downloads each missing file, checks its size and SHA-256 with the app's
    /// own check, and only then moves it into place.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = Self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        var done: Int64 = 0
        for file in files {
            let target = directory.appendingPathComponent(file.fileName)
            if let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes {
                done += file.bytes; progress(Double(done) / Double(bytes)); continue
            }
            let model = file.transferModel
            let (temporary, response) = try await URLSession.shared.download(from: model.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalModelError.http }
            try ModelLibrary.verify(temporary, model: model)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            done += file.bytes; progress(Double(done) / Double(bytes))
        }
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

/// Runs one rendered prompt on MLX and reports the same numbers llama.cpp does.
actor MLXInference {
    struct Result: Sendable {
        let text: String
        let promptTokens: Int
        let promptSeconds: Double
        let generatedTokens: Int
        let generateSeconds: Double
    }

    #if canImport(MLXLLM) && !targetEnvironment(simulator)
    private var container: ModelContainer?
    private var loadedFolder: URL?

    private func load(_ files: MLXModelFiles) async throws -> ModelContainer {
        if let container, loadedFolder == files.directory { return container }
        guard files.isDownloaded else { throw MLXRuntimeError.missingFiles }
        // Keep MLX's buffer cache small: iOS ends apps that hold too much memory.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        let loaded = try await loadModelContainer(from: files.directory, using: TokenizerFolderLoader())
        container = loaded; loadedFolder = files.directory
        return loaded
    }

    func unload() {
        container = nil; loadedFolder = nil
        MLX.Memory.clearCache()
    }

    /// The prompt is already rendered in the model's chat format, so it is
    /// tokenized as is, exactly the text llama.cpp gets. A `grammar` constrains
    /// tool calls once the output starts one, as llama.cpp's lazy grammar does.
    func generate(_ files: MLXModelFiles, prompt: String, limit: Int, sampling: SamplingProfile,
                  grammar: ToolCallGrammar?) async throws -> Result {
        let container = try await load(files)
        let temperature = Float(sampling.temperature), topP = Float(sampling.topP), topK = sampling.topK
        let penalty = sampling.repeatPenalty.map(Float.init)
        return try await container.perform { (context: ModelContext) async throws -> Result in
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let input = LMInput(tokens: MLXArray(tokens.map(Int32.init)))
            var parameters = GenerateParameters(maxTokens: limit, temperature: temperature, topP: topP, topK: topK, seed: 7)
            parameters.repetitionPenalty = penalty
            var components = GenerationComponents()
            if let grammar {
                let lazy = try LazyToolCallProcessor(grammar: grammar, tokenizer: context.tokenizer)
                components = components.appendingLogitProcessor { lazy.fresh() }
            }
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters,
                                             components: components)
            var generated: [Int] = []
            let info = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (token: Int) -> GenerateDisposition in
                generated.append(token)
                return .more
            }
            return Result(text: context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true),
                          promptTokens: info.promptTokenCount, promptSeconds: info.promptTime,
                          generatedTokens: info.generationTokenCount, generateSeconds: info.generateTime)
        }
    }
    #else
    func unload() {}
    func generate(_ files: MLXModelFiles, prompt: String, limit: Int, sampling: SamplingProfile,
                  grammar: ToolCallGrammar?) async throws -> Result {
        throw MLXRuntimeError.unsupported
    }
    #endif
}

#if canImport(MLXLLM) && !targetEnvironment(simulator)
/// Loads the tokenizer from the model's own folder (no network).
private struct TokenizerFolderLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
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
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// llama.cpp's lazy grammar, for MLX: text is free until the output matches
/// one of the grammar's trigger patterns, then every token must keep the tool
/// call valid. The grammar is fed the text from the trigger's capture group on,
/// as llama.cpp does. The compiled grammar is shared; each trigger starts a
/// clone of the untouched template matcher.
private final class LazyToolCallProcessor: LogitProcessor, @unchecked Sendable {
    private let template: GrammarConstraint
    private let tokenizer: any MLXLMCommon.Tokenizer
    private let triggers: [NSRegularExpression]
    private let vocabSize: Int
    private var matcher: GrammarConstraint?
    private var generated: [Int] = []

    init(grammar: ToolCallGrammar, tokenizer: any MLXLMCommon.Tokenizer) throws {
        let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
        do {
            let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                                                        eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            template = try GrammarConstraint(tokenizer: grammarTokenizer, grammar: grammar.text, rootRule: ToolCallGrammar.root)
            vocabSize = grammarTokenizer.vocabSize
        } catch {
            throw MLXRuntimeError.grammar(String(describing: error))
        }
        self.tokenizer = tokenizer
        triggers = try grammar.triggerPatterns.map { try NSRegularExpression(pattern: $0) }
    }

    private init(copying other: LazyToolCallProcessor, withState: Bool) {
        template = other.template; tokenizer = other.tokenizer; triggers = other.triggers; vocabSize = other.vocabSize
        if withState { matcher = try? other.matcher?.clone(); generated = other.generated }
    }

    /// A new processor for a new generation: shares the compiled grammar, not the state.
    func fresh() -> any LogitProcessor { LazyToolCallProcessor(copying: self, withState: false) }
    /// An independent copy with the same state, as `LogitProcessor` requires of classes.
    func copy() -> LazyToolCallProcessor { LazyToolCallProcessor(copying: self, withState: true) }

    func prompt(_ prompt: MLXArray) { matcher = nil; generated.removeAll() }

    func process(logits: MLXArray) -> MLXArray {
        guard let matcher, let mask = try? matcher.computeMask(), mask.needsApply else { return logits }
        let width = logits.shape[logits.ndim - 1]
        var bias = [Float](repeating: -Float.infinity, count: width)
        for index in 0..<min(vocabSize, width) where (UInt32(bitPattern: mask.mask[index / 32]) >> UInt32(index % 32)) & 1 == 1 {
            bias[index] = 0
        }
        return logits + MLXArray(bias)
    }

    func didSample(token: MLXArray) {
        let id = token.item(Int.self)
        if let matcher {
            _ = try? matcher.commitToken(Int32(id))
            return
        }
        generated.append(id)
        let text = tokenizer.decode(tokenIds: generated, skipSpecialTokens: false)
        let range = NSRange(text.startIndex..., in: text)
        for trigger in triggers {
            guard let match = trigger.firstMatch(in: text, range: range) else { continue }
            let start = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let from = Range(start, in: text), let started = try? template.clone() else { return }
            for piece in tokenizer.encode(text: String(text[from.lowerBound...]), addSpecialTokens: false) {
                _ = try? started.commitToken(Int32(piece))
            }
            matcher = started
            return
        }
    }

    func didEmit(token: Int) {}
    func finalizeGeneration() {}
}
#endif
