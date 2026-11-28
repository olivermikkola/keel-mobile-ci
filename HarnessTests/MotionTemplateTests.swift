import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class MotionTemplateTests: XCTestCase {
    func testEveryStyleIsASealedPageWithRenderFrame() {
        for style in MotionTemplate.Style.allCases {
            let scene = MotionTemplate.Scene(style: style, headline: "Runs <b>offline</b>", caption: "It's yours", seconds: 2.5)
            let html = MotionTemplate.html(scene, photo: "data:image/jpeg;base64,AAAA", index: 1, count: 4)
            XCTAssertTrue(html.contains("window.renderFrame=function(t)"), style.rawValue)
            XCTAssertTrue(html.contains("Runs &lt;b&gt;offline&lt;/b&gt;"), "headline escaped in \(style.rawValue)")
            XCTAssertTrue(html.contains("It&#39;s yours"))
            XCTAssertFalse(html.contains("<b>offline"), "no injected markup")
            XCTAssertFalse(html.contains("http://") || html.contains("https://"), "loads nothing from the network")
            XCTAssertTrue(html.contains("const scenes=[{id:'s0',start:0,length:2.5,style:'\(style.rawValue)'}],barBase=2.5,barFull=10"), html)
        }
    }

    func testPhotoStylesUseThePhotoAndTheTitleDoesNot() {
        let photo = "data:image/jpeg;base64,QUJD"
        XCTAssertTrue(MotionTemplate.html(.init(style: .headline, headline: "a", seconds: 2), photo: photo, index: 0, count: 1).contains("url('data:image/jpeg;base64,QUJD')"))
        XCTAssertTrue(MotionTemplate.html(.init(style: .device, headline: "a", seconds: 2), photo: photo, index: 0, count: 1).contains("url('data:image/jpeg;base64,QUJD')"))
        XCTAssertFalse(MotionTemplate.html(.init(style: .title, headline: "a", seconds: 2), photo: photo, index: 0, count: 1).contains("QUJD"))
        XCTAssertTrue(MotionTemplate.html(.init(style: .headline, headline: "a", seconds: 2), photo: nil, index: 0, count: 1).contains("background:none"))
    }

    func testScreenshotsGoInThePhoneFrame() {
        XCTAssertEqual(MotionTemplate.style(forPhotoNote: "screenshot, document; text: \"Keel\""), .device)
        XCTAssertEqual(MotionTemplate.style(forPhotoNote: "beach, sky"), .headline)
        XCTAssertEqual(MotionTemplate.style(forPhotoNote: ""), .headline)
    }

    func testAVeryShortSceneStillAnimates() {
        let html = MotionTemplate.html(.init(style: .headline, headline: "a", seconds: 0), photo: nil, index: 0, count: 1)
        XCTAssertTrue(html.contains("length:0.5"), "never divides by zero")
    }

    func testATimelinePlaysScenesOneAfterAnother() {
        let scenes: [(scene: MotionTemplate.Scene, photo: String?)] = [
            (.init(style: .device, headline: "LOCAL CHAT", caption: "Your phone answers.", seconds: 2.35), "data:image/jpeg;base64,QQ"),
            (.init(style: .headline, headline: "OFFLINE", caption: "No signal needed.", seconds: 1.8), "data:image/jpeg;base64,Qg"),
            (.init(style: .title, headline: "TRY IT", caption: "", seconds: 0.2), nil),
        ]
        let timing = MotionTemplate.starts(scenes.map(\.scene))
        XCTAssertEqual(timing.map(\.start), [0, 2.35, 4.15])
        XCTAssertEqual(timing.map(\.length), [2.35, 1.8, 0.5], "a too-short scene gets the minimum")
        let html = MotionTemplate.timeline(scenes)
        XCTAssertTrue(html.contains("{id:'s0',start:0,length:2.35,style:'device'},{id:'s1',start:2.35,length:1.8,style:'headline'},{id:'s2',start:4.15,length:0.5,style:'title'}"), html)
        XCTAssertTrue(html.contains("barBase=0,barFull=4.65"))
        for text in ["LOCAL CHAT", "Your phone answers.", "OFFLINE", "No signal needed.", "TRY IT"] {
            XCTAssertTrue(html.contains(text), text)
        }
        for id in ["s0", "s1", "s2"] {
            XCTAssertTrue(html.contains("id=\"\(id)-photo\"") && html.contains("id=\"\(id)-head\"") && html.contains("id=\"\(id)-cap\""), id)
        }
    }
}
