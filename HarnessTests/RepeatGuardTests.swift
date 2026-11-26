import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class RepeatGuardTests: XCTestCase {
    func testCanonicalIgnoresKeyOrder() {
        XCTAssertEqual(RepeatGuard.canonical(["b": "1", "a": "2"]), RepeatGuard.canonical(["a": "2", "b": "1"]))
    }

    // Mirrors desktop `escalates_gentle_then_detailed_and_resets` (guard.rs).
    func testEscalatesGentleThenDetailedAndResets() {
        let guardian = RepeatGuard(thresholds: [2, 4])
        let args = ["path": "foo.py"]
        XCTAssertNil(guardian.observe(name: "read_file", arguments: args))
        let gentle = guardian.observe(name: "read_file", arguments: args)
        XCTAssertTrue(gentle?.contains("You are repeating the exact same tool call") == true)
        XCTAssertNil(guardian.observe(name: "read_file", arguments: args))
        let detailed = guardian.observe(name: "read_file", arguments: args)
        XCTAssertTrue(detailed?.contains("consecutive_calls: 4") == true)
        XCTAssertTrue(detailed?.contains(#"{"path":"foo.py"}"#) == true)
        guardian.reset()
        XCTAssertNil(guardian.observe(name: "read_file", arguments: args))
    }

    func testDesktopThresholdsAreTwoFourSeven() {
        let guardian = RepeatGuard()
        let hits = (1...8).compactMap { n in guardian.observe(name: "list_files", arguments: ["path": ""]) == nil ? nil : n }
        XCTAssertEqual(hits, [2, 4, 7])
    }

    func testDifferentArgumentsBreakTheChain() {
        let guardian = RepeatGuard(thresholds: [2])
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "a"]))
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "b"]))
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "a"]))
        XCTAssertNotNil(guardian.observe(name: "read_file", arguments: ["path": "a"]))
    }

    func testLongArgumentsArePreviewed() {
        let guardian = RepeatGuard(thresholds: [1, 2])
        let long = ["query": String(repeating: "é", count: 900)]
        _ = guardian.observe(name: "search_file", arguments: long)
        let detailed = guardian.observe(name: "search_file", arguments: long)!
        XCTAssertTrue(detailed.contains("more chars)"))
        XCTAssertLessThan(detailed.unicodeScalars.count, 1000)
    }

    func testOverlappingReadRangesRemindModelAndClearOnEditOrReset() {
        let guardian = RepeatGuard()
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift", "start_line": "1", "count": "30"]))
        // Non-overlapping follow-up slice should pass quietly.
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift", "start_line": "31", "count": "30"]))
        // Overlapping range via either start_line or offset triggers reminder.
        let overlap = guardian.observe(name: "read_file", arguments: ["path": "App.swift", "offset": "15", "count": "20"])
        XCTAssertTrue(overlap?.contains("already read lines 1–30 of App.swift") == true)
        XCTAssertTrue(overlap?.contains("overlaps requested 16–35") == true)

        // Modifying the file clears cached read ranges for that path.
        XCTAssertNil(guardian.observe(name: "propose_edit", arguments: ["path": "App.swift", "old_text": "a", "new_text": "b"]))
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift", "start_line": "10", "count": "15"]))

        // Reset clears all tracked ranges.
        guardian.reset()
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift", "start_line": "1", "count": "20"]))
    }

    /// A read without a count returns as many lines as fit, so only its first line is known.
    func testReadWithoutCountOnlyClaimsItsFirstLine() {
        let guardian = RepeatGuard()
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift"]))
        XCTAssertNil(guardian.observe(name: "read_file", arguments: ["path": "App.swift", "start_line": "150"]))
    }

    func testHardStopTriggersOnRepeatedFailedCallEvenAcrossInterspersedSuccesses() {
        let guardLoop = RepeatGuard()
        let breaker = CircuitBreaker()
        let editArgs = ["path": "attachments/Photo.jpg", "old_text": "a dog and a cat", "new_text": "two cats"]
        let listArgs = ["path": "."]

        _ = guardLoop.observe(name: "propose_edit", arguments: editArgs)
        _ = breaker.recordFailure(.other("EditPlanError"))
        XCTAssertNil(guardLoop.evaluateStop(name: "propose_edit", arguments: editArgs, succeeded: false, breaker: breaker))

        // Interspersed list_files succeeds and resets consecutive breaker count,
        // yet repeating the exact same failed propose_edit still hard-stops on attempt 2.
        _ = guardLoop.observe(name: "list_files", arguments: listArgs)
        breaker.recordSuccess()
        XCTAssertNil(guardLoop.evaluateStop(name: "list_files", arguments: listArgs, succeeded: true, breaker: breaker))

        _ = guardLoop.observe(name: "propose_edit", arguments: editArgs)
        _ = breaker.recordFailure(.other("EditPlanError"))
        let stop = guardLoop.evaluateStop(name: "propose_edit", arguments: editArgs, succeeded: false, breaker: breaker)
        XCTAssertEqual(stop, .repeatedFailedCall(tool: "propose_edit", attempts: 2))
    }

    func testHardStopCoversConsecutiveFailuresTotalFailuresIdenticalRepeatsAndMalformedCalls() {
        // 3 consecutive different failures -> consecutiveFailures
        let g1 = RepeatGuard()
        let b1 = CircuitBreaker(tripThreshold: 3)
        for i in 1...3 {
            let args = ["path": "missing-\(i).txt"]
            _ = g1.observe(name: "read_file", arguments: args)
            _ = b1.recordFailure(.notFound)
            let stop = g1.evaluateStop(name: "read_file", arguments: args, succeeded: false, breaker: b1)
            if i < 3 { XCTAssertNil(stop) } else { XCTAssertEqual(stop, .consecutiveFailures(count: 3)) }
        }

        // 3 identical succeeding calls in a row -> repeatedIdenticalCall
        let g2 = RepeatGuard()
        let b2 = CircuitBreaker()
        for i in 1...3 {
            _ = g2.observe(name: "list_files", arguments: ["path": "."])
            b2.recordSuccess()
            let stop = g2.evaluateStop(name: "list_files", arguments: ["path": "."], succeeded: true, breaker: b2)
            if i < 3 { XCTAssertNil(stop) } else { XCTAssertEqual(stop, .repeatedIdenticalCall(tool: "list_files", attempts: 3)) }
        }

        // 3 consecutive malformed tool calls -> repeatedMalformedCalls
        let g3 = RepeatGuard()
        XCTAssertNil(g3.recordMalformedCall())
        XCTAssertNil(g3.recordMalformedCall())
        XCTAssertEqual(g3.recordMalformedCall(), .repeatedMalformedCalls(count: 3))
    }

    func testStripInternalNotesRemovesHarnessSteeringAnnotations() {
        let raw = """
        Tool error: Photo.jpg is an image or binary file and cannot be edited as text.

        [repeat-tool-reminder] Repeated tool call detected:
        - tool: propose_edit

        [circuit-breaker] 4 tool calls in a row failed.
        """
        XCTAssertEqual(
            RepeatGuard.stripInternalNotes(raw),
            "Tool error: Photo.jpg is an image or binary file and cannot be edited as text."
        )
    }
}
