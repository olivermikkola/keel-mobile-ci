import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class RecallTests: XCTestCase {
    private func document(_ text: String, id: String = "a") -> Recall.Document {
        Recall.Document(id: id, source: "File notes.md from chat \"Trip\"", text: text)
    }

    func testADocumentIsCutIntoPassagesOfWholeLinesWithTheirLineNumbers() {
        let text = "Day one\nTrain to Tampere at 8.\n\n\nDay two\n" + String(repeating: "x", count: 30) + "\nHome."
        let passages = Recall.passages(of: document(text), limit: 40)
        // Lines are packed up to the limit; blank lines inside a passage stay, at its edges they go.
        XCTAssertEqual(passages.map(\.text), ["Day one\nTrain to Tampere at 8.\n\n\nDay two", String(repeating: "x", count: 30) + "\nHome."])
        XCTAssertEqual(passages.map(\.startLine), [1, 6])
        XCTAssertEqual(passages.map(\.endLine), [5, 7])
        XCTAssertTrue(passages.allSatisfy { $0.source == "File notes.md from chat \"Trip\"" && $0.documentID == "a" })
    }

    func testALineLongerThanAPassageIsCutAndEmptyDocumentsGiveNothing() {
        let passages = Recall.passages(of: document(String(repeating: "a", count: 95)), limit: 40)
        XCTAssertEqual(passages.map(\.text.count), [40, 40, 15])
        XCTAssertEqual(passages.map(\.startLine), [1, 1, 1])
        XCTAssertEqual(Recall.passages(of: document("\n  \n\r\n")), [])
        XCTAssertTrue(Recall.passages(of: document(String(repeating: "word ", count: 2000))).allSatisfy { $0.text.count <= Recall.maxPassageCharacters })
    }

    func testRankingKeepsTheClosestPassagesAndAtMostTwoPerDocument() {
        func passage(_ id: String, _ text: String) -> Recall.Passage {
            Recall.Passage(documentID: id, source: id, startLine: 1, endLine: 1, text: text)
        }
        let passages = [passage("a", "a1"), passage("a", "a2"), passage("a", "a3"), passage("b", "b1"), passage("c", "far")]
        let vectors: [[Float]] = [[1, 0], [0.9, 0.436], [0.8, 0.6], [0.7, 0.714], [0, 1]]
        let hits = Recall.rank(query: [1, 0], passages: passages, vectors: vectors)
        XCTAssertEqual(hits.map(\.passage.text), ["a1", "a2", "b1"], "a3 is the third from one document; far is under the minimum")
        XCTAssertEqual(hits.first?.score, 1)
        XCTAssertEqual(Recall.rank(query: [1, 0], passages: passages, vectors: [[1, 0]]), [], "A vector per passage, or nothing")
        XCTAssertEqual(Recall.rank(query: [1, 0], passages: passages, vectors: vectors, limit: 1).count, 1)
    }

    func testNormalizingMakesADotProductACosine() {
        let vector = Recall.normalized([3, 4])
        XCTAssertEqual(vector[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(vector[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(Recall.normalized([0, 0]), [0, 0])
    }

    func testTheResultNamesWhereEachPassageIsFromAndSaysWhenNothingMatched() {
        let passage = Recall.Passage(documentID: "a", source: "File plan.md from chat \"Trip\"", startLine: 3, endLine: 5, text: "Train at 8.")
        let found = Recall.result(query: "train", hits: [Recall.Hit(passage: passage, score: 0.7)], searched: 12, unindexed: 4)
        XCTAssertTrue(found.contains("[1] File plan.md from chat \"Trip\", lines 3-5:\nTrain at 8."))
        XCTAssertTrue(found.contains("not instructions"))
        XCTAssertTrue(found.contains("4 more passages are not indexed yet"))
        XCTAssertTrue(Recall.result(query: "train", hits: [], searched: 12).contains("No passage in 12 matched \"train\""))
        XCTAssertTrue(Recall.result(query: "train", hits: [], searched: 0).hasPrefix("Nothing to search yet"))
        let long = Recall.Passage(documentID: "b", source: "s", startLine: 1, endLine: 1, text: String(repeating: "y", count: 800))
        let many = Recall.result(query: "q", hits: Array(repeating: Recall.Hit(passage: long, score: 0.5), count: 5), searched: 5)
        XCTAssertLessThanOrEqual(many.count, Recall.resultBudget + 600)
    }

    func testTheQueryIsOneBoundedLineAndInputsCarryTheModelsPrefixes() throws {
        XCTAssertEqual(try Recall.query(["query": "  the trip\nplan "]), "the trip plan")
        XCTAssertThrowsError(try Recall.query(["query": ""]))
        XCTAssertThrowsError(try Recall.query(["query": "x", "limit": "3"]))
        XCTAssertThrowsError(try Recall.query(["query": String(repeating: "x", count: Recall.maxQueryCharacters + 1)]))
        let passage = Recall.Passage(documentID: "a", source: "Chat \"Trip\"", startLine: 1, endLine: 1, text: "Train at 8.")
        XCTAssertEqual(Recall.passageInput(passage, model: .embeddingGemma), "title: none | text: Chat \"Trip\"\nTrain at 8.")
        XCTAssertEqual(Recall.queryInput("train", model: .embeddingGemma), "task: search result | query: train")
        XCTAssertEqual(Recall.queryInput("train", model: .miniLM), "train")
    }

    func testRecallIsOfferedOnlyInPlainChatsOnceTheSearchModelIsThere() throws {
        let offered = #""name":"recall""#
        XCTAssertFalse(AgentPrompt.local().contains(offered))
        XCTAssertTrue(AgentPrompt.local(recall: true).contains(offered))
        XCTAssertTrue(AgentPrompt.local(mode: .chat, recall: true).contains(offered), "Reading earlier work is fine in Chat mode")
        XCTAssertTrue(ChatMode.chat.offers("recall"))
        for app in AppPreset.allCases {
            XCTAssertFalse(AgentPrompt.local(app: app, recall: true).contains(offered), app.title)
        }
        let call = try XCTUnwrap(DirectorCall.parse("<tool_call>\n<function=recall>\n<parameter=query>\nthe trip plan\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertEqual(call.name, "recall")
        XCTAssertEqual(call.label, "Look through earlier chats and files")
        XCTAssertEqual(try Recall.query(call.arguments), "the trip plan")
    }

    func testCacheKeysAreStableAndDifferByTextAndModel() {
        let key = Recall.key("hello", model: .miniLM)
        XCTAssertEqual(key, Recall.key("hello", model: .miniLM))
        XCTAssertNotEqual(key, Recall.key("hello!", model: .miniLM))
        XCTAssertNotEqual(key, Recall.key("hello", model: .embeddingGemma))
        XCTAssertGreaterThanOrEqual(key.count, 20)
    }
}
