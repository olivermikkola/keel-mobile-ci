import SwiftUI
import UIKit
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Runs the runtime benchmark on this iPhone: llama.cpp with the catalog's
/// LFM3 GGUF, then MLX with the same model in MLX 4-bit, on the same prompts.
@MainActor
final class RuntimeBenchmarkModel: ObservableObject {
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var phase: String?
    @Published private(set) var reports: [RuntimeBenchmark.Report] = []
    @Published var error: String?
    private var work: Task<Void, Never>?

    let pack = MLXModelPack.lfm3
    let mlx = MLXRunner()

    var busy: Bool { work != nil }
    func directory(_ models: ModelLibrary) -> URL { pack.directory(in: models.modelsDirectory) }
    func packInstalled(_ models: ModelLibrary) -> Bool { pack.missing(in: directory(models)).isEmpty }

    static var device: String {
        var info = utsname(); uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(machine) · iOS \(UIDevice.current.systemVersion)"
    }

    func download(_ models: ModelLibrary) {
        guard work == nil else { return }
        error = nil
        let folder = directory(models), pack = pack
        work = Task {
            defer { work = nil; downloadProgress = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var root = folder; try? root.setResourceValues(excluded)
                let total = Double(pack.totalBytes)
                let missing = pack.missing(in: folder)
                let missingBytes = missing.reduce(Int64(0)) { $0 + $1.bytes }
                let savedPartial = missing.reduce(Int64(0)) { sum, file in
                    let staging = folder.appendingPathComponent(file.name).appendingPathExtension("download")
                    let bytes = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    return sum + min(bytes, file.bytes)
                }
                let remaining = max(Int64(0), missingBytes - savedPartial)
                let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
                guard remaining == 0 || available > remaining + 256_000_000 else { throw LocalModelError.storage }
                var done = total - Double(missingBytes)
                for file in missing {
                    let base = done
                    let destination = folder.appendingPathComponent(file.name)
                    let staging = destination.appendingPathExtension("download")
                    if let existing = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                       existing > file.bytes {
                        try? FileManager.default.removeItem(at: staging)
                    }
                    var transfer = LocalModel(id: file.name, name: file.name, bytes: file.bytes, revision: pack.revision,
                                              sha256: file.sha256, detail: "", repository: pack.repository, fileName: file.name)
                    transfer.sourceURL = pack.url(for: file)
                    let partial = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    downloadProgress = min(1, (base + Double(partial)) / total)
                    do {
                        try await ModelTransfer.fetch(transfer, to: staging, configuration: .ephemeral) { [weak self] received, _ in
                            Task { @MainActor [weak self] in
                                guard self?.work != nil else { return }
                                self?.downloadProgress = min(1, (base + Double(received)) / total)
                            }
                        }
                        try Task.checkCancellation()
                        let verification = Task.detached(priority: .utility) { try ModelLibrary.verify(staging, model: transfer) }
                        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                        try Task.checkCancellation()
                    } catch {
                        if error is ModelVerificationFailure { try? FileManager.default.removeItem(at: staging) }
                        else if case LocalModelError.integrity = error { try? FileManager.default.removeItem(at: staging) }
                        throw error
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: staging, to: destination)
                    done += Double(file.bytes)
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = error is LocalModelError || error is ModelVerificationFailure
                    ? error.localizedDescription : "Download interrupted. Your progress is kept; check your connection and resume."
            }
        }
    }

    func removePack(_ models: ModelLibrary) {
        guard work == nil else { return }
        Task { await mlx.unload() }
        try? FileManager.default.removeItem(at: directory(models))
        objectWillChange.send()
    }

    func run(models: ModelLibrary, chat: LocalChat) {
        guard work == nil, !chat.running,
              let gguf = models.catalog.first(where: { $0.id == self.pack.ggufModelID }), models.installed.contains(gguf.id) else { return }
        error = nil; reports = []
        let path = models.path(gguf).path, folder = directory(models), pack = pack, mlx = mlx
        let inference = chat.inference, device = Self.device, sampling = RuntimeRouter.sampling(for: gguf)
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            defer { work = nil; phase = nil; UIApplication.shared.isIdleTimerDisabled = false }
            do {
                // Free the chat's model (llama.cpp or MLX) so only the benchmark's model is in memory.
                await chat.unloadModelsNow()
                // One untimed reply first, so loading and GPU kernel setup are not counted in case 1.
                phase = "Warming up llama.cpp…"
                _ = try await inference.generate(LocalGenerationRequest(path: path, prompt: RuntimeBenchmark.warmUpPrompt(family: pack.family),
                                                                        limit: 8, contextSize: gguf.contextSize, model: gguf),
                                                 cancellation: InferenceCancellation(), onPrefill: { _, _ in }, onText: { _ in })
                // llama.cpp: a fresh context per case, so no runtime reuses an earlier prompt.
                let llama = try await RuntimeBenchmark.run(
                    runtime: "llama.cpp", model: gguf.name, device: device, family: pack.family, grammar: false,
                    thermalState: { ProcessInfo.processInfo.thermalState.rawValue },
                    progress: { item, index, count in self.phase = "llama.cpp \(index + 1)/\(count) · \(item.id)" }
                ) { item in
                    await inference.unload()
                    let cancellation = InferenceCancellation()
                    let collected = OutputBox()
                    let request = LocalGenerationRequest(path: path, prompt: item.prompt, limit: item.replyLimit,
                                                         contextSize: gguf.contextSize, model: gguf)
                    _ = try await withTaskCancellationHandler {
                        try await inference.generate(request, cancellation: cancellation, onPrefill: { _, _ in },
                                                     onText: { collected.append($0) })
                    } onCancel: { cancellation.cancel() }
                    try Task.checkCancellation()
                    let telemetry = await inference.latestTelemetry()
                    return .init(prefillTokens: telemetry?.prefillTokens ?? 0, prefillSeconds: telemetry?.prefillDuration ?? 0,
                                 decodedTokens: telemetry?.decodedTokens ?? 0, decodeSeconds: telemetry?.decodeDuration ?? 0,
                                 peakBytes: telemetry?.footprintBytes, output: collected.text)
                }
                reports = [llama]
                await inference.unload()

                phase = "Loading MLX…"
                try await mlx.load(directory: folder)
                // MLX compiles its GPU kernels on first use; keep that out of case 1.
                phase = "Warming up MLX…"
                _ = try await mlx.generate(prompt: RuntimeBenchmark.warmUpPrompt(family: pack.family), limit: 8,
                                           temperature: Float(sampling.temperature), topK: sampling.topK, topP: Float(sampling.topP),
                                           cancelled: { Task.isCancelled })
                let candidate = try await RuntimeBenchmark.run(
                    runtime: "MLX", model: pack.name, device: device, family: pack.family, grammar: false,
                    thermalState: { ProcessInfo.processInfo.thermalState.rawValue },
                    progress: { item, index, count in self.phase = "MLX \(index + 1)/\(count) · \(item.id)" }
                ) { item in
                    let g = try await mlx.generate(prompt: item.prompt, limit: item.replyLimit, temperature: Float(sampling.temperature),
                                                   topK: sampling.topK, topP: Float(sampling.topP), reuseCache: false, cancelled: { Task.isCancelled })
                    return .init(prefillTokens: g.promptTokens, prefillSeconds: g.promptSeconds, decodedTokens: g.generatedTokens,
                                 decodeSeconds: g.generateSeconds, peakBytes: g.peakBytes, output: g.text)
                }
                await mlx.unload()
                reports = [llama, candidate]
                recordCalibration(reports: [llama, candidate], gguf: gguf, modelsDirectory: models.modelsDirectory)
            } catch is CancellationError {
                await mlx.unload()
                self.error = "Stopped. Keep Keel open while the benchmark runs."
            } catch {
                await mlx.unload()
                self.error = error.localizedDescription
            }
        }
    }

    func stop() { work?.cancel() }

    var verdict: String? {
        guard reports.count == 2 else { return nil }
        return RuntimeBenchmark.verdict(current: reports[0], candidate: reports[1])
    }
    var json: String { RuntimeBenchmark.json(reports) }

    private func recordCalibration(reports: [RuntimeBenchmark.Report], gguf: LocalModel, modelsDirectory: URL) {
        let device = HardwareProfile.detectCurrent(appleIntelligenceAvailable: AppleModelRunner.isAvailable)
        let url = HardwareRecommendationStore.calibrationFileURL(in: modelsDirectory)
        var store = SpeedCalibrationStore.load(from: url)
        var changed = false
        for report in reports {
            guard let actual = report.decodeTokensPerSecond else { continue }
            let runtime: InferenceRuntimeKind = report.runtime.hasPrefix("MLX") ? .mlx : .llamaCpp
            let quant = runtime == .mlx ? "4-bit" : gguf.quantization
            let thermal = ThermalLevel(rawValue: min(max(report.hottest, 0), 3)) ?? .nominal
            let predicted = ModelFitEstimator.predictTokensPerSecond(
                input: gguf.fitInput,
                on: device,
                runtime: runtime,
                thermal: thermal
            )
            let speedRuns = report.runs.filter { $0.kind == .speed }
            let totalDecoded = speedRuns.reduce(0) { $0 + $1.decodedTokens }
            let totalSeconds = speedRuns.reduce(0.0) { $0 + $1.decodeSeconds }
            if store.record(SpeedObservation(
                chipID: device.chipID,
                runtime: runtime,
                quantBucket: quant,
                thermalLevel: thermal,
                predictedTokensPerSecond: predicted,
                actualTokensPerSecond: actual,
                decodedTokens: totalDecoded,
                decodeDuration: totalSeconds,
                footprintBytes: report.peakBytes
            )) {
                changed = true
            }
        }
        if changed {
            try? store.save(to: url)
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ text: String) { lock.lock(); value += text; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return value }
    }
}

struct RuntimeBenchmarkView: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @StateObject private var bench = RuntimeBenchmarkModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    @AppStorage(RuntimeRouter.useMLXKey) private var useMLXInChats = false

    private var gguf: LocalModel? { models.catalog.first { $0.id == bench.pack.ggufModelID } }

    var body: some View {
        List {
            Section {
                Text("Compares two ways of running the same model on this \(KeelDevice.name): llama.cpp (what Keel uses) and MLX. Same model (LFM3 1.7B), same 9 prompts: three for reading and writing speed, six tool requests. Takes a few minutes; keep Keel open.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Tool requests run without the tool-call grammar on both, because MLX does not have Keel's grammar yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(KeelStyle.surface)
            Section("Models") {
                LabeledContent("llama.cpp", value: gguf.map { models.installed.contains($0.id) ? "\($0.name) ✓" : "Download \($0.name) above" } ?? "—")
                if bench.packInstalled(models) {
                    LabeledContent("MLX", value: "\(bench.pack.name) ✓")
                    Button("Remove MLX model", role: .destructive) { bench.removePack(models) }.disabled(bench.busy)
                } else if let progress = bench.downloadProgress {
                    ProgressView(value: progress) { Text("Downloading MLX model · \(Int(progress * 100))%").font(.caption) }
                    Button("Cancel") { bench.stop() }
                } else {
                    Button {
                        bench.download(models)
                    } label: {
                        Label("Download \(bench.pack.name) · \(ByteCountFormatter.string(fromByteCount: bench.pack.totalBytes, countStyle: .file))",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(bench.busy || models.isTransferring)
                    .accessibilityIdentifier("downloadMLXPack")
                }
            }.listRowBackground(KeelStyle.surface)
            Section {
                Toggle("Use MLX for LFM3 chats", isOn: $useMLXInChats)
                    .disabled(!bench.packInstalled(models) || bench.busy)
                    .accessibilityIdentifier("useMLXInChats")
            } footer: {
                Text("Experimental. When on, chats with LFM3 · 1.7B are written by MLX instead of llama.cpp; the note under each reply says MLX. For now MLX has no tool-call grammar, re-reads the whole prompt on every tool step, and cannot read photos.")
            }.listRowBackground(KeelStyle.surface)
            Section {
                #if targetEnvironment(simulator)
                Text("MLX needs a physical \(KeelDevice.name): the simulator has no Metal GPU for it.").foregroundStyle(.secondary)
                #else
                if let phase = bench.phase {
                    HStack { ProgressView(); Text(phase).font(.callout) }
                    Button("Stop", role: .destructive) { bench.stop() }
                } else {
                    Button { bench.run(models: models, chat: chat) } label: { Label("Run benchmark", systemImage: "speedometer") }
                        .disabled(bench.busy || chat.running || !bench.packInstalled(models) || !(gguf.map { models.installed.contains($0.id) } ?? false))
                        .accessibilityIdentifier("runRuntimeBenchmark")
                }
                #endif
                if let error = bench.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }.listRowBackground(KeelStyle.surface)
            if !bench.reports.isEmpty {
                Section("Results") {
                    ForEach(bench.reports, id: \.runtime) { report in
                        Text(RuntimeBenchmark.summary(report)).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    if let verdict = bench.verdict { Text(verdict).font(.callout.weight(.semibold)) }
                    Button(copied ? "Copied" : "Copy results (JSON)") {
                        UIPasteboard.general.string = bench.json
                        copied = true
                    }
                    ShareLink(item: bench.json, preview: SharePreview("Keel runtime benchmark")) {
                        Label("Share results", systemImage: "square.and.arrow.up")
                    }
                }.listRowBackground(KeelStyle.surface)
            }
        }
        .scrollContentBackground(.hidden).background(KeelStyle.background)
        .navigationTitle("Runtime benchmark")
        .onChange(of: scenePhase) { _, phase in if phase == .background { bench.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if bench.busy {
                bench.stop()
                bench.error = "Your \(KeelDevice.name) is low on memory. Benchmark stopped; close other apps and try again."
            }
            Task { await bench.mlx.unload() }
        }
        .onDisappear { if bench.phase != nil { bench.stop() } }
    }
}
