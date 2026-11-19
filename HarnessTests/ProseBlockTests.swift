import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ProseBlockTests: XCTestCase {
    func testAReplyWithHeadingParagraphAndListsBecomesBlocks() {
        let reply = """
        ## Plan for the trip

        Here is what I would do **first**.
        It fits one day.

        - Book the train
        - Pack:
          - charger
          - passport
        1. Leave at 8
        2) Arrive by noon

        ---
        Done.
        """
        XCTAssertEqual(ProseBlock.parse(reply), [
            .heading(level: 2, text: "Plan for the trip"),
            .paragraph("Here is what I would do **first**.\nIt fits one day."),
            .list([
                .init(marker: "•", depth: 0, text: "Book the train"),
                .init(marker: "•", depth: 0, text: "Pack:"),
                .init(marker: "•", depth: 1, text: "charger"),
                .init(marker: "•", depth: 1, text: "passport"),
                .init(marker: "1.", depth: 0, text: "Leave at 8"),
                .init(marker: "2.", depth: 0, text: "Arrive by noon"),
            ]),
            .rule,
            .paragraph("Done."),
        ])
    }

    func testBlankLinesBetweenItemsKeepOneListAndIndentedLinesContinueAnItem() {
        let blocks = ProseBlock.parse("1. First step\n   that runs long\n\n2. Second step\n\nAfter the list.")
        XCTAssertEqual(blocks, [
            .list([.init(marker: "1.", depth: 0, text: "First step that runs long"),
                   .init(marker: "2.", depth: 0, text: "Second step")]),
            .paragraph("After the list."),
        ])
    }

    func testTaskBoxesQuotesAndDeepNestingAreBounded() {
        let blocks = ProseBlock.parse("- [ ] buy milk\n- [x] call Anna\n            - very deep\n> quoted line\n> second line")
        XCTAssertEqual(blocks, [
            .list([.init(marker: "☐", depth: 0, text: "buy milk"),
                   .init(marker: "☑", depth: 0, text: "call Anna"),
                   .init(marker: "•", depth: ProseBlock.maxDepth, text: "very deep")]),
            .quote("quoted line\nsecond line"),
        ])
    }

    func testATableNeedsItsSeparatorLineAndRowsAreFittedToTheHeader() {
        let table = "| City | Price |\n|:-----|------:|\n| Turku | 12 € |\n| Oulu |\n| a \\| b | 3 | extra |\nafter"
        XCTAssertEqual(ProseBlock.parse(table), [
            .table(header: ["City", "Price"], rows: [["Turku", "12 €"], ["Oulu", ""], ["a | b", "3"]]),
            .paragraph("after"),
        ])
        // Still being written: a header without its separator is ordinary text.
        XCTAssertEqual(ProseBlock.parse("| City | Price |"), [.paragraph("| City | Price |")])
        XCTAssertEqual(ProseBlock.parse("use a | b here\nnot a table"), [.paragraph("use a | b here\nnot a table")])
    }

    func testThingsThatOnlyLookLikeMarkdownStayParagraphs() {
        XCTAssertEqual(ProseBlock.parse("#hashtag and 2024. was a year"), [.paragraph("#hashtag and 2024. was a year")])
        XCTAssertEqual(ProseBlock.parse("**Bold opener** then text"), [.paragraph("**Bold opener** then text")])
        XCTAssertEqual(ProseBlock.parse("-5 degrees\n3.14 is pi"), [.paragraph("-5 degrees\n3.14 is pi")])
        XCTAssertEqual(ProseBlock.parse(""), [])
        XCTAssertEqual(ProseBlock.parse("Saved partial reply"), [.paragraph("Saved partial reply")])
    }

    func testLinksShowTheirAddressAndTagsAreNotReadAsHTML() {
        XCTAssertEqual(ProseBlock.inlineSafe("See [the docs](https://example.com/a?b=1) now"),
                       "See the docs (https://example.com/a?b=1) now")
        XCTAssertEqual(ProseBlock.inlineSafe("![chart](https://x.test/c.png)"), "chart (https://x.test/c.png)")
        XCTAssertEqual(ProseBlock.inlineSafe("[https://a.test](https://a.test)"), "https://a.test")
        XCTAssertEqual(ProseBlock.inlineSafe("array[0] and [note] stay, a < b"), "array[0] and [note] stay, a \\< b")
        XCTAssertEqual(ProseBlock.inlineSafe("use <div> here"), "use \\<div> here")
        XCTAssertEqual(ProseBlock.inlineSafe("[unfinished](https://x"), "[unfinished](https://x")
    }
}
