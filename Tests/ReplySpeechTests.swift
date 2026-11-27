import XCTest
import AVFoundation
import SwiftUI
@testable import KeelMobile

@MainActor
final class ReplySpeechTests: XCTestCase {
    func testSpeakToggleAndCompletionReleaseSessionAndIgnoreStaleCallback() {
        var finishCallback: ReplySpeech.Finish?
        var spokenInputs: [String] = []
        var stops = 0
        let speech = ReplySpeech { text, finish in
            spokenInputs.append(text)
            finishCallback = finish
            return { stops += 1 }
        }
        let firstID = UUID()
        speech.toggle(messageID: firstID, text: "Hello **world**.\n\n```swift\nlet x = 1\n```\n\nDone.")
        XCTAssertEqual(speech.speakingMessageID, firstID)
        XCTAssertEqual(spokenInputs, ["Hello world.\n\nDone."])

        // Toggling the same message stops playback.
        speech.toggle(messageID: firstID, text: "Ignored")
        XCTAssertNil(speech.speakingMessageID)
        XCTAssertEqual(stops, 1)

        // Stale finish callback from the stopped utterance does nothing.
        let staleFinish = finishCallback
        let secondID = UUID()
        speech.speak(messageID: secondID, text: "Second reply")
        XCTAssertEqual(speech.speakingMessageID, secondID)
        staleFinish?()
        XCTAssertEqual(speech.speakingMessageID, secondID)
        XCTAssertEqual(stops, 1)

        // Current finish callback clears the speaking state cleanly.
        finishCallback?()
        XCTAssertNil(speech.speakingMessageID)
        XCTAssertEqual(stops, 2)
    }

    func testSceneInactivityStopsSpeakingImmediately() {
        var stops = 0
        let speech = ReplySpeech { _, _ in
            return { stops += 1 }
        }
        let id = UUID()
        speech.speak(messageID: id, text: "Read this aloud")
        XCTAssertEqual(speech.speakingMessageID, id)
        XCTAssertFalse(speech.sceneDidChange(.active))
        XCTAssertTrue(speech.sceneDidChange(.inactive))
        XCTAssertNil(speech.speakingMessageID)
        XCTAssertEqual(stops, 1)
    }

    func testEmptyOrToolOnlyReplyDoesNotStartSynthesizer() {
        var starts = 0
        let speech = ReplySpeech { _, _ in
            starts += 1
            return {}
        }
        speech.speak(messageID: UUID(), text: "<tool_call>\n<function=list_files>\n<parameter=path>.</parameter>\n</function>\n</tool_call>")
        XCTAssertNil(speech.speakingMessageID)
        XCTAssertEqual(starts, 0)
    }

    func testSystemSpeechUtteranceCapsLengthAndUsesDefaultRate() {
        let long = String(repeating: "b", count: SpeechText.maxCharacters + 200)
        let utterance = SystemSpeechOutput.makeUtterance(long, locale: Locale(identifier: "en-US"))
        XCTAssertEqual(utterance.speechString.count, SpeechText.maxCharacters)
        XCTAssertEqual(utterance.rate, AVSpeechUtteranceDefaultSpeechRate)
    }
}
