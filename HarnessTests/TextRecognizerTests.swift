import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class TextRecognizerTests: XCTestCase {
    func testRecognizeTextReturnsStubbedText() async throws {
        let recognizer = MockTextRecognizer(stubbedText: "Hello World\nLine 2")
        let text = try await recognizer.recognizeText(from: Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(text, "Hello World\nLine 2")
        XCTAssertEqual(recognizer.callCount, 1)
    }

    func testEmptyDataThrowsError() async {
        let recognizer = MockTextRecognizer(stubbedText: "Should not be returned")
        do {
            _ = try await recognizer.recognizeText(from: Data())
            XCTFail("Expected emptyData error")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .emptyData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSentinelMarkersSimulateErrors() async {
        let recognizer = MockTextRecognizer()

        // Invalid image
        do {
            _ = try await recognizer.recognizeText(from: Data("INVALID_IMAGE".utf8))
            XCTFail("Expected invalidImage error")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .invalidImage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Low resolution
        do {
            _ = try await recognizer.recognizeText(from: Data("LOW_RES".utf8))
            XCTFail("Expected lowResolution error")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .lowResolution(width: 16, height: 16))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Blank image / no text
        do {
            _ = try await recognizer.recognizeText(from: Data("BLANK_IMAGE".utf8))
            XCTFail("Expected noTextDetected error")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .noTextDetected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Internal engine failure
        do {
            _ = try await recognizer.recognizeText(from: Data("FAIL_INTERNAL".utf8))
            XCTFail("Expected recognitionFailed error")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .recognitionFailed("Simulated Vision engine failure"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCustomHandlerExecution() async throws {
        let recognizer = MockTextRecognizer { data, options in
            XCTAssertEqual(options.minimumConfidence, 0.5)
            return "Custom: \(data.count) bytes"
        }
        let options = TextRecognitionOptions(minimumConfidence: 0.5)
        let result = try await recognizer.recognizeText(from: Data([0xAA, 0xBB]), options: options)
        XCTAssertEqual(result, "Custom: 2 bytes")
    }

    func testConcurrentCallsAreThreadSafe() async throws {
        let recognizer = MockTextRecognizer()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let data = Data("TEXT:Worker \(i)".utf8)
                    let text = try? await recognizer.recognizeText(from: data)
                    XCTAssertEqual(text, "Worker \(i)")
                }
            }
        }
        XCTAssertEqual(recognizer.callCount, 20)
    }

    func testZeroTextThrowsNoTextDetected() async {
        let recognizer = MockTextRecognizer(stubbedText: "   \n  \t  ")
        do {
            _ = try await recognizer.recognizeText(from: Data([0x01]))
            XCTFail("Expected noTextDetected error for whitespace-only text")
        } catch let error as TextRecognitionError {
            XCTAssertEqual(error, .noTextDetected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
