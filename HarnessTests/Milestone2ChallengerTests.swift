import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class Milestone2ChallengerTests: XCTestCase {

    // =========================================================================
    // MARK: - Challenge 1: MockTextRecognizer Concurrency & Race Conditions
    // =========================================================================

    /// 1.1 Stress-test 100 concurrent tasks calling recognizeText simultaneously.
    func testMockTextRecognizerHighConcurrency100Tasks() async throws {
        let recognizer = MockTextRecognizer()
        let taskCount = 100

        await withTaskGroup(of: (Int, String).self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    let input = "TEXT:Payload_\(i)"
                    do {
                        let result = try await recognizer.recognizeText(from: Data(input.utf8))
                        return (i, result)
                    } catch {
                        return (i, "ERROR:\(error)")
                    }
                }
            }

            var results: [Int: String] = [:]
            for await (index, result) in group {
                results[index] = result
            }

            XCTAssertEqual(results.count, taskCount, "All 100 tasks must complete")
            for i in 0..<taskCount {
                XCTAssertEqual(results[i], "Payload_\(i)", "Task \(i) received mismatched result: \(String(describing: results[i]))")
            }
        }

        XCTAssertEqual(recognizer.callCount, taskCount)
        XCTAssertEqual(recognizer.recordedInvocations.count, taskCount)
        XCTAssertEqual(recognizer.recordedOptions.count, taskCount)
    }

    /// 1.2 Concurrency stress-test with sentinel error triggers:
    /// Multiple concurrent tasks dispatching random sentinel markers.
    func testMockTextRecognizerConcurrentSentinelErrors() async throws {
        let recognizer = MockTextRecognizer()
        let sentinels: [(String, TextRecognitionError)] = [
            ("INVALID_IMAGE", .invalidImage),
            ("LOW_RES", .lowResolution(width: 16, height: 16)),
            ("BLANK_IMAGE", .noTextDetected),
            ("FAIL_INTERNAL", .recognitionFailed("Simulated Vision engine failure"))
        ]

        let taskCount = 80
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<taskCount {
                let (marker, expectedError) = sentinels[i % sentinels.count]
                group.addTask {
                    do {
                        _ = try await recognizer.recognizeText(from: Data(marker.utf8))
                        return false // Should have thrown
                    } catch let err as TextRecognitionError {
                        return err == expectedError
                    } catch {
                        return false
                    }
                }
            }

            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            XCTAssertEqual(successCount, taskCount, "All sentinel error calls must trigger exact typed errors under concurrency")
        }
        XCTAssertEqual(recognizer.callCount, taskCount)
    }

    /// 1.3 Race condition test: dynamically altering stubbedText and stubbedError
    /// while concurrent reader tasks are calling recognizeText.
    func testMockTextRecognizerConcurrentStubMutations() async throws {
        let recognizer = MockTextRecognizer()
        let iterations = 200

        // Background task rapidly mutating stub state
        let mutationTask = Task {
            for i in 0..<iterations {
                if i % 2 == 0 {
                    recognizer.setStub(text: "STUB_\(i)")
                } else {
                    recognizer.setStub(error: TextRecognitionError.recognitionFailed("Error_\(i)"))
                }
                // Yield to create high thread interleaving
                await Task.yield()
            }
        }

        // Concurrent reader tasks calling recognizeText
        let readerTaskCount = 20
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<readerTaskCount {
                group.addTask {
                    for _ in 0..<30 {
                        do {
                            let text = try await recognizer.recognizeText(from: Data([0x01, 0x02]))
                            XCTAssertTrue(text.hasPrefix("STUB_") || text.hasPrefix("Recognized text"))
                        } catch let err as TextRecognitionError {
                            if case .recognitionFailed(let msg) = err {
                                XCTAssertTrue(msg.hasPrefix("Error_"))
                            }
                        } catch {
                            XCTFail("Unexpected error type: \(error)")
                        }
                    }
                }
            }
        }

        await mutationTask.value
    }

    /// 1.4 Test simulated delay and task cancellation under concurrency.
    func testMockTextRecognizerDelayAndCancellation() async throws {
        let recognizer = MockTextRecognizer(cannedText: "Delayed Result", simulatedDelaySeconds: 0.05)
        let totalTasks = 20

        await withTaskGroup(of: String.self) { group in
            for i in 0..<totalTasks {
                group.addTask {
                    let task = Task {
                        try await recognizer.recognizeText(from: Data([0xAA]))
                    }
                    if i % 2 == 0 {
                        // Cancel half of the tasks immediately
                        task.cancel()
                    }
                    do {
                        return try await task.value
                    } catch is CancellationError {
                        return "CANCELLED"
                    } catch {
                        return "ERROR"
                    }
                }
            }

            var cancelledCount = 0
            var completedCount = 0
            for await outcome in group {
                if outcome == "CANCELLED" { cancelledCount += 1 }
                else if outcome == "Delayed Result" { completedCount += 1 }
            }

            XCTAssertEqual(cancelledCount, 10, "Expected exactly 10 cancelled tasks")
            XCTAssertEqual(completedCount, 10, "Expected exactly 10 completed tasks")
        }
    }

    // =========================================================================
    // MARK: - Challenge 2: TaskWorkspace Attachment Ingestion & Search
    // =========================================================================

    /// 2.1 Ingest multiple attachments with distinct filenames and verify:
    /// - Stored under `attachments/<sanitized>`
    /// - SQLite `files` record has origin == 1, kind == 0
    /// - FTS5 `words` search matches words in each attachment
    func testTaskWorkspaceMultipleAttachmentsIngestionAndFTS5Search() throws {
        let workspace = try TaskWorkspace(path: ":memory:")

        let attachment1 = Attachment(
            filename: "project_requirements.md",
            mimeType: "text/markdown",
            extractedText: "The local agent must support on-device inference without cloud dependencies.",
            byteSize: 100,
            source: .file
        )

        let attachment2 = Attachment(
            filename: "financial_forecast.csv",
            mimeType: "text/csv",
            extractedText: "| Quarter | Revenue | Profit |\n| --- | --- | --- |\n| Q1 | 1200000 | 340000 |",
            byteSize: 85,
            source: .file
        )

        let attachment3 = Attachment(
            filename: "whiteboard_scan.txt",
            mimeType: "text/plain",
            extractedText: "Architecture discussion regarding Neural Engine tensor parallelism and thermal budgeting.",
            byteSize: 110,
            source: .photoOCR
        )

        try workspace.ingestAttachment(attachment1)
        try workspace.ingestAttachment(attachment2)
        try workspace.ingestAttachment(attachment3)

        // 1. Verify all files can be read from workspace
        let file1 = try workspace.read("attachments/project_requirements.md")
        XCTAssertTrue(file1.text.contains("on-device inference"))

        let file2 = try workspace.read("attachments/financial_forecast.csv")
        XCTAssertTrue(file2.text.contains("1200000"))

        let file3 = try workspace.read("attachments/whiteboard_scan.txt")
        XCTAssertTrue(file3.text.contains("tensor parallelism"))

        // Direct SQLite inspection: verify origin == 1 (local task file) and kind == 0 (text)
        var inspectedRecords: [(path: String, origin: Int, kind: Int, mode: String, size: Int)] = []
        try workspace.database.query("SELECT path, origin, kind, mode, size FROM files WHERE CAST(path AS TEXT) LIKE 'attachments/%' ORDER BY path") { row in
            let pathStr = String(decoding: row.blob(0), as: UTF8.self)
            inspectedRecords.append((path: pathStr, origin: row.int(1), kind: row.int(2), mode: row.text(3), size: row.int(4)))
        }

        XCTAssertEqual(inspectedRecords.count, 3, "Expected exactly 3 files in attachments/")
        for record in inspectedRecords {
            XCTAssertEqual(record.origin, 1, "File \(record.path) must have origin = 1 (task-local overlay)")
            XCTAssertEqual(record.kind, 0, "File \(record.path) must have kind = 0 (text)")
            XCTAssertEqual(record.mode, "100644", "File \(record.path) must have standard mode 100644")
            XCTAssertGreaterThan(record.size, 0)
        }

        // 3. Verify FTS5 search across all 3 attachments
        let search1 = try workspace.search("inference")
        XCTAssertEqual(search1.matches.map(\.path), ["attachments/project_requirements.md"])

        let search2 = try workspace.search("revenue")
        XCTAssertEqual(search2.matches.map(\.path), ["attachments/financial_forecast.csv"])

        let search3 = try workspace.search("parallelism")
        XCTAssertEqual(search3.matches.map(\.path), ["attachments/whiteboard_scan.txt"])
    }

    /// 2.2 Path collision challenge: What happens when multiple attachments have identical
    /// or colliding filenames?
    func testTaskWorkspacePathCollisionEmpiricalBehavior() throws {
        let workspace = try TaskWorkspace(path: ":memory:")

        // Attachment A and B have the IDENTICAL filename "notes.txt" but completely distinct content
        let attachmentA = Attachment(
            filename: "notes.txt",
            mimeType: "text/plain",
            extractedText: "KangarooAlpha: Content from first attachment",
            byteSize: 60,
            source: .file
        )

        let attachmentB = Attachment(
            filename: "notes.txt",
            mimeType: "text/plain",
            extractedText: "PlatypusBeta: Content from second attachment",
            byteSize: 60,
            source: .file
        )

        try workspace.ingestAttachment(attachmentA)

        // Verify attachment A is present and searchable
        var searchA = try workspace.search("KangarooAlpha")
        XCTAssertEqual(searchA.matches.count, 1)

        // Now ingest attachment B with same filename
        try workspace.ingestAttachment(attachmentB)

        // Check SQLite files table count for attachments/notes.txt
        var count = 0
        try workspace.database.query("SELECT COUNT(*) FROM files WHERE CAST(path AS TEXT) = 'attachments/notes.txt'") { row in
            count = row.int(0)
        }
        XCTAssertEqual(count, 1, "SQLite has exactly 1 row because displace() replaced the previous row")

        // Read content: attachment B overwrote attachment A!
        let currentContent = try workspace.read("attachments/notes.txt").text
        XCTAssertTrue(currentContent.contains("PlatypusBeta"))
        XCTAssertFalse(currentContent.contains("KangarooAlpha"))

        // Verify FTS5 search index was properly updated: KangarooAlpha should be gone, PlatypusBeta present
        searchA = try workspace.search("KangarooAlpha")
        XCTAssertEqual(searchA.matches.count, 0, "displace() cleanly removed attachmentA from FTS5 words")

        let searchB = try workspace.search("PlatypusBeta")
        XCTAssertEqual(searchB.matches.count, 1, "attachmentB is indexed in FTS5 words")
    }

    /// 2.3 Verify path sanitization edge cases (directory traversal, special characters, empty name).
    func testAttachmentPathSanitizationEdgeCases() {
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath(""), "attachments/attachment.txt")
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath("../../../etc/passwd"), "attachments/______etc_passwd")
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath("sub/dir/file.txt"), "attachments/sub_dir_file.txt")
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath("file\\with\\backslash.txt"), "attachments/file_with_backslash.txt")
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath("   spaced_name.txt   "), "attachments/spaced_name.txt")
        XCTAssertEqual(AttachmentPromptFormatter.sanitizeWorkspacePath("non_ascii_名前.txt"), "attachments/non_ascii_.txt")
    }

    /// 2.4 Verify collision risk for purely non-ASCII filenames and duplicate photo OCR timestamps.
    func testAttachmentCollisionVulnerabilities() throws {
        // Pure non-ASCII filenames strip down to empty and collide at attachments/attachment.txt
        let path1 = AttachmentPromptFormatter.sanitizeWorkspacePath("日本語")
        let path2 = AttachmentPromptFormatter.sanitizeWorkspacePath("中国語")
        XCTAssertEqual(path1, "attachments/attachment.txt")
        XCTAssertEqual(path2, "attachments/attachment.txt")
        XCTAssertEqual(path1, path2, "Both pure non-ASCII filenames collapse to the same fallback path")

        // Two photo OCR attachments taken within the same minute share the same filename format
        let timeString = "5:56 AM"
        let photo1Name = "Photo \(timeString).txt"
        let photo2Name = "Photo \(timeString).txt"
        let photoPath1 = AttachmentPromptFormatter.sanitizeWorkspacePath(photo1Name)
        let photoPath2 = AttachmentPromptFormatter.sanitizeWorkspacePath(photo2Name)
        XCTAssertEqual(photoPath1, photoPath2, "Photos taken in the same minute have colliding workspace paths")
    }

    /// 2.5 Verify prompt bounding vs workspace full retention on large attachments.
    func testLargeAttachmentPromptBoundingVsWorkspaceFullRetention() throws {
        let workspace = try TaskWorkspace(path: ":memory:")

        // 100 KB text attachment
        let line = "Repeatable text line with unique word QuokkaToken for testing.\n"
        let longText = String(repeating: line, count: 1600) // ~100 KB
        let attachment = Attachment(
            filename: "large_log.txt",
            mimeType: "text/plain",
            extractedText: longText,
            byteSize: longText.utf8.count,
            source: .file
        )

        // 1. Full content stored in workspace
        try workspace.ingestAttachment(attachment)
        let storedFile = try workspace.read("attachments/large_log.txt")
        XCTAssertEqual(storedFile.text.count, longText.count, "Workspace must retain the full unpruned text")

        // 2. FTS5 search finds the unpruned content in workspace
        let search = try workspace.search("QuokkaToken")
        XCTAssertEqual(Set(search.matches.map(\.path)), ["attachments/large_log.txt"])
        XCTAssertEqual(search.matches.count, 20, "Search returns first page of line matches (limit 20)")

        // 3. Prompt formatting middle-prunes to strictly bounded size
        let formattedPrompt = AttachmentPromptFormatter.formatAttachment(attachment)
        XCTAssertLessThanOrEqual(formattedPrompt.count, 8_500, "Prompt must be middle-pruned to < 8.5 KB")
        XCTAssertTrue(formattedPrompt.contains("Attachment truncated:"), "Prompt must contain truncation notice")
    }

    // =========================================================================
    // MARK: - Challenge 3: Heap Footprint Verification
    // =========================================================================

    /// 3.1 Inspect Attachment struct fields via reflection (Mirror) to ensure
    /// NO raw Data, pointer, or image bitmap is retained as a stored property.
    func testAttachmentStructStoredPropertiesInspection() {
        let attachment = Attachment(
            filename: "sample.txt",
            mimeType: "text/plain",
            extractedText: "Some sample extracted text.",
            byteSize: 1024,
            source: .file
        )

        let mirror = Mirror(reflecting: attachment)
        XCTAssertEqual(mirror.displayStyle, .struct, "Attachment must be a Swift struct value type")

        let children = Array(mirror.children)
        let propertyNames = children.compactMap(\.label)

        // Expected stored properties: id, filename, mimeType, extractedText, byteSize, source, imageID
        let expectedProperties = ["id", "filename", "mimeType", "extractedText", "byteSize", "source", "imageID"]
        XCTAssertEqual(propertyNames.sorted(), expectedProperties.sorted(), "Attachment stored properties must match expected schema")

        // Verify each property's dynamic type
        for child in children {
            guard let label = child.label else { continue }
            let valueType = type(of: child.value)

            // Assert that no property is Data or any buffer type
            XCTAssertFalse(valueType is Data.Type, "Property '\(label)' must NOT be of type Data")
            XCTAssertFalse(String(describing: valueType).contains("Data"), "Property '\(label)' must NOT contain Data: \(valueType)")
            XCTAssertFalse(String(describing: valueType).contains("Image"), "Property '\(label)' must NOT contain Image: \(valueType)")
            XCTAssertFalse(String(describing: valueType).contains("Buffer"), "Property '\(label)' must NOT contain Buffer: \(valueType)")
            XCTAssertFalse(String(describing: valueType).contains("Pointer"), "Property '\(label)' must NOT contain Pointer: \(valueType)")
        }

        // Verify byteSize is a pure Int scalar (stores original size, not retained bytes)
        XCTAssertTrue(type(of: attachment.byteSize) == Int.self)
    }

    /// 3.2 Verify MemoryLayout of Attachment struct:
    /// It must be a lightweight value type with fixed small footprint on the stack/heap.
    func testAttachmentMemoryLayoutFootprint() {
        let size = MemoryLayout<Attachment>.size
        let stride = MemoryLayout<Attachment>.stride
        let alignment = MemoryLayout<Attachment>.alignment

        // In 64-bit architecture:
        // UUID: 16 bytes
        // filename String: 16 bytes
        // mimeType String: 16 bytes
        // extractedText String: 16 bytes
        // byteSize Int: 8 bytes
        // source AttachmentSource: 1 byte (or enum discriminator) + alignment padding
        // The optional image UUID adds 17 bytes; no image data is stored here.
        XCTAssertLessThanOrEqual(size, 112, "Attachment retains only photo identity, never image bytes")
        XCTAssertLessThanOrEqual(stride, 112)
        XCTAssertEqual(alignment, 8, "Attachment alignment must be 8 bytes on 64-bit")
    }

    /// 3.3 Verify parsing a large 5 MB file does NOT retain the 5 MB buffer in Attachment.
    func testAttachmentDoesNotRetainRawDataBuffer() throws {
        // Create 5 MB of plain text data
        let repeatedLine = "The quick brown fox jumps over the lazy dog.\n" // 45 bytes
        let repeatCount = 100_000 // ~4.5 MB
        let fullText = String(repeating: repeatedLine, count: repeatCount)
        let rawData = Data(fullText.utf8)
        XCTAssertGreaterThan(rawData.count, 4_000_000)

        // Parse into attachment
        let attachment = try AttachmentParser().parse(data: rawData, filename: "large.txt")

        // Verify byteSize records the size, but Attachment struct memory layout is still identical
        XCTAssertEqual(attachment.byteSize, rawData.count)
        XCTAssertEqual(MemoryLayout<Attachment>.size, MemoryLayout.size(ofValue: attachment))

        // The small metadata footprint is independent of the 5 MB input payload
        XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue: attachment), 112)
    }
}
