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
}
