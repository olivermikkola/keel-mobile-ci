import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ReadURLError: Error { case url, response, tooLarge, contentType, encoding }

/// Harness-only network tool. The app must explicitly wire it before it can run.
struct ReadURL {
    static let byteLimit = 512 * 1024
    static let textLimit = 6_000
    static let timeout: TimeInterval = 15

    struct Result: Equatable {
        let text: String
        let truncated: Bool
    }

    static func validatedURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw ReadURLError.url
        }
        return url
    }

    func execute(_ call: RepositoryCall,
                 configuration: URLSessionConfiguration = .ephemeral) async throws -> Result {
        guard call.name == "read_url", let value = call.url else { throw RepositoryAgentError.call }
        let url = try Self.validatedURL(value)
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("text/html, text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await ReadURLTransfer.fetch(request, configuration: config, limit: Self.byteLimit)
        try Task.checkCancellation()
        // Redirects are deliberately refused; the model can request the destination explicitly.
        guard (200..<300).contains(response.statusCode) else { throw ReadURLError.response }
        guard let mime = response.mimeType?.lowercased(), ["text/html", "text/plain"].contains(mime) else {
            throw ReadURLError.contentType
        }
        guard let source = String(data: data, encoding: .utf8) else { throw ReadURLError.encoding }
        return Self.convert(source, html: mime == "text/html")
    }

    /// A bounded, inert text extraction, not a browser. No scripts, styles or subresources run.
    static func convert(_ source: String, html: Bool = true) -> Result {
        var text = source
        if html {
            // Input is bounded before conversion. Strip raw-text elements before ordinary tags.
            for pattern in [#"(?is)<!--.*?(?:-->|$)"#,
                            #"(?is)<(script|style|head)\b[^<>]*>.*?(?:</\1\s*>|$)"#,
                            #"(?s)<[^<>]*>"#] {
                text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
            let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
            let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});"#)
            let original = text
            var decodedText = ""
            var cursor = original.startIndex
            for match in regex.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
                guard let keyRange = Range(match.range(at: 1), in: original),
                      let range = Range(match.range, in: original) else { continue }
                decodedText.append(contentsOf: original[cursor..<range.lowerBound])
                let key = String(original[keyRange])
                var decoded = entities[key]
                if key.hasPrefix("#") {
                    let hex = key.hasPrefix("#x")
                    if let number = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                       let scalar = UnicodeScalar(number), number >= 32 { decoded = String(scalar) }
                }
                decodedText.append(contentsOf: decoded ?? String(original[range]))
                cursor = range.upperBound
            }
            decodedText.append(contentsOf: original[cursor...])
            text = decodedText
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var output = ""
        var bytes = 0
        for character in text {
            guard bytes + character.utf8.count <= textLimit else { return Result(text: output, truncated: true) }
            bytes += character.utf8.count
            output.append(character)
        }
        return Result(text: output, truncated: false)
    }
}
