import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

#if canImport(PDFKit)
/// Apple PDFKit text extractor for iOS and macOS.
public struct PDFKitTextExtractor: PDFTextExtractor {
    public init() {}

    public func extractText(from pdfData: Data) throws -> String {
        guard let document = PDFDocument(data: pdfData) else {
            throw AttachmentError.invalidPDF
        }
        if document.isEncrypted || document.isLocked {
            throw AttachmentError.encryptedPDF
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw AttachmentError.emptyFile }

        var pages: [String] = []
        for index in 0..<pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pages.append("--- Page \(index + 1) ---\n\(trimmed)")
                }
            }
        }

        let fullText = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            throw AttachmentError.noTextInPDF
        }
        return AttachmentTextNormalizer.normalize(fullText)
    }
}
#endif
