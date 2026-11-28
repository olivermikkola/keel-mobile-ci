import XCTest
@testable import KeelMobile

@MainActor
final class DecideSessionTests: XCTestCase {
    private var folder: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("decide-\(UUID().uuidString)", isDirectory: true)
        defaultsSuite = "keel.decide.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeSession() -> DecideSession {
        DecideSession(defaults: defaults, storageURL: folder.appendingPathComponent("decide-session.json"))
    }

    func testResumeIdentifiesUnfinishedAndFailedDocumentsAndResetsWhenQuestionsChange() {
        let session = makeSession()
        let q1 = DecisionQuestion.yesNo("Needs payment?")
        session.questions = [q1]
        session.add(pasted: "Invoice A due tomorrow")
        session.add(pasted: "Invoice B paid")
        session.add(pasted: "Invoice C overdue")
        let docs = session.documents
        XCTAssertEqual(docs.count, 3)

        let yesAnswer = DecisionAnswer(kind: .yesNo, probabilities: [0.92, 0.08], index: 0, confidence: 0.92)
        // Doc 0 done, doc 1 failed, doc 2 not yet run.
        session.setOutcomesForTesting([
            docs[0].id: [.done(answers: [yesAnswer], fractionRead: 1, seconds: 1.2)],
            docs[1].id: [.failed("Stopped")],
        ], asked: [q1])

        XCTAssertTrue(session.canResume)
        XCTAssertEqual(session.remainingDocuments.map(\.id), [docs[1].id, docs[2].id])

        // Changing questions invalidates resume so every document is answered against the new set.
        session.questions = [q1, DecisionQuestion.yesNo("Has late fee?")]
        XCTAssertFalse(session.canResume)
        XCTAssertEqual(session.remainingDocuments.count, 3)
    }

    func testMultiPartCSVUpdatesWhenLaterPartFinishesAndQuotesCommas() throws {
        let session = makeSession()
        let q = DecisionQuestion.yesNo("Pay money, soon?")
        session.questions = [q]
        session.add(pasted: "Lease, \"North\" wing")
        let doc = try XCTUnwrap(session.documents.first)

        let unsureNo = DecisionAnswer(kind: .yesNo, probabilities: [0.45, 0.55], index: 1, confidence: 0.55)
        let sureYes = DecisionAnswer(kind: .yesNo, probabilities: [0.96, 0.04], index: 0, confidence: 0.96)

        // Part 1 only: unsure No.
        session.setOutcomesForTesting([
            doc.id: [.done(answers: [unsureNo], fractionRead: 1, seconds: 1.0)],
        ], asked: [q])
        let firstCSV = try String(contentsOf: try XCTUnwrap(session.csvFileURL()), encoding: .utf8)
        XCTAssertTrue(firstCSV.contains("\"Pay money, soon?\""), "header quotes comma")
        XCTAssertTrue(firstCSV.contains("\"Lease, \"\"North\"\" wing\""), "document name escapes quotes")
        XCTAssertTrue(firstCSV.contains("No 55%"))

        // Part 2 completes on the same document key: outcomes.count stays 1, but CSV updates to Part 2's sure Yes.
        session.setOutcomesForTesting([
            doc.id: [
                .done(answers: [unsureNo], fractionRead: 1, seconds: 1.0),
                .done(answers: [sureYes], fractionRead: 1, seconds: 1.1),
            ],
        ], asked: [q])
        let updatedCSV = try String(contentsOf: try XCTUnwrap(session.csvFileURL()), encoding: .utf8)
        XCTAssertTrue(updatedCSV.contains("Yes 96% (part 2 of 2)"), updatedCSV)
    }

    func testHandoffToChatAttachesCSVInWorkMode() throws {
        let session = makeSession()
        let q = DecisionQuestion.yesNo("Needs action?")
        session.questions = [q]
        session.add(pasted: "Electric bill 82 EUR")
        let doc = try XCTUnwrap(session.documents.first)
        let yes = DecisionAnswer(kind: .yesNo, probabilities: [0.95, 0.05], index: 0, confidence: 0.95)
        session.setOutcomesForTesting([doc.id: [.done(answers: [yes], fractionRead: 1, seconds: 0.8)]], asked: [q])

        let chat = LocalChat(transcript: folder.appendingPathComponent("chat/chat.json"))
        _ = chat.setChatMode(.chat)
        XCTAssertEqual(chat.chatMode, .chat)

        XCTAssertTrue(session.handoffToChat(chat))
        XCTAssertEqual(chat.chatMode, .work)
        XCTAssertEqual(chat.incomingDraftPrompt, "Summarize these Decide results and highlight what needs my attention.")
        let csvURL = try XCTUnwrap(chat.incomingSharedFileURL)
        let content = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Electric bill 82 EUR"))
        XCTAssertTrue(content.contains("Yes 95%"))
    }
}
