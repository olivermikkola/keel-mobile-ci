import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class NarrationVoicePackTests: XCTestCase {
    func testTheDefaultVoiceShipsWithThePackAndMatchesTheTool() {
        XCTAssertTrue(NarrationVoicePack.voiceIDs.contains(NarrationVoicePack.defaultVoice))
        XCTAssertEqual(NarrationVoicePack.defaultVoice, ShortVideoRequest.defaultVoiceID)
        for voice in NarrationVoicePack.voiceIDs {
            XCTAssertNoThrow(try ShortVideoRequest.parseVoice(voice), voice)
        }
    }

    func testProgressStaysBelowDoneUntilThePackHasSpoken() {
        XCTAssertEqual(NarrationVoicePack.progress(bytesOnDisk: 0), 0)
        XCTAssertEqual(NarrationVoicePack.progress(bytesOnDisk: NarrationVoicePack.approximateBytes / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(NarrationVoicePack.progress(bytesOnDisk: NarrationVoicePack.approximateBytes * 3), 0.95)
    }

    func testFitsOnAn8GBPhoneButNotATinyOne() {
        XCTAssertTrue(NarrationVoicePack.fits(physicalMemoryBytes: 8 * 1_073_741_824))
        XCTAssertFalse(NarrationVoicePack.fits(physicalMemoryBytes: 512 * 1_048_576))
    }
}
