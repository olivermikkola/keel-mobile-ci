import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// What the phone itself finds in each photo for the Videos screen, so the
/// model that writes the lines knows what it is talking about: the strongest
/// scene labels from Apple's on-device classifier and any text in the photo.
/// No model download; a fraction of a second a photo, on any iPhone.
enum VideoPhotoNotes {
    /// Labels weaker than this are left out.
    static let minimumConfidence: Float = 0.3

    static func notes(for photos: [URL], text: any TextRecognizer = VisionTextRecognizer()) async -> [String] {
        var notes: [String] = []
        for url in photos {
            guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { notes.append(""); continue }
            let words = (try? await text.recognizeText(from: data)) ?? ""
            notes.append(VideoScript.note(labels: await labels(data), text: words))
        }
        return notes
    }

    static func labels(_ data: Data) async -> [String] {
        #if canImport(Vision)
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(data: data, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? [])
                .filter { $0.confidence >= minimumConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(3)
                .map(\.identifier)
        }.value
        #else
        return []
        #endif
    }
}
