import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ChatTitleTests: XCTestCase {
    func testKeepsAPlainTitle() {
        XCTAssertEqual(ChatTitle.parse("Ruben the funny dog video"), "Ruben the funny dog video")
        XCTAssertEqual(ChatTitle.parse("  weekend trip plan \n"), "Weekend trip plan")
    }

    func testStripsQuotesLabelsAndMarkdown() {
        XCTAssertEqual(ChatTitle.parse("\"Budget for March\""), "Budget for March")
        XCTAssertEqual(ChatTitle.parse("Title: Fix the login page."), "Fix the login page")
        XCTAssertEqual(ChatTitle.parse("**Sourdough starter help**"), "Sourdough starter help")
        XCTAssertEqual(ChatTitle.parse("“Tokyo itinerary”\nHere is why…"), "Tokyo itinerary")
    }

    func testUsesTheTextAfterFinishedReasoning() {
        XCTAssertEqual(ChatTitle.parse("<think>about dogs</think>\nDog names"), "Dog names")
        XCTAssertNil(ChatTitle.parse("<think>still thinking about the"))
    }

    func testRejectsWhatIsNotATitle() {
        XCTAssertNil(ChatTitle.parse(""))
        XCTAssertNil(ChatTitle.parse("…"))
        XCTAssertNil(ChatTitle.parse("<tool_call>{\"name\":\"x\"}</tool_call>"))
        XCTAssertNil(ChatTitle.parse("This chat is about planning a long trip through Japan with a lot of stops"))
        XCTAssertNil(ChatTitle.parse(String(repeating: "a", count: 61)))
    }

    func testOnlyTheFirstExchangeIsTitled() {
        XCTAssertTrue(ChatTitle.isFirstExchange(userMessages: 1))
        XCTAssertFalse(ChatTitle.isFirstExchange(userMessages: 2))
        XCTAssertFalse(ChatTitle.isFirstExchange(userMessages: 0))
    }
}
