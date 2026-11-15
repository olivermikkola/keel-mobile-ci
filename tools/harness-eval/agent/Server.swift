import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A llama.cpp server (`llama-server`) with a Bonsai GGUF loaded.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

struct ModelServer {
    let base: URL

    struct Sampling {
        var topK = 40
        var topP = 0.9
        var temperature = 0.6
        var presencePenalty = 0.0
        var minP: Double?
        var repeatPenalty: Double?
        /// Extra stop strings besides the end-of-turn token.
        var stop: [String] = []
    }

    struct Completion {
        let text: String
        let tokens: [Int]
        let predicted: Int
        let promptMilliseconds: Double
        let predictedMilliseconds: Double
        /// Tokens the server actually had to evaluate for this prompt.
        let serverEvaluated: Int
    }

    private func post(_ path: String, _ body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900
        let done = DispatchSemaphore(value: 0)
        let result = Box<Result<Data, Error>>(.failure(URLError(.unknown)))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result.value = .success(data) }
            else { result.value = .failure(error ?? URLError(.badServerResponse)) }
            done.signal()
        }.resume()
        done.wait()
        guard let object = try JSONSerialization.jsonObject(with: result.value.get()) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return object
    }

    func tokenize(_ text: String, special: Bool = true) throws -> [Int] {
        let reply = try post("tokenize", ["content": text, "add_special": special, "parse_special": true])
        return (reply["tokens"] as? [Int]) ?? []
    }

    func complete(_ prompt: String, limit: Int, seed: Int, sampling: Sampling, grammar: ToolCallGrammar? = nil) throws -> Completion {
        var body: [String: Any] = [
            "prompt": prompt, "n_predict": limit, "top_k": sampling.topK, "top_p": sampling.topP,
            "temperature": sampling.temperature, "presence_penalty": sampling.presencePenalty, "seed": seed,
            "min_p": sampling.minP ?? 0, "repeat_penalty": sampling.repeatPenalty ?? 1, "repeat_last_n": 64,
            "cache_prompt": true, "return_tokens": true, "stop": ["<|im_end|>"] + sampling.stop,
        ]
        if let grammar {
            // The same lazy grammar and trigger patterns the phone gives llama.cpp (type 2: pattern).
            body["grammar"] = grammar.text
            body["grammar_lazy"] = true
            body["grammar_triggers"] = grammar.triggerPatterns.map { ["type": 2, "value": $0] }
        }
        let reply = try post("completion", body)
        let timings = reply["timings"] as? [String: Any] ?? [:]
        var text = reply["content"] as? String ?? ""
        // The server drops a matched stop string; the phone keeps what it stopped on.
        if let word = reply["stopping_word"] as? String, sampling.stop.contains(word) { text += word }
        return Completion(text: text, tokens: reply["tokens"] as? [Int] ?? [],
                          predicted: reply["tokens_predicted"] as? Int ?? 0,
                          promptMilliseconds: timings["prompt_ms"] as? Double ?? 0,
                          predictedMilliseconds: timings["predicted_ms"] as? Double ?? 0,
                          serverEvaluated: timings["prompt_n"] as? Int ?? 0)
    }

    func modelName() -> String {
        var request = URLRequest(url: base.appendingPathComponent("props"))
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        let name = Box("unknown")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let path = object["model_path"] as? String { name.value = URL(fileURLWithPath: path).lastPathComponent }
            done.signal()
        }.resume()
        done.wait()
        return name.value
    }
}
