import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

/// Simulates a growing task and counts the turns whose prompt no longer starts with
/// the previous turn's prompt. Those are the turns llama.cpp must re-evaluate from
/// the first changed message. Appends alone never change the prefix.
final class PrefixStableCompactionTests: XCTestCase {
    let reserved = 600

    struct Run {
        var turns = 0
        var changedTurns = 0
        var folds = 0
        var worstTokens = 0
    }

    func simulate(_ budget: ContextBudget, steps: Int, resultChars: Int) -> Run {
        var messages = [HarnessMessage(.user, "Fix the failing test in Sources/App.swift")]
        var run = Run()
        var previous: [HarnessMessage]?
        for step in 0..<steps {
            // Before each model turn, compact as the app would, then check the prompt.
            if let report = budget.compact(&messages, reservedTokens: reserved), report.summarizedMessages > 0 {
                run.folds += 1
            }
            run.turns += 1
            if let previous, !messages.starts(with: previous) { run.changedTurns += 1 }
            run.worstTokens = max(run.worstTokens, budget.estimate(messages) + reserved)
            // The reply and the tool result join the history for the next turn.
            messages.append(.init(.assistant, "<tool_call>\n<function=read_file>\n<parameter=path>file\(step).swift</parameter>\n</function>\n</tool_call>"))
            messages.append(.init(.tool, "file\(step).swift lines 1-200\n" + String(repeating: "x", count: resultChars)))
            previous = messages
        }
        return run
    }

    func testBudgetIsRespectedInBothModes() {
        for resultChars in [600, 1_500] {
            for style in [ContextBudget.CompactionStyle.eager, .stablePrefix] {
                let budget = ContextBudget(maxContextTokens: 4_096, style: style)
                let run = simulate(budget, steps: 60, resultChars: resultChars)
                XCTAssertLessThanOrEqual(run.worstTokens, budget.compactionThresholdTokens,
                                         "\(style), \(resultChars)-char results: prompt stayed over the threshold")
            }
        }
    }

    /// Measured: 600-char results, 60 turns: eager 11 changed turns, stablePrefix 6.
    func testStablePrefixChangesFewerTurnsWithSmallResults() {
        let eager = simulate(ContextBudget(maxContextTokens: 4_096, style: .eager), steps: 60, resultChars: 600)
        let stable = simulate(ContextBudget(maxContextTokens: 4_096, style: .stablePrefix), steps: 60, resultChars: 600)
        print("PREFIX 600-char eager: turns=\(eager.turns) changedTurns=\(eager.changedTurns) folds=\(eager.folds) worstTokens=\(eager.worstTokens)")
        print("PREFIX 600-char stablePrefix: turns=\(stable.turns) changedTurns=\(stable.changedTurns) folds=\(stable.folds) worstTokens=\(stable.worstTokens)")
        XCTAssertLessThan(stable.changedTurns, eager.changedTurns)
    }

    /// Measured: 1500-char results, 60 turns: eager 18 changed turns, stablePrefix 18.
    /// With large results the three protected steps fill most of the window, so
    /// the fold cannot move far enough to change the rate. Only "no worse" is asserted.
    func testStablePrefixIsNoWorseWithLargeResults() {
        let eager = simulate(ContextBudget(maxContextTokens: 4_096, style: .eager), steps: 60, resultChars: 1_500)
        let stable = simulate(ContextBudget(maxContextTokens: 4_096, style: .stablePrefix), steps: 60, resultChars: 1_500)
        print("PREFIX 1500-char eager: turns=\(eager.turns) changedTurns=\(eager.changedTurns) folds=\(eager.folds) worstTokens=\(eager.worstTokens)")
        print("PREFIX 1500-char stablePrefix: turns=\(stable.turns) changedTurns=\(stable.changedTurns) folds=\(stable.folds) worstTokens=\(stable.worstTokens)")
        XCTAssertLessThanOrEqual(stable.changedTurns, eager.changedTurns)
    }

    func testDefaultBudgetIsStillEager() {
        XCTAssertEqual(ContextBudget(maxContextTokens: 4_096).style, .eager)
        XCTAssertEqual(ContextBudget(maxContextTokens: 4_096, style: .stablePrefix).lowWaterTokens, 1_228)
    }
}
