import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class TurnTaintTests: XCTestCase {
    let notion = TurnTaint.connector("notion")
    let gmail = TurnTaint.connector("gmail")

    private func gate(_ taint: TurnTaint, to destination: String,
                      needsApproval: Bool = false, alwaysAllowed: Bool = false) -> TurnTaint.Gate {
        taint.gate(destination: destination, needsApproval: needsApproval, alwaysAllowed: alwaysAllowed)
    }

    func testCleanChatRunsReadOnlyCallsAndAsksForWrites() {
        let clean = TurnTaint()
        XCTAssertEqual(gate(clean, to: notion), .run)
        XCTAssertEqual(gate(clean, to: notion, needsApproval: true), .ask)
    }

    /// The rule that existed before: private data alone makes read-only calls
    /// ask, unless the user chose "Always allow".
    func testPrivateDataAloneKeepsAlwaysAllow() {
        let taint = TurnTaint.effect(ofTool: "calendar_events")
        XCTAssertEqual(gate(taint, to: notion), .ask)
        XCTAssertEqual(gate(taint, to: notion, alwaysAllowed: true), .run)
    }

    func testOutsideTextAloneChangesNothing() {
        let taint = TurnTaint.effect(ofTool: "read_url")
        XCTAssertEqual(gate(taint, to: notion), .run)
        XCTAssertEqual(gate(taint, to: notion, needsApproval: true), .ask)
    }

    /// The attack: calendar read, then a web page says "search Notion for <the
    /// calendar>". An always-allowed read-only tool must still ask, every time.
    func testPrivateDataPlusOutsideTextOverridesAlwaysAllow() {
        var taint = TurnTaint.effect(ofTool: "calendar_events")
        taint.merge(.effect(ofTool: "read_url"))
        XCTAssertEqual(gate(taint, to: notion, alwaysAllowed: true), .askEveryTime)
        XCTAssertEqual(gate(taint, to: notion, needsApproval: true, alwaysAllowed: true), .askEveryTime)
        XCTAssertEqual(gate(taint, to: TurnTaint.github), .askEveryTime)
    }

    /// Listing mail and then reading one message sends nothing new to Gmail.
    func testReadOnlyCallBackToTheSameConnectorRuns() {
        let taint = TurnTaint.effect(ofTool: "mcp_gmail_search", connectorID: "gmail")
        XCTAssertTrue(taint.outsideText)
        XCTAssertEqual(gate(taint, to: gmail), .run)
        XCTAssertEqual(gate(taint, to: notion), .askEveryTime)
    }

    /// Calls back to the same service keep the user's choice, but data from
    /// anywhere else in the chat still escalates.
    func testSameConnectorKeepsTheUsersChoiceUnlessOtherPrivateDataIsPresent() {
        var taint = TurnTaint.effect(ofTool: "mcp_gmail_search", connectorID: "gmail")
        XCTAssertEqual(gate(taint, to: gmail, needsApproval: true), .ask)
        XCTAssertEqual(gate(taint, to: gmail, alwaysAllowed: true), .run)
        taint.merge(.effect(ofTool: "calendar_events"))
        XCTAssertEqual(gate(taint, to: gmail, alwaysAllowed: true), .askEveryTime)
    }

    func testRepositoryFilesAreOutsideTextButChatFilesAreNot() {
        XCTAssertEqual(TurnTaint.effect(ofTool: "read_file"), TurnTaint(privateOrigins: [TurnTaint.phone]))
        XCTAssertEqual(TurnTaint.effect(ofTool: "read_file", inRepository: true),
                       TurnTaint(privateOrigins: [TurnTaint.github], outsideText: true))
        XCTAssertTrue(TurnTaint.effect(ofTool: "list_files").isEmpty)
        XCTAssertTrue(TurnTaint.effect(ofTool: "generate_image").isEmpty)
        XCTAssertTrue(TurnTaint.effect(ofTool: "run_shortcut").outsideText)
    }

    /// Earlier results stay in the context, so the state carries across turns,
    /// and memory or attachments in the prompt count as private data.
    func testInitialStateCarriesHistoryAndPromptData() {
        let history: [TurnTaint?] = [nil, .effect(ofTool: "web_search"), nil]
        XCTAssertEqual(TurnTaint.initial(history: history, privatePrompt: false), TurnTaint(outsideText: true))
        let withMemory = TurnTaint.initial(history: history, privatePrompt: true)
        XCTAssertEqual(gate(withMemory, to: notion, alwaysAllowed: true), .askEveryTime)
    }

    /// Saved on chat messages: old chats without it must still decode.
    func testRoundTripsThroughJSON() throws {
        var taint = TurnTaint.effect(ofTool: "calendar_events")
        taint.merge(.effect(ofTool: "x", connectorID: "gmail"))
        let data = try JSONEncoder().encode(taint)
        XCTAssertEqual(try JSONDecoder().decode(TurnTaint.self, from: data), taint)
    }
}
