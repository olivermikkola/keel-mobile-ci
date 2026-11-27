import Foundation

/// What Hugging Face says about a GGUF before any weights are downloaded: its
/// size and SHA-256, from the `X-Linked-Size` and `X-Linked-Etag` headers of
/// the resolve redirect, and its first 256 KB, which hold the header. The
/// download is then pinned to that size and checksum like a catalog model.
enum HuggingFaceImport {
    struct Remote: Equatable, Sendable {
        let bytes: Int64
        let sha256: String
        let header: GGUFHeader
        let prefix: Data
    }

    enum Failure: LocalizedError, Equatable {
        case noChecksum, unreachable(Int)
        var errorDescription: String? {
            switch self {
            case .noChecksum: return "Hugging Face did not give a size and checksum for this file, so Keel cannot verify a download. Check that the link is to a .gguf file in a model repository."
            case .unreachable(let status) where status == 401 || status == 403:
                return "This file needs a Hugging Face sign-in (the model is gated or private). Keel downloads public files only."
            case .unreachable(let status) where status == 404: return "Hugging Face has no file at this link. Check the repository, revision and file name."
            case .unreachable: return "Hugging Face could not be reached. Check your connection and try again."
            }
        }
    }

    static func inspect(_ link: HuggingFaceGGUFLink, configuration: URLSessionConfiguration) async throws -> Remote {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var head = URLRequest(url: link.resolveURL, timeoutInterval: 30)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: head, delegate: KeepRedirect())
        guard let http = headResponse as? HTTPURLResponse else { throw Failure.unreachable(0) }
        guard (200..<400).contains(http.statusCode) else { throw Failure.unreachable(http.statusCode) }
        let etag = (http.value(forHTTPHeaderField: "X-Linked-Etag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" W/")).lowercased()
        guard let size = http.value(forHTTPHeaderField: "X-Linked-Size").flatMap(Int64.init), size > 0,
              etag.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Failure.noChecksum }

        // Only the header: read at most 256 KB even if the server ignores Range.
        var range = URLRequest(url: link.resolveURL, timeoutInterval: 60)
        range.setValue("bytes=0-\(GGUFHeader.maxHeaderBytes - 1)", forHTTPHeaderField: "Range")
        range.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (stream, rangeResponse) = try await session.bytes(for: range)
        guard let status = (rangeResponse as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 else {
            throw Failure.unreachable((rangeResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var prefix = Data()
        prefix.reserveCapacity(GGUFHeader.maxHeaderBytes)
        for try await byte in stream {
            try Task.checkCancellation()
            prefix.append(byte)
            if prefix.count >= GGUFHeader.maxHeaderBytes { break }
        }
        let header: GGUFHeader
        do { header = try GGUFHeader.parse(prefix) } catch { throw ImportedModel.Problem.notGGUF(error.localizedDescription) }
        return Remote(bytes: size, sha256: etag, header: header, prefix: prefix)
    }

    /// Keeps the redirect itself, whose headers describe the stored file.
    private final class KeepRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
