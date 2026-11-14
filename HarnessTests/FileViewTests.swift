import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class FileViewTests: XCTestCase {
    let deck = """
    # Photosynthesis

    Q: What gas do plants take in?
    A: Carbon dioxide

    **Q2:** Where does it happen?
    - [ ] Mitochondria
    - [x] Chloroplasts
    - [ ] Nucleus

    Question 3: What do plants give off?
    Answer: Oxygen,
    mostly.
    """

    func testKindFollowsTheFile() {
        XCTAssertEqual(FileView.kind(path: "site/index.html", text: ""), .page)
        XCTAssertEqual(FileView.kind(path: "Sales.CSV", text: "a\n1"), .table)
        XCTAssertEqual(FileView.kind(path: "notes.md", text: "# Notes\n\nHello"), .document)
        XCTAssertEqual(FileView.kind(path: "bio.md", text: deck), .cards)
        XCTAssertEqual(FileView.kind(path: "one.md", text: "Q: Only one?\nA: Yes"), .document)
        XCTAssertNil(FileView.kind(path: "app.js", text: ""))
        XCTAssertNil(FileView.document(path: "app.js", text: "", read: { _ in nil }))
    }

    func testEveryViewerCarriesThePolicyFirst() throws {
        for (path, text) in [("a.md", "# Hi"), ("a.csv", "x\n1"), ("a.md", deck), ("a.html", "<!doctype html><p>hi")] {
            let page = try XCTUnwrap(FileView.document(path: path, text: text) { _ in nil })
            let policy = try XCTUnwrap(page.range(of: "Content-Security-Policy"), path)
            XCTAssertNil(page[..<policy.lowerBound].range(of: "<script"), path)
            XCTAssertNil(page[..<policy.lowerBound].range(of: "<style"), path)
        }
    }

    func testMarkdownBlocks() {
        let html = Markdown.html("""
        # Title #
        Some *soft* and **strong** text with `a < b` and ~~old~~.
        Next line.

        - one
          - nested
        - [x] done
        - [ ] todo

        1. first
        2. second

        > quoted **bit**

        ---

        | Name | Price |
        | :--- | ---: |
        | Tea \\| hot | 3 |

        ```
        <b>not bold</b>
        ```
        """)
        XCTAssertTrue(html.contains("<h1>Title</h1>"), html)
        XCTAssertTrue(html.contains("<p>Some <em>soft</em> and <strong>strong</strong> text with <code>a &lt; b</code> and <del>old</del>.<br>\nNext line.</p>"), html)
        XCTAssertTrue(html.contains("<ul><li>one<ul><li>nested</li></ul></li><li><input type=\"checkbox\" disabled checked> done</li><li><input type=\"checkbox\" disabled> todo</li></ul>"), html)
        XCTAssertTrue(html.contains("<ol><li>first</li><li>second</li></ol>"), html)
        XCTAssertTrue(html.contains("<blockquote><p>quoted <strong>bit</strong></p></blockquote>"), html)
        XCTAssertTrue(html.contains("<hr>"), html)
        XCTAssertTrue(html.contains("<th>Name</th><th style=\"text-align:right\">Price</th>"), html)
        XCTAssertTrue(html.contains("<td>Tea | hot</td><td style=\"text-align:right\">3</td>"), html)
        XCTAssertTrue(html.contains("<pre><code>&lt;b&gt;not bold&lt;/b&gt;</code></pre>"), html)
    }

    func testMarkdownNeverPassesMarkupOrScriptLinksThrough() {
        let html = Markdown.html("""
        <script>alert(1)</script>
        [ok](https://example.com) [bad](javascript:alert(1)) ![img](x.png) [quote](https://x.com/"onmouseover=alert(1))
        """)
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">ok</a>"), html)
        XCTAssertFalse(html.contains("javascript:"), html)
        XCTAssertTrue(html.contains(" bad "), html)
        XCTAssertFalse(html.contains("<img"), html)
        XCTAssertFalse(html.contains("\"onmouseover"), html)
    }

    func testStudyDeckReadsCardsAndQuizzes() {
        let parsed = StudyDeck.parse(deck)
        XCTAssertEqual(parsed.title, "Photosynthesis")
        XCTAssertEqual(parsed.cards.count, 3)
        XCTAssertEqual(parsed.cards[0], StudyDeck.Card(question: "What gas do plants take in?", answer: "Carbon dioxide"))
        XCTAssertEqual(parsed.cards[1].question, "Where does it happen?")
        XCTAssertEqual(parsed.cards[1].choices, ["Mitochondria", "Chloroplasts", "Nucleus"])
        XCTAssertEqual(parsed.cards[1].correct, [1])
        XCTAssertTrue(parsed.cards[1].isQuiz)
        XCTAssertEqual(parsed.cards[2].answer, "Oxygen,\nmostly.")
    }

    func testAQuestionWithoutAnAnswerIsNotACard() {
        let parsed = StudyDeck.parse("Q: Open?\n\nQ: Choices but none ticked\n- [ ] a\n- [ ] b\n\nQ: Real\nA: yes")
        XCTAssertEqual(parsed.cards.map(\.question), ["Real"])
    }

    func testTableShowsCSVWithNumbersAlignedAndTextEscaped() {
        let html = FileView.table("item,price,note\nTea,3.5,<b>hot</b>\nCake,4,\n")
        XCTAssertTrue(html.contains("2 rows · 3 columns"), html)
        XCTAssertTrue(html.contains("<th>item</th><th class=\"num\">price</th><th>note</th>"), html)
        XCTAssertTrue(html.contains("<td class=\"num\">3.5</td><td>&lt;b&gt;hot&lt;/b&gt;</td>"), html)
        let big = FileView.table("n\n" + (1...2_500).map(String.init).joined(separator: "\n"))
        XCTAssertTrue(big.contains("2500 rows · 1 column · showing the first 2000"), String(big.prefix(200)))
        XCTAssertEqual(big.components(separatedBy: "<tr>").count - 1, 2_001)
    }

    func testCardTextCannotCloseTheDataScript() throws {
        let page = try XCTUnwrap(FileView.document(path: "x.md", text: "Q: a</script><script>alert(1)</script>\nA: b\n\nQ: c\nA: <!-- d", read: { _ in nil }))
        XCTAssertEqual(page.components(separatedBy: "</script>").count - 1, 2, "only the data and the card script close")
        XCTAssertTrue(page.contains("a<\\/script><script>alert(1)<\\/script>"), page)
        XCTAssertFalse(page.contains("<!--"))
    }
}
