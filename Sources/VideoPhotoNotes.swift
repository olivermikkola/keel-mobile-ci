import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// What the phone itself finds in each photo for the Videos screen, so the
/// model that writes the lines knows what it is talking about: any dogs or
/// cats, the strongest scene labels from Apple's on-device classifier and any
/// text in the photo.
/// No model download; a fraction of a second a photo, on any iPhone.
enum VideoPhotoNotes {
    /// Labels weaker than this are left out.
    static let minimumConfidence: Float = 0.3

    static func notes(for photos: [URL], text: any TextRecognizer = VisionTextRecognizer()) async -> [String] {
        var notes: [String] = []
        for url in photos {
            guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { notes.append(""); continue }
            let words = (try? await text.recognizeText(from: data)) ?? ""
            notes.append(VideoScript.note(animals: await animals(data), labels: await labels(data), text: words))
        }
        return notes
    }

    /// "dog" and "cat" from Apple's animal detector, which finds a pet the
    /// scene classifier ranks below the furniture.
    static func animals(_ data: Data) async -> [String] {
        #if canImport(Vision)
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeAnimalsRequest()
            let handler = VNImageRequestHandler(data: data, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            var found: [String] = []
            for observation in request.results ?? [] {
                for label in observation.labels where label.confidence >= minimumConfidence {
                    let name = label.identifier.lowercased()
                    if !found.contains(name) { found.append(name) }
                }
            }
            return found
        }.value
        #else
        return []
        #endif
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
