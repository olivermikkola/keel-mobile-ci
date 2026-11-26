import Foundation
import llama
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Turns text into vectors with a small embedding model (a GGUF file run by
/// llama.cpp). It always runs on the CPU: the model is small, the graphics
/// processor stays free for the chat model, and it also works in the background.
actor EmbeddingRuntime {
    /// Longer inputs are cut to this many tokens. A passage is far shorter.
    static let maxTokens = 512
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil; model = nil; loadedPath = nil
    }

    private func load(_ path: String) throws {
        if loadedPath == path, context != nil { return }
        unload()
        LocalInference.prepareBackend()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 0
        var cpuDevices: [OpaquePointer?] = [nil]
        let loaded = cpuDevices.withUnsafeMutableBufferPointer { devices in
            parameters.devices = devices.baseAddress
            return llama_model_load_from_file(path, parameters)
        }
        guard let loaded else { throw LocalModelError.load }
        var options = llama_context_default_params()
        options.n_ctx = UInt32(Self.maxTokens)
        options.n_batch = UInt32(Self.maxTokens)
        options.n_ubatch = UInt32(Self.maxTokens)
        options.embeddings = true
        options.n_threads = LocalInference.preferredCPUThreads()
        options.n_threads_batch = options.n_threads
        options.offload_kqv = false
        options.op_offload = false
        guard let created = llama_init_from_model(loaded, options) else {
            llama_model_free(loaded)
            throw LocalModelError.context
        }
        model = loaded; context = created; loadedPath = path
    }

    /// One vector per text, each scaled to length 1. The model pools the
    /// tokens of a text the way its own file says (mean, for the ones we use).
    func embed(_ texts: [String], modelPath: String, isCancelled: @Sendable () -> Bool = { false }) async throws -> [[Float]] {
        try load(modelPath)
        guard let model, let context, let vocab = llama_model_get_vocab(model) else { throw LocalModelError.load }
        let width = Int(llama_model_n_embd(model))
        let encoderOnly = llama_model_has_encoder(model) && !llama_model_has_decoder(model)
        var vectors: [[Float]] = []
        for (step, text) in texts.enumerated() {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            switch ThermalPolicy.currentDecision(step: step) {
            case .proceed: break
            case .throttle(let pause):
                try await Task.sleep(nanoseconds: pause)
                if isCancelled() || Task.isCancelled { throw CancellationError() }
            case .stop:
                throw LocalModelError.thermal
            }
            var tokens = [llama_token](repeating: 0, count: Self.maxTokens)
            var count = Int(llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), true, false))
            if count < 0 {
                // Longer than the limit: tokenize it all, keep the start.
                var all = [llama_token](repeating: 0, count: -count)
                let full = Int(llama_tokenize(vocab, text, Int32(text.utf8.count), &all, Int32(all.count), true, false))
                guard full > 0 else { throw LocalModelError.decode }
                tokens = Array(all.prefix(Self.maxTokens)); count = tokens.count
            }
            guard count > 0 else { throw LocalModelError.decode }
            llama_memory_clear(llama_get_memory(context), true)
            var batch = llama_batch_init(Int32(count), 0, 1)
            defer { llama_batch_free(batch) }
            for index in 0..<count {
                batch.token[index] = tokens[index]
                batch.pos[index] = llama_pos(index)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]?[0] = 0
                // Pooling needs every token's output, not only the last one's.
                batch.logits[index] = 1
            }
            batch.n_tokens = Int32(count)
            let status = encoderOnly ? llama_encode(context, batch) : llama_decode(context, batch)
            guard status == 0, let pooled = llama_get_embeddings_seq(context, 0) else { throw LocalModelError.decode }
            vectors.append(Recall.normalized(Array(UnsafeBufferPointer(start: pooled, count: width))))
        }
        return vectors
    }
}

/// Keeps the vectors of passages already read by the embedding model, so a
/// search only works on what is new, and answers a `recall` call.
actor RecallIndex {
    /// At most this many passages are searched, newest documents first.
    static let maxPassages = 1_500
    /// New passages indexed per search. The rest wait for the next search,
    /// so the first one on a full phone does not take minutes.
    static let newPerSearch = 120

    private let runtime = EmbeddingRuntime()
    private let cacheURL: URL
    private var vectors: [String: [Float]]?

    init(cacheURL: URL) { self.cacheURL = cacheURL }

    func unload() async {
        vectors = nil
        await runtime.unload()
    }

    func search(_ query: String, documents: [Recall.Document], model: Recall.Model, modelPath: String,
                progress: @Sendable (Int, Int) -> Void = { _, _ in },
                isCancelled: @Sendable () -> Bool = { false }) async throws -> String {
        var known = vectors ?? Self.read(cacheURL)
        let passages = Array(documents.flatMap { Recall.passages(of: $0) }.prefix(Self.maxPassages))
        guard !passages.isEmpty else { return Recall.result(query: query, hits: [], searched: 0) }
        let inputs = passages.map { Recall.passageInput($0, model: model) }
        let keys = inputs.map { Recall.key($0, model: model) }
        let missing = keys.indices.filter { known[keys[$0]] == nil }
        let batch = Array(missing.prefix(Self.newPerSearch))
        var newlyIndexed = 0
        defer {
            if newlyIndexed > 0 {
                // Keep whatever passages were already embedded even if cancelled mid-batch.
                if newlyIndexed == missing.count {
                    let current = Set(keys)
                    known = known.filter { current.contains($0.key) }
                }
                Self.write(known, to: cacheURL)
                vectors = known
            }
            Task { await runtime.unload() }
        }
        for (done, index) in batch.enumerated() {
            progress(done, batch.count)
            let vector = try await runtime.embed([inputs[index]], modelPath: modelPath, isCancelled: isCancelled)
            known[keys[index]] = vector[0]
            newlyIndexed += 1
        }
        vectors = known
        let asked = try await runtime.embed([Recall.queryInput(query, model: model)], modelPath: modelPath, isCancelled: isCancelled)[0]
        let indexed = keys.indices.filter { known[keys[$0]] != nil }
        let hits = Recall.rank(query: asked, passages: indexed.map { passages[$0] }, vectors: indexed.map { known[keys[$0]] ?? [] })
        return Recall.result(query: query, hits: hits, searched: indexed.count, unindexed: passages.count - indexed.count)
    }

    /// Alignment-safe decode of raw Float32 bytes (Data decoded from a plist is
    /// not guaranteed 4-byte aligned on ARM64).
    static func decodeFloats(from bytes: Data) -> [Float] {
        let count = bytes.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        let byteCount = count * MemoryLayout<Float>.stride
        _ = floats.withUnsafeMutableBytes { destination in
            bytes.copyBytes(to: destination, count: byteCount)
        }
        return floats
    }

    static func encodeFloats(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func read(_ url: URL) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return [:] }
        return stored.mapValues(decodeFloats(from:))
    }

    private static func write(_ vectors: [String: [Float]], to url: URL) {
        let stored = vectors.mapValues(encodeFloats)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }
}
