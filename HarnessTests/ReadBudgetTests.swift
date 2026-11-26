import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ReadBudgetTests: XCTestCase {
    private func workspace(_ files: [String: String]) throws -> TaskWorkspace {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(.init(repository: "owner/fixture", commit: ArchiveFixture.commit, tree: ArchiveFixture.tree),
                              entries: ArchiveFixture.entries.map { .init(path: $0.path, mode: $0.mode, type: $0.type, sha: $0.sha, size: $0.size) })
        _ = try workspace.importArchive(ArchiveFixture.dynamic)
        for (path, text) in files { try workspace.applyOverlay(.write(path: path, text: text)) }
        return workspace
    }

    private func read(_ workspace: TaskWorkspace, _ arguments: String, contextSize: UInt32) throws -> [String: Any] {
        let call = try XCTUnwrap(try RepositoryCall.parse("<tool_call>\n<function=read_file>\n\(arguments)\n</function>\n</tool_call>"))
        let tools = WorkspaceTools(workspace: workspace, readBytes: ReadBudget.bytes(contextSize: contextSize))
        // Run outside XCTUnwrap, which records a failure when its argument throws.
        let text = try tools.execute(call).text
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// 300 lines of ordinary code, about 13 KB.
    private let code = (1...300).map { "    let value\($0) = compute(\"item-\($0)\", scale: \($0 % 7))" }.joined(separator: "\n")

    func testBudgetGrowsWithContextAndStopsAtTwelveKilobytes() {
        XCTAssertEqual(ReadBudget.bytes(contextSize: 4_096), 6_000)
        XCTAssertEqual(ReadBudget.bytes(contextSize: 8_192), 6_144)
        XCTAssertEqual(ReadBudget.bytes(contextSize: 16_384), 12_000)
        XCTAssertEqual(ReadBudget.bytes(contextSize: 32_768), 12_000)
    }

    func testAReadWithoutACountReturnsAsMuchAsFitsAndSaysWhereToContinue() throws {
        let files = try workspace(["src/big.swift": code])
        let small = try read(files, "<parameter=path>src/big.swift</parameter>", contextSize: 8_192)
        let large = try read(files, "<parameter=path>src/big.swift</parameter>", contextSize: 32_768)
        let smallEnd = try XCTUnwrap(small["end_line"] as? Int), largeEnd = try XCTUnwrap(large["end_line"] as? Int)
        // The old default was 30 lines.
        XCTAssertGreaterThan(smallEnd, 100)
        XCTAssertGreaterThan(largeEnd, smallEnd)
        XCTAssertEqual(small["next_start_line"] as? Int, smallEnd + 1)
        XCTAssertEqual(small["total_lines"] as? Int, 300)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: small).count, 6_144 + 64)

        // Continuing picks up exactly where the cut was, with no gap or overlap.
        let next = try read(files, "<parameter=path>src/big.swift</parameter>\n<parameter=start_line>\(smallEnd + 1)</parameter>", contextSize: 8_192)
        XCTAssertEqual(next["start_line"] as? Int, smallEnd + 1)
        let first = try XCTUnwrap(small["content"] as? String), second = try XCTUnwrap(next["content"] as? String)
        XCTAssertTrue(code.hasPrefix(first + "\n" + second))
    }

    func testAShortFileIsReadWholeInOneCall() throws {
        let files = try workspace(["notes.txt": (1...120).map { "line \($0)" }.joined(separator: "\n")])
        let whole = try read(files, "<parameter=path>notes.txt</parameter>", contextSize: 8_192)
        XCTAssertEqual(whole["end_line"] as? Int, 120)
        XCTAssertNil(whole["next_start_line"])
    }

    func testAnExplicitCountIsStillHonouredAndBounded() throws {
        let files = try workspace(["src/big.swift": code])
        let ten = try read(files, "<parameter=path>src/big.swift</parameter>\n<parameter=start_line>5</parameter>\n<parameter=count>10</parameter>", contextSize: 32_768)
        XCTAssertEqual(ten["start_line"] as? Int, 5)
        XCTAssertEqual(ten["end_line"] as? Int, 14)
        XCTAssertThrowsError(try RepositoryCall.parse("<tool_call>\n<function=read_file>\n<parameter=path>a</parameter>\n<parameter=count>401</parameter>\n</function>\n</tool_call>"))
    }

    func testOneLineTooLongForTheBudgetIsStillAnError() throws {
        let files = try workspace(["min.js": String(repeating: "a", count: 20_000)])
        XCTAssertThrowsError(try read(files, "<parameter=path>min.js</parameter>", contextSize: 32_768))
    }

    func testEndFindsTheLongestFittingWindow() {
        // Each line "costs" its number; the budget is 100.
        func fits(_ end: Int) -> Bool { (0..<end).reduce(0, +) <= 100 }
        XCTAssertEqual(ReadBudget.end(offset: 0, count: 400, total: 50, fits: fits), 14) // 0+…+13 = 91, +14 = 105
        XCTAssertEqual(ReadBudget.end(offset: 0, count: 5, total: 50, fits: fits), 5)
        XCTAssertEqual(ReadBudget.end(offset: 0, count: 400, total: 3, fits: fits), 3)
        XCTAssertNil(ReadBudget.end(offset: 3, count: 10, total: 3, fits: fits))
    }
}
