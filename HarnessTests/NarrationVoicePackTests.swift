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

    func testA12AndA13PhonesUseTheCPUChainAndNewerOnesKeepV3() {
        // iPhone XR (A12): v3 was killed at its memory limit on the device.
        XCTAssertEqual(NarrationVoicePack.pipeline(machineIdentifier: "iPhone11,8"), .legacyCPU)
        XCTAssertEqual(NarrationVoicePack.pipeline(machineIdentifier: "iPhone12,1"), .legacyCPU)
        XCTAssertEqual(NarrationVoicePack.pipeline(machineIdentifier: "iPhone13,2"), .v3)
        XCTAssertEqual(NarrationVoicePack.pipeline(machineIdentifier: "iPhone16,1"), .v3)
        XCTAssertEqual(NarrationVoicePack.pipeline(machineIdentifier: "arm64"), .v3, "Simulator chooses its own chain")
    }
}
