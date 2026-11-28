import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class ComputerHostTests: XCTestCase {
    private let validFingerprint = String(repeating: "a", count: 64)
    private let validToken = "token_0123456789abcdef"

    func testParsesValidPairingURIWithLANAndTailscale() throws {
        let uri = "keelpair://v1?n=Oliver%20Beelink&u=https%3A%2F%2F192.168.1.42%3A11488%2Chttps%3A%2F%2F100.88.12.5%3A11488&f=\(validFingerprint)&t=\(validToken)"
        let bundle = try ComputerPairingBundle.parse(uri)
        XCTAssertEqual(bundle.version, 1)
        XCTAssertEqual(bundle.hostName, "Oliver Beelink")
        XCTAssertEqual(bundle.urls, ["https://192.168.1.42:11488", "https://100.88.12.5:11488"])
        XCTAssertEqual(bundle.fingerprint, validFingerprint)
        XCTAssertEqual(bundle.token, validToken)
    }

    func testRejectsHTTPAndMalformedPairingLinks() {
        let httpURI = "keelpair://v1?n=PC&u=http%3A%2F%2F192.168.1.42%3A11488&f=\(validFingerprint)&t=\(validToken)"
        XCTAssertThrowsError(try ComputerPairingBundle.parse(httpURI))

        let shortFP = "keelpair://v1?n=PC&u=https%3A%2F%2F192.168.1.42%3A11488&f=deadbeef&t=\(validToken)"
        XCTAssertThrowsError(try ComputerPairingBundle.parse(shortFP))

        let badScheme = "https://example.com?n=PC&u=https%3A%2F%2F127.0.0.1%3A11488&f=\(validFingerprint)&t=\(validToken)"
        XCTAssertThrowsError(try ComputerPairingBundle.parse(badScheme))

        let embeddedCreds = "keelpair://v1?n=PC&u=https%3A%2F%2Fuser%3Apass%40192.168.1.42%3A11488&f=\(validFingerprint)&t=\(validToken)"
        XCTAssertThrowsError(try ComputerPairingBundle.parse(embeddedCreds))

        let shortToken = "keelpair://v1?n=PC&u=https%3A%2F%2F192.168.1.42%3A11488&f=\(validFingerprint)&t=short"
        XCTAssertThrowsError(try ComputerPairingBundle.parse(shortToken))
    }

    func testSavedComputerProfileOrdersPreferredURLFirst() {
        let profile = SavedComputerProfile(
            hostName: "Beelink",
            urls: ["https://192.168.1.42:11488", "https://100.88.12.5:11488"],
            preferredURL: "https://100.88.12.5:11488"
        )
        XCTAssertEqual(profile.orderedURLs, ["https://100.88.12.5:11488", "https://192.168.1.42:11488"])
    }

    func testSSEParserHandlesReplayAndKeepaliveComments() {
        var parser = ComputerSSEParser()
        XCTAssertNil(parser.feed(line: ": ping"))
        XCTAssertNil(parser.feed(line: "id: 7"))
        XCTAssertNil(parser.feed(line: "event: text"))
        XCTAssertNil(parser.feed(line: #"data: {"text":"Hello "}"#))
        let frame1 = parser.feed(line: "")
        XCTAssertEqual(frame1, ComputerSSEFrame(seq: 7, event: "text", data: #"{"text":"Hello "}"#))

        XCTAssertNil(parser.feed(line: "id: 8"))
        XCTAssertNil(parser.feed(line: "event: approval_request"))
        XCTAssertNil(parser.feed(line: #"data: {"id":"a1","tool":"run_shell","summary":"cargo test","arguments_json":"{}"}"#))
        let frame2 = parser.feed(line: "")
        XCTAssertEqual(frame2?.seq, 8)
        XCTAssertEqual(frame2?.event, "approval_request")
    }

    func testDecodesHostInfoAndThreadDetailPayloads() throws {
        let infoJSON = """
        {
          "protocol_version": 1,
          "host_name": "Beelink",
          "desktop_version": "0.7.2",
          "model_name": "Inkling 2 Mini",
          "model_id": "inkling-2-mini",
          "runtime_state": "running",
          "available_models": [{"id": "inkling-2-mini", "name": "Inkling 2 Mini", "installed": true}],
          "active_turns": 1,
          "pending_approvals": 0,
          "schedule_count": 2
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(ComputerHostInfo.self, from: infoJSON)
        XCTAssertEqual(info.host_name, "Beelink")
        XCTAssertEqual(info.model_name, "Inkling 2 Mini")
        XCTAssertEqual(info.schedule_count, 2)

        let schedJSON = """
        {
          "id": "s1",
          "name": "Morning brief",
          "prompt": "Summarize today's notes",
          "app_preset": "chat",
          "workspace_path": null,
          "interval_minutes": 1440,
          "repeat": true,
          "enabled": true,
          "watch_path": "/home/user/notes",
          "last_run_at": null,
          "next_run_at": 1800000000,
          "last_thread_id": null,
          "last_status": "idle"
        }
        """.data(using: .utf8)!
        let sched = try JSONDecoder().decode(ComputerSchedule.self, from: schedJSON)
        XCTAssertEqual(sched.name, "Morning brief")
        XCTAssertTrue(sched.repeat_enabled)
        XCTAssertEqual(sched.watch_path, "/home/user/notes")
    }
}
