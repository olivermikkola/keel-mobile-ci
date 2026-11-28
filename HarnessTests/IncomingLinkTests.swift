import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class IncomingLinkTests: XCTestCase {
    func testParsesAskDeepLinkAndBoundsLength() {
        let url = URL(string: "keelmobile://ask?text=Summarize%20this%20note")!
        XCTAssertEqual(IncomingLink.parse(url), .draftPrompt("Summarize this note"))

        let huge = String(repeating: "a", count: IncomingLink.maxPromptCharacters + 500)
        var components = URLComponents(string: "keelmobile://ask")!
        components.queryItems = [URLQueryItem(name: "prompt", value: huge)]
        if case .draftPrompt(let parsed) = IncomingLink.parse(components.url!) {
            XCTAssertEqual(parsed.count, IncomingLink.maxPromptCharacters)
        } else {
            XCTFail("Expected bounded draftPrompt")
        }
    }

    func testNewChatLinkFromTheWidget() {
        XCTAssertEqual(IncomingLink.parse(URL(string: "keelmobile://new")!), .newChat)
        XCTAssertEqual(IncomingLink.parse(URL(string: "KEELMOBILE://NEW")!), .newChat)
    }

    func testParsesOpenURLAndRejectsNonHTTPSchemes() {
        let valid = URL(string: "keelmobile://open?url=https%3A%2F%2Fexample.com%2Farticle")!
        XCTAssertEqual(IncomingLink.parse(valid), .draftPrompt("Read and summarize https://example.com/article"))

        let withNote = URL(string: "keelmobile://open?url=https%3A%2F%2Fexample.com&text=Extract%20key%20dates")!
        XCTAssertEqual(IncomingLink.parse(withNote), .draftPrompt("Extract key dates\n\nhttps://example.com"))

        let unsafe = URL(string: "keelmobile://open?url=javascript%3Aalert(1)")!
        XCTAssertNil(IncomingLink.parse(unsafe))
    }

    func testIgnoresShortcutCallbackAndUnrelatedSchemes() {
        let shortcutReturn = URL(string: "keelmobile://shortcut-result?token=abc")!
        XCTAssertNil(IncomingLink.parse(shortcutReturn))

        let httpsURL = URL(string: "https://example.com")!
        XCTAssertNil(IncomingLink.parse(httpsURL))
    }

    func testParsesSharedFileURL() {
        let file = URL(fileURLWithPath: "/tmp/report.csv")
        XCTAssertEqual(IncomingLink.parse(file), .sharedFile(file))
    }
}
