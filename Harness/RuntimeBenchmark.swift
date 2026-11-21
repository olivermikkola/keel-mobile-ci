import Foundation

/// A fixed benchmark for comparing two inference runtimes on the same model
/// and the same prompts: llama.cpp (what Keel uses) and MLX (a candidate).
///
/// Both runtimes get the exact same rendered prompt text, so only the runtime
/// differs. The cases cover reading a short and a long prompt, writing an
/// answer, and tool calls under the tool-call grammar. Scoring and the report
/// live here so they can be tested without a phone; the app only runs the cases.
enum RuntimeBenchmark {
    enum Kind: String, Codable, Sendable { case speed, tool }

    struct Case: Equatable, Sendable {
        let id: String
        let kind: Kind
        /// The rendered prompt, exactly as the phone would send it.
        let prompt: String
        let replyLimit: Int
        /// The tool a good answer calls first; nil when the answer is plain text.
        let expectedTool: String?
        /// Set for tool cases: the runtime must constrain tool calls with it.
        let grammar: ToolCallGrammar?
    }

    /// One case as one runtime ran it.
    struct Run: Codable, Equatable, Sendable {
        let caseID: String
        let kind: Kind
        let prefillTokens: Int
        let prefillSeconds: Double
        let decodedTokens: Int
        let decodeSeconds: Double
        /// Peak memory the runtime reported for this case, if it can tell.
        let peakBytes: UInt64?
        /// `ProcessInfo.ThermalState.rawValue` when the case ended (0 nominal … 3 critical).
        let thermalState: Int
        let output: String
        /// Filled by `score`.
        var outcome: Outcome? = nil
    }

    enum Outcome: String, Codable, Sendable {
        /// What a good answer does: a valid call to the expected tool, or a
        /// plain answer when no tool is needed.
        case asExpected
        /// A valid call, but to another tool.
        case otherCall
        /// A plain answer where a call was expected.
        case answer
        /// The strict parser rejects it: on the phone this costs a correction step.
        case rejected
    }

    struct Report: Codable, Equatable, Sendable {
        let runtime: String
        let model: String
        let device: String
        let runs: [Run]

        var prefillTokensPerSecond: Double? { Self.median(runs.filter { $0.kind == .speed }.compactMap {
            $0.prefillSeconds > 0 && $0.prefillTokens > 0 ? Double($0.prefillTokens) / $0.prefillSeconds : nil }) }
        var decodeTokensPerSecond: Double? { Self.median(runs.filter { $0.kind == .speed }.compactMap {
            $0.decodeSeconds > 0 && $0.decodedTokens > 1 ? Double($0.decodedTokens) / $0.decodeSeconds : nil }) }
        var peakBytes: UInt64? { runs.compactMap(\.peakBytes).max() }
        var hottest: Int { runs.map(\.thermalState).max() ?? 0 }
        var toolRuns: [Run] { runs.filter { $0.kind == .tool } }
        var asExpecteds: Int { toolRuns.filter { $0.outcome == .asExpected }.count }
        var rejectedCalls: Int { toolRuns.filter { $0.outcome == .rejected }.count }

        static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
    }

    /// The runtime counts as clearly faster only when it is at least this much
    /// quicker at both reading and writing.
    static let clearlyFaster = 1.30

    // MARK: Running

    /// What a runtime reports for one case.
    struct Sample: Sendable {
        let prefillTokens: Int
        let prefillSeconds: Double
        let decodedTokens: Int
        let decodeSeconds: Double
        let peakBytes: UInt64?
        let output: String
    }

    /// Runs every case on one runtime, in order, and scores the result. The
    /// same loop drives llama.cpp and MLX on the phone and the MLX probe on a
    /// Mac. `grammar` false runs tool cases unconstrained on every runtime, so
    /// a runtime without the lazy tool-call grammar is compared fairly. On the
    /// main actor, so a screen can show progress; the runtimes are actors.
    @MainActor
    static func run(runtime: String, model: String, device: String, family: ModelFamily, grammar: Bool,
                    only: Set<String>? = nil, thermalState: () -> Int = { 0 },
                    progress: (Case, Int, Int) -> Void = { _, _, _ in },
                    generate: (Case) async throws -> Sample) async throws -> Report {
        let all = cases(family: family).filter { only?.contains($0.id) ?? true }
        var runs: [Run] = []
        for (index, original) in all.enumerated() {
            try Task.checkCancellation()
            let item = grammar ? original : Case(id: original.id, kind: original.kind, prompt: original.prompt,
                                                 replyLimit: original.replyLimit, expectedTool: original.expectedTool, grammar: nil)
            progress(item, index, all.count)
            let sample = try await generate(item)
            runs.append(Run(caseID: item.id, kind: item.kind, prefillTokens: sample.prefillTokens, prefillSeconds: sample.prefillSeconds,
                            decodedTokens: sample.decodedTokens, decodeSeconds: sample.decodeSeconds, peakBytes: sample.peakBytes,
                            thermalState: thermalState(), output: sample.output))
        }
        let label = grammar ? runtime : runtime + " (no grammar)"
        return Report(runtime: label, model: model, device: device, runs: scored(runs, family: family))
    }

    // MARK: Cases

    /// A short untimed prompt run once per runtime before the cases, so model
    /// loading and first-use GPU kernel compilation are not measured.
    static func warmUpPrompt(family: ModelFamily) -> String {
        ModelPrompt.render(family: family, system: "You are Keel.", messages: [(role: "user", text: "Say hello.")])
    }

    static func cases(family: ModelFamily) -> [Case] {
        let chat = "You are Keel, a helpful AI assistant running locally on this iPhone. Explain clearly."
        func plain(_ id: String, _ user: String, limit: Int) -> Case {
            Case(id: id, kind: .speed,
                 prompt: ModelPrompt.render(family: family, system: chat, messages: [(role: "user", text: user)]),
                 replyLimit: limit, expectedTool: nil, grammar: nil)
        }
        let system = AgentPrompt.local()
        let grammar = ToolCallGrammar.make(prompt: system, family: family)
        func tool(_ id: String, _ user: String, expect: String?) -> Case {
            Case(id: id, kind: .tool,
                 prompt: ModelPrompt.render(family: family, system: system, messages: [(role: "user", text: user)]),
                 replyLimit: 384, expectedTool: expect, grammar: grammar)
        }
        return [
            plain("short-answer", "Why is the sky blue? Answer in one paragraph.", limit: 256),
            plain("long-read", "Summarise this report in three bullet points.\n\n" + longDocument, limit: 160),
            plain("long-write", "Write a 300-word story about a lighthouse keeper who finds a message in a bottle.", limit: 512),
            tool("files", "What files do I have in this chat?", expect: "list_files"),
            tool("calculate", "Work out exactly 48,213 × 7,919 and tell me the result.", expect: "run_js"),
            tool("save-note", "Save a note called shopping.md with milk, eggs and bread on separate lines.", expect: "create_file"),
            tool("table", "Make a table called expenses with columns item and price, and add coffee 3.50.", expect: "run_sql"),
            tool("web-page", "Make me a one-page website for a bakery called Sunrise, with a menu section.", expect: "create_file"),
            tool("no-tool", "What is the capital of Finland?", expect: nil),
        ]
    }

    /// About 1,500 tokens of plain prose, the size of a file a tool returns.
    static let longDocument: String = {
        let paragraphs = [
            "The harbour authority recorded 412 ship arrivals in the third quarter, up from 371 a year earlier. Container traffic grew fastest, while passenger ferries were flat because one route was suspended for repairs during August.",
            "Maintenance spending rose by eleven percent. Most of it went to dredging the eastern channel, which had silted up after the spring storms, and to replacing two of the oldest cranes on the north quay.",
            "Staff turnover fell for the second quarter in a row. The new shift pattern, introduced in April, was cited in exit interviews less often than the old one, and overtime hours dropped by a fifth.",
            "Energy use per handled container fell by six percent after the shore-power connections at berths three and four came into service. Ships at those berths now switch off their auxiliary engines.",
            "The main risk for the next quarter is the planned closure of the rail link for track renewal. Freight will move by road for three weeks, and the authority has asked hauliers to book slots in advance.",
        ]
        return (0..<4).map { round in paragraphs.map { "Section \(round + 1). " + $0 }.joined(separator: "\n\n") }
            .joined(separator: "\n\n")
    }()

    // MARK: Scoring

    /// Reads the output the way the phone does: native format first, then the strict parser.
    static func score(_ run: Run, family: ModelFamily, expectedTool: String?) -> Outcome {
        var output = run.output
        do { output = try NativeToolCall.normalize(output, family: family) } catch { return .rejected }
        let normalized = ToolCallText.normalize(output)
        if normalized.repaired { output = normalized.text }
        let call: DirectorCall?
        do { call = try DirectorCall.parse(output) } catch { return .rejected }
        guard let call else { return expectedTool == nil ? .asExpected : .answer }
        return call.name == expectedTool ? .asExpected : .otherCall
    }

    static func scored(_ runs: [Run], family: ModelFamily) -> [Run] {
        let expected = Dictionary(uniqueKeysWithValues: cases(family: family).map { ($0.id, $0.expectedTool) })
        return runs.map { run in
            var run = run
            run.outcome = score(run, family: family, expectedTool: expected[run.caseID] ?? nil)
            return run
        }
    }

    // MARK: Report

    static func summary(_ report: Report) -> String {
        func rate(_ value: Double?) -> String { value.map { String(format: "%.1f tok/s", $0) } ?? "n/a" }
        let memory = report.peakBytes.map { String(format: "%.2f GB", Double($0) / 1_000_000_000) } ?? "n/a"
        let thermal = ["nominal", "fair", "serious", "critical"][min(max(report.hottest, 0), 3)]
        return """
        \(report.runtime) · \(report.model) · \(report.device)
        Reading: \(rate(report.prefillTokensPerSecond)) · Writing: \(rate(report.decodeTokensPerSecond)) · Peak memory: \(memory) · Hottest: \(thermal)
        Tool calls: \(report.asExpecteds)/\(report.toolRuns.count) as expected, \(report.rejectedCalls) rejected
        """
    }

    /// Plain-words comparison of a candidate runtime against the current one.
    static func verdict(current: Report, candidate: Report) -> String {
        guard let currentRead = current.prefillTokensPerSecond, let currentWrite = current.decodeTokensPerSecond,
              let read = candidate.prefillTokensPerSecond, let write = candidate.decodeTokensPerSecond else {
            return "Not enough speed results to compare."
        }
        let readRatio = read / currentRead, writeRatio = write / currentWrite
        let directions = "\(candidate.runtime) reads at \(String(format: "%.2f", readRatio))× and writes at \(String(format: "%.2f", writeRatio))× the speed of \(current.runtime)."
        let fasterEnough = readRatio >= clearlyFaster && writeRatio >= clearlyFaster
        let toolsHold = candidate.rejectedCalls <= current.rejectedCalls && candidate.asExpecteds >= current.asExpecteds
        let decision: String
        switch (fasterEnough, toolsHold) {
        case (true, true): decision = "Worth adding: clearly faster and tool calls hold up."
        case (true, false): decision = "Faster, but tool calls are worse. Fix that before adding it."
        case (false, _): decision = "Not worth a second runtime: not clearly faster (needs \(Int((clearlyFaster - 1) * 100))% or more at both)."
        }
        return directions + " " + decision
    }

    static func json(_ reports: [Report]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(reports)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
