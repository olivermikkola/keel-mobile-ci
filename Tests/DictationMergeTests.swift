import XCTest
@testable import KeelMobile

final class DictationMergeTests: XCTestCase {
    func testSpokenWordsFollowTheTypedDraft() {
        XCTAssertEqual(OfflineDictation.merged(base: "", spoken: "hello"), "hello")
        XCTAssertEqual(OfflineDictation.merged(base: "Keep", spoken: "hello"), "Keep hello")
        XCTAssertEqual(OfflineDictation.merged(base: "Keep ", spoken: "hello"), "Keep hello")
        XCTAssertEqual(OfflineDictation.merged(base: "Keep", spoken: ""), "Keep")
    }
}
