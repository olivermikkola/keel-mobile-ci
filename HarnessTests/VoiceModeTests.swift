import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class VoiceModeTests: XCTestCase {
    func testAFullTurnListensSendsAfterAPauseSpeaksAndListensAgain() {
        var voice = VoiceMode()
        XCTAssertEqual(voice.start(now: 0), [.startListening])
        XCTAssertEqual(voice.hear("what is", now: 1), [])
        XCTAssertEqual(voice.tick(now: 2), [], "Still talking")
        XCTAssertEqual(voice.hear("what is the capital of Finland", now: 2.5), [])
        XCTAssertEqual(voice.tick(now: 3), [])
        XCTAssertEqual(voice.tick(now: 2.6 + VoiceMode.pauseSeconds), [.stopListening, .send("what is the capital of Finland")])
        XCTAssertEqual(voice.phase, .thinking)
        XCTAssertEqual(voice.hear("late words", now: 5), [], "Nothing is heard while the model works")
        XCTAssertEqual(voice.replyFinished("Helsinki.", now: 9), [.speak("Helsinki.")])
        XCTAssertEqual(voice.phase, .speaking)
        XCTAssertEqual(voice.speechFinished(now: 11), [.startListening])
        XCTAssertEqual(voice.phase, .listening)
        XCTAssertEqual(voice.heard, "")
    }

    func testTheSameWordsAgainDoNotRestartThePauseAndSilenceTurnsItOff() {
        var voice = VoiceMode()
        _ = voice.start(now: 0)
        _ = voice.hear("hello", now: 1)
        _ = voice.hear(" hello ", now: 2.5)
        XCTAssertEqual(voice.tick(now: 1.1 + VoiceMode.pauseSeconds), [.stopListening, .send("hello")])

        var quiet = VoiceMode()
        _ = quiet.start(now: 100)
        XCTAssertEqual(quiet.tick(now: 100 + VoiceMode.idleSeconds - 1), [])
        XCTAssertEqual(quiet.tick(now: 100 + VoiceMode.idleSeconds), [.stopListening])
        XCTAssertFalse(quiet.isOn)
    }

    func testTheRecognizerStoppingByItselfSendsWhatWasHeardOrEndsVoiceMode() {
        var voice = VoiceMode()
        _ = voice.start(now: 0)
        _ = voice.hear("remind me to call Anna", now: 1)
        XCTAssertEqual(voice.listeningEnded(), [.send("remind me to call Anna")])
        var silent = VoiceMode()
        _ = silent.start(now: 0)
        XCTAssertEqual(silent.listeningEnded(), [])
        XCTAssertEqual(silent.phase, .off)
    }

    func testNoReplyEndsVoiceModeAndInterruptingGoesBackToListening() {
        var voice = VoiceMode()
        _ = voice.start(now: 0); _ = voice.hear("hi", now: 0); _ = voice.tick(now: 5)
        XCTAssertEqual(voice.replyFinished(nil, now: 6), [])
        XCTAssertEqual(voice.phase, .off)

        var talking = VoiceMode()
        _ = talking.start(now: 0); _ = talking.hear("hi", now: 0); _ = talking.tick(now: 5)
        XCTAssertEqual(talking.interrupt(now: 6), [.stopReply, .startListening])
        _ = talking.hear("actually", now: 7); _ = talking.tick(now: 10)
        _ = talking.replyFinished("A long answer.", now: 12)
        XCTAssertEqual(talking.interrupt(now: 13), [.stopSpeaking, .startListening])
        XCTAssertEqual(talking.phase, .listening)
        XCTAssertEqual(talking.speechFinished(now: 14), [], "The interrupted speech ending changes nothing")
    }

    func testStopUndoesWhateverIsHappening() {
        for (setup, expected) in [(0, [VoiceMode.Action.stopListening]), (1, [.stopReply]), (2, [.stopSpeaking])] {
            var voice = VoiceMode()
            _ = voice.start(now: 0)
            if setup >= 1 { _ = voice.hear("hi", now: 0); _ = voice.tick(now: 5) }
            if setup >= 2 { _ = voice.replyFinished("Hello.", now: 6) }
            XCTAssertEqual(voice.stop(), expected)
            XCTAssertEqual(voice.phase, .off)
            XCTAssertEqual(voice.stop(), [])
            XCTAssertEqual(voice.start(now: 10), [.startListening], "It can start again")
        }
    }
}
