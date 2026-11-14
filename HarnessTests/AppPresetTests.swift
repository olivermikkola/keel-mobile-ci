import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class AppPresetTests: XCTestCase {
    private func tools(_ prompt: String) -> Set<String> {
        Set(prompt.components(separatedBy: "\n").filter { $0.hasPrefix(#"{"type":"function""#) }.map(AgentPrompt.toolName))
    }

    func testEachAppAddsItsInstructionsAndOnlyItsTools() {
        let plain = AgentPrompt.local()
        XCTAssertEqual(tools(plain).count, 9)
        for app in AppPreset.allCases {
            let prompt = AgentPrompt.local(app: app)
            XCTAssertTrue(prompt.contains(app.instructions), app.title)
            XCTAssertEqual(tools(prompt), app.tools, app.title)
            XCTAssertFalse(plain.contains(app.instructions))
            // The guidance never names a tool the app does not have.
            for missing in tools(plain).subtracting(app.tools) {
                XCTAssertFalse(prompt.contains(missing), "\(app.title) mentions \(missing)")
            }
        }
        XCTAssertEqual(tools(AgentPrompt.local(app: .sheets)), tools(plain))
        XCTAssertLessThan(AgentPrompt.local(app: .docs).count, plain.count - 800)
    }

    func testAppInstructionsNameTheFormatTheirViewerOpens() {
        XCTAssertTrue(AppPreset.websites.instructions.contains("index.html"))
        XCTAssertTrue(AppPreset.sheets.instructions.contains(".csv"))
        XCTAssertTrue(AppPreset.docs.instructions.contains(".md"))
        XCTAssertTrue(AppPreset.study.instructions.contains("Q:") && AppPreset.study.instructions.contains("A: line"))
        // The format the Study instructions describe is a deck the viewer accepts.
        let example = "# Planets\n\nQ: Largest planet?\nA: Jupiter\n\nQ: Closest to the Sun?\n- Venus\n- Mercury\nA: Mercury"
        XCTAssertEqual(FileView.kind(path: "planets.md", text: example), .cards)
    }

    func testEveryAppHasStartersAndAStableName() throws {
        for app in AppPreset.allCases {
            XCTAssertEqual(app.starters.count, 3)
            XCTAssertFalse(app.summary.isEmpty)
            let data = try JSONEncoder().encode(app)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(app.rawValue)\"")
        }
        XCTAssertEqual(AppPreset.allCases.map(\.rawValue), ["websites", "sheets", "docs", "study"])
    }
}
