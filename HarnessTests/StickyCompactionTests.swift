import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

/// The app rebuilds the prompt from the whole chat before every model step.
/// These tests grow a chat the way a repository task does and count the steps
/// whose prompt does not start with the previous step's prompt: each of those
/// makes the phone re-read the prompt from the first changed message.
final class StickyCompactionTests: XCTestCase {
    private let reserved = 1_536 + 512

    private struct Run { var rereads = 0; var steps = 0; var worstTokens = 0; var shortestKept = Int.max }

    private func grow(steps: Int, prompt: (_ history: [HarnessMessage]) -> [HarnessMessage]) -> Run {
        var history = [HarnessMessage(.user, "Can you look for discrepancies in this repository?")]
        var previous: [HarnessMessage]?
        var run = Run()
        let budget = ContextBudget(maxContextTokens: 8_192)
        for step in 0..<steps {
            let sent = prompt(history)
            run.steps += 1
            run.worstTokens = max(run.worstTokens, budget.estimate(sent) + reserved)
            if let previous {
                var kept = 0
                while kept < previous.count, kept < sent.count, previous[kept] == sent[kept] { kept += 1 }
                if kept < previous.count { run.rereads += 1; run.shortestKept = min(run.shortestKept, kept) }
            }
            history.append(.init(.assistant, "<tool_call>\n<function=read_file>\n<parameter=path>file\(step).swift</parameter>\n</function>\n</tool_call>"))
            history.append(.init(.tool, "file\(step).swift lines 1-40\n" + String(repeating: "let value = compute(x) // line\n", count: 40)))
            previous = sent + history.suffix(2)
        }
        return run
    }

    func testCompactingTheWholeChatEveryStepRereadsEveryStepOnceOverBudget() {
        // What the app did before: compact the full history from scratch each step.
        let budget = ContextBudget(maxContextTokens: 8_192)
        let run = grow(steps: 30) { history in
            var copy = history
            budget.compact(&copy, reservedTokens: self.reserved)
            return copy
        }
        print("COMPACTION from scratch: \(run.rereads) of \(run.steps) steps re-read, worst kept \(run.shortestKept) message(s)")
        XCTAssertGreaterThanOrEqual(run.rereads, 15, "every step after the first fold changes the prompt")
        XCTAssertEqual(run.shortestKept, 1, "only the first message survives")
    }

    func testStickyCompactionAppendsAndFoldsRarely() {
        var sticky = StickyCompaction(maxContextTokens: 8_192)
        let run = grow(steps: 30) { sticky.prompt($0, reservedTokens: self.reserved) }
        print("COMPACTION sticky: \(run.rereads) of \(run.steps) steps re-read, worst \(run.worstTokens) of \(sticky.budget.compactionThresholdTokens) tokens")
        XCTAssertLessThanOrEqual(run.rereads, 4, "a fold now and then, appends in between")
        XCTAssertLessThanOrEqual(run.worstTokens, sticky.budget.compactionThresholdTokens, "still within budget")
    }

    func testAnotherHistoryStartsOver() {
        var sticky = StickyCompaction(maxContextTokens: 8_192)
        let first = [HarnessMessage(.user, "Task A")] + (0..<40).map { HarnessMessage(.tool, "result \($0) " + String(repeating: "a", count: 800)) }
        _ = sticky.prompt(first, reservedTokens: reserved)
        let other = [HarnessMessage(.user, "Task B"), HarnessMessage(.tool, "short")]
        XCTAssertEqual(sticky.prompt(other, reservedTokens: reserved), other)
    }
}
