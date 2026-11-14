import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class WebPreviewTests: XCTestCase {
    private let files = [
        "site/style.css": "body { color: red; }",
        "site/js/app.js": "document.title = 'ok';",
        "shared/theme.css": "h1 { font-size: 2em; }",
        "site/tricky.js": "const s = '</script><img src=x onerror=alert(1)>';",
    ]

    private func build(_ html: String, at path: String = "site/index.html") -> String {
        WebPreview.document(html: html, path: path) { files[$0] }
    }

    func testInlinesLocalStylesheetsAndScripts() {
        let page = build("""
        <!DOCTYPE html><html><head>
        <link rel="stylesheet" href="style.css">
        <link href='../shared/theme.css' rel=stylesheet>
        <script src="js/app.js?v=2"></script>
        </head><body><h1>Hi</h1></body></html>
        """)
        XCTAssertTrue(page.contains("<style>\nbody { color: red; }\n</style>"), page)
        XCTAssertTrue(page.contains("<style>\nh1 { font-size: 2em; }\n</style>"), page)
        XCTAssertTrue(page.contains("<script>\ndocument.title = 'ok';\n</script>"), page)
        XCTAssertFalse(page.contains("href="), page)
        XCTAssertFalse(page.contains("src="), page)
    }

    func testPolicyComesRightAfterTheDoctypeAndBlocksTheNetwork() {
        let page = build("<!doctype html>\n<html><head><script>fetch('https://example.com')</script></head></html>")
        XCTAssertTrue(page.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""), page)
        XCTAssertTrue(WebPreview.contentSecurityPolicy.contains("default-src 'none'"))
        XCTAssertTrue(WebPreview.contentSecurityPolicy.contains("connect-src 'none'"))
        XCTAssertTrue(WebPreview.contentSecurityPolicy.contains("form-action 'none'"))

        let bare = build("<p>No doctype</p>")
        XCTAssertTrue(bare.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""), bare)
    }

    func testLeavesRemoteAndMissingFilesForThePolicyToBlock() {
        let html = """
        <link rel="stylesheet" href="https://cdn.example.com/a.css">
        <link rel="stylesheet" href="//cdn.example.com/b.css">
        <script src="missing.js"></script>
        <script src="data:text/javascript,alert(1)"></script>
        <link rel="stylesheet" href="../../outside.css">
        """
        let page = build(html)
        XCTAssertTrue(page.hasSuffix(html), page)
    }

    func testInlinedCodeCannotCloseItsOwnTag() {
        let page = build(#"<script src="tricky.js"></script>"#)
        XCTAssertTrue(page.contains(#"'<\/script><img src=x onerror=alert(1)>'"#), page)
        XCTAssertEqual(page.components(separatedBy: "</script>").count, 2, page)
    }

    func testResolvesPathsAgainstThePage() {
        XCTAssertEqual(WebPreview.resolve("a.css", from: "index.html"), "a.css")
        XCTAssertEqual(WebPreview.resolve("./css/a.css", from: "site/index.html"), "site/css/a.css")
        XCTAssertEqual(WebPreview.resolve("/root.css", from: "site/index.html"), "root.css")
        XCTAssertEqual(WebPreview.resolve("my%20file.css#x", from: "index.html"), "my file.css")
        XCTAssertNil(WebPreview.resolve("../a.css", from: "index.html"))
        XCTAssertNil(WebPreview.resolve("javascript:alert(1)", from: "index.html"))
        XCTAssertNil(WebPreview.resolve("", from: "index.html"))
        XCTAssertTrue(WebPreview.isPage("Site/Index.HTML"))
        XCTAssertFalse(WebPreview.isPage("notes.md"))
    }
}
