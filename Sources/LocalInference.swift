import Foundation
import llama
import Metal
import os

enum LocalModelError: LocalizedError {
    case load, context, decode, tooLong, integrity, storage, http, thermal, vision, grammar
    var errorDescription: String? {
        switch self {
        case .grammar: return "Keel could not prepare the tool-call format for this model. Nothing was run."
        case .vision: return "This photo needs a ready vision model. Choose LFM3 VL and finish downloading its files."
        case .load: return "Keel could not open this model. Try again or choose a different model."
        case .context: return "This model ran out of memory on this device."
        case .decode: return "The model stopped unexpectedly. Your partial reply has been kept."
        case .tooLong: return "This conversation exceeds the model’s context. Start a new chat or send a shorter message."
        case .integrity: return "The model download failed verification. Download it again."
        case .storage: return "There is not enough free storage to download this model."
        case .http: return "The model download failed. Check your connection and try again."
        case .thermal: return "Your device reached critical heat. Your partial reply is kept; let it cool for a few minutes."
        }
    }
}

// Separate from the actor so a cancellation can interrupt a synchronous decode.
// A step's flag can have the turn's flag as parent: stopping the turn stops
// the step, and the step can stop alone (a looping reply) without ending the turn.
final class InferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let parent: InferenceCancellation?
    init(parent: InferenceCancellation? = nil) { self.parent = parent }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); let own = cancelled; lock.unlock()
        return own || parent?.isCancelled == true
    }
}

/// Whether llama.cpp can run a model on this graphics chip. Its Metal backend
/// (`ggml-metal-device.m`, pinned b12367) only enables simdgroup reduction and
/// simdgroup matrix multiply on the Apple7 family (A14 and newer). On an A12 or
/// A13 it refuses matrix multiply, softmax and flash attention there, so with
/// every layer "on the GPU" each step bounced to the CPU and back: an iPhone XR
/// decoded Qwen3 0.6B at 2.8 tok/s. Those chips run llama.cpp on the CPU.
enum LlamaGPU {
    static let usable: Bool = {
        #if targetEnvironment(simulator)
        return true // the simulator already runs on the CPU; keep moves testable
        #else
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
        #endif
    }()
}

/// Where the model's maths runs. iOS refuses graphics-processor work from an
/// app in the background, so a reply that continues there has to move to the
/// CPU, and may move back when the app returns. Set from the main thread,
/// read by the generation loop between tokens.
final class InferencePlacement: @unchecked Sendable {
    private let lock = NSLock()
    private var cpuOnly = false
    private var moveCount = 0
    /// Always the CPU on chips older than the A14 (`LlamaGPU.usable`).
    var wantsCPU: Bool { lock.withLock { cpuOnly } || !LlamaGPU.usable }
    /// How many times a loaded model was moved, for tests and diagnostics.
    var moves: Int { lock.withLock { moveCount } }
    func set(cpuOnly: Bool) { lock.withLock { self.cpuOnly = cpuOnly } }
    fileprivate func recordMove() { lock.withLock { moveCount += 1 } }
}

struct LocalGenerationRequest: Sendable {
    let path: String
    let prompt: String
    let limit: Int
    let contextSize: UInt32
    var model: LocalModel? = nil
    var images: [Data] = []
    var projectorPath: String? = nil
    /// Constrains tool calls once the model starts one; nil for plain chat.
    var grammar: ToolCallGrammar? = nil
    /// Additional tool schemas dynamically activated via `load_tools` without mutating the system prompt.
    var extraToolSchemas: [String] = []
    /// Always take the most likely token. For tests that compare two runs.
    var greedy = false
    /// A side question asked on the chat's prompt (the chat title): reading it
    /// must not replace the saved state the next real turn will start from.
    var keepCheckpoint = false
}

protocol LocalGenerating: Sendable {
    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int
    func generate(path: String, prompt: String, limit: Int, contextSize: UInt32, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int
    func generate(path: String, prompt: String, limit: Int, cancellation: InferenceCancellation,
                  onText: @Sendable (String) -> Void) async throws -> Int
    func latestTelemetry() async -> InferenceTelemetry?
    /// True while the reply being written can carry on after the app leaves
    /// the foreground (llama.cpp can move to the CPU; MLX and Apple's model cannot).
    var canContinueInBackground: Bool { get }
}

extension LocalGenerating {
    func latestTelemetry() async -> InferenceTelemetry? { nil }
    var canContinueInBackground: Bool { false }

    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        guard request.images.isEmpty else { throw LocalModelError.vision }
        return try await generate(path: request.path, prompt: request.prompt, limit: request.limit,
                                  contextSize: request.contextSize, cancellation: cancellation,
                                  onPrefill: onPrefill, onText: onText)
    }

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
    /// CPU features and backends compiled into the runtime, for diagnostics.
    nonisolated static var systemInfo: String { String(cString: llama_print_system_info()) }
    nonisolated let placement = InferencePlacement()
    nonisolated var canContinueInBackground: Bool { true }
    /// Whether the loaded model was placed on the CPU on request.
    private var loadedOnCPU = false
    private var loadedSettings: LocalModel?
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vision: OpaquePointer?
    private var loadedProjectorPath: String?
    private var loadedPath: String?
    private var loadedContextSize: UInt32 = 0
    // Append-only prompt cache. The context keeps the exact token sequence it
    // has already decoded, including generated tokens. Reuse is allowed only
    // when that whole sequence is a prefix of the next prompt; otherwise the
    // cache is trimmed to the shared start. Hybrid recurrent state cannot be
    // trimmed, so for those models `checkpoint` stands in.
    private var cachedTokens: [llama_token] = []
    /// Hybrid and recurrent models (Bonsai 2, LFM3) cannot rewind their
    /// recurrent state, so a prompt that differs anywhere after what was read
    /// used to be read again from the start: every tool step re-read the whole
    /// chat. After each prompt is read, this keeps that state (llama.cpp's
    /// partial sequence state, about 19 MB for Bonsai 2 2B) and the tokens it
    /// covers. When the next prompt starts with those tokens, the state is put
    /// back and only the new tokens are read, as llama-server's context
    /// checkpoints do. Valid only while `cachedTokens` starts with `tokens`, so
    /// every path that clears or trims the context also retires it.
    private var checkpoint: (tokens: [llama_token], state: [UInt8])?
    /// How many tokens before the end of a prompt `checkpoint` is taken.
    static let checkpointLag = 8
    private var lastStats = PrefixStats(reusedTokens: 0, decodedTokens: 0)
    private var lastTelemetry: InferenceTelemetry?
    /// Starts llama.cpp once for the whole app, with its logging off.
    nonisolated static func prepareBackend() { _ = backend }
    private static let backend: Void = {
        // llama.cpp diagnostics may contain prompt fragments; never log them.
        llama_log_set({ _, _, _ in }, nil)
        mtmd_helper_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    deinit {
        if let vision { mtmd_free(vision) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func unload() {
        if let vision { mtmd_free(vision) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        vision = nil; loadedProjectorPath = nil
        context = nil; model = nil; loadedPath = nil; loadedContextSize = 0
        loadedOnCPU = false; loadedSettings = nil
        cachedTokens.removeAll()
        checkpoint = nil
        lastStats = PrefixStats(reusedTokens: 0, decodedTokens: 0)
        lastTelemetry = nil
    }

    /// Saves the recurrent state while a prompt is read (see `checkpoint`).
    /// Attention-only models trim their cache directly and skip this.
    private func saveCheckpoint(_ context: OpaquePointer, tokens: [llama_token]) {
        checkpoint = nil
        guard let model, llama_model_is_hybrid(model) || llama_model_is_recurrent(model) else { return }
        let flags = llama_state_seq_flags(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)
        let size = llama_state_seq_get_size_ext(context, 0, flags)
        guard size > 0 else { return }
        #if !targetEnvironment(simulator)
        // A copy the phone cannot afford is not worth a memory warning.
        guard os_proc_available_memory() > size + 128_000_000 else { return }
        #endif
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data_ext(context, $0.baseAddress, size, 0, flags) }
        guard written == size else { return }
        checkpoint = (tokens, state)
    }

    /// Puts the saved state back when the first `shared` tokens of the next
    /// prompt include everything it covers, then drops the attention entries
    /// after it. Returns how many tokens the context now holds, or nil when it
    /// cannot be used (the caller then clears the context).
    private func restoreCheckpoint(_ context: OpaquePointer, shared: Int) -> Int? {
        guard let saved = checkpoint else { return nil }
        let covered = saved.tokens.count
        guard covered > 0, covered <= shared, cachedTokens.count >= covered, cachedTokens.starts(with: saved.tokens) else {
            checkpoint = nil
            return nil
        }
        let flags = llama_state_seq_flags(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)
        let read = saved.state.withUnsafeBufferPointer { llama_state_seq_set_data_ext(context, $0.baseAddress, $0.count, 0, flags) }
        guard read == saved.state.count, llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(covered), -1) else {
            checkpoint = nil
            return nil
        }
        cachedTokens.removeSubrange(covered...)
        return covered
    }

    /// After a step stops part-way through its reply, removes the reply from
    /// the context so it holds exactly a known prefix of `tokens`: all of them
    /// where the cache can be trimmed, otherwise up to `checkpoint`. Returns
    /// false when neither works (the caller then clears the context).
    private func keepReadPrompt(_ context: OpaquePointer, tokens: [llama_token]) -> Bool {
        cachedTokens = tokens
        if llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(tokens.count), -1) { return true }
        if restoreCheckpoint(context, shared: tokens.count) != nil { return true }
        cachedTokens.removeAll()
        return false
    }

    func prefixStats() -> PrefixStats { lastStats }
    // async on purpose: LocalGenerating's extension declares an async overload
    // returning nil; a sync actor method would lose to it in async callers.
    func latestTelemetry() async -> InferenceTelemetry? { lastTelemetry }

    private func load(_ path: String, contextSize: UInt32 = 4096, settings: LocalModel? = nil,
                      projectorPath: String? = nil, cpu: Bool = false, checkMemory: Bool = true,
                      cancellation: InferenceCancellation) throws {
        if loadedPath == path && loadedContextSize == contextSize && loadedProjectorPath == projectorPath && loadedOnCPU == cpu { return }
        unload()
        #if !targetEnvironment(simulator)
        let architecture = settings?.architecture ?? LocalModel.catalog.first(where: { path.hasSuffix($0.fileName) })?.architecture ?? .bonsai2
        if checkMemory {
        let bytes = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Hybrid attention means only every fourth layer has a KV cache.
        // Compute the requirement from the pinned model metadata rather than
        // reserving a flat 40 KB/token, which rejected models that actually fit.
        let visionBytes = settings?.visionFile?.bytes ?? 0
        let required = architecture.requiredBytes(weights: UInt64(bytes) + UInt64(visionBytes), contextSize: contextSize,
                                                  appHeadroom: visionBytes > 0 ? 640_000_000 : 384_000_000)
        #if DEBUG
        print("MODEL_MEMORY weights=\(bytes) kv_per_token=\(architecture.kvBytesPerToken) context=\(contextSize) required=\(required) available=\(os_proc_available_memory())")
        #endif
        guard os_proc_available_memory() > required else { throw LocalModelError.context }
        }
        #endif
        _ = Self.backend
        var parameters = llama_model_default_params()
        parameters.progress_callback = { _, pointer in
            guard let pointer else { return true }
            return !Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        parameters.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        #if targetEnvironment(simulator)
        let onCPU = true
        #else
        let onCPU = cpu
        #endif
        parameters.n_gpu_layers = onCPU ? 0 : 99
        // A nil device list means "auto-select GPUs". A list containing only
        // nil explicitly selects CPU for model placement. The framework may
        // still probe Metal while registering its available backends.
        var cpuDevices: [OpaquePointer?] = [nil]
        let loaded = cpuDevices.withUnsafeMutableBufferPointer { devices in
            if onCPU { parameters.devices = devices.baseAddress }
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
        options.n_threads = Self.preferredCPUThreads()
        options.n_threads_batch = options.n_threads
        if onCPU {
            options.offload_kqv = false
            options.op_offload = false
        }
        #if !targetEnvironment(simulator)
        // Use the same cache layout that the model's memory check budgeted.
        // Quantized V-cache requires Flash Attention on Metal.
        if architecture.kvBlockElements == 32 {
            options.type_k = architecture.kvBlockBytes == 34 ? GGML_TYPE_Q8_0 : GGML_TYPE_Q4_0
            options.type_v = options.type_k
            options.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        }
        #endif
        guard let created = llama_init_from_model(loaded, options) else {
            llama_model_free(loaded)
            throw LocalModelError.context
        }
        model = loaded; context = created; loadedPath = path; loadedContextSize = contextSize
        loadedOnCPU = cpu; loadedSettings = settings
        if let projectorPath {
            var params = mtmd_context_params_default()
            params.use_gpu = !onCPU
            params.n_threads = options.n_threads
            params.warmup = false
            params.progress_callback = { _, pointer in
                guard let pointer else { return true }
                return !Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            guard let projector = mtmd_init_from_file(projectorPath, loaded, params) else { unload(); throw LocalModelError.vision }
            vision = projector; loadedProjectorPath = projectorPath
            guard mtmd_support_vision(projector) else { unload(); throw LocalModelError.vision }
        }
    }

    /// Performance-core count on Apple Silicon (e.g. 2 on A17/A18/A19 Pro),
    /// avoiding ggml barrier stalls on slower Efficiency cores and cutting heat.
    nonisolated static func preferredCPUThreads() -> Int32 {
        #if targetEnvironment(simulator)
        // The simulator runs on the CPU. A 3-core CI Mac would otherwise get
        // one thread; measured LFM3 prompt reading went from ~1.3 to ~3 tok/s.
        return Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        #else
        var perfCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &perfCores, &size, nil, 0) == 0, perfCores > 0 {
            return min(4, perfCores)
        }
        return Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
        #endif
    }

    private enum MoveOutcome { case unchanged, movedWithState, reloadedClean }

    /// Moves the loaded model between the graphics processor and the CPU and
    /// keeps everything it has read: the conversation state is streamed to a
    /// protected temporary file (avoiding a 300–700 MB heap spike while both
    /// models exist), the GPU model is unloaded, the CPU model is loaded, and
    /// the state is streamed back in. Returns true when state was preserved,
    /// false when `allowDropState` fell back to a clean reload.
    private func move(toCPU: Bool, decoded: Int, allowDropState: Bool = false, cancellation: InferenceCancellation) throws -> Bool {
        guard let old = context, let path = loadedPath else { throw LocalModelError.load }
        let tokens = cachedTokens, contextSize = loadedContextSize, settings = loadedSettings, projector = loadedProjectorPath
        let memory = llama_get_memory(old)
        var keepState = true
        if Int(llama_memory_seq_pos_max(memory, 0)) >= decoded {
            if !llama_memory_seq_rm(memory, 0, llama_pos(decoded), -1) {
                guard allowDropState else { throw LocalModelError.decode }
                keepState = false
            }
        }
        let size = keepState ? llama_state_seq_get_size(old, 0) : 0
        var stateFile: URL?
        defer { if let stateFile { try? FileManager.default.removeItem(at: stateFile) } }
        if size > 0 {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("keel-state-\(UUID().uuidString).bin")
            // CompleteUntilFirstUserAuthentication keeps the ephemeral state file
            // encrypted at rest while still readable if the user locks the screen
            // during a background GPU-to-CPU handoff; `defer` deletes it right away.
            guard FileManager.default.createFile(atPath: temp.path, contents: nil,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                guard allowDropState else { throw LocalModelError.decode }
                keepState = false
                // Proceed to clean reload below without a state file.
                return try reloadClean(path: path, contextSize: contextSize, settings: settings,
                                       projector: projector, toCPU: toCPU, cancellation: cancellation)
            }
            stateFile = temp
            var dummyToken: llama_token = 0
            let written = llama_state_seq_save_file(old, temp.path, 0, &dummyToken, 0)
            if written == 0 {
                guard allowDropState else { throw LocalModelError.decode }
                return try reloadClean(path: path, contextSize: contextSize, settings: settings,
                                       projector: projector, toCPU: toCPU, cancellation: cancellation)
            }
        }
        // The old copy is freed before the new one is loaded, so peak RAM stays
        // bounded to one model copy instead of doubling during backgrounding.
        unload()
        try load(path, contextSize: contextSize, settings: settings, projectorPath: projector,
                 cpu: toCPU, checkMemory: false, cancellation: cancellation)
        guard let context else { throw LocalModelError.load }
        if let stateFile {
            var dummyToken: llama_token = 0
            var loadedCount = 0
            let read = llama_state_seq_load_file(context, stateFile.path, 0, &dummyToken, 1, &loadedCount)
            if read == 0 {
                if allowDropState {
                    llama_memory_clear(llama_get_memory(context), true)
                    cachedTokens.removeAll()
                    placement.recordMove()
                    return false
                }
                unload()
                throw LocalModelError.decode
            }
        }
        cachedTokens = keepState ? tokens : []
        placement.recordMove()
        return keepState
    }

    private func reloadClean(path: String, contextSize: UInt32, settings: LocalModel?,
                             projector: String?, toCPU: Bool, cancellation: InferenceCancellation) throws -> Bool {
        unload()
        try load(path, contextSize: contextSize, settings: settings, projectorPath: projector,
                 cpu: toCPU, checkMemory: false, cancellation: cancellation)
        cachedTokens.removeAll()
        placement.recordMove()
        return false
    }

    /// MiniCPM5's tool tags (`<function`, `<param`, ...) are control tokens,
    /// which plain detokenizing drops. Only those tags are rendered; every
    /// other control token stays hidden as before.
    static let toolMarkupTokens: Set<String> = ["<tool_call>", "</tool_call>", "<function", "</function>",
                                                "<param", "</param>", "<parameters>", "</parameters>",
                                                "<|tool_call_start|>", "<|tool_call_end|>"]

    private static func piece(_ token: llama_token, vocab: OpaquePointer) throws -> [UInt8] {
        func render(special: Bool) throws -> [UInt8] {
            var buffer = [CChar](repeating: 0, count: 256)
            var size = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)
            if size < 0 {
                buffer = [CChar](repeating: 0, count: Int(-size))
                size = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)
            }
            guard size >= 0 else { throw LocalModelError.decode }
            return buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }
        }
        let plain = try render(special: false)
        guard plain.isEmpty, llama_vocab_get_attr(vocab, token).rawValue & LLAMA_TOKEN_ATTR_CONTROL.rawValue != 0 else { return plain }
        let markup = try render(special: true)
        return toolMarkupTokens.contains(String(decoding: markup, as: UTF8.self)) ? markup : plain
    }

    // Native templates are selected per model, with thinking disabled and
    // control tokens in user/file data defused before trusted image markers.
    /// The system prompt of a chat with no tools.
    static let plainSystem = "You are Keel, a helpful AI assistant running locally on this device. Explain clearly. Tools are unavailable in this conversation, so you cannot access files, run commands, or change them."

    static func prompt(_ messages: [ChatMessage], system: String = plainSystem, model: LocalModel? = nil, customInstructions: String = "", thinking: Bool = false) -> String {
        // The rendering lives in the harness package so the eval tool sends
        // the model exactly what the phone does.
        let fullSystem = CustomInstructions.apply(customInstructions, to: system)
        return ModelPrompt.render(family: model?.family ?? .bonsai, system: fullSystem,
                                  messages: messages.map { (role: $0.role, text: $0.text) },
                                  imageCounts: messages.map { ($0.attachments ?? []).compactMap(\.imageID).count },
                                  thinking: thinking)
    }

    // Runs on this actor, never the main thread. The only output is text chunks.
    func generate(path: String, prompt: String, limit: Int = 512,
                  contextSize: UInt32 = 4096,
                  cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void,
                  onText: @Sendable (String) -> Void) async throws -> Int {
        let settings = LocalModel.catalog.first { path.hasSuffix($0.fileName) }
        return try await generate(LocalGenerationRequest(path: path, prompt: prompt, limit: limit,
            contextSize: contextSize, model: settings), cancellation: cancellation, onPrefill: onPrefill, onText: onText)
    }

    func generate(_ request: LocalGenerationRequest, cancellation: InferenceCancellation,
                  onPrefill: @Sendable (Int, Int) -> Void, onText: @Sendable (String) -> Void) async throws -> Int {
        let path = request.path, prompt = request.prompt, limit = request.limit, contextSize = request.contextSize
        guard request.images.count <= AttachmentLimits.maxImages,
              request.images.allSatisfy({ $0.count <= AttachmentLimits.maxImageBytes }),
              request.images.isEmpty || request.model?.visionFile != nil else { throw LocalModelError.vision }
        // async on purpose: LocalGenerating's extension has an async overload
        // with this exact signature that drops onPrefill. In async code Swift
        // prefers the async candidate, so a sync method here would lose to it.
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        try await checkThermals(cancellation: cancellation)
        if context != nil, loadedPath == path, loadedContextSize == contextSize, loadedProjectorPath == request.projectorPath,
           loadedOnCPU != placement.wantsCPU {
            // Same model, other place (the app went to the background or came
            // back between steps): move it and keep what it has read.
            do {
                _ = try move(toCPU: placement.wantsCPU, decoded: cachedTokens.count, allowDropState: true, cancellation: cancellation)
            }
            catch is CancellationError { throw CancellationError() }
            catch { unload() }
        }
        try load(path, contextSize: contextSize, settings: request.model, projectorPath: request.projectorPath,
                 cpu: placement.wantsCPU, cancellation: cancellation)
        guard var context, var vocab = model.flatMap({ llama_model_get_vocab($0) }) else { throw LocalModelError.load }
        guard !cancellation.isCancelled else { throw CancellationError() }
        var completed = false
        /// Set when a stopped step was rolled back to an exact point (see below).
        var rolledBack = false
        var prefillDuration: TimeInterval = 0
        var decodeStarted: TimeInterval?
        var generated = 0
        lastTelemetry = nil
        func watchForStop(_ context: OpaquePointer) {
            llama_set_abort_callback(context, { pointer in
                guard let pointer else { return false }
                return Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }, Unmanaged.passUnretained(cancellation).toOpaque())
        }
        watchForStop(context)
        defer {
            // The context may have been replaced by a move; use the current one.
            if let context = self.context {
            llama_set_abort_callback(context, nil, nil)
            if prefillDuration > 0 || generated > 0 || lastStats.reusedTokens > 0 {
                let decodeDuration = decodeStarted.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
                lastTelemetry = InferenceTelemetry(
                    prefillTokens: lastStats.decodedTokens,
                    reusedTokens: lastStats.reusedTokens,
                    prefillDuration: prefillDuration,
                    decodedTokens: generated,
                    decodeDuration: decodeDuration,
                    footprintBytes: InferenceTelemetry.currentFootprintBytes(),
                    onCPU: loadedOnCPU
                )
            }
            // A canceled or failed turn leaves an unknown suffix in the
            // context. Drop it rather than guessing what can be reused, unless
            // it was rolled back to an exact point.
            if (!completed && !rolledBack) || !request.images.isEmpty {
                llama_memory_clear(llama_get_memory(context), true)
                cachedTokens.removeAll()
            }
            } else { cachedTokens.removeAll() }
        }
        var sampler: UnsafeMutablePointer<llama_sampler>?
        defer { if let sampler { llama_sampler_free(sampler) } }
        var generatedTokens: [llama_token] = []
        /// How many tokens the context holds once the prompt is read.
        var promptTokens = 0
        // Moves the model when the app's place changed (see `InferencePlacement`).
        // `decoded` tokens are kept. The sampler belongs to the old model, so it
        // is built again and shown the tokens written so far (grammar, penalties).
        func moveIfNeeded(decoded: Int, allowDropState: Bool = false) throws -> MoveOutcome {
            let wantsCPU = placement.wantsCPU
            guard wantsCPU != loadedOnCPU else { return .unchanged }
            if let old = sampler { llama_sampler_free(old); sampler = nil }
            let preserved = try move(toCPU: wantsCPU, decoded: decoded, allowDropState: allowDropState, cancellation: cancellation)
            guard let moved = self.context, let movedVocab = self.model.flatMap({ llama_model_get_vocab($0) }) else { throw LocalModelError.load }
            context = moved; vocab = movedVocab
            watchForStop(moved)
            return preserved ? .movedWithState : .reloadedClean
        }

        var tokens: [llama_token] = []
        // Keel stops a step as soon as a complete tool call is written, so most
        // tool steps end here, not at the end of a reply. The prompt was read in
        // full; only the reply after it is unknown. Roll back to an exact point
        // instead of clearing, or every tool step reads the whole chat again.
        // Runs before the clearing `defer` above (defers run in reverse).
        defer {
            if !completed, request.images.isEmpty, promptTokens > 0, promptTokens == tokens.count, let context = self.context {
                rolledBack = keepReadPrompt(context, tokens: tokens)
            }
        }
        let images = !request.images.isEmpty
        let addSpecial = request.model?.family.addsTokenizerSpecialTokens ?? true
        let prefillStarted = ProcessInfo.processInfo.systemUptime
        if !request.images.isEmpty {
            guard let vision else { throw LocalModelError.vision }
            llama_memory_clear(llama_get_memory(context), true); cachedTokens.removeAll()
            try await prefillImages(prompt: prompt, images: request.images, vision: vision, context: context,
                                    limit: limit, cancellation: cancellation, onPrefill: onPrefill)
        } else {
        let required = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), nil, 0, addSpecial, true)
        let count = Int(abs(required))
        guard count > 0, count + limit < Int(llama_n_ctx(context)) else { throw LocalModelError.tooLong }
        tokens = [llama_token](repeating: 0, count: count)
        let actual = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(count), addSpecial, true)
        guard Int(actual) == count else { throw LocalModelError.decode }
        // Reuse the decoded sequence up to the first differing token.
        // Prefix reuse is what removes the repeated multi-second prefill on
        // every tool step. Re-tokenized history can differ from the tokens the
        // model sampled, so a divergence trims the cache back to the match.
        // Recurrent/hybrid memory (Bonsai, LFM3) cannot be trimmed; llama.cpp
        // then returns false, and the state saved while the last prompt was read (see
        // `checkpoint`) is put back instead. Only without one is it cleared.
        var prefix = 0
        while prefix < cachedTokens.count, prefix < tokens.count, cachedTokens[prefix] == tokens[prefix] { prefix += 1 }
        // If the whole prompt is already read (a moved model, or a step that was
        // stopped and rolled back to its prompt) there are no fresh outputs to
        // sample from, so the last token is read again.
        if prefix != cachedTokens.count || prefix == count {
            let keep = min(prefix, count - 1)
            if keep > 0, llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(keep), -1) {
                cachedTokens.removeSubrange(keep...)
                prefix = keep
            } else if let restored = restoreCheckpoint(context, shared: keep) {
                prefix = restored
            } else {
                llama_memory_clear(llama_get_memory(context), true)
                cachedTokens.removeAll()
                prefix = 0
            }
        }
        lastStats = PrefixStats(reusedTokens: prefix, decodedTokens: count - prefix)
        onPrefill(prefix, count)
        var offset = prefix
        // The state is saved a few tokens before the end: the next prompt
        // re-renders this turn's opening (with thinking on, `<think>\n` becomes
        // `<think>\n\n</think>`, one token apart), so state taken at the very
        // end would never match again. llama-server does the same.
        let checkpointAt = count - Self.checkpointLag
        while offset < count {
            if cancellation.isCancelled { throw CancellationError() }
            try await checkThermals(cancellation: cancellation)
            if try moveIfNeeded(decoded: offset, allowDropState: true) == .reloadedClean {
                offset = 0
                lastStats = PrefixStats(reusedTokens: 0, decodedTokens: count)
                onPrefill(0, count)
                continue
            }
            var length = min(256, count - offset)
            if offset < checkpointAt { length = min(length, checkpointAt - offset) }
            func read(at start: Int, count batchCount: Int) -> Int32 {
                tokens.withUnsafeMutableBufferPointer {
                    llama_decode(context, llama_batch_get_one($0.baseAddress!.advanced(by: start), Int32(batchCount)))
                }
            }
            var result = read(at: offset, count: length)
            // The graphics processor refuses work once the app is in the
            // background: move to the CPU and read this part again.
            if result != 0, !cancellation.isCancelled, placement.wantsCPU, !loadedOnCPU {
                switch try moveIfNeeded(decoded: offset, allowDropState: true) {
                case .unchanged:
                    break
                case .movedWithState:
                    result = read(at: offset, count: length)
                case .reloadedClean:
                    offset = 0
                    lastStats = PrefixStats(reusedTokens: 0, decodedTokens: count)
                    onPrefill(0, count)
                    continue
                }
            }
            guard result == 0 else {
                if cancellation.isCancelled { throw CancellationError() }
                throw LocalModelError.decode
            }
            offset += length
            if offset == checkpointAt, !request.keepCheckpoint { saveCheckpoint(context, tokens: Array(tokens[..<offset])) }
            onPrefill(min(count, offset), count)
        }
        promptTokens = count
        }
        // llama_decode only queues GPU work; wait for it, or the prompt's
        // reading time is counted as writing (a one-batch prompt read "instantly").
        llama_synchronize(context)
        prefillDuration = max(0, ProcessInfo.processInfo.systemUptime - prefillStarted)
        let sampling = request.model?.family.sampling ?? .app
        func makeSampler(_ vocab: OpaquePointer) throws -> UnsafeMutablePointer<llama_sampler> {
            guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw LocalModelError.context }
            if let grammar = request.grammar {
                // First in the chain, so the later samplers only ever see allowed
                // tokens. Until a trigger matches it leaves every token alone.
                let patterns = grammar.triggerPatterns.map { strdup($0) }
                defer { patterns.forEach { free($0) } }
                var pointers = patterns.map { UnsafePointer<CChar>($0) }
                let constrained = pointers.withUnsafeMutableBufferPointer { buffer in
                    llama_sampler_init_grammar_lazy_patterns(vocab, grammar.text, ToolCallGrammar.root,
                                                             buffer.baseAddress, buffer.count, nil, 0)
                }
                guard let constrained else { llama_sampler_free(chain); throw LocalModelError.grammar }
                llama_sampler_chain_add(chain, constrained)
            }
            if request.greedy {
                llama_sampler_chain_add(chain, llama_sampler_init_greedy())
                return chain
            }
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(sampling.topK)))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(sampling.topP), 1))
            if let minP = sampling.minP { llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(minP), 1)) }
            if let penalty = sampling.repeatPenalty {
                llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, Float(penalty), 0, 0))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(sampling.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
            return chain
        }
        sampler = try makeSampler(vocab)
        var pending = Data()
        generatedTokens.reserveCapacity(limit)
        // Zero-RAM n-gram speculative decoding: only on pure-attention models
        // whose KV cache supports suffix removal (`llama_memory_seq_rm`), and
        // never when images or a lazy grammar are active.
        let modelArchitecture = request.model?.architecture
        var speculationAllowed = !images && request.grammar == nil && modelArchitecture?.linearAttentionLayerCount == 0
        let speculator = NGramSpeculator()
        func emitToken(_ emittedToken: llama_token) throws {
            pending.append(contentsOf: try Self.piece(emittedToken, vocab: vocab))
            if let text = String(data: pending, encoding: .utf8) {
                onText(text); pending.removeAll(keepingCapacity: true)
            }
        }
        decodeStarted = ProcessInfo.processInfo.systemUptime
        while generated < limit {
            if cancellation.isCancelled { throw CancellationError() }
            try await checkThermals(cancellation: cancellation, step: generated)
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            try emitToken(token)
            // The token is chosen but not yet read back in: the one point where
            // the model can change place without losing anything.
            func rebuildSampler() throws {
                let rebuilt = try makeSampler(vocab)
                for written in generatedTokens { llama_sampler_accept(rebuilt, written) }
                llama_sampler_accept(rebuilt, token)
                sampler = rebuilt
            }
            func replayHistoryOnCurrentContext() throws {
                var replay = tokens + generatedTokens
                var replayOffset = 0
                while replayOffset < replay.count {
                    if cancellation.isCancelled { throw CancellationError() }
                    let batchLen = min(256, replay.count - replayOffset)
                    let stepResult = replay.withUnsafeMutableBufferPointer {
                        llama_decode(context, llama_batch_get_one($0.baseAddress!.advanced(by: replayOffset), Int32(batchLen)))
                    }
                    guard stepResult == 0 else {
                        if cancellation.isCancelled { throw CancellationError() }
                        throw LocalModelError.decode
                    }
                    replayOffset += batchLen
                }
            }
            let held = images ? nil as Int? : promptTokens + generated
            if let held {
                switch try moveIfNeeded(decoded: held, allowDropState: true) {
                case .unchanged:
                    break
                case .movedWithState:
                    try rebuildSampler()
                case .reloadedClean:
                    try replayHistoryOnCurrentContext()
                    try rebuildSampler()
                }
            }
            // Attempt zero-RAM n-gram speculative batch verification on Metal
            // for pure-attention models when a trailing n-gram matches earlier context.
            if speculationAllowed, !loadedOnCPU, let basePos = held,
               limit - generated > 1,
               basePos + 2 < Int(llama_n_ctx(context)) {
                let maxDraft = min(speculator.maxDraftTokens,
                                   min(limit - generated - 1, Int(llama_n_ctx(context)) - basePos - 2))
                var history = tokens
                history.reserveCapacity(tokens.count + generatedTokens.count + 1)
                history.append(contentsOf: generatedTokens)
                history.append(token)
                let draft = speculator.propose(from: history, maxTokens: maxDraft)
                if !draft.isEmpty {
                    let batchTokens = [token] + draft
                    var batch = llama_batch_init(Int32(batchTokens.count), 0, 1)
                    defer { llama_batch_free(batch) }
                    batch.n_tokens = Int32(batchTokens.count)
                    for i in 0..<batchTokens.count {
                        batch.token?[i] = batchTokens[i]
                        batch.pos?[i] = llama_pos(basePos + i)
                        batch.n_seq_id?[i] = 1
                        batch.seq_id?[i]?[0] = 0
                        batch.logits?[i] = 1
                    }
                    if llama_decode(context, batch) == 0 {
                        generatedTokens.append(token)
                        generated += 1
                        var hitEOG = false
                        for i in 0..<draft.count {
                            let sampled = llama_sampler_sample(sampler, context, Int32(i))
                            if sampled == draft[i] && !llama_vocab_is_eog(vocab, sampled) {
                                try emitToken(sampled)
                                generatedTokens.append(sampled)
                                generated += 1
                            } else {
                                let trimFrom = llama_pos(basePos + 1 + i)
                                guard llama_memory_seq_rm(llama_get_memory(context), 0, trimFrom, -1) else {
                                    speculationAllowed = false
                                    throw LocalModelError.decode
                                }
                                if llama_vocab_is_eog(vocab, sampled) {
                                    hitEOG = true
                                    break
                                }
                                try emitToken(sampled)
                                var correction = sampled
                                let corrResult = withUnsafeMutablePointer(to: &correction) {
                                    llama_decode(context, llama_batch_get_one($0, 1))
                                }
                                guard corrResult == 0 else {
                                    if cancellation.isCancelled { throw CancellationError() }
                                    throw LocalModelError.decode
                                }
                                generatedTokens.append(sampled)
                                generated += 1
                                break
                            }
                        }
                        if hitEOG { break }
                        continue
                    } else {
                        // Fall back cleanly if the multi-token batch failed (e.g. background transition).
                        speculationAllowed = false
                    }
                }
            }
            var result = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            if result != 0, let held, !cancellation.isCancelled, placement.wantsCPU, !loadedOnCPU {
                switch try moveIfNeeded(decoded: held, allowDropState: true) {
                case .unchanged:
                    break
                case .movedWithState:
                    try rebuildSampler()
                    result = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
                case .reloadedClean:
                    try replayHistoryOnCurrentContext()
                    try rebuildSampler()
                    result = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
                }
            }
            guard result == 0 else {
                if cancellation.isCancelled { throw CancellationError() }
                throw LocalModelError.decode
            }
            generatedTokens.append(token)
            generated += 1
        }
        if !pending.isEmpty { onText(String(decoding: pending, as: UTF8.self)) }
        cachedTokens = request.images.isEmpty ? tokens + generatedTokens : []
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

    private func prefillImages(prompt: String, images: [Data], vision: OpaquePointer, context: OpaquePointer,
                               limit: Int, cancellation: InferenceCancellation,
                               onPrefill: @Sendable (Int, Int) -> Void) async throws {
        guard let chunks = mtmd_input_chunks_init() else { throw LocalModelError.decode }
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = []
        defer { for bitmap in bitmaps { if let bitmap { mtmd_bitmap_free(bitmap) } } }
        for image in images {
            try await checkThermals(cancellation: cancellation)
            if cancellation.isCancelled { throw CancellationError() }
            let wrapper = image.withUnsafeBytes { bytes in
                mtmd_helper_bitmap_init_from_buf(vision, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                                false, mtmd_helper_init_opt_default())
            }
            guard let bitmap = wrapper.bitmap, wrapper.video_ctx == nil else { throw LocalModelError.vision }
            bitmaps.append(bitmap)
        }
        let status = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: prompt.utf8.count, add_special: false, parse_special: true)
            return bitmaps.withUnsafeBufferPointer { mtmd_tokenize(vision, chunks, &input, $0.baseAddress, $0.count) }
        }
        guard status == 0 else { throw LocalModelError.vision }
        let total = Int(mtmd_helper_get_n_tokens(chunks))
        guard total > 0, total + limit < Int(llama_n_ctx(context)) else { throw LocalModelError.tooLong }
        onPrefill(0, total)
        var position: llama_pos = 0
        for index in 0..<mtmd_input_chunks_size(chunks) {
            if cancellation.isCancelled { throw CancellationError() }
            try await checkThermals(cancellation: cancellation)
            guard let chunk = mtmd_input_chunks_get(chunks, index) else { throw LocalModelError.decode }
            let status = mtmd_helper_eval_chunk_single(vision, context, chunk, position, 0, 256,
                                                     index + 1 == mtmd_input_chunks_size(chunks), &position)
            guard status == 0 else {
                if cancellation.isCancelled { throw CancellationError() }
                throw LocalModelError.decode
            }
            onPrefill(min(Int(position), total), total)
        }
        lastStats = PrefixStats(reusedTokens: 0, decodedTokens: total)
    }

    private func checkThermals(cancellation: InferenceCancellation, step: Int = 0) async throws {
        try await Self.enforceThermal(ThermalPolicy.currentDecision(step: step), cancellation: cancellation)
    }

    static func enforceThermal(_ decision: ThermalDecision, cancellation: InferenceCancellation) async throws {
        switch decision {
        case .proceed:
            return
        case .throttle(let pauseNanoseconds):
            try await Task.sleep(nanoseconds: pauseNanoseconds)
            if cancellation.isCancelled { throw CancellationError() }
        case .stop:
            throw LocalModelError.thermal
        }
    }
}
