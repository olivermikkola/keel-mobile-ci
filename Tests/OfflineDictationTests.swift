import XCTest
import Speech
import SwiftUI
@testable import KeelMobile

@MainActor
final class OfflineDictationTests: XCTestCase {
    func testRequestRequiresOfflineRecognition() {
        let request = SpeechCapture.offlineRequest()
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
    }

    func testPartialFinalAndStopKeepTextAndReleaseSession() async {
        var callback: OfflineDictation.Update?
        var stops = 0
        let dictation = OfflineDictation { update in
            callback = update
            return { stops += 1 }
        }
        await dictation.start()
        XCTAssertTrue(dictation.recording)
        callback?("Hello", false, nil)
        XCTAssertEqual(dictation.text, "Hello")
        callback?("Hello world", true, nil)
        XCTAssertEqual(dictation.text, "Hello world")
        XCTAssertFalse(dictation.recording)
        XCTAssertEqual(stops, 1)
        callback?("stale callback", false, nil)
        XCTAssertEqual(dictation.text, "Hello world")
        dictation.stop()
        XCTAssertEqual(stops, 1)
    }

    func testPermissionCompletionAfterDismissCannotKeepMicrophoneOpen() async {
        var permission: CheckedContinuation<Void, Never>?
        var stops = 0
        let dictation = OfflineDictation { _ in
            await withCheckedContinuation { permission = $0 }
            return { stops += 1 }
        }
        let start = Task { await dictation.start() }
        for _ in 0..<50 where permission == nil { await Task.yield() }
        XCTAssertTrue(dictation.preparing)
        dictation.stop()
        permission?.resume()
        await start.value
        XCTAssertFalse(dictation.recording)
        XCTAssertFalse(dictation.preparing)
        XCTAssertEqual(stops, 1)
    }

    func testPermissionAlertInactivityDoesNotAbortPreparationButRecordingStops() async {
        var permission: CheckedContinuation<Void, Never>?
        var stops = 0
        let dictation = OfflineDictation { _ in
            await withCheckedContinuation { permission = $0 }
            return { stops += 1 }
        }
        let start = Task { await dictation.start() }
        for _ in 0..<50 where permission == nil { await Task.yield() }
        XCTAssertTrue(dictation.preparing)
        XCTAssertFalse(dictation.sceneDidChange(.inactive))
        XCTAssertTrue(dictation.preparing)
        permission?.resume()
        await start.value
        XCTAssertTrue(dictation.recording)
        XCTAssertTrue(dictation.sceneDidChange(.inactive))
        XCTAssertFalse(dictation.recording)
        XCTAssertEqual(stops, 1)
    }

    func testUnavailableDoesNotRecordAndShowsError() async {
        let dictation = OfflineDictation { _ in throw DictationError.unavailable }
        await dictation.start()
        XCTAssertFalse(dictation.recording)
        XCTAssertFalse(dictation.preparing)
        XCTAssertTrue(dictation.error?.contains("Offline dictation is unavailable") == true)
    }

    func testInterruptionKeepsPartialTextAndStops() async {
        var callback: OfflineDictation.Update?
        var stops = 0
        let dictation = OfflineDictation { update in callback = update; return { stops += 1 } }
        await dictation.start()
        callback?("My draft", false, nil)
        callback?(nil, true, "Interrupted")
        XCTAssertEqual(dictation.text, "My draft")
        XCTAssertEqual(dictation.error, "Interrupted")
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(dictation.recording)
        print("Dictation lifecycle proof: partial/final text, stale callbacks, delayed permission, unavailable recognizer and interruption verified with injected capture. Real microphone/offline accuracy requires an iPhone.")
    }
}
