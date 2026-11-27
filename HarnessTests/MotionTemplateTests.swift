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
            XCTAssertTrue(html.contains("const length=2.5,index=1,count=4"))
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
        XCTAssertTrue(html.contains("const length=0.5"), "never divides by zero")
    }
}
