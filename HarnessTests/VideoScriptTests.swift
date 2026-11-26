import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class VideoScriptTests: XCTestCase {
    func testThePromptAsksForOneNumberedLinePerPhoto() throws {
        let (system, user) = try VideoScript.prompt(description: "  our  weekend in Porvoo ", photoCount: 4)
        XCTAssertTrue(system.contains("exactly 4 lines, numbered 1 to 4"))
        XCTAssertEqual(user, "The video is about: our weekend in Porvoo")
        XCTAssertThrowsError(try VideoScript.prompt(description: "x", photoCount: 0)) { XCTAssertEqual($0 as? VideoScript.Problem, .noPhotos) }
        XCTAssertThrowsError(try VideoScript.prompt(description: "x", photoCount: 7)) { XCTAssertEqual($0 as? VideoScript.Problem, .tooManyPhotos) }
        XCTAssertThrowsError(try VideoScript.prompt(description: "  ", photoCount: 2)) { XCTAssertEqual($0 as? VideoScript.Problem, .description) }
    }

    func testAChangeSendsTheLinesSoFar() throws {
        let previous = [VideoScript.Line(narration: "First light.", caption: "DAWN"), .init(narration: "Then the sea.")]
        let (_, user) = try VideoScript.prompt(description: "trip", photoCount: 2, previous: previous, change: "make it funnier")
        XCTAssertTrue(user.contains("1. First light. | DAWN\n2. Then the sea."))
        XCTAssertTrue(user.contains("Change: make it funnier\nWrite all 2 lines again"))
    }

    func testParsesNumberedLinesAndSkipsEverythingElse() throws {
        let reply = """
        <think>
        1. not this one
        </think>
        Here is your script:
        **1.** The road opened up just after sunrise. | Morning drive
        2) "By noon the beach was ours."
        3: We stayed until the lights came on | GOLDEN HOUR IN THE OLD TOWN
        2. a second line two is ignored
        """
        let lines = try VideoScript.parse(reply, photoCount: 3)
        XCTAssertEqual(lines, [
            .init(narration: "The road opened up just after sunrise.", caption: "Morning drive"),
            .init(narration: "By noon the beach was ours.", caption: nil),
            .init(narration: "We stayed until the lights came on", caption: "GOLDEN HOUR IN THE"),
        ])
    }

    func testAMissingLineFailsInsteadOfGuessing() {
        XCTAssertThrowsError(try VideoScript.parse("1. One.\n3. Three.", photoCount: 3)) {
            XCTAssertEqual($0 as? VideoScript.Problem, .script)
        }
    }

    func testALongLineIsCutToStayAShortScene() throws {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let line = try XCTUnwrap(VideoScript.parse("1. \(long)", photoCount: 1).first)
        XCTAssertEqual(line.narration.split(separator: " ").count, VideoScript.maxWordsPerLine)
    }

    func testTheStoryboardKeepsThePhotoOrderAndRendersAsAPlan() throws {
        let lines = [VideoScript.Line(narration: "One.", caption: "A"), .init(narration: "Two."), .init(narration: "Three."), .init(narration: "Four.")]
        let arguments = VideoScript.arguments(lines: lines, photoNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"], voice: "af_heart")
        XCTAssertEqual(arguments.scenes.map(\.imagePath), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(arguments.scenes.map(\.motion), [.slowZoom, .panLeft, .panRight, .slowZoom])
        XCTAssertEqual(arguments.scenes[0].overlay, "A")
        let plan = ShortVideoRequest.plan(arguments)
        XCTAssertEqual(plan.clips.count, 4)
        XCTAssertEqual(plan.width, 1080); XCTAssertEqual(plan.height, 1920)
    }

    func testPhotoNotesTellTheModelWhatEachPhotoShows() throws {
        let notes = [VideoScript.note(labels: ["screenshot", "document"], text: "Your models.\n Your iPhone."), "", "beach, sky"]
        XCTAssertEqual(notes[0], "screenshot, document; text: \"Your models. Your iPhone.\"")
        let (system, user) = try VideoScript.prompt(description: "Keel tour", photoCount: 3, photoNotes: notes)
        XCTAssertTrue(user.contains("What the photos show:\nPhoto 1: screenshot, document; text: \"Your models. Your iPhone.\"\nPhoto 3: beach, sky"))
        XCTAssertFalse(user.contains("Photo 2:"), "a photo with no note is left out")
        XCTAssertTrue(system.contains("line 1 is a hook"))
        XCTAssertTrue(system.contains("Never invent features"))
        XCTAssertTrue(system.contains("End every line with | and an on-screen caption"))
        XCTAssertEqual(VideoScript.note(labels: [], text: "  "), "")
    }
}
