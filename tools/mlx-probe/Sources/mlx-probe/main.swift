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

// Streaming, as chats use it: the pieces must add up to the decoded reply.
final class Pieces: @unchecked Sendable { var text = "" ; let lock = NSLock() }
let pieces = Pieces()
let streamed = try await runner.generate(prompt: RuntimeBenchmark.cases(family: pack.family)[0].prompt, limit: 64,
                                         temperature: 0, topK: 1, topP: 1, contextSize: 8192, cancelled: { false },
                                         onText: { piece in pieces.lock.withLock { pieces.text += piece } })
let joined = pieces.lock.withLock { pieces.text }
print("Streaming check: \(joined == streamed.text ? "pieces match the reply" : "MISMATCH") · \(streamed.generatedTokens) tokens · \(joined.prefix(80).replacingOccurrences(of: "\n", with: " "))")
guard joined == streamed.text else { print("Streamed: \(joined)\nDecoded: \(streamed.text)"); exit(1) }
// Prompt reuse, as an agent's second step: the app's own rendering of the same
// chat plus the reply and a tool result. Read with the cache, it must give
// exactly the reply a fresh read gives.
let question = "What files do I have in this chat?"
let firstPrompt = ModelPrompt.render(family: pack.family, system: AgentPrompt.local(), messages: [("user", question)])
let first = try await runner.generate(prompt: firstPrompt, limit: 96, temperature: 0, topK: 1, topP: 1, contextSize: 8192, cancelled: { false })
let secondPrompt = ModelPrompt.render(family: pack.family, system: AgentPrompt.local(), messages: [
    ("user", question), ("assistant", first.text),
    ("tool", "{\"entries\":[\"notes.txt\",\"budget.csv\"],\"path\":\".\",\"result_type\":\"directory_listing\",\"total\":2}")])
print("Reuse diagnosis: \(await runner.reuseDiagnosis(prompt: secondPrompt))")
print("Step 1 raw: \(first.text.debugDescription)")
let reusedStep = try await runner.generate(prompt: secondPrompt, limit: 96, temperature: 0, topK: 1, topP: 1, contextSize: 8192, cancelled: { false })
let freshStep = try await runner.generate(prompt: secondPrompt, limit: 96, temperature: 0, topK: 1, topP: 1, contextSize: 8192,
                                          reuseCache: false, cancelled: { false })
print(String(format: "Reuse check: step 1 wrote %d tokens · step 2 reused %d and read %d in %.2f s; fresh read %d in %.2f s · replies %@",
             first.generatedTokens, reusedStep.reusedTokens, reusedStep.promptTokens, reusedStep.promptSeconds,
             freshStep.promptTokens, freshStep.promptSeconds, reusedStep.text == freshStep.text ? "match" : "DIFFER"))
print("Step 1: \(first.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
print("Step 2: \(reusedStep.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
guard reusedStep.reusedTokens > 0 else { print("Reuse check: NOT REUSED (the second prompt did not start with the cached tokens)"); exit(1) }
guard reusedStep.text == freshStep.text else { print("Fresh: \(freshStep.text)"); exit(1) }

let report = try await RuntimeBenchmark.run(
    runtime: "MLX", model: pack.name, device: ProcessInfo.processInfo.hostName, family: pack.family, grammar: false,
    thermalState: { ProcessInfo.processInfo.thermalState.rawValue },
    progress: { item, index, count in print("[\(index + 1)/\(count)] \(item.id)") }
) { item in
    let g = try await runner.generate(prompt: item.prompt, limit: item.replyLimit, temperature: Float(sampling.temperature),
                                      topK: sampling.topK, topP: Float(sampling.topP), reuseCache: false, cancelled: { false })
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
