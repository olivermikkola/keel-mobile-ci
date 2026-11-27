import Foundation

// Classifies collected model outputs with the app's real RepositoryCall.parse
// (extracted verbatim by run.sh), before and after ToolCallText.normalize.
struct Row: Decodable { let task: String; let turn: Int; let sample: Int; let output: String; let tokens: Int? }

enum Outcome: String, CaseIterable { case answer = "plain answer", call = "valid call", invalid = "rejected" }

func outcome(_ text: String) -> Outcome {
    do { return try RepositoryCall.parse(text) == nil ? .answer : .call } catch { return .invalid }
}

let path = CommandLine.arguments.dropFirst().first ?? "/dev/stdin"
let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
let rows = try lines.map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }

var before: [Outcome: Int] = [:], after: [Outcome: Int] = [:]
var repaired = 0, recovered: [Row] = [], stillRejected: [Row] = [], limitHits = 0
for row in rows {
    if (row.tokens ?? 0) >= 512 { limitHits += 1 }
    let b = outcome(row.output)
    let n = ToolCallText.normalize(row.output)
    let a = outcome(n.text)
    before[b, default: 0] += 1; after[a, default: 0] += 1
    if n.repaired { repaired += 1 }
    if b == .invalid && a == .call { recovered.append(row) }
    if a == .invalid { stillRejected.append(row) }
    if b == .call && a != .call { print("REGRESSION: \(row.task) turn \(row.turn)"); exit(2) }
}

print("samples: \(rows.count)  (512-token limit hits: \(limitHits))")
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
print(pad("outcome", 14) + lpad("strict", 9) + lpad("+harness", 10))
for o in Outcome.allCases {
    print(pad(o.rawValue, 14) + lpad(String(before[o] ?? 0), 9) + lpad(String(after[o] ?? 0), 10))
}
print("normalized: \(repaired), recovered from rejected: \(recovered.count), regressions: 0")
for row in stillRejected.prefix(5) {
    print("--- still rejected (turn \(row.turn)): \(row.task)\n\(row.output.prefix(400))")
}
for row in recovered.prefix(3) {
    print("--- recovered (turn \(row.turn)): \(row.task)\n\(row.output.prefix(400))")
}
