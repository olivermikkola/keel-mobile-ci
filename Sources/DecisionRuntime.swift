import Foundation
import llama
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Runs a d1 decision model (LiquidAI d1-2B, a GGUF file) with llama.cpp and
/// answers questions about one document per call. Nothing is generated: each
/// answer is read from the next-token scores of the option labels.
///
/// Each question is read as one single batch, document included. d1's
/// short convolutions keep nothing between batches, so a prompt read in
/// pieces, or a document read once and reused for several questions, gives
/// different answers (measured against llama.cpp's server: up to 0.79 apart).
/// llama.cpp's server does the same ("a question is read in one batch").
///
/// Plain Foundation and llama.cpp only: `tools/decide-eval` builds this same
/// file on Linux to compare it with llama.cpp's `/v1/systemone` server.
actor DecisionRuntime {
    struct Settings: Sendable {
        /// Most tokens of one question, document included. Each question is
        /// read in one batch of up to this size, so it also sets the memory
        /// the model needs while reading.
        /// llama.cpp's reading buffer grows by about 0.55 MB per token of this
        /// size (measured: 2.2 GB at 4,096 tokens, 9.7 GB at 16,384), so a
        /// phone reads at most 4,096 tokens per question; longer documents
        /// are read in parts (`parts(of:)`).
        var contextSize: UInt32 = 4_096
        var gpu = true
        var threads: Int32 = DecisionRuntime.preferredCPUThreads()
        /// Flash attention keeps the reading buffer from growing with the
        /// square of the batch. Off only to measure the difference.
        var flashAttention = true
    }

    private static let backend: Void = {
        // llama.cpp diagnostics may contain prompt fragments; never log them.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    static func preferredCPUThreads() -> Int32 {
        #if canImport(Darwin) && !targetEnvironment(simulator)
        var perfCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &perfCores, &size, nil, 0) == 0, perfCores > 0 {
            return min(4, perfCores)
        }
        #endif
        return Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    struct Result: Sendable {
        let answers: [DecisionAnswer]
        /// Tokens the model read for this document, all questions included.
        let readTokens: Int
        /// The share of the document's text that fitted, 1 when all of it did.
        let fractionRead: Double
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var loadedSettings: Settings?
    private var spellings: [String] = []
    private var temperatures: [String: Double] = [:]
    /// Set by a cancelled task, read by llama.cpp between steps of a batch.
    private let abort = AbortFlag()

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil; model = nil; loadedPath = nil; loadedSettings = nil
    }

    private func load(_ path: String, settings: Settings) throws {
        if loadedPath == path, let loadedSettings, loadedSettings.contextSize == settings.contextSize,
           loadedSettings.gpu == settings.gpu, loadedSettings.threads == settings.threads,
           loadedSettings.flashAttention == settings.flashAttention, context != nil { return }
        unload()
        _ = Self.backend
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = settings.gpu ? 99 : 0
        var cpuDevices: [OpaquePointer?] = [nil]
        let loaded = cpuDevices.withUnsafeMutableBufferPointer { devices in
            if !settings.gpu { parameters.devices = devices.baseAddress }
            return llama_model_load_from_file(path, parameters)
        }
        guard let loaded else { throw DecisionRuntimeError.load }

        let architecture = Self.meta(loaded, "general.architecture") ?? ""
        let type = Self.meta(loaded, architecture + ".decision.type") ?? ""
        guard type == DecisionModel.type else { llama_model_free(loaded); throw DecisionError.notDecisionModel(type) }
        var temperatures: [String: Double] = [:]
        let prefix = architecture + ".decision.temperature."
        for index in 0..<llama_model_meta_count(loaded) {
            var key = [CChar](repeating: 0, count: 256), value = [CChar](repeating: 0, count: 64)
            guard llama_model_meta_key_by_index(loaded, index, &key, key.count) >= 0,
                  llama_model_meta_val_str_by_index(loaded, index, &value, value.count) >= 0 else { continue }
            let name = String(cString: key)
            guard name.hasPrefix(prefix), let temperature = Double(String(cString: value)), temperature > 0 else { continue }
            temperatures[String(name.dropFirst(prefix.count))] = temperature
        }
        guard let vocab = llama_model_get_vocab(loaded) else { llama_model_free(loaded); throw DecisionRuntimeError.load }
        var controls: [String] = []
        for token in 0..<llama_vocab_n_tokens(vocab)
        where llama_vocab_get_attr(vocab, token).rawValue & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0 {
            if let text = llama_vocab_get_text(vocab, token) { controls.append(String(cString: text)) }
        }

        var options = llama_context_default_params()
        options.n_ctx = settings.contextSize
        // One question, one batch: d1 gives other answers when a prompt is split.
        options.n_batch = settings.contextSize
        options.n_ubatch = settings.contextSize
        options.n_seq_max = 1
        options.flash_attn_type = settings.flashAttention ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED
        options.n_threads = settings.threads
        options.n_threads_batch = settings.threads
        if !settings.gpu { options.offload_kqv = false; options.op_offload = false }
        options.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        options.abort_callback_data = Unmanaged.passUnretained(abort).toOpaque()
        guard let created = llama_init_from_model(loaded, options) else {
            llama_model_free(loaded)
            throw DecisionRuntimeError.context
        }
        model = loaded; context = created; loadedPath = path; loadedSettings = settings
        spellings = DecisionModel.spellings(controls)
        self.temperatures = temperatures
    }

    private static func meta(_ model: OpaquePointer, _ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard llama_model_meta_val_str(model, key, &buffer, buffer.count) >= 0 else { return nil }
        return String(cString: buffer)
    }

    /// The parts a document is read in so that every question about each part
    /// fits `contextSize`: the document itself when it fits.
    func parts(of document: String, questions: [DecisionQuestion], modelPath: String,
               settings: Settings = Settings()) throws -> [String] {
        try load(modelPath, settings: settings)
        guard let model, let vocab = llama_model_get_vocab(model) else { throw DecisionRuntimeError.load }
        let tokenizer = Tokenizer(vocab: vocab)
        let labels = try questions.map { try DecisionModel.labels(for: $0, tokenizer: tokenizer) }
        let overhead = zip(questions, labels).map { question, labels in
            tokenizer.tokens(DecisionModel.prompt(state: "", question: question, labels: labels.map(\.text), spellings: spellings),
                             parseSpecial: true).count
        }.max() ?? 0
        // Room for the document in the longest question, with a margin for
        // tokens that merge differently at the joins.
        let room = Int(settings.contextSize) - overhead - 32
        guard room > 64 else { throw DecisionError.tooLong(tokens: overhead, limit: Int(settings.contextSize)) }
        func size(_ text: String) -> Int {
            tokenizer.tokens(DecisionModel.breakSpecial(text, spellings: spellings), parseSpecial: true).count
        }
        let total = size(document)
        if total <= room { return [document] }
        var count = (total + room - 1) / room
        while count <= 400 {
            try Task.checkCancellation()
            let parts = DecisionModel.split(document, into: count)
            if parts.allSatisfy({ size($0) <= room }) { return parts }
            count += max(1, count / 10)
        }
        throw DecisionError.tooLong(tokens: total, limit: Int(settings.contextSize))
    }

    /// Answers every question about `document` (nil: no document). A document
    /// too long for the context is cut at the end; `fractionRead` says how much
    /// was read. `between` runs before each question (heat checks).
    func ask(document: String?, questions: [DecisionQuestion], modelPath: String, settings: Settings = Settings(),
             between: @Sendable () async throws -> Void = {}) async throws -> Result {
        guard !questions.isEmpty else { return Result(answers: [], readTokens: 0, fractionRead: 1) }
        try load(modelPath, settings: settings)
        guard let model, let context, let vocab = llama_model_get_vocab(model) else { throw DecisionRuntimeError.load }
        let tokenizer = Tokenizer(vocab: vocab)
        let labels = try questions.map { try DecisionModel.labels(for: $0, tokenizer: tokenizer) }
        let limit = Int(settings.contextSize)

        func prompts(_ text: String?) -> [[Int32]] {
            zip(questions, labels).map { question, labels in
                tokenizer.tokens(DecisionModel.prompt(state: text, question: question, labels: labels.map(\.text), spellings: spellings),
                                 parseSpecial: true)
            }
        }
        var text = document
        var tokens = prompts(text)
        var fraction = 1.0
        if let document, let longest = tokens.map(\.count).max(), longest > limit {
            // Cut the document to fit, then check again: tokens per character vary.
            let documentTokens = max(1, tokenizer.tokens(document, parseSpecial: false).count)
            var room = Double(limit - (longest - documentTokens) - 8) / Double(documentTokens)
            for _ in 0..<6 {
                guard room > 0 else { break }
                let characters = Int(Double(document.count) * room)
                text = String(document.prefix(characters))
                tokens = prompts(text)
                if (tokens.map(\.count).max() ?? 0) <= limit { fraction = Double(characters) / Double(document.count); break }
                room *= 0.95
            }
            if (tokens.map(\.count).max() ?? 0) > limit { throw DecisionError.tooLong(tokens: longest, limit: limit) }
        }
        if let longest = tokens.map(\.count).max(), longest > limit { throw DecisionError.tooLong(tokens: longest, limit: limit) }

        let memory = llama_get_memory(context)
        defer { llama_memory_clear(memory, true) }
        var read = 0
        var answers: [DecisionAnswer] = []
        for (index, question) in questions.enumerated() {
            try await between()
            try Task.checkCancellation()
            llama_memory_clear(memory, true)
            let logits = try await decode(tokens[index], context: context)
            read += tokens[index].count
            let width = Int(llama_vocab_n_tokens(vocab))
            let groups = try labels[index].map { label in
                try label.tokens.map { token -> Float in
                    guard token >= 0, Int(token) < width else { throw DecisionError.result }
                    return logits[Int(token)]
                }
            }
            answers.append(try DecisionModel.answer(question, labelLogits: groups,
                                                    temperature: DecisionModel.temperature(for: question, temperatures: temperatures)))
        }
        return Result(answers: answers, readTokens: read, fractionRead: fraction)
    }

    /// Reads `tokens` from position 0 in one batch and returns the
    /// next-token logits after the last one. A cancelled task stops llama.cpp
    /// mid-batch through the abort callback.
    private func decode(_ tokens: [Int32], context: OpaquePointer) async throws -> UnsafeBufferPointer<Float> {
        guard !tokens.isEmpty, let model, let vocab = llama_model_get_vocab(model) else { throw DecisionError.result }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = llama_pos(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]?[0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        abort.isSet = false
        let status = await withTaskCancellationHandler {
            llama_decode(context, batch)
        } onCancel: { [abort] in abort.isSet = true }
        abort.isSet = false
        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else { throw DecisionRuntimeError.decode }
        guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else { throw DecisionError.result }
        return UnsafeBufferPointer(start: logits, count: Int(llama_vocab_n_tokens(vocab)))
    }

    final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private struct Tokenizer: DecisionTokenizer {
        let vocab: OpaquePointer
        func tokens(_ text: String, parseSpecial: Bool) -> [Int32] {
            let length = Int32(text.utf8.count)
            var buffer = [llama_token](repeating: 0, count: max(64, text.utf8.count / 3 + 16))
            var count = llama_tokenize(vocab, text, length, &buffer, Int32(buffer.count), false, parseSpecial)
            if count < 0 {
                buffer = [llama_token](repeating: 0, count: Int(-count))
                count = llama_tokenize(vocab, text, length, &buffer, Int32(buffer.count), false, parseSpecial)
            }
            return Array(buffer.prefix(Int(max(0, count))))
        }
    }
}

enum DecisionRuntimeError: LocalizedError {
    case load, context, decode
    var errorDescription: String? {
        switch self {
        case .load: return "The decision model could not be opened. Remove it and download it again."
        case .context: return "There is not enough memory to read this document. Close other apps and try again."
        case .decode: return "The decision model stopped while reading. Try again."
        }
    }
}
