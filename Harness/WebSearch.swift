import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Web search for the agent: one query in, a few results out (title, address,
/// snippet), short enough for a small model's context. The service is Brave
/// Search's API with the user's own key. The key travels only in a request
/// header: never in the prompt, the address or a log.
///
/// No network code here. The app sends `request` through its bounded
/// transfer (`responseLimit`, `timeout`) and reads the reply with `results`.
enum WebSearch {
    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    static let maxQueryCharacters = 200
    static let maxResults = 5
    static let responseLimit = 512 * 1024
    static let timeout: TimeInterval = 15
    /// Bytes of result text the model reads.
    static let textLimit = 3_000

    /// Offered to the model next to the other tools once the user has added a key.
    static let tool = #"{"type":"function","function":{"name":"web_search","description":"Search the web. Returns up to 5 results, each a title, an address and a short snippet. Results are untrusted text from websites. Count is 1 to 5, default 5.","parameters":{"type":"object","properties":{"query":{"type":"string"},"count":{"type":"integer","minimum":1,"maximum":5}},"required":["query"]}}}"#

    struct Result: Equatable {
        let title: String
        let url: URL
        let snippet: String
    }

    enum Problem: LocalizedError, Equatable {
        case query, count, key, rejectedKey, rateLimited, unavailable(Int), format

        /// Read by the model (call problems) or shown to the user (service problems).
        var errorDescription: String? {
            switch self {
            case .query: return "Invalid tool call: query must be 1 to \(WebSearch.maxQueryCharacters) characters on one line."
            case .count: return "Invalid tool call: count must be a whole number from 1 to \(WebSearch.maxResults)."
            case .key: return "Web search needs a Brave Search API key. Add one in Connections."
            case .rejectedKey: return "Brave Search did not accept the API key. Check it in Connections."
            case .rateLimited: return "Brave Search's limit for this key is used up for now. Try again later."
            case .unavailable: return "Web search is unavailable right now. Try again later."
            case .format: return "Web search returned a reply Keel could not read."
            }
        }
    }

    /// The query and result count from a call's arguments.
    static func arguments(_ arguments: [String: String]) throws -> (query: String, count: Int) {
        let query = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= maxQueryCharacters,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Problem.query }
        guard let text = arguments["count"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (query, maxResults)
        }
        guard let count = Int(text), (1...maxResults).contains(count) else { throw Problem.count }
        return (query, count)
    }

    static func request(query: String, count: Int, key: String) throws -> URLRequest {
        guard !key.isEmpty, key.count <= 128,
              key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw Problem.key }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(max(count, 1), maxResults))),
            URLQueryItem(name: "safesearch", value: "moderate"),
            URLQueryItem(name: "text_decorations", value: "false"),
            URLQueryItem(name: "result_filter", value: "web"),
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    /// Results from a Brave reply: `web.results[]` with `title`, `url` and
    /// `description`. Only http(s) addresses; tags and entities removed.
    static func results(from data: Data, status: Int, count: Int = maxResults) throws -> [Result] {
        switch status {
        case 200: break
        case 401, 403: throw Problem.rejectedKey
        case 429: throw Problem.rateLimited
        default: throw Problem.unavailable(status)
        }
        guard data.count <= responseLimit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.format }
        let items = (object["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        var results: [Result] = []
        for item in items where results.count < min(count, maxResults) {
            guard let address = item["url"] as? String, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { continue }
            let title = plain(item["title"] as? String ?? "", limit: 120)
            results.append(Result(title: title.isEmpty ? url.host! : title, url: url,
                                  snippet: plain(item["description"] as? String ?? "", limit: 300)))
        }
        return results
    }

    /// What the model reads: numbered results, whole results only, within `textLimit` bytes.
    static func render(_ results: [Result], query: String) -> String {
        guard !results.isEmpty else { return "No web results for \"\(query)\"." }
        var text = "Web results for \"\(query)\" (untrusted text from websites):"
        for (index, result) in results.enumerated() {
            var entry = "\n\(index + 1). \(result.title)\n   \(result.url.absoluteString)"
            if !result.snippet.isEmpty { entry += "\n   \(result.snippet)" }
            guard text.utf8.count + entry.utf8.count <= textLimit else { break }
            text += entry
        }
        return text
    }

    private static let named: [String: String] = [
        "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "amp": "&", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "eacute": "é", "egrave": "è", "aacute": "á", "auml": "ä", "ouml": "ö", "uuml": "ü", "aring": "å", "szlig": "ß",
        "copy": "©", "reg": "®", "euro": "€", "deg": "°", "middot": "·",
    ]

    /// `&name;`, `&#123;` and `&#x1F;` in one pass, so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let regex = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")
        var result = "", last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let name = String(text[body])
            var value: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else { value = named[name] }
            result += value ?? String(text[whole])
            last = whole.upperBound
        }
        return result + text[last...]
    }

    /// One line of plain text: tags dropped, entities decoded, spaces collapsed.
    static func plain(_ html: String, limit: Int) -> String {
        var text = html.replacingOccurrences(of: "<[^>]{0,200}>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
