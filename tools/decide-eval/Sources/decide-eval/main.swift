import Foundation
import KeelHarness

// decide-eval --model d1.gguf --request request.json [--threads N] [--context N] [--split] [--no-flash]
// The request: {"state": text or null, "questions": [{"id", "type": "noul"|"choice"|"score",
//   "instructions", "criteria": [[key, description or null], ...] for choice, [level, ...] for score,
//   {"true": text, "false": text} or null for noul}]}
// Prints {"answers": {id: answer as llama.cpp's server writes it}, "read_tokens", "seconds"}.

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let modelPath = argument("--model"), let requestPath = argument("--request"),
      let data = FileManager.default.contents(atPath: requestPath),
      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = request["questions"] as? [[String: Any]] else {
    FileHandle.standardError.write("usage: decide-eval --model FILE --request FILE [--threads N] [--context N] [--split] [--no-flash]\n".data(using: .utf8)!)
    exit(2)
}

var ids: [String] = []
var questions: [DecisionQuestion] = []
for item in raw {
    let id = item["id"] as? String ?? "q\(ids.count)"
    let text = item["instructions"] as? String ?? ""
    switch item["type"] as? String {
    case "noul":
        let criteria = item["criteria"] as? [String: String]
        questions.append(.yesNo(text, yes: criteria?["true"], no: criteria?["false"]))
    case "choice":
        let pairs = item["criteria"] as? [[Any]] ?? []
        questions.append(.choice(text, options: pairs.map { DecisionOption(key: $0[0] as? String ?? "", description: $0.count > 1 ? $0[1] as? String : nil) }))
    case "score":
        questions.append(.scale(text, levels: item["criteria"] as? [String] ?? []))
    default:
        FileHandle.standardError.write("unknown question type in \(id)\n".data(using: .utf8)!)
        exit(2)
    }
    ids.append(id)
}

var settings = DecisionRuntime.Settings()
settings.gpu = false
if let threads = argument("--threads").flatMap(Int32.init) { settings.threads = threads }
if CommandLine.arguments.contains("--no-flash") { settings.flashAttention = false }
if let context = argument("--context").flatMap(UInt32.init) { settings.contextSize = context }

let runtime = DecisionRuntime()

func render(_ result: DecisionRuntime.Result) -> [String: Any] {
    var answers: [String: Any] = [:]
    for (index, answer) in result.answers.enumerated() {
        let question = questions[index]
        switch answer.kind {
        case .yesNo:
            answers[ids[index]] = ["type": "noul", "noul": answer.probabilities[0]]
        case .choice:
            answers[ids[index]] = ["type": "choice", "choice": question.options[answer.index].key, "confidence": answer.confidence,
                                   "probabilities": Dictionary(uniqueKeysWithValues: zip(question.options.map(\.key), answer.probabilities))]
        case .scale:
            answers[ids[index]] = ["type": "score", "score": Double(answer.index), "confidence": answer.confidence,
                                   "probabilities": Dictionary(uniqueKeysWithValues: zip(question.options.map(\.key), answer.probabilities))]
        }
    }
    return answers
}

// --split: read the document in parts that fit --context, as the app does on a phone.
let start = Date()
let output: [String: Any]
if CommandLine.arguments.contains("--split"), let document = request["state"] as? String {
    let parts = try await runtime.parts(of: document, questions: questions, modelPath: modelPath, settings: settings)
    var results: [[String: Any]] = []
    var answered: [DecisionRuntime.Result] = []
    var read = 0
    for part in parts {
        let result = try await runtime.ask(document: part, questions: questions, modelPath: modelPath, settings: settings)
        read += result.readTokens
        answered.append(result)
        results.append(["answers": render(result), "fraction_read": result.fractionRead, "characters": part.count])
    }
    // The document's answer per question, as the app shows it: the surest part's.
    var combined: [String: Any] = [:]
    for index in questions.indices {
        guard let best = DecisionModel.combine(answered.map { $0.answers[index] }) else { continue }
        let one = DecisionRuntime.Result(answers: questions.indices.map { $0 == index ? best.answer : answered[best.part].answers[$0] },
                                         readTokens: 0, fractionRead: 1)
        combined[ids[index]] = ["answer": render(one)[ids[index]] as Any, "part": best.part + 1]
    }
    output = ["parts": results, "combined": combined, "read_tokens": read, "seconds": Date().timeIntervalSince(start)]
} else {
    let result = try await runtime.ask(document: request["state"] as? String, questions: questions, modelPath: modelPath, settings: settings)
    output = ["answers": render(result), "read_tokens": result.readTokens, "fraction_read": result.fractionRead,
              "seconds": Date().timeIntervalSince(start)]
}
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
