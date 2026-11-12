import XCTest
@testable import KeelHarness

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
}
