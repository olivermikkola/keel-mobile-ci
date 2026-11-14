import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ReadURLTests: XCTestCase {
    func testStrictCallAndURL() throws {
        let call = try RepositoryCall.parse("<tool_call><function=read_url><parameter=url>https://example.com</parameter></function></tool_call>")
        XCTAssertEqual(call?.url, "https://example.com")
        for url in ["file:///etc/passwd", "https://user:secret@example.com", "data:text/plain,hi", "relative"] {
            XCTAssertThrowsError(try ReadURL.validatedURL(url))
        }
        XCTAssertThrowsError(try RepositoryCall.parse("<tool_call><function=read_url><parameter=url>https://example.com</parameter><parameter=count>1</parameter></function></tool_call>"))
    }

    func testHTMLBecomesInertReadableText() {
        let html = "<head><title>hidden</title></head><h1>Hello &amp; welcome</h1><!-- secret --><style>hide</style><script>bad()</script><p>caf&#233; &lt;ok&gt; &#x1F600;</p>"
        XCTAssertEqual(ReadURL.convert(html).text, "Hello & welcome café <ok> 😀")
        XCTAssertEqual(ReadURL.convert("hello<script>unfinished").text, "hello")
        XCTAssertEqual(ReadURL.convert("a < b", html: false).text, "a < b")
    }

    func testDenseEntitiesAndMalformedTagsStayBounded() {
        XCTAssertEqual(ReadURL.convert(String(repeating: "&amp;", count: 90_000)).text, String(repeating: "&", count: ReadURL.textLimit))
        let start = Date()
        _ = ReadURL.convert(String(repeating: "<script", count: 60_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testOutputByteLimitPreservesUnicodeAndReportsTruncation() {
        let result = ReadURL.convert(String(repeating: "😀", count: 2000), html: false)
        XCTAssertEqual(result.text.utf8.count, ReadURL.textLimit)
        XCTAssertTrue(result.truncated)
    }

    private func fetch(_ path: String) async throws -> ReadURL.Result {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadURLProtocol.self]
        return try await ReadURL().execute(RepositoryCall(name: "read_url", path: "", offset: 0, count: 0, query: nil,
                                                         url: "https://example.com/" + path), configuration: config)
    }

    func testFetchConvertsHTML() async throws {
        let result = try await fetch("ok")
        XCTAssertEqual(result.text, "Hello world")
    }

    func testRejectsStatusMimeAndOversizedChunkedBody() async {
        for path in ["status", "mime", "large", "declared"] {
            do { _ = try await fetch(path); XCTFail("Accepted \(path)") } catch { }
        }
    }

    func testCancellationStopsWaiting() async {
        let task = Task { try await fetch("stall") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { }
    }

    func testResourceDeadlineStopsStalledResponse() async {
        let start = Date()
        do { _ = try await fetch("stall"); XCTFail("Deadline ignored") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(start), ReadURL.timeout + 5)
    }
}

private final class ReadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "stall" { return }
        var headers = ["Content-Type": path == "mime" ? "image/png" : "text/html; charset=utf-8"]
        if path == "declared" { headers["Content-Length"] = String(ReadURL.byteLimit + 1) }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "status" ? 404 : 200,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "large" {
            let chunk = Data(repeating: 65, count: 8192)
            for _ in 0...ReadURL.byteLimit / chunk.count { client?.urlProtocol(self, didLoad: chunk) }
        } else { client?.urlProtocol(self, didLoad: Data("<p>Hello <b>world</b></p>".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
