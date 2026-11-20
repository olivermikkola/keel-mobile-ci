import Foundation
import CryptoKit
import SwiftUI

// The pinned Bonsai 2 GGUFs are Qwen3.5 hybrid-attention models. Only every
// fourth layer keeps an attention KV cache; the other layers carry a finite
// recurrent state. Values below come from the pinned GGUF metadata:
// qwen35.block_count=32, full_attention_interval=4, head_count_kv=4,
// key_length=value_length=256, ssm.inner_size=4096, ssm.state_size=128,
// ssm.conv_kernel=4. Do not turn these back into a flat per-token guess.
struct ModelArchitecture: Equatable, Sendable {
    var attentionLayers: Int? = nil
    var kvBlockBytes: UInt64 = 18
    var kvBlockElements: UInt64 = 32
    let layerCount: Int
    let fullAttentionInterval: Int
    let kvHeadCount: Int
    let keyLength: Int
    let valueLength: Int
    let ssmInnerSize: Int
    let ssmStateSize: Int
    let ssmConvKernel: Int

    static let bonsai2 = ModelArchitecture(layerCount: 32, fullAttentionInterval: 4,
                                           kvHeadCount: 4, keyLength: 256, valueLength: 256,
                                           ssmInnerSize: 4096, ssmStateSize: 128, ssmConvKernel: 4)

    var fullAttentionLayerCount: Int { attentionLayers ?? (layerCount / max(1, fullAttentionInterval)) }
    var linearAttentionLayerCount: Int { layerCount - fullAttentionLayerCount }

    // Q4_0 stores 32 values in 2 bytes of scale plus 16 bytes of quants.
    var kvBytesPerToken: UInt64 {
        let values = UInt64(fullAttentionLayerCount) * UInt64(kvHeadCount)
            * UInt64(keyLength + valueLength)
        return (values * kvBlockBytes + kvBlockElements - 1) / kvBlockElements
    }

    // Recurrent state is small but not zero: F32 state plus the convolution
    // ring buffer for each linear-attention layer. The 384 MB app headroom
    // covers embeddings, the compute graph and transient buffers.
    func requiredBytes(weights: UInt64, contextSize: UInt32, appHeadroom: UInt64 = 384_000_000) -> UInt64 {
        let kv = UInt64(contextSize) * kvBytesPerToken
        let recurrentPerLayer = UInt64(ssmInnerSize) * UInt64(ssmStateSize) * 4
            + UInt64(ssmConvKernel) * UInt64(ssmInnerSize) * 4
        return weights + kv + UInt64(linearAttentionLayerCount) * recurrentPerLayer + appHeadroom
    }
}

struct ModelAsset: Sendable {
    let fileName: String
    let repository: String
    let revision: String
    let bytes: Int64
    let sha256: String
    var transferModel: LocalModel {
        LocalModel(id: fileName, name: fileName, bytes: bytes, revision: revision, sha256: sha256,
                   detail: "", repository: repository, fileName: fileName)
    }
}

struct LocalModel: Identifiable, Sendable {
    let repository: String
    let fileName: String
    let family: ModelFamily
    let visionFile: ModelAsset?
    var downloadBytes: Int64 { bytes + (visionFile?.bytes ?? 0) }
    var isImported: Bool { repository == ImportedModel.source }
    /// Apple's built-in model: no file, run by `AppleModelRunner`.
    var isSystem: Bool { repository == LocalModel.systemSource }
    var quantization: String { isSystem ? "Built into iOS" : isImported ? "GGUF" : family == .bonsai ? "Q2_0" : "Q4_K_M" }
    var assets: [ModelAsset] {
        guard !isSystem else { return [] }
        return [ModelAsset(fileName: fileName, repository: repository, revision: revision, bytes: bytes, sha256: sha256)] + (visionFile.map { [$0] } ?? [])
    }

    let id: String
    let name: String
    let bytes: Int64
    let revision: String
    let sha256: String
    let detail: String
    let contextSize: UInt32
    let architecture: ModelArchitecture

    init(id: String, name: String, bytes: Int64, revision: String, sha256: String, detail: String,
         contextSize: UInt32 = 4096, architecture: ModelArchitecture = .bonsai2,
         repository: String? = nil, fileName: String? = nil, family: ModelFamily = .bonsai,
         visionFile: ModelAsset? = nil) {
        self.repository = repository ?? "prism-ml/Ternary-Bonsai-2-\(id)-gguf"
        self.fileName = fileName ?? "Ternary-Bonsai-2-\(id)-Q2_0.gguf"
        self.family = family; self.visionFile = visionFile
        self.id = id
        self.name = name
        self.bytes = bytes
        self.revision = revision
        self.sha256 = sha256
        self.detail = detail
        self.contextSize = contextSize
        self.architecture = architecture
    }

    /// A download address given as is: a pasted link, already validated.
    var sourceURL: URL?
    var url: URL {
        sourceURL ?? URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    /// A model the user imported: pinned to the size and SHA-256 seen at
    /// import, with the memory layout read from its header.
    init(imported model: ImportedModel) {
        let quantizedKV = model.family == .bonsai
        self.init(id: model.id, name: model.name, bytes: model.bytes, revision: "imported", sha256: model.sha256,
                  detail: "Imported \(model.architecture) model. \(model.contextSize / 1024)K context. Tool use depends on the model.",
                  contextSize: model.contextSize,
                  architecture: ModelArchitecture(attentionLayers: model.attentionLayerCount,
                                                  kvBlockBytes: quantizedKV ? 18 : 2, kvBlockElements: quantizedKV ? 32 : 1,
                                                  layerCount: model.layerCount, fullAttentionInterval: 1,
                                                  kvHeadCount: model.kvHeadCount, keyLength: model.keyLength, valueLength: model.valueLength,
                                                  ssmInnerSize: model.ssmInnerSize, ssmStateSize: model.ssmStateSize,
                                                  ssmConvKernel: model.ssmConvKernel),
                  repository: ImportedModel.source, fileName: model.fileName, family: model.family)
    }
    static let lfmArchitecture = ModelArchitecture(attentionLayers: 11, kvBlockBytes: 2, kvBlockElements: 1,
        layerCount: 24, fullAttentionInterval: 1, kvHeadCount: 4, keyLength: 128, valueLength: 128,
        ssmInnerSize: 2048, ssmStateSize: 0, ssmConvKernel: 7)
    static let miniArchitecture = ModelArchitecture(kvBlockBytes: 2, kvBlockElements: 1,
        layerCount: 42, fullAttentionInterval: 1, kvHeadCount: 2, keyLength: 128, valueLength: 128,
        ssmInnerSize: 0, ssmStateSize: 0, ssmConvKernel: 0)
    static let systemSource = "apple/system"
    /// Apple's on-device model. Listed only where `AppleModelRunner.isAvailable`.
    /// Its chats render as ChatML, which `ApplePrompt` splits for Apple's API.
    static let apple = LocalModel(id: "apple", name: "Apple on-device", bytes: 0, revision: "system", sha256: "",
        detail: "Apple's built-in model. Nothing to download. About 4K context, so long tasks get compacted sooner.",
        contextSize: 4096, repository: systemSource, fileName: "apple-system-model", family: .bonsai)

    /// Not a chat model: the small multilingual model behind search by
    /// meaning (`Recall`). Downloaded from its own row on the Models screen.
    static let search = LocalModel(id: "search", name: "Search by meaning", bytes: 333_590_944,
        revision: "0f741b5a6585bd53aeb15cd1372c56f2a0f65e12",
        sha256: "b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63",
        detail: "Lets Keel find things in your earlier chats and in files it made, by what they mean rather than exact words. Works in many languages. Runs on this iPhone.",
        contextSize: 512, repository: "ggml-org/embeddinggemma-300M-GGUF", fileName: "embeddinggemma-300M-Q8_0.gguf", family: .bonsai)

    /// Not a chat model: LiquidAI's d1 decision model behind Decide. It answers
    /// yes/no, pick-one and scale questions about documents in one pass,
    /// without writing a reply. Text only, so its photo file is not downloaded.
    static let decide = LocalModel(id: "decide", name: "Decide · d1 2B", bytes: 1_099_629_888,
        revision: "4a181094d1b6addfaa3a0956f78e7ab2aa406a0c",
        sha256: "adca5789ad30ae6027e8e936749bb9f19673097492ab26fa1c5b69643ca50b4b",
        detail: "Answers yes or no, pick-one and scale questions about your documents with a percentage, without writing a reply. Runs on this iPhone.",
        contextSize: 16_384, architecture: lfmArchitecture,
        repository: "LiquidAI/d1-2B-GGUF", fileName: "d1-2B-Q4_K_M.gguf", family: .lfm3)

    /// Models that are downloaded and removed like the others but are never
    /// picked for chats.
    static let utilities = [search, decide]

    static let catalog = [
        LocalModel(id: "4B", name: "Bonsai 2 · 4B", bytes: 1_212_103_520,
                   revision: "50ebba61be85e5be07e8083db468ace0fc1bac43",
                   sha256: "64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4",
                   detail: "Start here. 16K context with quantized KV cache. Smaller download and faster prefill.",
                   contextSize: 16_384),
        LocalModel(id: "9B", name: "Bonsai 2 · 9B", bytes: 2_556_640_128,
                   revision: "82265ccc78ddaac4700286a35e9badcc32376dd9",
                   sha256: "1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d",
                   detail: "Target model for autonomous tasks. 32K context with Q4_0 quantized KV cache on Apple Silicon.",
                   contextSize: 32_768),
        LocalModel(id: "lfm3", name: "LFM3 · 1.7B", bytes: 1_099_627_808,
            revision: "cd0c74c575b5c416f3011b5b4c298077f26ca8c2",
            sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4",
            detail: "Small text and tool model. 32K conversation context. Try it with your everyday tasks.",
            contextSize: 32_768, architecture: lfmArchitecture,
            repository: "LiquidAI/LFM3-1.7B-GGUF", fileName: "LFM3-1.7B-Q4_K_M.gguf", family: .lfm3),
        LocalModel(id: "lfm3-vl", name: "LFM3 VL · 2B", bytes: 1_099_627_808,
            revision: "1add221a5ea6c047fcf1eaaf2d247939d7cf8849",
            sha256: "56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb",
            detail: "Text and photos. Includes a vision model. 32K conversation context.",
            contextSize: 32_768, architecture: lfmArchitecture,
            repository: "LiquidAI/LFM3-VL-2B-GGUF", fileName: "LFM3-VL-2B-Q4_K_M.gguf", family: .lfm3,
            visionFile: ModelAsset(fileName: "mmproj-LFM3-VL-2B-Q8_0.gguf", repository: "LiquidAI/LFM3-VL-2B-GGUF",
                revision: "1add221a5ea6c047fcf1eaaf2d247939d7cf8849", bytes: 203_031_872,
                sha256: "c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab")),
        LocalModel(id: "minicpm5", name: "MiniCPM5 · 2B", bytes: 1_561_318_368,
            revision: "8ad02b786ab81e33d465e1c80562640c55ab2877",
            sha256: "ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd",
            detail: "Small text and tool model. 16K conversation context. Compare it on the same tasks.",
            contextSize: 16_384, architecture: miniArchitecture,
            repository: "openbmb/MiniCPM5-2B-GGUF", fileName: "MiniCPM5-2B-Q4_K_M.gguf", family: .miniCPM5)
    ]
}

struct ModelVerificationFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { "Download verification failed. The damaged download was removed; retry to get a fresh copy." }
}

@MainActor
final class ModelLibrary: ObservableObject {
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var partialBytes: [String: Int64] = [:]
    @Published private(set) var downloading: String?
    @Published private(set) var progress: Double = 0 { didSet { reportContinued() } }
    @Published private(set) var verifying = false { didSet { reportContinued() } }
    @Published private(set) var restarting = false
    @Published private(set) var failedModel: LocalModel?
    @Published private(set) var failureDetail: String?
    @Published var selected: String {
        didSet {
            defaults.set(selected, forKey: "localModel")
            defaults.set(selected, forKey: Self.modeKey(mode))
        }
    }
    @Published var error: String?
    /// Models the user imported, in the order they were added.
    @Published private(set) var imported: [ImportedModel] = []
    /// What an import in progress is doing, for the screen; nil when idle.
    @Published private(set) var importing: String? { didSet { reportContinued() } }
    private let builtIn: [LocalModel]
    var catalog: [LocalModel] { builtIn + system + imported.map(LocalModel.init(imported:)) }
    /// Apple's model, on phones where it can run; checked once at launch.
    private let system: [LocalModel]
    var isTransferring: Bool { downloading != nil || importing != nil }
    private var importedList: URL { directory.appendingPathComponent("imported-models.json") }
    private let directory: URL
    private let defaults: UserDefaults
    private let transferConfiguration: () -> URLSessionConfiguration
    private let backgroundAllowance: BackgroundAllowance
    private let startContinued: ContinuedWork.Starter
    /// On iOS 26 and later, what keeps a download going after the user leaves the app.
    private var continued: ContinuedWorkSession?
    private var scenePhase: ScenePhase = .active
    private var download: Task<Void, Never>?
    private var transferID: UUID?
    var isHoldingBackgroundGrace: Bool { backgroundAllowance.isHoldingBackgroundTime }

    init(directory: URL? = nil, defaults: UserDefaults = .standard, catalog: [LocalModel] = LocalModel.catalog,
         transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         backgroundAllowance: BackgroundAllowance? = nil,
         continuedWork: @escaping ContinuedWork.Starter = ContinuedWork.system,
         includeSystemModel: Bool = true) {
        precondition(!catalog.isEmpty)
        self.startContinued = continuedWork
        self.builtIn = catalog
        self.system = includeSystemModel && AppleModelRunner.isAvailable ? [.apple] : []
        self.defaults = defaults
        self.transferConfiguration = transferConfiguration
        self.backgroundAllowance = backgroundAllowance ?? BackgroundAllowance()
        self.directory = directory ?? Self.defaultDirectory
        imported = (try? Data(contentsOf: self.directory.appendingPathComponent("imported-models.json"))).map(ImportedModel.load) ?? []
        selected = defaults.string(forKey: "localModel") ?? "4B"
        if !self.catalog.contains(where: { $0.id == selected }) { selected = catalog[0].id }
        // An import cut short by a killed process leaves only its staging file.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []
        where file.hasPrefix("custom-") && file.hasSuffix(".import") {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(file))
        }
        // A killed process cannot run the download task's cleanup. Reclaim
        // only our known staging files; installed models are left untouched.
        for model in (catalog + LocalModel.utilities).flatMap({ $0.assets.map(\.transferModel) }) {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(model.fileName + ".partial"))
            // A crash during the one-shot integrity retry must not leave a
            // second staging file that no resume path can claim.
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(model.fileName + ".download.retry"))
        }
        #if DEBUG && targetEnvironment(simulator)
        ModelDownloadUITestFixture.prepare(in: self.directory)
        if ProcessInfo.processInfo.arguments.contains("--model-failure-fixture") {
            failedModel = catalog[1]
            error = ModelVerificationFailure(detail: "").localizedDescription
            failureDetail = "SHA-256 mismatch. Recorded UI fixture; no model was downloaded by this fixture."
        }
        #endif
        refresh()
    }

    var current: LocalModel { catalog.first { $0.id == selected } ?? catalog[0] }

    /// The mode the chat on screen is in. Picking a model remembers it for
    /// this mode; switching mode brings back that mode's model if installed.
    private(set) var mode: ChatMode = .work
    private static func modeKey(_ mode: ChatMode) -> String { "localModel.\(mode.rawValue)" }
    /// Returns true when the selected model changed.
    @discardableResult
    func switchMode(_ mode: ChatMode) -> Bool {
        guard self.mode != mode else { return false }
        self.mode = mode
        guard downloading == nil, let id = defaults.string(forKey: Self.modeKey(mode)),
              id != selected, installed.contains(id), catalog.contains(where: { $0.id == id }) else { return false }
        selected = id
        return true
    }
    /// Whether a model is one of the recommended ones for the current mode.
    func isRecommended(_ model: LocalModel) -> Bool { mode.recommendedModelIDs.contains(model.id) }
    func path(_ model: LocalModel) -> URL { directory.appendingPathComponent(model.fileName) }
    /// The app's model folder.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
    }
    /// Where models live; the runtime benchmark keeps its MLX folder in here.
    var modelsDirectory: URL { directory }
    func partialPath(_ model: LocalModel) -> URL { directory.appendingPathComponent(model.fileName + ".download") }
    func visionPath(_ model: LocalModel) -> URL? { model.visionFile.map { directory.appendingPathComponent($0.fileName) } }
    func refresh() {
        installed = Set((catalog + LocalModel.utilities).filter { model in
            model.assets.allSatisfy { asset in
                (try? directory.appendingPathComponent(asset.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(asset.bytes)
            }
        }.map(\.id))
        partialBytes = [:]
        for model in catalog + LocalModel.utilities where !installed.contains(model.id) {
            let saved = model.assets.reduce(Int64(0)) { result, asset in
                let complete = directory.appendingPathComponent(asset.fileName)
                let bytes = (try? complete.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if Int64(bytes) == asset.bytes { return result + asset.bytes }
                let partial = complete.appendingPathExtension("download")
                return result + Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            if saved > 0 { partialBytes[model.id] = saved }
        }
    }

    func install(_ model: LocalModel) {
        let requested = model
        guard !isTransferring, !model.isImported, !model.isSystem, model.downloadBytes > 0 else { return }
        downloading = model.id; progress = Double(partialBytes[model.id] ?? 0) / Double(model.downloadBytes)
        verifying = false; restarting = false; error = nil; failedModel = nil; failureDetail = nil
        let transferID = UUID(); self.transferID = transferID
        beginContinued(title: "Downloading \(model.name)")
        download = Task {
            var transferringAsset = requested
            defer { downloading = nil; download = nil; verifying = false; restarting = false; self.transferID = nil; backgroundAllowance.release(); finishContinued(); refresh() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                var finishedBytes: Int64 = 0
                for asset in requested.assets {
                    verifying = false; restarting = false
                    let model = asset.transferModel
                    transferringAsset = model
                    if FileManager.default.fileExists(atPath: path(model).path) {
                        let existingPath = path(model)
                        let verification = Task.detached(priority: .utility) { try Self.verify(existingPath, model: model) }
                        do {
                            try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                            finishedBytes += model.bytes
                            continue
                        } catch { if Task.isCancelled { throw CancellationError() } }
                    }
                    let completedBytes = finishedBytes
                    let staging = partialPath(model)
                    var working = staging
                    let existing = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let remaining = max(0, model.bytes - existing)
                    let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        .volumeAvailableCapacityForImportantUsage ?? 0
                    guard remaining == 0 || capacity > remaining + 256_000_000 else { throw LocalModelError.storage }
                    // A saved prefix may be damaged even when HTTP Range is exact.
                    // Recover once from a verified integrity failure, never install
                    // unverified data and never loop through repeated full downloads.
                    for attempt in 0...1 {
                        do {
                            try await ModelTransfer.fetch(model, to: working, configuration: transferConfiguration()) { [weak self] received, _ in
                                Task { @MainActor [weak self] in
                                    guard self?.transferID == transferID else { return }
                                    self?.progress = min(1, Double(completedBytes + received) / Double(requested.downloadBytes))
                                }
                            }
                            try Task.checkCancellation()
                            verifying = true
                            let verification = Task.detached(priority: .utility) { try Self.verify(working, model: model) }
                            try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                            try Task.checkCancellation()
                            break
                        } catch {
                            let damaged: Bool
                            if error is ModelVerificationFailure { damaged = true }
                            else if case LocalModelError.integrity = error { damaged = true }
                            else { damaged = false }
                            #if DEBUG
                            print("MODEL_RETRY_CHECK damaged=\(damaged) existing=\(existing) attempt=\(attempt) cancelled=\(Task.isCancelled) error=\(type(of: error))")
                            #endif
                            guard damaged, existing > 0, attempt == 0, !Task.isCancelled else { throw error }
                            try FileManager.default.removeItem(at: working)
                            // A URLSession may still hold the old path open while
                            // its delegate drains. Retry into a separate file so a
                            // late callback can never append to the clean copy.
                            working = directory.appendingPathComponent(model.fileName + ".download.retry")
                            try? FileManager.default.removeItem(at: working)
                            verifying = false; restarting = true; progress = 0
                            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                                .volumeAvailableCapacityForImportantUsage ?? 0
                            guard available > model.bytes + 256_000_000 else { throw LocalModelError.storage }
                        }
                    }
                    let destination = path(model)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: working)
                    } else { try FileManager.default.moveItem(at: working, to: destination) }
                    finishedBytes += model.bytes
                }
                // Search and Decide are not chat models; downloading one keeps the chat model.
                if !LocalModel.utilities.contains(where: { $0.id == requested.id }) { selected = requested.id }
                #if DEBUG
                print("MODEL_INSTALL_SUCCESS \(model.id)")
                #endif
            } catch is CancellationError { }
            catch let failure as URLError where failure.code == .cancelled { }
            catch {
                // A bad checksum/oversized body cannot be resumed safely. Keep
                // valid prefixes on transport errors, cancellation and relaunch.
                #if DEBUG
                print("MODEL_OUTER_CATCH \(model.id) \(type(of: error)) \(error.localizedDescription)")
                #endif
                if error is ModelVerificationFailure { try? FileManager.default.removeItem(at: partialPath(transferringAsset)) }
                else if case LocalModelError.integrity = error { try? FileManager.default.removeItem(at: partialPath(transferringAsset)) }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(transferringAsset.fileName + ".download.retry"))
                failedModel = model
                failureDetail = (error as? ModelVerificationFailure)?.detail
                self.error = error is LocalModelError || error is ModelVerificationFailure ? error.localizedDescription : "Download interrupted. Your progress is kept; check your connection and resume."
            }
        }
    }

    nonisolated static func verify(_ url: URL, model: LocalModel) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map({ Int64($0) }) == model.bytes else {
            throw ModelVerificationFailure(detail: "Expected \(model.bytes) bytes; received \(size.map { String($0) } ?? "unknown"). Model revision: \(model.revision).")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        let actual = hash.finalize().map({ String(format: "%02x", $0) }).joined()
        guard actual == model.sha256 else {
            throw ModelVerificationFailure(detail: "SHA-256 mismatch. Expected: \(model.sha256). Received: \(actual). Bytes: \(model.bytes). Model revision: \(model.revision).")
        }
    }

    /// Copies a .gguf the user picked into the app, after checking it can run:
    /// a readable header, a prompt format Keel speaks and memory this device
    /// has. The copy is hashed as it is written, which pins the model.
    func importModel(from source: URL) {
        guard !isTransferring else { return }
        guard imported.count < ImportedModel.limit else {
            error = "You have \(ImportedModel.limit) imported models. Remove one before importing another."; return
        }
        error = nil; failedModel = nil; failureDetail = nil
        importing = "Checking the file…"
        let directory = directory, memory = ProcessInfo.processInfo.physicalMemory
        let importID = UUID(); transferID = importID
        beginContinued(title: "Importing a model")
        download = Task {
            defer { importing = nil; download = nil; transferID = nil; backgroundAllowance.release(); finishContinued(); refresh() }
            do {
                let report: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
                    Task { @MainActor in
                        guard self?.transferID == importID else { return }
                        self?.importing = "Copying into Keel · \(Int(Double(done) / Double(max(1, total)) * 100))%"
                    }
                }
                let copy = Task.detached(priority: .userInitiated) {
                    try Self.copyChecked(source, into: directory, physicalMemoryBytes: memory, progress: report)
                }
                let model = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
                do { try Task.checkCancellation() }
                catch {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName))
                    throw error
                }
                imported.append(model)
                do { try saveImported() } catch {
                    imported.removeLast()
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName))
                    throw error
                }
                selected = model.id
            } catch is CancellationError {
            } catch {
                self.error = error is ImportedModel.Problem || error is LocalModelError
                    ? error.localizedDescription : "The file could not be imported. Choose it again from Files."
            }
        }
    }

    /// Downloads a GGUF from a pasted Hugging Face link. Its header is read
    /// first (256 KB) and checked like a file from Files; the download is
    /// pinned to the size and SHA-256 Hugging Face reports, and verified.
    func importModel(link text: String) {
        guard !isTransferring else { return }
        guard imported.count < ImportedModel.limit else {
            error = "You have \(ImportedModel.limit) imported models. Remove one before importing another."; return
        }
        let link: HuggingFaceGGUFLink
        do { link = try HuggingFaceGGUFLink.parse(text) } catch { self.error = error.localizedDescription; return }
        error = nil; failedModel = nil; failureDetail = nil
        importing = "Reading the model's header from Hugging Face…"
        let directory = directory, memory = ProcessInfo.processInfo.physicalMemory, configuration = transferConfiguration
        let importID = UUID(); transferID = importID
        beginContinued(title: "Importing a model")
        download = Task {
            let id = ImportedModel.newID()
            let staging = directory.appendingPathComponent(id + ".import")
            defer { importing = nil; download = nil; transferID = nil; backgroundAllowance.release(); finishContinued(); try? FileManager.default.removeItem(at: staging); refresh() }
            do {
                try Task.checkCancellation()
                let remote = try await HuggingFaceImport.inspect(link, configuration: configuration())
                let plan = try ImportedModel.plan(header: remote.header, bytes: remote.bytes, physicalMemoryBytes: memory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
                try folder.setResourceValues(attributes)
                let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
                guard available > remote.bytes + 256_000_000 else { throw LocalModelError.storage }
                var transfer = LocalModel(id: id, name: link.fileName, bytes: remote.bytes, revision: link.revision,
                                          sha256: remote.sha256, detail: "", repository: link.repository, fileName: link.filePath)
                transfer.sourceURL = link.resolveURL
                importing = "Downloading · 0%"
                try await ModelTransfer.fetch(transfer, to: staging, configuration: configuration()) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard self?.transferID == importID else { return }
                        self?.importing = "Downloading · \(Int(Double(received) / Double(max(1, total)) * 100))%"
                    }
                }
                try Task.checkCancellation()
                importing = "Verifying download…"
                let verification = Task.detached(priority: .utility) {
                    try Self.verify(staging, model: transfer)
                    let file = try FileHandle(forReadingFrom: staging)
                    defer { try? file.close() }
                    let prefix = try file.read(upToCount: remote.prefix.count) ?? Data()
                    guard prefix == remote.prefix else {
                        throw ModelVerificationFailure(detail: "The downloaded header differs from the inspected model. Try the link again.")
                    }
                }
                try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                let model = ImportedModel(id: id, name: link.fileName, bytes: remote.bytes, sha256: remote.sha256,
                                          header: remote.header, family: plan.family, contextSize: plan.contextSize)
                try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(model.fileName))
                imported.append(model)
                do { try saveImported() } catch {
                    imported.removeLast()
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName))
                    throw error
                }
                selected = model.id
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch {
                self.error = error is ImportedModel.Problem || error is LocalModelError || error is HuggingFaceImport.Failure
                    || error is ModelVerificationFailure
                    ? error.localizedDescription : "The model could not be downloaded. Check your connection and try again."
            }
        }
    }

    nonisolated static func copyChecked(_ source: URL, into directory: URL, physicalMemoryBytes: UInt64,
                                        progress: @Sendable (Int64, Int64) -> Void) throws -> ImportedModel {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "gguf" else { throw ImportedModel.Problem.notGGUF("Choose a .gguf file.") }
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else { throw ImportedModel.Problem.notGGUF("The file is empty.") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: GGUFHeader.maxHeaderBytes) ?? Data()
        let header: GGUFHeader
        do { header = try GGUFHeader.parse(prefix) }
        catch { throw ImportedModel.Problem.notGGUF(error.localizedDescription) }
        let plan = try ImportedModel.plan(header: header, bytes: size, physicalMemoryBytes: physicalMemoryBytes)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available > size + 256_000_000 else { throw LocalModelError.storage }
        let id = ImportedModel.newID()
        let staging = directory.appendingPathComponent(id + ".import")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw LocalModelError.storage }
        defer { try? FileManager.default.removeItem(at: staging) }
        var hash = SHA256(), copied: Int64 = 0
        do {
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            try input.seek(toOffset: 0)
            progress(0, size)
            while let block = try input.read(upToCount: 4_194_304), !block.isEmpty {
                try Task.checkCancellation()
                let checkedPrefix = prefix.dropFirst(min(Int(copied), prefix.count)).prefix(block.count)
                guard Int64(block.count) <= size - copied,
                      block.starts(with: checkedPrefix) else {
                    throw ImportedModel.Problem.notGGUF("The file changed after its header was checked. Choose it again from Files.")
                }
                hash.update(data: block)
                try output.write(contentsOf: block)
                copied += Int64(block.count)
                progress(copied, size)
            }
            guard copied == size else { throw ImportedModel.Problem.notGGUF("The file changed while it was being copied.") }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try Task.checkCancellation()
        let model = ImportedModel(id: id, name: source.lastPathComponent, bytes: size,
                                  sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                  header: header, family: plan.family, contextSize: plan.contextSize)
        try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(model.fileName))
        return model
    }

    func removeImported(_ id: String) {
        guard !isTransferring, let index = imported.firstIndex(where: { $0.id == id }) else { return }
        let model = imported.remove(at: index)
        do { try saveImported() }
        catch {
            imported.insert(model, at: index)
            self.error = "Could not remove this model. Try again."
            return
        }
        do {
            let file = directory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { self.error = "Could not remove this model. Try again." }
        if selected == id { selected = builtIn[0].id }
        refresh()
    }

    private func saveImported() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(imported).write(to: importedList, options: [.atomic, .completeFileProtection])
    }

    func cancel() {
        backgroundAllowance.release()
        download?.cancel()
    }

    /// True while iOS keeps a download or import running in the background.
    var continuesInBackground: Bool { continued?.isRunning == true }

    /// Called from the tap that starts a download or import, while the app is
    /// in front: asks iOS to let it finish if the user leaves.
    private func beginContinued(title: String) {
        continued?.finish(success: false)
        continued = startContinued(.transfer, title, "Starting…") { [weak self] in
            // The user cancelled it from the Lock Screen, or iOS needed the resources.
            self?.cancel()
        }
        reportContinued()
    }

    private func reportContinued() {
        guard let continued else { return }
        if downloading != nil {
            continued.update(fraction: progress,
                             subtitle: verifying ? "Checking the download…" : "\(Int(min(max(progress, 0), 1) * 100))% downloaded")
        } else if let importing {
            continued.update(fraction: KeelLiveActivitySnapshot.parsedPercentage(from: importing) ?? 0, subtitle: importing)
        }
    }

    private func finishContinued() {
        continued?.finish(success: error == nil && failedModel == nil && !Task.isCancelled)
        continued = nil
    }

    func sceneDidChange(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            backgroundAllowance.release()
        case .background:
            guard isTransferring else { return }
            // iOS 26: the system is already keeping this download running and
            // showing its progress. Nothing to stop.
            if continued?.isRunning == true { return }
            backgroundAllowance.acquire(name: "KeelModelTransfer") { [weak self] in
                // The system may have taken the download over in the meantime.
                guard self?.continued?.isRunning != true else { return }
                self?.cancel()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
    func discardPartial(_ model: LocalModel) {
        guard !isTransferring, !model.isImported else { return }
        do { for asset in model.assets {
            let partial = partialPath(asset.transferModel)
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        }; error = nil; refresh() }
        catch { self.error = "Could not discard this partial download. Try again." }
    }
    func remove(_ model: LocalModel) {
        guard !isTransferring, !model.isImported else { return }
        do { for asset in model.assets {
            let file = path(asset.transferModel)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }; refresh() }
        catch { self.error = "Could not remove this model. Try again." }
    }
}
