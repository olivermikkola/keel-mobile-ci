import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class RuntimeBenchmarkTests: XCTestCase {
    private func run(_ id: String, kind: RuntimeBenchmark.Kind = .speed, prefill: Int = 100, prefillSeconds: Double = 1,
                     decoded: Int = 50, decodeSeconds: Double = 1, peak: UInt64? = nil, thermal: Int = 0,
                     output: String = "An answer.") -> RuntimeBenchmark.Run {
        RuntimeBenchmark.Run(caseID: id, kind: kind, prefillTokens: prefill, prefillSeconds: prefillSeconds,
                             decodedTokens: decoded, decodeSeconds: decodeSeconds, peakBytes: peak,
                             thermalState: thermal, output: output)
    }

    func testCasesShareOnePromptPerFamilyAndToolCasesCarryTheGrammar() throws {
        for family in [ModelFamily.bonsai, .lfm3, .miniCPM5] {
            let cases = RuntimeBenchmark.cases(family: family)
            XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "ids are unique")
            XCTAssertEqual(cases, RuntimeBenchmark.cases(family: family), "the same prompts every time")
            for item in cases where item.kind == .tool {
                XCTAssertNotNil(item.grammar, item.id)
                if let expected = item.expectedTool { XCTAssertTrue(item.prompt.contains("\"name\":\"\(expected)\""), item.id) }
            }
            XCTAssertTrue(cases.filter { $0.kind == .speed }.allSatisfy { $0.grammar == nil })
        }
        // The long case is long enough to measure reading speed, short enough for a 4K context.
        let long = RuntimeBenchmark.longDocument.utf8.count
        XCTAssertGreaterThan(long, 4_000)
        XCTAssertLessThan(long, 12_000)
    }

    func testOutputIsScoredTheWayThePhoneReadsIt() {
        let call = "<tool_call>\n<function=list_files>\n<parameter=path>.</parameter>\n</function>\n</tool_call>"
        XCTAssertEqual(RuntimeBenchmark.score(run("files", kind: .tool, output: call), family: .lfm3, expectedTool: "list_files"), .asExpected)
        XCTAssertEqual(RuntimeBenchmark.score(run("files", kind: .tool, output: call), family: .lfm3, expectedTool: "run_js"), .otherCall)
        XCTAssertEqual(RuntimeBenchmark.score(run("no-tool", kind: .tool, output: "Helsinki."), family: .lfm3, expectedTool: nil), .asExpected)
        XCTAssertEqual(RuntimeBenchmark.score(run("files", kind: .tool, output: "You have no files."), family: .lfm3, expectedTool: "list_files"), .answer)
        XCTAssertEqual(RuntimeBenchmark.score(run("files", kind: .tool, output: "<tool_call><function=list_files>"),
                                              family: .lfm3, expectedTool: "list_files"), .rejected)
        // MiniCPM5 writes its own format; the phone converts it first.
        let native = "<function name=\"list_files\"><param name=\"path\">.</param></function>"
        XCTAssertEqual(RuntimeBenchmark.score(run("files", kind: .tool, output: native), family: .miniCPM5, expectedTool: "list_files"), .asExpected)

        // The "files" case expects shell (ls) since shell replaced list_files in Work chats.
        let shellCall = "<tool_call>\n<function=shell>\n<parameter=command>ls</parameter>\n</function>\n</tool_call>"
        let scored = RuntimeBenchmark.scored([run("files", kind: .tool, output: shellCall), run("no-tool", kind: .tool, output: "Helsinki.")], family: .lfm3)
        XCTAssertEqual(scored.map(\.outcome), [.asExpected, .asExpected])
    }

    func testReportUsesMediansOfSpeedCasesOnly() {
        let report = RuntimeBenchmark.Report(runtime: "llama.cpp", model: "LFM3 1.7B", device: "iPhone16,1", runs: [
            run("a", prefill: 100, prefillSeconds: 1, decoded: 40, decodeSeconds: 2, peak: 900),
            run("b", prefill: 300, prefillSeconds: 1, decoded: 60, decodeSeconds: 2, peak: 1_200, thermal: 2),
            run("c", prefill: 200, prefillSeconds: 1, decoded: 50, decodeSeconds: 2),
            run("t", kind: .tool, prefill: 9_000, prefillSeconds: 1, decoded: 9_000, decodeSeconds: 1),
        ])
        XCTAssertEqual(report.prefillTokensPerSecond, 200)
        XCTAssertEqual(report.decodeTokensPerSecond, 25)
        XCTAssertEqual(report.peakBytes, 1_200)
        XCTAssertEqual(report.hottest, 2)
        let summary = RuntimeBenchmark.summary(report)
        XCTAssertTrue(summary.contains("Reading: 200.0 tok/s"), summary)
        XCTAssertTrue(summary.contains("Hottest: serious"), summary)
        XCTAssertEqual(RuntimeBenchmark.Report.median([]), nil)
        XCTAssertEqual(RuntimeBenchmark.Report.median([1, 3]), 2)
    }

    func testVerdictNeedsClearSpeedAtBothAndToolCallsThatHold() {
        func report(_ name: String, read: Double, write: Double, tools: [String]) -> RuntimeBenchmark.Report {
            let calls = tools.map { output -> RuntimeBenchmark.Run in
                var tool = run("files", kind: .tool, output: output)
                tool.outcome = output.isEmpty ? .rejected : .asExpected
                return tool
            }
            return RuntimeBenchmark.Report(runtime: name, model: "m", device: "d", runs: [
                run("s", prefill: Int(read), prefillSeconds: 1, decoded: Int(write), decodeSeconds: 1)] + calls)
        }
        let current = report("llama.cpp", read: 100, write: 20, tools: ["ok", "ok"])
        XCTAssertTrue(RuntimeBenchmark.verdict(current: current, candidate: report("MLX", read: 140, write: 27, tools: ["ok", "ok"]))
            .contains("Worth adding"))
        XCTAssertTrue(RuntimeBenchmark.verdict(current: current, candidate: report("MLX", read: 200, write: 22, tools: ["ok", "ok"]))
            .contains("Not worth"), "reading alone is not enough")
        XCTAssertTrue(RuntimeBenchmark.verdict(current: current, candidate: report("MLX", read: 140, write: 27, tools: ["ok", ""]))
            .contains("tool calls are worse"))
        XCTAssertEqual(RuntimeBenchmark.verdict(current: current, candidate: report("MLX", read: 0, write: 0, tools: [])),
                       "Not enough speed results to compare.")
    }

    func testReportsRoundTripAsJSON() throws {
        var tool = run("files", kind: .tool, peak: 5)
        tool.outcome = .otherCall
        let reports = [RuntimeBenchmark.Report(runtime: "MLX", model: "m", device: "d", runs: [tool])]
        let decoded = try JSONDecoder().decode([RuntimeBenchmark.Report].self, from: Data(RuntimeBenchmark.json(reports).utf8))
        XCTAssertEqual(decoded, reports)
    }
}

/// The cases against a real llama.cpp server, as the phone sends them (same
/// prompts, lazy tool-call grammar, the family's sampler). Skipped unless
/// `KEEL_BENCH_SERVER` is set, e.g.
/// `KEEL_BENCH_SERVER=http://127.0.0.1:8197 KEEL_BENCH_FAMILY=lfm3 swift test --filter RuntimeBenchmarkLiveTests`.
/// Desktop CPU numbers are not phone numbers; this proves the cases and scoring.
final class RuntimeBenchmarkLiveTests: XCTestCase {
    func testCasesRunAndScoreAgainstARealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["KEEL_BENCH_SERVER"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set KEEL_BENCH_SERVER to a llama-server address to run")
        }
        let family = ModelFamily(rawValue: environment["KEEL_BENCH_FAMILY"] ?? "lfm3") ?? .lfm3
        let sampling = family.sampling
        var runs: [RuntimeBenchmark.Run] = []
        for item in RuntimeBenchmark.cases(family: family) {
            var body: [String: Any] = ["prompt": item.prompt, "n_predict": item.replyLimit, "top_k": sampling.topK,
                                       "top_p": sampling.topP, "temperature": sampling.temperature, "seed": 7,
                                       "cache_prompt": false]
            if let grammar = item.grammar {
                body["grammar"] = grammar.text
                body["grammar_lazy"] = true
                body["grammar_triggers"] = grammar.triggerPatterns.map { ["type": 2, "value": $0] }
            }
            var request = URLRequest(url: server.appendingPathComponent("completion"))
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let timings = reply["timings"] as? [String: Any] ?? [:]
            runs.append(RuntimeBenchmark.Run(
                caseID: item.id, kind: item.kind,
                prefillTokens: timings["prompt_n"] as? Int ?? 0, prefillSeconds: (timings["prompt_ms"] as? Double ?? 0) / 1000,
                decodedTokens: timings["predicted_n"] as? Int ?? 0, decodeSeconds: (timings["predicted_ms"] as? Double ?? 0) / 1000,
                peakBytes: nil, thermalState: 0, output: reply["content"] as? String ?? ""))
        }
        let report = RuntimeBenchmark.Report(runtime: "llama.cpp (desktop CPU)", model: family.rawValue, device: "Linux",
                                             runs: RuntimeBenchmark.scored(runs, family: family))
        print("LIVE " + RuntimeBenchmark.summary(report).replacingOccurrences(of: "\n", with: "\nLIVE "))
        for run in report.runs {
            print("LIVE \(run.caseID): \(run.outcome?.rawValue ?? "-") · \(run.prefillTokens) read, \(run.decodedTokens) written · "
                  + run.output.prefix(90).replacingOccurrences(of: "\n", with: " "))
        }
        XCTAssertEqual(report.runs.count, RuntimeBenchmark.cases(family: family).count)
        XCTAssertNotNil(report.prefillTokensPerSecond)
        XCTAssertEqual(report.rejectedCalls, 0, "the grammar keeps every call parseable")
    }
}

final class RuntimeBenchmarkRunTests: XCTestCase {
    @MainActor func testRunDrivesEveryCaseAndScoresIt() async throws {
        var seen: [(String, Bool)] = []
        let report = try await RuntimeBenchmark.run(runtime: "Fake", model: "lfm3", device: "test", family: .lfm3, grammar: false,
                                                    thermalState: { 1 }) { item in
            seen.append((item.id, item.grammar != nil))
            let call = item.expectedTool.map { "<tool_call>\n<function=\($0)>\n<parameter=path>\n.\n</parameter>\n</function>\n</tool_call>" }
            return .init(prefillTokens: 100, prefillSeconds: 0.5, decodedTokens: 20, decodeSeconds: 1, peakBytes: 7, output: call ?? "Helsinki.")
        }
        XCTAssertEqual(seen.map(\.0), RuntimeBenchmark.cases(family: .lfm3).map(\.id))
        XCTAssertFalse(seen.contains { $0.1 }, "No grammar on any case when grammar is off")
        XCTAssertEqual(report.runtime, "Fake (no grammar)")
        XCTAssertEqual(report.prefillTokensPerSecond, 200)
        XCTAssertEqual(report.decodeTokensPerSecond, 20)
        XCTAssertEqual(report.hottest, 1)
        XCTAssertEqual(report.peakBytes, 7)
        XCTAssertTrue(report.runs.allSatisfy { $0.outcome != nil })
        XCTAssertEqual(report.rejectedCalls, 0)
    }

    @MainActor func testOnlyAndGrammar() async throws {
        var grammars: [Bool] = []
        let report = try await RuntimeBenchmark.run(runtime: "Fake", model: "m", device: "d", family: .lfm3, grammar: true,
                                                    only: ["files", "short-answer"]) { item in
            grammars.append(item.grammar != nil)
            return .init(prefillTokens: 1, prefillSeconds: 1, decodedTokens: 2, decodeSeconds: 1, peakBytes: nil, output: "x")
        }
        XCTAssertEqual(report.runs.map(\.caseID), ["short-answer", "files"])
        XCTAssertEqual(grammars, [false, true], "Tool cases keep their grammar when grammar is on")
        XCTAssertEqual(report.runtime, "Fake")
    }
}

final class RuntimeBenchmarkWarmUpTests: XCTestCase {
    func testWarmUpPromptIsShortAndNotACase() {
        let warm = RuntimeBenchmark.warmUpPrompt(family: .lfm3)
        XCTAssertTrue(warm.contains("Say hello."))
        XCTAssertLessThan(warm.count, 300)
        XCTAssertFalse(RuntimeBenchmark.cases(family: .lfm3).contains { $0.prompt == warm })
    }
}
