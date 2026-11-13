import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Production iOS text recognition engine powered by Apple Vision (`VNRecognizeTextRequest`).
public final class VisionTextRecognizer: TextRecognizer, Sendable {
    public init() {}

    public func recognizeText(from imageData: Data, options: TextRecognitionOptions) async throws -> String {
        guard !imageData.isEmpty else {
            throw TextRecognitionError.emptyData
        }

        try Task.checkCancellation()

        #if canImport(Vision) && canImport(CoreGraphics)
        return try await Task.detached(priority: .userInitiated) { () -> String in
            try Task.checkCancellation()

            // 1. Inspect image properties without full bitmap decode using CGImageSource
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                throw TextRecognitionError.invalidImage
            }

            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
                throw TextRecognitionError.invalidImage
            }

            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

            // 2. Minimum resolution guard (32x32)
            guard width >= 32 && height >= 32 else {
                throw TextRecognitionError.lowResolution(width: width, height: height)
            }

            // 3. Memory-bounded thumbnail decoding:
            // Downsample images exceeding maxDimension (e.g. 2560px) to limit memory to ~20 MB
            let maxDimension = options.maxDimension
            let longestEdge = max(width, height)
            let cgImage: CGImage?

            if longestEdge > maxDimension {
                let downsampleOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension
                ]
                cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary)
            } else {
                cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary)
            }

            guard let image = cgImage else {
                throw TextRecognitionError.invalidImage
            }

            // 4. Perform Vision OCR within an isolated autoreleasepool to flush memory immediately
            var recognizedLines: [String] = []

            try autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = options.usesLanguageCorrection
                if !options.languages.isEmpty {
                    request.recognitionLanguages = options.languages
                }
                if #available(iOS 16.0, macOS 13.0, *) {
                    request.revision = VNRecognizeTextRequestRevision3
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    throw TextRecognitionError.recognitionFailed(error.localizedDescription)
                }

                guard let observations = request.results, !observations.isEmpty else {
                    return
                }

                // 5. Spatial sort: Top-to-bottom, left-to-right reading order
                // Note: Vision normalized coordinates have (0, 0) at BOTTOM-LEFT.
                let sorted = observations.sorted { a, b in
                    let yDelta = abs(a.boundingBox.origin.y - b.boundingBox.origin.y)
                    if yDelta > 0.02 {
                        return a.boundingBox.origin.y > b.boundingBox.origin.y
                    } else {
                        return a.boundingBox.origin.x < b.boundingBox.origin.x
                    }
                }

                for observation in sorted {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    if candidate.confidence >= options.minimumConfidence {
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            recognizedLines.append(text)
                        }
                    }
                }
            }

            // 6. Zero-text validation
            guard !recognizedLines.isEmpty else {
                throw TextRecognitionError.noTextDetected
            }

            let result = recognizedLines.joined(separator: "\n")
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextRecognitionError.noTextDetected
            }

            return result
        }.value
        #else
        throw TextRecognitionError.recognitionFailed("Vision framework is unavailable on this platform.")
        #endif
    }
}
