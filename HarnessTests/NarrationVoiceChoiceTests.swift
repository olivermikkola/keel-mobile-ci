import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class NarrationVoiceChoiceTests: XCTestCase {
    func testKokoroIdsStayPlainAndAppleIdsArePrefixed() {
        XCTAssertEqual(NarrationVoiceChoice(id: "af_heart"), .kokoro("af_heart"))
        XCTAssertEqual(NarrationVoiceChoice(id: "apple:com.apple.voice.premium.en-US.Zoe"), .apple(identifier: "com.apple.voice.premium.en-US.Zoe"))
        XCTAssertEqual(NarrationVoiceChoice.apple(identifier: "x").id, "apple:x")
        XCTAssertEqual(NarrationVoiceChoice(id: "apple:"), .kokoro("apple:"), "an empty Apple id is not an Apple voice")
        XCTAssertTrue(NarrationVoiceChoice(id: "af_heart").needsKokoro)
        XCTAssertFalse(NarrationVoiceChoice(id: "apple:x").needsKokoro)
    }

    func testOffersPersonalVoiceFirstThenTheBestEnglishVoicesOncePerName() {
        typealias V = NarrationVoiceChoice.AppleVoice
        let voices = [
            V(identifier: "s.zoe", name: "Zoe", language: "en-US", quality: .standard, isPersonal: false),
            V(identifier: "p.zoe", name: "Zoe", language: "en-US", quality: .premium, isPersonal: false),
            V(identifier: "e.daniel", name: "Daniel", language: "en-GB", quality: .enhanced, isPersonal: false),
            V(identifier: "s.anna", name: "Anna", language: "de-DE", quality: .premium, isPersonal: false),
            V(identifier: "me", name: "Oliver", language: "en-US", quality: .standard, isPersonal: true),
            V(identifier: "s.fred", name: "Fred", language: "en-US", quality: .standard, isPersonal: false),
        ]
        let offered = NarrationVoiceChoice.offered(voices)
        XCTAssertEqual(offered.map(\.identifier), ["me", "p.zoe", "e.daniel", "s.fred"])
        XCTAssertEqual(offered[0].label, "Oliver · your Personal Voice")
        XCTAssertEqual(offered[1].label, "Zoe · Apple, premium")
        XCTAssertEqual(NarrationVoiceChoice.offered(voices, limit: 1).map(\.identifier), ["me", "p.zoe"])
    }
}
