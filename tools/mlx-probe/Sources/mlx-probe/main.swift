import Foundation
@testable import KeelHarness

// Usage: mlx-probe <model-folder> [output.json]
// Runs the runtime benchmark's cases through MLXRunner, the app's MLX code,
// with grammar off (as the app's comparison does) and prints the report.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("Usage: mlx-probe <model-folder> [output.json]"); exit(2) }
let folder = URL(fileURLWithPath: arguments[1])
let pack = MLXModelPack.lfm3
let missing = pack.missing(in: folder)
guard missing.isEmpty else { print("Missing or wrong-size files: \(missing.map(\.name))"); exit(1) }

let runner = MLXRunner()
let loadStart = Date()
try await runner.load(directory: folder)
print(String(format: "Loaded %@ in %.1f s", pack.name, Date().timeIntervalSince(loadStart)))
_ = try await runner.generate(prompt: RuntimeBenchmark.warmUpPrompt(family: pack.family), limit: 8, temperature: 0.6, topK: 40, topP: 0.9, cancelled: { false })
let sampling = SamplingProfile.app
let report = try await RuntimeBenchmark.run(
    runtime: "MLX", model: pack.name, device: ProcessInfo.processInfo.hostName, family: pack.family, grammar: false,
    thermalState: { ProcessInfo.processInfo.thermalState.rawValue },
    progress: { item, index, count in print("[\(index + 1)/\(count)] \(item.id)") }
) { item in
    let g = try await runner.generate(prompt: item.prompt, limit: item.replyLimit, temperature: Float(sampling.temperature),
                                      topK: sampling.topK, topP: Float(sampling.topP), cancelled: { false })
    return .init(prefillTokens: g.promptTokens, prefillSeconds: g.promptSeconds, decodedTokens: g.generatedTokens,
                 decodeSeconds: g.generateSeconds, peakBytes: g.peakBytes, output: g.text)
}
print(RuntimeBenchmark.summary(report))
for run in report.runs {
    print("\(run.caseID): \(run.outcome?.rawValue ?? "-") · \(run.prefillTokens) read, \(run.decodedTokens) written · "
          + run.output.prefix(160).replacingOccurrences(of: "\n", with: " "))
}
if arguments.count >= 3 {
    try RuntimeBenchmark.json([report]).write(toFile: arguments[2], atomically: true, encoding: .utf8)
}
