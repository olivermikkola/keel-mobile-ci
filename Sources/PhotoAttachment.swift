import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoAttachment {
    /// Decode only a bounded thumbnail, rather than a full-resolution camera image.
    static func make(_ data: Data, filename: String = "Photo.jpg", directory: URL? = nil) throws -> Attachment {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: AttachmentLimits.maxImageDimension
              ] as CFDictionary) else { throw AttachmentError.extractionFailed("The photo could not be opened.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentError.extractionFailed("The photo could not be prepared.")
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= AttachmentLimits.maxImageBytes else {
            throw AttachmentError.fileTooLarge(bytes: output.length, limit: AttachmentLimits.maxImageBytes)
        }
        let id = UUID()
        let folder = directory ?? storageDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var privateFolder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try privateFolder.setResourceValues(values)
        try (output as Data).write(to: folder.appendingPathComponent(id.uuidString + ".jpg"), options: [.atomic, .completeFileProtection])
        return Attachment(filename: filename, mimeType: "image/jpeg", extractedText: "Photo pixels supplied to the vision model.",
                          byteSize: output.length, source: .photo, imageID: id)
    }
    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoInputs", isDirectory: true)
    }

    static func load(_ attachment: Attachment, directory: URL? = nil) throws -> Data? {
        guard let id = attachment.imageID else { return nil }
        let file = (directory ?? storageDirectory).appendingPathComponent(id.uuidString + ".jpg")
        guard let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= AttachmentLimits.maxImageBytes else {
            throw AttachmentError.extractionFailed("This saved photo is unavailable. Attach it again.")
        }
        return try Data(contentsOf: file)
    }

    static func discard(_ attachments: [Attachment], retaining: Set<UUID> = [], directory: URL? = nil) {
        let ids = Set(attachments.compactMap(\.imageID)).subtracting(retaining)
        for id in ids {
            let file = (directory ?? storageDirectory).appendingPathComponent(id.uuidString + ".jpg")
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Loads a file URL picked from Files or shared from another app ("Send to Keel").
/// Image files attach as pixels when the model sees images, or fall back to
/// on-device Vision text recognition on text-only models instead of failing as
/// binary files.
enum ImportedFileAttachment {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
    static let maxImageFileBytes = 32 * 1024 * 1024

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func ocrFilename(for filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "Photo" : stem) + ".txt"
    }

    static func load(
        from url: URL,
        hasVision: Bool,
        photoDirectory: URL? = nil,
        recognizer: (any TextRecognizer)? = nil,
        onOCRStart: @escaping @Sendable () -> Void = {}
    ) async throws -> Attachment {
        let isImage = isImageFile(url)
        let limit = isImage ? maxImageFileBytes : AttachmentLimits.maxFileSizeBytes
        let (filename, data) = try await Task.detached(priority: .userInitiated) { () throws -> (String, Data) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > limit {
                throw AttachmentError.fileTooLarge(bytes: bytes, limit: limit)
            }
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            return (url.lastPathComponent, data)
        }.value

        if isImage {
            if hasVision {
                return try await Task.detached(priority: .userInitiated) {
                    try PhotoAttachment.make(data, filename: filename, directory: photoDirectory)
                }.value
            }
            onOCRStart()
            #if canImport(Vision)
            let ocr: any TextRecognizer = recognizer ?? VisionTextRecognizer()
            #else
            let ocr: any TextRecognizer = recognizer ?? MockTextRecognizer()
            #endif
            let text = try await ocr.recognizeText(from: data)
            try Task.checkCancellation()
            return Attachment(
                filename: ocrFilename(for: filename),
                mimeType: "text/plain",
                extractedText: text,
                byteSize: data.count,
                source: .photoOCR
            )
        }

        return try await Task.detached(priority: .userInitiated) { () throws -> Attachment in
            #if canImport(PDFKit)
            let pdfExtractor: (any PDFTextExtractor)? = PDFKitTextExtractor()
            #else
            let pdfExtractor: (any PDFTextExtractor)? = nil
            #endif
            let text = try AttachmentParser.extractText(from: data, filename: filename, pdfExtractor: pdfExtractor)
            try Task.checkCancellation()
            let mime = AttachmentMIMEDetector.detectMIME(filename: filename, data: data)
            return Attachment(
                filename: filename,
                mimeType: mime,
                extractedText: text,
                byteSize: data.count,
                source: .file
            )
        }.value
    }
}
