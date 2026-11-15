import SwiftUI
import UIKit

/// Advanced → Runtime benchmark. Runs the same fixed cases
/// (`Harness/RuntimeBenchmark.swift`) on LFM3 1.7B through llama.cpp on the
/// GPU, llama.cpp on the CPU only (what work in the background would get) and
/// MLX, alternating over two rounds so the phone warming up affects all three,
/// and shows a plain-words verdict with results to copy.
@MainActor
final class RuntimeBenchmarkRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase = ""
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var reports: [RuntimeBenchmark.Report] = []
    @Published private(set) var mlxDownloaded = MLXModelFiles.lfm3.isDownloaded
    @Published var error: String?

    static let rounds = 2
    private let files = MLXModelFiles.lfm3
    private let mlx = MLXInference()
    private var task: Task<Void, Never>?

    var verdict: String? {
        guard let current = reports.first(where: { $0.runtime == "llama.cpp" }),
              let candidate = reports.first(where: { $0.runtime == "MLX" }) else { return nil }
        return RuntimeBenchmark.verdict(current: current, candidate: candidate)
    }

    var copyText: String {
        (reports.map(RuntimeBenchmark.summary) + [verdict ?? "", RuntimeBenchmark.json(reports)])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func downloadMLX() {
        guard !running else { return }
        running = true; error = nil; downloadProgress = 0; phase = "Downloading the MLX model…"
        task = Task {
            defer { running = false; downloadProgress = nil; phase = ""; mlxDownloaded = files.isDownloaded }
            do {
                try await files.download { value in Task { @MainActor in self.downloadProgress = value } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func removeMLX() {
        guard !running else { return }
        do { try files.remove() } catch { self.error = error.localizedDescription }
        mlxDownloaded = files.isDownloaded
    }

    func run(model: LocalModel, path: URL, llama: LocalInference) {
        guard !running else { return }
        running = true; error = nil; reports = []
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                running = false; phase = ""
                UIApplication.shared.isIdleTimerDisabled = false
            }
            let cases = RuntimeBenchmark.cases(family: model.family)
            var llamaRuns: [RuntimeBenchmark.Run] = [], cpuRuns: [RuntimeBenchmark.Run] = [], mlxRuns: [RuntimeBenchmark.Run] = []
            do {
                for round in 1...Self.rounds {
                    for (index, item) in cases.enumerated() {
                        try Task.checkCancellation()
                        phase = "Round \(round) of \(Self.rounds) · llama.cpp · \(index + 1)/\(cases.count)"
                        llamaRuns.append(try await runLlama(item, model: model, path: path, llama: llama, cpuOnly: false))
                    }
                    for (index, item) in cases.enumerated() {
                        try Task.checkCancellation()
                        phase = "Round \(round) of \(Self.rounds) · llama.cpp CPU · \(index + 1)/\(cases.count)"
                        cpuRuns.append(try await runLlama(item, model: model, path: path, llama: llama, cpuOnly: true))
                    }
                    await llama.unload()
                    for (index, item) in cases.enumerated() {
                        try Task.checkCancellation()
                        phase = "Round \(round) of \(Self.rounds) · MLX · \(index + 1)/\(cases.count)"
                        mlxRuns.append(try await runMLX(item, sampling: model.family.sampling))
                    }
                    await mlx.unload()
                }
            } catch is CancellationError {
                await mlx.unload()
                return
            } catch {
                await mlx.unload()
                self.error = error.localizedDescription
            }
            let device = Self.deviceName
            await llama.unload()
            reports = [("llama.cpp", llamaRuns), ("llama.cpp CPU", cpuRuns), ("MLX", mlxRuns)].filter { !$0.1.isEmpty }.map { runtime, runs in
                RuntimeBenchmark.Report(runtime: runtime, model: model.name, device: device,
                                        runs: RuntimeBenchmark.scored(runs, family: model.family))
            }
        }
    }

    func cancel() { task?.cancel() }

    private func runLlama(_ item: RuntimeBenchmark.Case, model: LocalModel, path: URL,
                          llama: LocalInference, cpuOnly: Bool) async throws -> RuntimeBenchmark.Run {
        // Start every case cold, as MLX does: no prompt cache carried between cases.
        await llama.unload()
        let text = TextBox()
        var request = LocalGenerationRequest(path: path.path, prompt: item.prompt, limit: item.replyLimit,
                                             contextSize: model.contextSize, model: model, grammar: item.grammar)
        request.cpuOnly = cpuOnly
        _ = try await llama.generate(request, cancellation: InferenceCancellation(), onPrefill: { _, _ in },
                                     onText: { text.append($0) })
        let telemetry = await llama.latestTelemetry()
        return RuntimeBenchmark.Run(
            caseID: item.id, kind: item.kind,
            prefillTokens: telemetry?.prefillTokens ?? 0, prefillSeconds: telemetry?.prefillDuration ?? 0,
            decodedTokens: telemetry?.decodedTokens ?? 0, decodeSeconds: telemetry?.decodeDuration ?? 0,
            peakBytes: InferenceTelemetry.currentFootprintBytes(),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue, output: text.value)
    }

    private func runMLX(_ item: RuntimeBenchmark.Case, sampling: SamplingProfile) async throws -> RuntimeBenchmark.Run {
        let result = try await mlx.generate(files, prompt: item.prompt, limit: item.replyLimit,
                                            sampling: sampling, grammar: item.grammar)
        return RuntimeBenchmark.Run(
            caseID: item.id, kind: item.kind,
            prefillTokens: result.promptTokens, prefillSeconds: result.promptSeconds,
            decodedTokens: result.generatedTokens, decodeSeconds: result.generateSeconds,
            peakBytes: InferenceTelemetry.currentFootprintBytes(),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue, output: result.text)
    }

    static var deviceName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

struct RuntimeBenchmarkView: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @StateObject private var runner = RuntimeBenchmarkRunner()
    @State private var copied = false

    private var gguf: LocalModel? { models.catalog.first { $0.id == "lfm3" } }

    var body: some View {
        Form {
            Section {
                Text("Runs the same prompts on LFM3 1.7B three ways: llama.cpp on the GPU, which Keel uses today; llama.cpp on the CPU only, which is all iOS allows in the background; and MLX, Apple's framework. It measures reading and writing speed, memory, heat and tool calls. It takes several minutes and warms the phone.")
                    .foregroundStyle(.secondary)
            }
            Section("Models") {
                LabeledContent("llama.cpp", value: gguf.map { models.installed.contains($0.id) ? "Ready" : "Download LFM3 · 1.7B in Models" } ?? "Not in catalog")
                if runner.mlxDownloaded {
                    LabeledContent("MLX", value: "Ready")
                    Button("Remove the MLX model", role: .destructive) { runner.removeMLX() }.disabled(runner.running)
                } else if let progress = runner.downloadProgress {
                    ProgressView(value: progress) { Text("Downloading the MLX model") }
                } else {
                    Button("Download the MLX model (\(ByteCountFormatter.string(fromByteCount: MLXModelFiles.lfm3.bytes, countStyle: .file)))") {
                        runner.downloadMLX()
                    }.disabled(runner.running)
                }
            }
            Section {
                if runner.running && runner.downloadProgress == nil {
                    ProgressView { Text(runner.phase) }
                    Button("Stop", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run the benchmark") {
                        guard let gguf else { return }
                        runner.run(model: gguf, path: models.path(gguf), llama: chat.inference)
                    }
                    .disabled(gguf.map { !models.installed.contains($0.id) } ?? true || !runner.mlxDownloaded || chat.running)
                    .accessibilityIdentifier("runRuntimeBenchmark")
                }
            } footer: {
                Text(chat.running ? "Wait for the chat to finish first." : "Keep Keel open until it finishes: iOS stops the model in the background.")
            }
            if let error = runner.error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if !runner.reports.isEmpty {
                Section("Results") {
                    ForEach(runner.reports, id: \.runtime) { report in
                        Text(RuntimeBenchmark.summary(report)).font(.system(.footnote, design: .monospaced))
                    }
                    if let verdict = runner.verdict { Text(verdict).font(.headline) }
                    Button(copied ? "Copied" : "Copy results") {
                        UIPasteboard.general.string = runner.copyText
                        copied = true
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(KeelStyle.background)
        .navigationTitle("Runtime benchmark")
        .onDisappear { runner.cancel() }
    }
}
