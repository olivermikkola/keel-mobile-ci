import XCTest
@testable import KeelMobile

final class ArchiveWriterTests: XCTestCase {
    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("chat.json")
    }

    private func archive(_ title: String) -> SavedTasks {
        var archive = SavedTasks()
        archive.tasks[0].title = title
        archive.tasks[0].messages = [ChatMessage(role: "user", text: title)]
        return archive
    }

    private func title(at url: URL) throws -> String {
        try SavedTasks.load(try Data(contentsOf: url)).tasks[0].title
    }

    func testCheckpointCoalescesAndCriticalSaveWaitsForIt() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = ArchiveWriter(destination: url)
        writer.writeCheckpoint(archive("first"))
        writer.writeCheckpoint(archive("second"))
        writer.flush()
        XCTAssertEqual(try title(at: url), "second")

        XCTAssertTrue(writer.writeNow(archive("third")))
        XCTAssertEqual(try title(at: url), "third")
        XCTAssertNil(writer.error)
    }

    func testOlderCheckpointCannotOverwriteNewerCriticalSave() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = ArchiveWriter(destination: url)
        for index in 0..<100 {
            writer.writeCheckpoint(archive("old-\(index)"))
            XCTAssertTrue(writer.writeNow(archive("new-\(index)")))
            writer.flush()
            XCTAssertEqual(try title(at: url), "new-\(index)")
        }
        XCTAssertNil(writer.error)
        print("Archive proof: 100 interleaved streaming checkpoints and critical saves; the newest snapshot won every time.")
    }

    func testWriterCreatesParentDirectory() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = ArchiveWriter(destination: url)
        XCTAssertTrue(writer.writeNow(archive("created")))
        XCTAssertEqual(try title(at: url), "created")
    }
}
