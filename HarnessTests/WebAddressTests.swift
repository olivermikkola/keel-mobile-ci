import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class WebAddressTests: XCTestCase {
    private let said = ["Summarise https://example.com/news/today?id=7 for me", "and also docs.example.org/guide/"]

    func testOnlyCompleteAddressesTheUserWroteMayBeOpened() {
        for allowed in ["https://example.com/news/today?id=7", "https://docs.example.org/guide/",
                        "https://DOCS.example.org/guide/"] {
            XCTAssertTrue(WebAddress.userWrote(allowed, in: said), allowed)
        }
        for refused in ["http://example.com/news/today?id=7", "https://docs.example.org/guide",
                        "https://example.com/news", "https://example.com", "https://example.com/news/today?id=7&files=secret",
                        "https://evil.example/?q=example.com", "https://example.com.evil.example/news", "https://other.org/",
                        "ftp://example.com/news", "https://user:pw@example.com/news", "example.com/news", "https://localhost/", ""] {
            XCTAssertFalse(WebAddress.userWrote(refused, in: said), refused)
        }
        XCTAssertFalse(WebAddress.userWrote("https://example.com/news", in: []))
    }

    func testSubstringsCaseChangesAndQueryChangesDoNotAuthorizeRequests() {
        let messages = ["Read https://www.example.com/private/Case?token=AbC and https://example.com.evil.test/page"]
        for address in ["https://example.com/private/Case?token=AbC", "https://www.example.com/private/case?token=AbC",
                        "https://www.example.com/private/Case?token=abc", "https://www.example.com/private/Case?token=AbC/",
                        "https://example.com", "https://www.example.com/private/Case?token=AbC&data=secret"] {
            XCTAssertFalse(WebAddress.userWrote(address, in: messages), address)
        }
        XCTAssertFalse(WebAddress.userWrote("https://collect.example/?d=secret", in: ["See https://redirect.example/?next=https://collect.example/?d=secret"]))
        XCTAssertFalse(WebAddress.userWrote("https://example.com", in: ["Email me@example.com"]))
    }

    func testMarkdownPunctuationRootSlashAndLocalFixtureLinks() {
        XCTAssertTrue(WebAddress.userWrote("https://example.com/", in: ["Read [this](https://EXAMPLE.com). "]))
        XCTAssertTrue(WebAddress.userWrote("https://example.com/a_(b)", in: ["See https://example.com/a_(b). "]))
        XCTAssertTrue(WebAddress.userWrote("http://127.0.0.1:8766/aura.html", in: ["Read http://127.0.0.1:8766/aura.html ?"]))
        XCTAssertTrue(WebAddress.userWrote("http://docs.example.org/guide/", in: ["docs.example.org/guide/"]))
        XCTAssertTrue(WebAddress.userWrote("https://example.com:443/", in: ["https://example.com#intro"]))
        XCTAssertFalse(WebAddress.userWrote("https://example.com:444/", in: ["https://example.com"]))
    }

    func testTheModelSeesWhatToDoAfterAFailedRead() {
        for error: ReadURLError in [.url, .response, .tooLarge, .contentType, .encoding] {
            XCTAssertFalse(error.localizedDescription.contains("operation couldn"), "\(error)")
        }
    }

    func testLocalChatsOfferReadURLAndSayWhatItCanOpen() throws {
        let prompt = AgentPrompt.local()
        XCTAssertTrue(prompt.contains(#""name":"read_url""#))
        XCTAssertTrue(prompt.contains("Only read_url reaches the internet, and only for web addresses the user wrote in this chat."))
        XCTAssertFalse(AgentPrompt.repository(name: "o/r", commit: "c", map: "").contains("read_url"))
        let call = try XCTUnwrap(DirectorCall.parse("<tool_call>\n<function=read_url>\n<parameter=url>\nhttps://example.com/a?x=1&amp;y=2\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(call.arguments["url"], "https://example.com/a?x=1&y=2")
        XCTAssertEqual(call.label, "Read web page · example.com")
    }
}
