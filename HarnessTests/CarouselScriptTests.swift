import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class CarouselScriptTests: XCTestCase {
    func testThePromptAsksForCoverPhotosAndClosing() throws {
        let (system, user) = try CarouselScript.prompt(description: "our  trip", photoCount: 3, photoNotes: ["harbour", "", "boat"])
        XCTAssertTrue(system.contains("Write exactly 5 lines, numbered 1 to 5"))
        XCTAssertTrue(system.contains("lines 2 to 4 are the photos"))
        XCTAssertTrue(user.contains("The carousel is about: our trip"))
        XCTAssertTrue(user.contains("Photo 1: harbour\nPhoto 3: boat"))
        XCTAssertThrowsError(try CarouselScript.prompt(description: "x", photoCount: 7))
    }

    func testParsesSlidesAndTheirKinds() throws {
        let reply = """
        <think>1. no</think>
        1. Your phone can do this | No internet, no cloud, just your iPhone.
        2. **Models that fit** | Pick one and it runs right here.
        3. Apps for real work | Docs, sheets and slides with offline viewers.
        4. Try it tonight | Join the TestFlight and see for yourself.
        """
        let slides = try CarouselScript.parse(reply, photoCount: 2)
        XCTAssertEqual(slides.map(\.kind), [.cover, .photo, .photo, .closing])
        XCTAssertEqual(slides[1].headline, "Models that fit")
        XCTAssertEqual(slides[3].body, "Join the TestFlight and see for yourself.")
        XCTAssertThrowsError(try CarouselScript.parse("1. Only a cover | x", photoCount: 2)) {
            XCTAssertEqual($0 as? CarouselScript.Problem, .script)
        }
    }

    func testLongHeadlinesAreCut() throws {
        let long = (1...12).map { "w\($0)" }.joined(separator: " ")
        let slides = try CarouselScript.parse("1. \(long) | a\n2. b | c\n3. d | e", photoCount: 1)
        XCTAssertEqual(slides[0].headline.split(separator: " ").count, CarouselScript.maxHeadlineWords)
    }

    func testThePageEscapesTextAndShowsTheCounter() {
        let slide = CarouselScript.Slide(kind: .cover, headline: "<script>alert(1)</script> & \"you\"", body: "It's here")
        let html = CarouselPage.html(slide, photo: "data:image/jpeg;base64,AAAA", index: 0, count: 4)
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;you&quot;"))
        XCTAssertTrue(html.contains("It&#39;s here"))
        XCTAssertTrue(html.contains("1/4"))
        XCTAssertTrue(html.contains("Swipe →"), "the cover asks to swipe")
        XCTAssertTrue(html.contains("url('data:image/jpeg;base64,AAAA')"))
        XCTAssertTrue(html.contains("window.renderFrame"), "the capture needs renderFrame")
        let closing = CarouselPage.html(.init(kind: .closing, headline: "End", body: ""), photo: nil, index: 3, count: 4)
        XCTAssertFalse(closing.contains("Swipe"))
        XCTAssertFalse(closing.contains("<p>"), "no empty paragraph")
        XCTAssertTrue(closing.contains("linear-gradient(160deg"), "a slide without a photo gets a plain background")
    }
}
