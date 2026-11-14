import Foundation
import llama
import os

enum LocalModelError: LocalizedError {
    case load, context, decode, tooLong, integrity, storage, http, thermal
    var errorDescription: String? {
        switch self {
        case .load: return "The model could not load. Close other apps or try the smaller model."
        case .context: return "There is not enough memory for this conversation. Try the smaller model."
        case .decode: return "The model stopped unexpectedly. Your partial reply has been kept."
        case .tooLong: return "This conversation exceeds the model’s context. Start a new chat or send a shorter message."
        case .integrity: return "The model download failed verification. Download it again."
        case .storage: return "There is not enough free storage to download this model."
        case .http: return "The model download failed. Check your connection and try again."
        case .thermal: return "Your iPhone needs to cool down. Your partial reply is kept; try again in a few minutes."
        }
    }
}

// Separate from the actor so a cancellation can interrupt a synchronous decode.
final class InferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

protocol LocalGenerating: Sendable {
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int
    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int
}

extension LocalGenerating {
    // Mocks and older implementations do not report prefill progress.
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        try await generate(path: path, prompt: prompt, limit: limit, contextSize: contextSize,
                           cancellation: cancellation, onText: onText)
    }

    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try await generate(path: path, prompt: prompt, limit: limit, cancellation: cancellation, onText: onText)
    }

    func generate(path: String, prompt: String, limit: Int = 512, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try await generate(path: path, prompt: prompt, limit: limit, contextSize: 4096, cancellation: cancellation, onText: onText)
    }
}

struct PrefixStats: Equatable {
    let reusedTokens: Int
    let decodedTokens: Int
}

actor LocalInference: LocalGenerating {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var loadedContextSize: UInt32 = 0
    // Append-only prompt cache. The context keeps the exact token sequence it
    // has already decoded, including generated tokens. Reuse is allowed only
    // when that whole sequence is a prefix of the next prompt; otherwise the
    // hybrid recurrent state cannot be rewound safely and we clear it.
    private var cachedTokens: [llama_token] = []
    private var lastStats = PrefixStats(reusedTokens: 0, decodedTokens: 0)
    private static let backend: Void = {
        // llama.cpp diagnostics may contain prompt fragments; never log them.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil; model = nil; loadedPath = nil; loadedContextSize = 0
        cachedTokens.removeAll()
        lastStats = PrefixStats(reusedTokens: 0, decodedTokens: 0)
    }

    func prefixStats() -> PrefixStats { lastStats }

    private func load(_ path: String, contextSize: UInt32 = 4096, cancellation: InferenceCancellation) throws {
        if loadedPath == path && loadedContextSize == contextSize { return }
        unload()
        #if !targetEnvironment(simulator)
        let bytes = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Hybrid attention means only every fourth layer has a KV cache.
        // Compute the requirement from the pinned model metadata rather than
        // reserving a flat 40 KB/token, which rejected models that actually fit.
        let architecture = LocalModel.catalog.first(where: { path.hasSuffix($0.fileName) })?.architecture ?? .bonsai2
        let required = architecture.requiredBytes(weights: UInt64(bytes), contextSize: contextSize)
        #if DEBUG
        print("MODEL_MEMORY weights=\(bytes) kv_per_token=\(architecture.kvBytesPerToken) context=\(contextSize) required=\(required) available=\(os_proc_available_memory())")
        #endif
        guard os_proc_available_memory() > required else { throw LocalModelError.context }
        #endif
        _ = Self.backend
        var parameters = llama_model_default_params()
        parameters.progress_callback = { _, pointer in
            guard let pointer else { return true }
            return !Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        parameters.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        #if targetEnvironment(simulator)
        parameters.n_gpu_layers = 0
        #else
        parameters.n_gpu_layers = 99
        #endif
        // A nil device list means "auto-select GPUs". A list containing only
        // nil explicitly selects CPU for model placement. The framework may
        // still probe Metal while registering its available backends.
        var cpuDevices: [OpaquePointer?] = [nil]
        let loaded = cpuDevices.withUnsafeMutableBufferPointer { devices in
            #if targetEnvironment(simulator)
            parameters.devices = devices.baseAddress
            #endif
            return llama_model_load_from_file(path, parameters)
        }
        guard let loaded else {
            if cancellation.isCancelled { throw CancellationError() }
            throw LocalModelError.load
        }
        var options = llama_context_default_params()
        options.n_ctx = contextSize
        options.n_batch = 256
        options.n_ubatch = 256
        options.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        options.n_threads_batch = options.n_threads
        #if targetEnvironment(simulator)
        options.offload_kqv = false
        options.op_offload = false
        #else
        // Quantized KV Cache:
        // Quantizing Keys and Values to 4-bit (GGML_TYPE_Q4_0) slashes KV cache memory consumption
        // by 75% compared to FP16, allowing a 32K context window to fit within the iPhone 15 Pro's
        // ~4.5 GB app memory ceiling.
        options.type_k = GGML_TYPE_Q4_0
        options.type_v = GGML_TYPE_Q4_0
        #endif
        guard let created = llama_init_from_model(loaded, options) else {
            llama_model_free(loaded)
            throw LocalModelError.context
        }
        model = loaded; context = created; loadedPath = path; loadedContextSize = contextSize
    }

    // The catalog contains only Bonsai 2 (Qwen ChatML). Thinking is disabled
    // explicitly to keep mobile replies bounded. Escape control tokens in data
    // so repository text cannot manufacture a ChatML role boundary.
    static func prompt(_ messages: [ChatMessage], system: String = "You are Keel, a helpful AI assistant running locally on this iPhone. Explain clearly. Tools are unavailable in this conversation, so you cannot access files, run commands, or change them.") -> String {
        // The rendering lives in the harness package so the eval tool sends
        // the model exactly what the phone does.
        AgentPrompt.chatML(system: system, messages: messages.map { (role: $0.role, text: $0.text) })
    }

    // Runs on this actor, never the main thread. The only output is text chunks.
    func generate(path: String, prompt: String, limit: Int = 512,
                  contextSize: UInt32 = 4096,
                  cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        // async on purpose: LocalGenerating's extension has an async overload
        // with this exact signature that drops onPrefill. In async code Swift
        // prefers the async candidate, so a sync method here would lose to it.
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        try checkThermals()
        try load(path, contextSize: contextSize, cancellation: cancellation)
        guard let model, let context else { throw LocalModelError.load }
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let vocab = llama_model_get_vocab(model) else { throw LocalModelError.load }
        var completed = false
        llama_set_abort_callback(context, { pointer in
            guard let pointer else { return false }
            return Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer {
            llama_set_abort_callback(context, nil, nil)
            // A canceled or failed turn leaves an unknown suffix in the
            // context. Drop it rather than guessing what can be reused.
            if !completed {
                llama_memory_clear(llama_get_memory(context), true)
                cachedTokens.removeAll()
            }
        }

        let required = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), nil, 0, true, true)
        let count = Int(abs(required))
        guard count > 0, count + limit < Int(llama_n_ctx(context)) else { throw LocalModelError.tooLong }
        var tokens = [llama_token](repeating: 0, count: count)
        let actual = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(count), true, true)
        guard Int(actual) == count else { throw LocalModelError.decode }
        // Reuse the decoded sequence only when it is an exact token prefix.
        // Prefix reuse is what removes the repeated multi-second prefill on
        // every tool step; a divergence falls back to a clean prefill.
        var prefix = 0
        while prefix < cachedTokens.count, prefix < tokens.count, cachedTokens[prefix] == tokens[prefix] { prefix += 1 }
        if prefix != cachedTokens.count {
            llama_memory_clear(llama_get_memory(context), true)
            cachedTokens.removeAll()
            prefix = 0
        }
        lastStats = PrefixStats(reusedTokens: prefix, decodedTokens: count - prefix)
        onPrefill(prefix, count)
        for offset in stride(from: prefix, to: count, by: 256) {
            if cancellation.isCancelled { throw CancellationError() }
            try checkThermals()
            let length = min(256, count - offset)
            let result = tokens.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress!.advanced(by: offset), Int32(length)))
            }
            guard result == 0 else {
                if cancellation.isCancelled { throw CancellationError() }
                throw LocalModelError.decode
            }
            onPrefill(min(count, offset + length), count)
        }
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw LocalModelError.context }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        var pending = Data()
        var generated = 0
        var generatedTokens: [llama_token] = []
        generatedTokens.reserveCapacity(limit)
        for _ in 0..<limit {
            if cancellation.isCancelled { throw CancellationError() }
            try checkThermals()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var buffer = [CChar](repeating: 0, count: 256)
            var size = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if size < 0 {
                buffer = [CChar](repeating: 0, count: Int(-size))
                size = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            guard size >= 0 else { throw LocalModelError.decode }
            pending.append(contentsOf: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) })
            if let text = String(data: pending, encoding: .utf8) {
                onText(text); pending.removeAll(keepingCapacity: true)
            }
            let result = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard result == 0 else {
                if cancellation.isCancelled { throw CancellationError() }
                throw LocalModelError.decode
            }
            generatedTokens.append(token)
            generated += 1
        }
        if !pending.isEmpty { onText(String(decoding: pending, as: UTF8.self)) }
        cachedTokens = tokens + generatedTokens
        completed = true
        return generated
    }

    func generate(path: String, prompt: String, limit: Int = 512,
                  contextSize: UInt32 = 4096,
                  cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        try await generate(path: path, prompt: prompt, limit: limit, contextSize: contextSize,
                     cancellation: cancellation, onPrefill: { _, _ in }, onText: onText)
    }

    private func checkThermals() throws {
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            throw LocalModelError.thermal
        }
    }
}
