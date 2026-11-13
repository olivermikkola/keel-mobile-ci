import Foundation

/// Errors that can occur during text recognition.
public enum TextRecognitionError: Error, LocalizedError, Equatable, Sendable {
    case emptyData
    case invalidImage
    case lowResolution(width: Int, height: Int)
    case noTextDetected
    case recognitionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyData:
            return "Image data is empty."
        case .invalidImage:
            return "The file is not a supported or valid image."
        case .lowResolution(let w, let h):
            return "Image resolution is too low for text recognition (\(w)×\(h))."
        case .noTextDetected:
            return "No text could be recognized in the image."
        case .recognitionFailed(let message):
            return "Text recognition failed: \(message)"
        case .cancelled:
            return "Text recognition was cancelled."
        }
    }
}

/// Options to guide text recognition.
public struct TextRecognitionOptions: Equatable, Sendable {
    public var languages: [String]
    public var usesLanguageCorrection: Bool
    public var minimumConfidence: Float
    public var maxDimension: Int

    public init(
        languages: [String] = [],
        usesLanguageCorrection: Bool = true,
        minimumConfidence: Float = 0.3,
        maxDimension: Int = 2_560
    ) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumConfidence = minimumConfidence
        self.maxDimension = maxDimension
    }
}

/// Platform-agnostic contract for converting image data into recognized text.
public protocol TextRecognizer: Sendable {
    func recognizeText(from imageData: Data, options: TextRecognitionOptions) async throws -> String
}

public extension TextRecognizer {
    func recognizeText(from imageData: Data) async throws -> String {
        try await recognizeText(from: imageData, options: TextRecognitionOptions())
    }
}

/// A configurable mock text recognizer for Linux `swift test` suites, SwiftUI previews, and testing.
public final class MockTextRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var stubbedText: String?
    private var stubbedError: Error?
    private var handler: (@Sendable (Data, TextRecognitionOptions) throws -> String)?
    private var invocations: [Data] = []
    private var optionsInvocations: [TextRecognitionOptions] = []
    public var simulatedDelayNanoseconds: UInt64 = 0

    public init(stubbedText: String? = nil, stubbedError: TextRecognitionError? = nil) {
        self.stubbedText = stubbedText
        self.stubbedError = stubbedError
    }

    public init(cannedText: String? = nil, simulatedError: Error? = nil, simulatedDelaySeconds: Double = 0) {
        self.stubbedText = cannedText
        self.stubbedError = simulatedError
        self.simulatedDelayNanoseconds = UInt64(simulatedDelaySeconds * 1_000_000_000)
    }

    public init(handler: @escaping @Sendable (Data, TextRecognitionOptions) throws -> String) {
        self.handler = handler
    }

    public func setStub(text: String) {
        lock.lock(); defer { lock.unlock() }
        self.stubbedText = text
        self.stubbedError = nil
    }

    public func setStub(error: Error) {
        lock.lock(); defer { lock.unlock() }
        self.stubbedError = error
        self.stubbedText = nil
    }

    public var recordedInvocations: [Data] {
        lock.lock(); defer { lock.unlock() }
        return invocations
    }

    public var recordedOptions: [TextRecognitionOptions] {
        lock.lock(); defer { lock.unlock() }
        return optionsInvocations
    }

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return invocations.count
    }

    private func recordAndGetState(data: Data, options: TextRecognitionOptions) -> (String?, Error?, (@Sendable (Data, TextRecognitionOptions) throws -> String)?) {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(data)
        optionsInvocations.append(options)
        return (stubbedText, stubbedError, handler)
    }

    public func recognizeText(from imageData: Data, options: TextRecognitionOptions) async throws -> String {
        if simulatedDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)
        }
        try Task.checkCancellation()

        let (currentStubbedText, currentStubbedError, currentHandler) = recordAndGetState(data: imageData, options: options)

        guard !imageData.isEmpty else {
            throw TextRecognitionError.emptyData
        }

        if let currentHandler {
            return try currentHandler(imageData, options)
        }

        if let currentStubbedError {
            throw currentStubbedError
        }

        if let currentStubbedText {
            guard !currentStubbedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextRecognitionError.noTextDetected
            }
            return currentStubbedText
        }

        if let marker = String(data: imageData, encoding: .utf8) {
            switch marker {
            case "INVALID_IMAGE":
                throw TextRecognitionError.invalidImage
            case "LOW_RES":
                throw TextRecognitionError.lowResolution(width: 16, height: 16)
            case "BLANK_IMAGE":
                throw TextRecognitionError.noTextDetected
            case "FAIL_INTERNAL":
                throw TextRecognitionError.recognitionFailed("Simulated Vision engine failure")
            default:
                if marker.hasPrefix("TEXT:") {
                    let content = String(marker.dropFirst(5))
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TextRecognitionError.noTextDetected
                    }
                    return content
                }
            }
        }

        return "Recognized text from \(imageData.count) bytes of image data."
    }
}
