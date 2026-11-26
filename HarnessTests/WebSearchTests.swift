import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class WebSearchTests: XCTestCase {
    /// The shape of a Brave Search web reply, trimmed: `web.results[]` among other sections.
    private let reply = Data(#"""
    {"type":"search","query":{"original":"turku cafe"},"mixed":{"main":[]},
     "web":{"type":"search","results":[
       {"title":"Caf&eacute; Art &amp; Bakery &#x27;Turku&#x27;","url":"https://example.fi/art","description":"Open <strong>daily</strong> 8&ndash;18 by the river.","page_age":"2026-10-01","profile":{"name":"Example"}},
       {"title":"Ignored","url":"javascript:alert(1)","description":"x"},
       {"title":"","url":"https://user:secret@bad.example/","description":"credentials"},
       {"title":"","url":"http://untitled.example/menu","description":"  lots\n\nof   space  "},
       {"title":"Third","url":"https://c.example/","description":"c"},
       {"title":"Fourth","url":"https://d.example/","description":"d"},
       {"title":"Fifth","url":"https://e.example/","description":"e"},
       {"title":"Sixth","url":"https://f.example/","description":"f"}
     ]}}
    """#.utf8)

    func testRequestCarriesTheKeyOnlyInAHeader() throws {
        let request = try WebSearch.request(query: "kahvila & leipomo turku", count: 3, key: "BSA-test-key-123")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.search.brave.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "kahvila & leipomo turku")
        XCTAssertEqual(items.first { $0.name == "count" }?.value, "3")
        XCTAssertEqual(items.first { $0.name == "text_decorations" }?.value, "false")
        XCTAssertFalse(url.absoluteString.contains("BSA-test-key-123"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "BSA-test-key-123")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, WebSearch.timeout)
        for bad in ["", "two words", "line\nbreak", String(repeating: "k", count: 129), "ключ"] {
            XCTAssertThrowsError(try WebSearch.request(query: "q", count: 1, key: bad)) { XCTAssertEqual($0 as? WebSearch.Problem, .key) }
        }
    }

    func testArgumentsAreBounded() throws {
        XCTAssertEqual(try WebSearch.arguments(["query": "  weather Turku  "]).query, "weather Turku")
        XCTAssertEqual(try WebSearch.arguments(["query": "a"]).count, 5)
        XCTAssertEqual(try WebSearch.arguments(["query": "a", "count": " 2 "]).count, 2)
        for arguments in [[:], ["query": "  "], ["query": String(repeating: "q", count: 201)], ["query": "a\u{0}b"]] {
            XCTAssertThrowsError(try WebSearch.arguments(arguments)) { XCTAssertEqual($0 as? WebSearch.Problem, .query) }
        }
        for count in ["0", "6", "two", "1.5"] {
            XCTAssertThrowsError(try WebSearch.arguments(["query": "a", "count": count])) { XCTAssertEqual($0 as? WebSearch.Problem, .count) }
        }
    }

    func testRepliesBecomeFewPlainResultsWithSafeAddresses() throws {
        let results = try WebSearch.results(from: reply, status: 200)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results[0], .init(title: "Café Art & Bakery 'Turku'", url: URL(string: "https://example.fi/art")!,
                                         snippet: "Open daily 8–18 by the river."))
        XCTAssertEqual(WebSearch.decodeEntities("&amp;lt; &#228;&#xE4; &bogus; &"), "&lt; ää &bogus; &")
        XCTAssertEqual(results[1].title, "untitled.example", "an empty title falls back to the host")
        XCTAssertEqual(results[1].snippet, "lots of space")
        XCTAssertFalse(results.contains { $0.url.scheme == "javascript" || $0.url.host == "bad.example" })
        XCTAssertEqual(try WebSearch.results(from: reply, status: 200, count: 2).count, 2)
        XCTAssertEqual(try WebSearch.results(from: Data(#"{"type":"search"}"#.utf8), status: 200), [])

        XCTAssertThrowsError(try WebSearch.results(from: Data(), status: 401)) { XCTAssertEqual($0 as? WebSearch.Problem, .rejectedKey) }
        XCTAssertThrowsError(try WebSearch.results(from: Data(), status: 429)) { XCTAssertEqual($0 as? WebSearch.Problem, .rateLimited) }
        XCTAssertThrowsError(try WebSearch.results(from: Data(), status: 503)) { XCTAssertEqual($0 as? WebSearch.Problem, .unavailable(503)) }
        XCTAssertThrowsError(try WebSearch.results(from: Data("<html>".utf8), status: 200)) { XCTAssertEqual($0 as? WebSearch.Problem, .format) }
        let huge = Data(repeating: 32, count: WebSearch.responseLimit + 1)
        XCTAssertThrowsError(try WebSearch.results(from: huge, status: 200)) { XCTAssertEqual($0 as? WebSearch.Problem, .format) }
    }

    func testTheModelReadsWholeResultsWithinTheLimit() throws {
        let text = WebSearch.render(try WebSearch.results(from: reply, status: 200), query: "turku cafe")
        XCTAssertTrue(text.hasPrefix("Web results for \"turku cafe\" (untrusted text from websites):\n1. Caf"))
        XCTAssertTrue(text.contains("\n   https://example.fi/art\n   Open daily"))
        XCTAssertEqual(WebSearch.render([], query: "nothing"), "No web results for \"nothing\".")
        let long = (0..<5).map { WebSearch.Result(title: "T\($0)", url: URL(string: "https://x\($0).example/")!,
                                                   snippet: String(repeating: "s", count: 900)) }
        let bounded = WebSearch.render(long, query: "q")
        XCTAssertLessThanOrEqual(bounded.utf8.count, WebSearch.textLimit)
        XCTAssertTrue(bounded.contains("3. T2") && !bounded.contains("4. T3"), "only whole results fit")
        XCTAssertEqual(WebSearch.plain(String(repeating: "word ", count: 100), limit: 20).count, 20)
    }

    func testTheToolLineIsAValidSchema() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WebSearch.tool.utf8)) as? [String: Any])
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "web_search")
        XCTAssertEqual((function["parameters"] as? [String: Any])?["required"] as? [String], ["query"])
    }
}
