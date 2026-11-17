import XCTest
@testable import KeelMobile

/// Search by meaning with a real embedding model (all-MiniLM-L6-v2, the small
/// English test fixture) through the same runtime and index the app uses.
final class RecallSearchTests: XCTestCase {
    private func model() throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "all-MiniLM-L6-v2-Q4_K_M", withExtension: "gguf", subdirectory: "fixtures")).path
    }

    private let documents = [
        Recall.Document(id: "file:trip", source: "File plan.md from chat \"Trip\"",
                        text: "The train tickets to Tampere are in the blue folder on the desk.\nThe hotel is booked for two nights."),
        Recall.Document(id: "file:food", source: "File dinner.md from chat \"Cooking\"",
                        text: "Recipe: boil the potatoes for twenty minutes and add dill."),
        Recall.Document(id: "chat:code", source: "Chat \"Parser\"",
                        text: "User: why does parse return an empty array\nKeel: The function returns before reading its input."),
    ]

    func testVectorsAreNormalizedAndTheRightPassageIsClosest() async throws {
        let runtime = EmbeddingRuntime()
        let texts = ["where did I put the train tickets"] + documents.map(\.text)
        let vectors = try await runtime.embed(texts, modelPath: try model())
        XCTAssertEqual(vectors.count, 4)
        XCTAssertEqual(vectors[0].count, 384)
        for vector in vectors {
            XCTAssertEqual(vector.reduce(Float(0)) { $0 + $1 * $1 }, 1, accuracy: 1e-3)
        }
        let scores = vectors.dropFirst().map { passage in zip(vectors[0], passage).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        XCTAssertGreaterThan(scores[0], 0.4, "\(scores)")
        XCTAssertGreaterThan(scores[0], scores[1] + 0.2, "\(scores)")
        XCTAssertGreaterThan(scores[0], scores[2] + 0.2, "\(scores)")
        print("Embedding fixture scores for the train-ticket question: \(scores)")
    }

    func testASearchFindsTheFileByMeaningAndReusesItsSavedVectors() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("vectors.plist")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let path = try model()
        let first = RecallIndex(cacheURL: cache)
        let indexed = Counter()
        let found = try await first.search("where did I put the train tickets", documents: documents, model: .miniLM, modelPath: path,
                                           progress: { _, _ in indexed.add() })
        XCTAssertTrue(found.contains("[1] File plan.md from chat \"Trip\""), found)
        XCTAssertTrue(found.contains("blue folder"), found)
        XCTAssertFalse(found.contains("potatoes"), "An unrelated passage stays under the minimum score: \(found)")
        XCTAssertEqual(indexed.value, 3, "One passage per document was read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        // A new index over the same file: nothing is read again.
        let second = RecallIndex(cacheURL: cache)
        let again = Counter()
        let cooking = try await second.search("how long do I cook the potatoes", documents: documents, model: .miniLM, modelPath: path,
                                              progress: { _, _ in again.add() })
        XCTAssertEqual(again.value, 0)
        XCTAssertTrue(cooking.contains("[1] File dinner.md from chat \"Cooking\""), cooking)

        let nothing = try await second.search("quarterly tax filing deadline", documents: documents, model: .miniLM, modelPath: path)
        XCTAssertTrue(nothing.hasPrefix("No passage in 3 matched"), nothing)
        let empty = try await second.search("anything", documents: [], model: .miniLM, modelPath: path)
        XCTAssertTrue(empty.hasPrefix("Nothing to search yet"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
