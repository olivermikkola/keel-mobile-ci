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

    var fullAttentionLayerCount: Int { layerCount / max(1, fullAttentionInterval) }
    var linearAttentionLayerCount: Int { layerCount - fullAttentionLayerCount }

    // Q4_0 stores 32 values in 2 bytes of scale plus 16 bytes of quants.
    var kvBytesPerToken: UInt64 {
        let values = UInt64(fullAttentionLayerCount) * UInt64(kvHeadCount)
            * UInt64(keyLength + valueLength)
        return (values * 18 + 31) / 32
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

struct LocalModel: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let revision: String
    let sha256: String
    let detail: String
    let contextSize: UInt32
    let architecture: ModelArchitecture

    init(id: String, name: String, bytes: Int64, revision: String, sha256: String, detail: String,
         contextSize: UInt32 = 4096, architecture: ModelArchitecture = .bonsai2) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.revision = revision
        self.sha256 = sha256
        self.detail = detail
        self.contextSize = contextSize
        self.architecture = architecture
    }

    var fileName: String { "Ternary-Bonsai-2-\(id)-Q2_0.gguf" }
    var url: URL {
        URL(string: "https://huggingface.co/prism-ml/Ternary-Bonsai-2-\(id)-gguf/resolve/\(revision)/\(fileName)")!
    }
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
                   contextSize: 32_768)
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
    @Published private(set) var progress: Double = 0
    @Published private(set) var verifying = false
    @Published private(set) var restarting = false
    @Published private(set) var failedModel: LocalModel?
    @Published private(set) var failureDetail: String?
    @Published var selected: String {
        didSet { defaults.set(selected, forKey: "localModel") }
    }
    @Published var error: String?
    private let directory: URL
    private let defaults: UserDefaults
    private let transferConfiguration: () -> URLSessionConfiguration
    private var download: Task<Void, Never>?
    private var transferID: UUID?

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.defaults = defaults
        self.transferConfiguration = transferConfiguration
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        selected = defaults.string(forKey: "localModel") ?? "4B"
        if !LocalModel.catalog.contains(where: { $0.id == selected }) { selected = "4B" }
        // A killed process cannot run the download task's cleanup. Reclaim
        // only our known staging files; installed models are left untouched.
        for model in LocalModel.catalog {
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(model.fileName + ".partial"))
            // A crash during the one-shot integrity retry must not leave a
            // second staging file that no resume path can claim.
            try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(model.fileName + ".download.retry"))
        }
        #if DEBUG && targetEnvironment(simulator)
        ModelDownloadUITestFixture.prepare(in: self.directory)
        if ProcessInfo.processInfo.arguments.contains("--model-failure-fixture") {
            failedModel = LocalModel.catalog[1]
            error = ModelVerificationFailure(detail: "").localizedDescription
            failureDetail = "SHA-256 mismatch. Recorded UI fixture; no model was downloaded by this fixture."
        }
        #endif
        refresh()
    }

    var current: LocalModel { LocalModel.catalog.first { $0.id == selected } ?? LocalModel.catalog[0] }
    func path(_ model: LocalModel) -> URL { directory.appendingPathComponent(model.fileName) }
    func partialPath(_ model: LocalModel) -> URL { directory.appendingPathComponent(model.fileName + ".download") }
    func refresh() {
        installed = Set(LocalModel.catalog.filter { model in
            let size = try? path(model).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map { Int64($0) == model.bytes } ?? false
        }.map(\.id))
        partialBytes = Dictionary(uniqueKeysWithValues: LocalModel.catalog.compactMap { model -> (String, Int64)? in
            guard let size = try? partialPath(model).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { return nil }
            return (model.id, Int64(size))
        })
    }

    func install(_ model: LocalModel) {
        guard downloading == nil else { return }
        downloading = model.id; progress = Double(partialBytes[model.id] ?? 0) / Double(model.bytes)
        verifying = false; restarting = false; error = nil; failedModel = nil; failureDetail = nil
        let transferID = UUID(); self.transferID = transferID
        download = Task {
            defer { downloading = nil; download = nil; verifying = false; restarting = false; self.transferID = nil; refresh() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
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
                            Task { @MainActor in
                                guard self?.transferID == transferID else { return }
                                self?.progress = min(1, Double(received) / Double(model.bytes))
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
                selected = model.id
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
                if error is ModelVerificationFailure { try? FileManager.default.removeItem(at: partialPath(model)) }
                else if case LocalModelError.integrity = error { try? FileManager.default.removeItem(at: partialPath(model)) }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.fileName + ".download.retry"))
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

    func cancel() { download?.cancel() }
    func discardPartial(_ model: LocalModel) {
        guard downloading == nil else { return }
        do { try FileManager.default.removeItem(at: partialPath(model)); error = nil; refresh() }
        catch { self.error = "Could not discard this partial download. Try again." }
    }
    func remove(_ model: LocalModel) {
        guard downloading == nil else { return }
        do { try FileManager.default.removeItem(at: path(model)); refresh() }
        catch { self.error = "Could not remove this model. Try again." }
    }
}
