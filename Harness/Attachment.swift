import Foundation

/// Origin source of the attachment.
public enum AttachmentSource: String, Codable, Sendable, Equatable {
    case file
    case photoOCR = "photo_ocr"
}

/// Content kind of the attachment.
public enum AttachmentKind: String, Codable, Sendable, Equatable {
    case text
    case markdown
    case csv
    case pdf
    case photoOCR = "photo_ocr"
    case unsupported
}

/// Global limits for attachments.
public enum AttachmentLimits {
    /// 5 MB maximum raw file size.
    public static let maxFileSizeBytes = 5 * 1024 * 1024
    /// 64 KB default text buffer warning limit.
    public static let maxExtractedChars = 64 * 1024
    /// 8,000 characters prompt middle-pruning limit.
    public static let maxPromptAttachmentChars = 8_000
    /// 12,000 characters total prompt budget for all attachments.
    public static let maxTotalPromptChars = 12_000
}

/// Errors occurring during attachment processing and parsing.
public enum AttachmentError: LocalizedError, Equatable, Sendable {
    case emptyFile
    case binaryFile
    case invalidEncoding
    case fileTooLarge(bytes: Int, limit: Int)
    case unsupportedType(String)
    case invalidPDF
    case encryptedPDF
    case noTextInPDF
    case extractionFailed(String)
    case zeroTextRecognized
    case ocrFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .binaryFile, .invalidEncoding:
            return "Binary files without selectable text cannot be attached."
        case .fileTooLarge(let bytes, let limit):
            let mb = String(format: "%.1f", Double(bytes) / 1_048_576.0)
            let limitMb = limit / 1_048_576
            return "File is too large (\(mb) MB). Maximum supported size is \(limitMb) MB."
        case .unsupportedType(let type):
            return "Unsupported file type (\(type)). Supported types: text, Markdown, CSV, PDF, and photos."
        case .invalidPDF:
            return "The PDF document is corrupted or unreadable."
        case .encryptedPDF:
            return "Password-protected PDFs cannot be attached."
        case .noTextInPDF:
            return "This PDF contains scanned images without selectable text. Use 'Photo as text' to recognize text."
        case .extractionFailed(let reason):
            return "Failed to extract text: \(reason)"
        case .zeroTextRecognized:
            return "No text could be recognized in the image."
        case .ocrFailed(let message):
            return "Optical character recognition failed: \(message)"
        }
    }
}

/// An ingested document or recognized text attachment.
public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let extractedText: String
    public let byteSize: Int
    public let source: AttachmentSource

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        extractedText: String,
        byteSize: Int,
        source: AttachmentSource = .file
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.extractedText = extractedText
        self.byteSize = byteSize
        self.source = source
    }

    /// Estimated tokens using the Keel heuristic (3.8 characters per token + 4 overhead).
    public var estimatedTokens: Int {
        Int((Double(extractedText.unicodeScalars.count) / 3.8).rounded(.up)) + 4
    }

    /// Alias for token estimation.
    public var tokenCount: Int {
        estimatedTokens
    }

    /// Line count of the extracted text.
    public var lineCount: Int {
        extractedText.components(separatedBy: "\n").count
    }

    /// Human-readable file size string (e.g. "45 KB", "1.2 MB").
    public var formattedByteSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// Content kind classified from MIME type and filename.
    public var kind: AttachmentKind {
        if source == .photoOCR { return .photoOCR }
        return AttachmentMIMEDetector.classify(mimeType: mimeType, filename: filename)
    }
}

/// MIME and file extension classifier.
public enum AttachmentMIMEDetector {
    public static func classify(mimeType: String, filename: String) -> AttachmentKind {
        let ext = fileExtension(filename)
        let lowerMime = mimeType.lowercased()

        if lowerMime == "application/pdf" || ext == "pdf" { return .pdf }
        if lowerMime == "text/csv" || lowerMime == "text/comma-separated-values" || ext == "csv" { return .csv }
        if lowerMime == "text/markdown" || ext == "md" || ext == "markdown" { return .markdown }
        if isText(mimeType: lowerMime, ext: ext) { return .text }
        return .unsupported
    }

    public static func detectMIME(filename: String, data: Data) -> String {
        let ext = fileExtension(filename)
        // PDF magic bytes check: %PDF-
        if data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]) || ext == "pdf" {
            return "application/pdf"
        }
        if ext == "csv" { return "text/csv" }
        if ext == "md" || ext == "markdown" { return "text/markdown" }
        if ext == "json" { return "application/json" }
        if ext == "swift" { return "text/x-swift" }
        if ext == "py" { return "text/x-python" }
        if ext == "js" || ext == "mjs" || ext == "cjs" { return "text/javascript" }
        if ext == "ts" { return "text/typescript" }
        if ext == "html" || ext == "htm" { return "text/html" }
        if ext == "css" { return "text/css" }
        if ext == "xml" { return "application/xml" }
        if ext == "yaml" || ext == "yml" { return "text/yaml" }
        if ext == "sh" || ext == "bash" { return "text/x-sh" }
        if ext == "sql" { return "application/sql" }
        if ["c", "h", "cpp", "hpp", "rs", "go", "java", "kt"].contains(ext) { return "text/plain" }
        return "text/plain"
    }

    public static func fileExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "" }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    private static func isText(mimeType: String, ext: String) -> Bool {
        if mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml" || mimeType == "application/sql" {
            return true
        }
        let codeExtensions: Set<String> = [
            "txt", "swift", "py", "js", "ts", "json", "html", "css", "xml", "yaml", "yml",
            "sh", "bash", "c", "h", "cpp", "hpp", "rs", "go", "java", "kt", "sql"
        ]
        return codeExtensions.contains(ext)
    }
}

/// Normalizes raw UTF-8 text by stripping BOM, normalizing line endings, and validating character sanity.
public enum AttachmentTextNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = text

        // Strip UTF-8 BOM if present
        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }

        // Normalize CRLF and lone CR to Unix LF
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")

        // Strip null characters and unprintable control characters, preserving \t and \n
        var filteredScalars = String.UnicodeScalarView()
        filteredScalars.reserveCapacity(result.unicodeScalars.count)
        for scalar in result.unicodeScalars {
            let val = scalar.value
            if val == 0x09 || val == 0x0A { // \t and \n
                filteredScalars.append(scalar)
            } else if val < 0x20 || val == 0x7F {
                // Drop other ASCII control characters
                continue
            } else {
                filteredScalars.append(scalar)
            }
        }

        return String(filteredScalars)
    }
}

/// RFC 4180 compliant CSV parser that converts tabular data into clean Markdown representation.
public enum CSVParser {
    public static func parse(text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        let chars = Array(text)
        var i = 0
        let n = chars.count

        while i < n {
            let char = chars[i]

            if insideQuotes {
                if char == "\"" {
                    if i + 1 < n && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        insideQuotes = false
                    }
                } else if char == "\r" {
                    if i + 1 < n && chars[i + 1] == "\n" {
                        currentField.append("\n")
                        i += 2
                        continue
                    } else {
                        currentField.append("\n")
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    insideQuotes = true
                } else if char == "," {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                } else if char == "\r" {
                    if i + 1 < n && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    if !currentRow.allSatisfy(\.isEmpty) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else if char == "\n" {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    if !currentRow.allSatisfy(\.isEmpty) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(char)
                }
            }
            i += 1
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            if !currentRow.allSatisfy(\.isEmpty) {
                rows.append(currentRow)
            }
        }

        return rows
    }

    public static func formatAsMarkdown(rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return "" }

        // Sanitize cell contents (replace newlines with spaces, escape pipes)
        let normalizedRows = rows.map { row -> [String] in
            var padded = row
            while padded.count < maxColumns { padded.append("") }
            return padded.map { cell in
                cell.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }

        var lines: [String] = []

        // Header
        let headerRow = normalizedRows[0]
        lines.append("| " + headerRow.joined(separator: " | ") + " |")

        // Separator
        let separator = Array(repeating: "---", count: maxColumns).joined(separator: " | ")
        lines.append("| " + separator + " |")

        // Data rows
        for row in normalizedRows.dropFirst() {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n")
    }
}

/// Pure Swift protocol for PDF text extraction.
public protocol PDFTextExtractor: Sendable {
    func extractText(from pdfData: Data) throws -> String
}

/// Fallback or mock PDF text extractor.
public struct MockPDFTextExtractor: PDFTextExtractor {
    public var stubbedResult: Result<String, AttachmentError>

    public init(stubbedResult: Result<String, AttachmentError> = .success("Mock PDF Page 1 Content")) {
        self.stubbedResult = stubbedResult
    }

    public func extractText(from pdfData: Data) throws -> String {
        try stubbedResult.get()
    }
}

/// Unified attachment parser enforcing size limits and format normalization.
public struct AttachmentParser: Sendable {
    public let maxFileBytes: Int
    public let pdfExtractor: (any PDFTextExtractor)?

    public init(
        maxFileBytes: Int = AttachmentLimits.maxFileSizeBytes,
        pdfExtractor: (any PDFTextExtractor)? = nil
    ) {
        self.maxFileBytes = maxFileBytes
        self.pdfExtractor = pdfExtractor
    }

    public static func validateSize(_ data: Data, limit: Int = AttachmentLimits.maxFileSizeBytes) throws {
        guard data.count <= limit else {
            throw AttachmentError.fileTooLarge(bytes: data.count, limit: limit)
        }
    }

    public static func extractText(
        from data: Data,
        filename: String,
        mimeType: String? = nil,
        pdfExtractor: (any PDFTextExtractor)? = nil
    ) throws -> String {
        guard !data.isEmpty else {
            throw AttachmentError.emptyFile
        }
        try validateSize(data)

        let detectedMime = mimeType ?? AttachmentMIMEDetector.detectMIME(filename: filename, data: data)
        let kind = AttachmentMIMEDetector.classify(mimeType: detectedMime, filename: filename)

        switch kind {
        case .pdf:
            guard let extractor = pdfExtractor else {
                throw AttachmentError.extractionFailed("No PDF extractor configured on this platform.")
            }
            return try extractor.extractText(from: data)

        case .csv:
            // Check for binary null bytes
            guard !data.contains(0) else {
                throw AttachmentError.invalidEncoding
            }
            guard let rawString = String(data: data, encoding: .utf8) else {
                throw AttachmentError.invalidEncoding
            }
            let normalized = AttachmentTextNormalizer.normalize(rawString)
            let parsedRows = CSVParser.parse(text: normalized)
            return CSVParser.formatAsMarkdown(rows: parsedRows)

        case .text, .markdown:
            guard !data.contains(0) else {
                throw AttachmentError.invalidEncoding
            }
            guard let rawString = String(data: data, encoding: .utf8) else {
                throw AttachmentError.invalidEncoding
            }
            return AttachmentTextNormalizer.normalize(rawString)

        case .photoOCR:
            guard !data.contains(0), let rawString = String(data: data, encoding: .utf8) else {
                throw AttachmentError.invalidEncoding
            }
            return AttachmentTextNormalizer.normalize(rawString)

        case .unsupported:
            // Attempt UTF-8 plain text fallback if non-binary
            if !data.contains(0), let rawString = String(data: data, encoding: .utf8) {
                return AttachmentTextNormalizer.normalize(rawString)
            }
            throw AttachmentError.unsupportedType(detectedMime)
        }
    }

    public func parse(
        data: Data,
        filename: String,
        mimeType: String? = nil,
        source: AttachmentSource = .file
    ) throws -> Attachment {
        guard !data.isEmpty else { throw AttachmentError.emptyFile }
        try Self.validateSize(data, limit: maxFileBytes)

        let detectedMime = mimeType ?? AttachmentMIMEDetector.detectMIME(filename: filename, data: data)
        let text = try Self.extractText(from: data, filename: filename, mimeType: detectedMime, pdfExtractor: pdfExtractor)

        return Attachment(
            id: UUID(),
            filename: filename,
            mimeType: detectedMime,
            extractedText: text,
            byteSize: data.count,
            source: source
        )
    }
}

/// Guardrail formatter for preparing attachment contents for on-device inference prompts.
public enum AttachmentPromptFormatter {
    /// Defuses ChatML control sequences and XML delimiters to prevent prompt injection.
    public static func defuse(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "<tool_call>", with: "< tool_call>")
            .replacingOccurrences(of: "</tool_call>", with: "</ tool_call>")
            .replacingOccurrences(of: "<tool_response>", with: "< tool_response>")
            .replacingOccurrences(of: "</tool_response>", with: "</ tool_response>")
            .replacingOccurrences(of: "<attachment", with: "< attachment")
            .replacingOccurrences(of: "</attachment>", with: "</ attachment>")
    }

    /// Middle-prunes text exceeding character limits, keeping head and tail intact.
    public static func middlePrune(
        _ text: String,
        threshold: Int = AttachmentLimits.maxPromptAttachmentChars,
        headChars: Int = 5_500,
        tailChars: Int = 2_000
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > threshold else { return text }

        let head = String(String.UnicodeScalarView(scalars.prefix(headChars)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(tailChars)))
        let omitted = max(0, scalars.count - headChars - tailChars)

        return "\(head)\n… [Attachment truncated: \(omitted) characters omitted to fit prompt budget. Full content stored in workspace] …\n\(tail)"
    }

    /// Formats a single attachment into prompt XML syntax with defused tokens and middle-pruning.
    public static func formatAttachment(_ attachment: Attachment) -> String {
        let defused = defuse(attachment.extractedText)
        let pruned = middlePrune(defused)
        let safeFilename = sanitizeFilename(attachment.filename)
        return """
        <attachment filename="\(safeFilename)" mime_type="\(attachment.mimeType)" source="\(attachment.source.rawValue)">
        \(pruned)
        </attachment>
        """
    }

    /// Formats all attachments for a user turn.
    public static func formatAll(_ attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        return attachments.map { formatAttachment($0) }.joined(separator: "\n\n")
    }

    /// Sanitizes filename for XML tag attribute.
    public static func sanitizeFilename(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitizes workspace relative path to ensure attachments are stored under `attachments/`
    /// without directory traversal risks.
    public static func sanitizeWorkspacePath(_ filename: String) -> String {
        let safe = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isASCII && ($0.unicodeScalars.first?.value ?? 0) >= 32 }

        return safe.isEmpty ? "attachments/attachment.txt" : "attachments/\(safe)"
    }
}
