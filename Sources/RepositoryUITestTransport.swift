#if DEBUG && targetEnvironment(simulator)
import Foundation

// UI tests run in another process. An explicit simulator-only launch flag
// installs recorded HTTP responses while keeping the real parsing, object
// verification, navigation and persistence paths. Never included on a phone.
final class RepositoryUITestTransport: URLProtocol {
    private static var responses: [String: Any]? {
        guard ProcessInfo.processInfo.arguments.contains("--recorded-repository"),
              let value = ProcessInfo.processInfo.environment["KEEL_RECORDED_REPOSITORY"],
              let data = value.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func configuration() -> URLSessionConfiguration? {
        guard responses != nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.scheme == "https", ["api.github.com", GitHubAccountAPI.broker.host!].contains(url.host ?? ""),
              request.httpMethod == "GET", let response = Self.responses?[url.path],
              let data = try? JSONSerialization.data(withJSONObject: response),
              let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
