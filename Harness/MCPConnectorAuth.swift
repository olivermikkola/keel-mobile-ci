import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Browser sign-in for connectors, so nobody has to paste a token.
///
/// A service that needs an account answers the first request with 401 and says
/// where its sign-in lives. Keel then: reads the service's sign-in addresses,
/// registers itself as a public app (no secret), opens the service's own
/// sign-in page in the system browser, and swaps the returned code for an
/// access token (OAuth 2.1 with PKCE). The token goes to Keychain.
///
/// No network code here: each step is a request to send and a reply to read.
public enum MCPConnectorAuth {
    public static let redirectURI = "keelmobile://connector/callback"
    public static let clientName = "Keel"
    public static let responseLimit = 64 * 1024
    public static let timeout: TimeInterval = 15

    public enum Problem: LocalizedError, Equatable {
        case notSupported, response, cancelled, callback, refused

        public var errorDescription: String? {
            switch self {
            case .notSupported: return "This service does not offer sign-in from an app like Keel. If it gives you an access token, add it under Custom connector."
            case .response: return "The service's sign-in could not be reached. Check your connection and try again."
            case .cancelled: return "Sign-in was cancelled. Nothing was changed."
            case .callback: return "Sign-in could not be verified. Try connecting again."
            case .refused: return "The service did not accept the sign-in. Try connecting again."
            }
        }
    }

    /// Where a service's sign-in lives.
    public struct Metadata: Codable, Equatable, Sendable {
        public let issuer: String
        public let authorizationEndpoint: URL
        public let tokenEndpoint: URL
        public let registrationEndpoint: URL?
    }

    /// What Keel keeps in Keychain for a signed-in connector.
    public struct Grant: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public let clientID: String
        public let tokenEndpoint: URL
        public let resource: String?

        public init(accessToken: String, refreshToken: String?, expiresAt: Date?, clientID: String, tokenEndpoint: URL, resource: String?) {
            self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
            self.clientID = clientID; self.tokenEndpoint = tokenEndpoint; self.resource = resource
        }

        /// True when the token should be renewed before the next request.
        public func needsRefresh(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= 60
        }
    }

    public struct Tokens: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
    }

    // MARK: Finding the sign-in

    /// The `resource_metadata` address from a 401 reply's `WWW-Authenticate` header.
    public static func resourceMetadataURL(wwwAuthenticate header: String?) -> URL? {
        guard let header,
              let match = header.range(of: #"resource_metadata\s*=\s*"([^"]{1,512})""#, options: .regularExpression) else { return nil }
        let text = String(header[match])
        guard let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close else { return nil }
        return secure(String(text[text.index(after: open)..<close]))
    }

    /// The scopes a 401 reply asks for (`scope="read write"`), if it names any.
    public static func challengeScopes(wwwAuthenticate header: String?) -> [String] {
        guard let header,
              let match = header.range(of: #"(?<![a-z_])scope\s*=\s*"([^"]{1,1024})""#, options: .regularExpression) else { return [] }
        let text = String(header[match])
        guard let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close else { return [] }
        return text[text.index(after: open)..<close].split(separator: " ").map(String.init).filter(isScope)
    }

    /// Standard places to look when the 401 reply names none.
    public static func resourceMetadataURLs(endpoint: URL) -> [URL] {
        guard let origin = origin(of: endpoint) else { return [] }
        let path = endpoint.path == "/" ? "" : endpoint.path
        var urls = [URL]()
        if !path.isEmpty, let url = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { urls.append(url) }
        if let url = URL(string: origin + "/.well-known/oauth-protected-resource") { urls.append(url) }
        return urls
    }

    /// The sign-in server and scopes a service names for itself.
    public static func parseResource(from data: Data, status: Int) throws -> (resource: String?, issuer: URL, scopes: [String]) {
        guard status == 200, data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["authorization_servers"] as? [String],
              let issuer = servers.lazy.compactMap(secure).first else { throw Problem.response }
        let scopes = ((root["scopes_supported"] as? [String]) ?? []).filter(isScope)
        return (root["resource"] as? String, issuer, Array(scopes.prefix(40)))
    }

    /// Where a sign-in server publishes its addresses, most specific first.
    public static func metadataURLs(issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        let path = issuer.path == "/" ? "" : issuer.path
        let candidates = path.isEmpty
            ? ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"]
            : ["/.well-known/oauth-authorization-server" + path, "/.well-known/openid-configuration" + path,
               path + "/.well-known/openid-configuration"]
        return candidates.compactMap { URL(string: origin + $0) }
    }

    public static func parseMetadata(from data: Data, status: Int) throws -> Metadata {
        guard status == 200, data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authorize = (root["authorization_endpoint"] as? String).flatMap(secure),
              let token = (root["token_endpoint"] as? String).flatMap(secure) else { throw Problem.response }
        // PKCE with S256 is required. A server that lists its methods must list it.
        if let methods = root["code_challenge_methods_supported"] as? [String], !methods.contains("S256") {
            throw Problem.notSupported
        }
        return Metadata(issuer: (root["issuer"] as? String) ?? "", authorizationEndpoint: authorize, tokenEndpoint: token,
                        registrationEndpoint: (root["registration_endpoint"] as? String).flatMap(secure))
    }

    // MARK: Registering Keel with the service

    public static func registrationRequest(_ metadata: Metadata) throws -> URLRequest {
        guard let endpoint = metadata.registrationEndpoint else { throw Problem.notSupported }
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native"
        ]
        var request = post(endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public static func parseRegistration(from data: Data, status: Int) throws -> String {
        guard (200...201).contains(status), data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["client_id"] as? String, isOpaque(id, limit: 512) else {
            throw (400...499).contains(status) ? Problem.notSupported : Problem.response
        }
        return id
    }

    // MARK: Signing in

    /// The page to open in the system browser. `challenge` is the base64url
    /// SHA-256 of the verifier the app keeps for `tokenRequest`.
    public static func authorizeURL(_ metadata: Metadata, clientID: String, state: String, challenge: String,
                                    scopes: [String], resource: String?) throws -> URL {
        guard isOpaque(state, limit: 128), isOpaque(challenge, limit: 128),
              var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw Problem.response
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.queryItems = items
        guard let url = components.url else { throw Problem.response }
        return url
    }

    /// The one-time code from the address the browser returns to Keel.
    public static func code(from callback: URL, state: String) throws -> String {
        guard let expected = URLComponents(string: redirectURI),
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == expected.scheme, components.host == expected.host, components.path == expected.path,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil else {
            throw Problem.callback
        }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw Problem.callback }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? Problem.cancelled : Problem.refused
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, isOpaque(code, limit: 2_048) else {
            throw Problem.callback
        }
        return code
    }

    public static func tokenRequest(_ metadata: Metadata, clientID: String, code: String, verifier: String, resource: String?) -> URLRequest {
        var fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("client_id", clientID), ("code_verifier", verifier)]
        if let resource { fields.append(("resource", resource)) }
        return form(metadata.tokenEndpoint, fields)
    }

    public static func refreshRequest(_ grant: Grant) throws -> URLRequest {
        guard let refresh = grant.refreshToken else { throw Problem.refused }
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", grant.clientID)]
        if let resource = grant.resource { fields.append(("resource", resource)) }
        return form(grant.tokenEndpoint, fields)
    }

    public static func parseTokens(from data: Data, status: Int) throws -> Tokens {
        guard status == 200, data.count <= responseLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, isOpaque(access, limit: MCPConnector.maxTokenLength),
              ((root["token_type"] as? String) ?? "bearer").lowercased() == "bearer" else {
            throw (400...499).contains(status) ? Problem.refused : Problem.response
        }
        let refresh = (root["refresh_token"] as? String).flatMap { isOpaque($0, limit: MCPConnector.maxTokenLength) ? $0 : nil }
        let seconds = (root["expires_in"] as? Double) ?? (root["expires_in"] as? String).flatMap(Double.init)
        return Tokens(accessToken: access, refreshToken: refresh,
                      expiresIn: seconds.flatMap { $0.isFinite && $0 > 0 ? min($0, 366 * 86_400) : nil })
    }

    /// The saved grant after a sign-in or a renewal. A renewal that sends no
    /// new refresh token keeps the old one.
    public static func grant(from tokens: Tokens, clientID: String, tokenEndpoint: URL, resource: String?,
                             previous: Grant? = nil, now: Date = Date()) -> Grant {
        Grant(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken ?? previous?.refreshToken,
              expiresAt: tokens.expiresIn.map { now.addingTimeInterval($0) },
              clientID: clientID, tokenEndpoint: tokenEndpoint, resource: resource)
    }

    // MARK: Helpers

    /// An https address with no embedded credentials or fragment.
    static func secure(_ text: String) -> URL? {
        guard text.count <= 512, let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        return components.url
    }

    private static func origin(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return "https://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    private static func isOpaque(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit
            && text.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
    }

    private static func isScope(_ text: String) -> Bool {
        isOpaque(text, limit: 128) && !text.contains("\"") && !text.contains("\\")
    }

    private static func post(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var request = post(url)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        return request
    }
}

extension MCPConnector {
    /// Services Keel can connect with one tap. Each address was checked against
    /// the live service; the user never types it.
    public struct CatalogEntry: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let summary: String
        public let endpoint: String
        /// SF Symbol shown beside the name.
        public let symbol: String
        /// True when the service asks the user to sign in to an account.
        public let signIn: Bool
        /// Tools switched on first, by the service's own names.
        public let preferredTools: [String]
    }

    public static let catalog: [CatalogEntry] = [
        CatalogEntry(id: "notion", name: "Notion", summary: "Search, read and write your pages",
                     endpoint: "https://mcp.notion.com/mcp", symbol: "doc.text", signIn: true,
                     preferredTools: ["notion-search", "notion-fetch", "notion-create-pages", "notion-update-page"]),
        CatalogEntry(id: "linear", name: "Linear", summary: "Find, create and update issues",
                     endpoint: "https://mcp.linear.app/mcp", symbol: "checklist", signIn: true,
                     preferredTools: ["list_issues", "get_issue", "create_issue", "update_issue", "create_comment"]),
        CatalogEntry(id: "atlassian", name: "Jira & Confluence", summary: "Atlassian issues and pages",
                     endpoint: "https://mcp.atlassian.com/v2/mcp", symbol: "square.stack.3d.up", signIn: true, preferredTools: []),
        CatalogEntry(id: "sentry", name: "Sentry", summary: "Look up errors and issues in your apps",
                     endpoint: "https://mcp.sentry.dev/mcp", symbol: "ant", signIn: true, preferredTools: []),
        CatalogEntry(id: "huggingface", name: "Hugging Face", summary: "Search models, datasets and papers",
                     endpoint: "https://huggingface.co/mcp", symbol: "face.smiling", signIn: false, preferredTools: []),
        CatalogEntry(id: "context", name: "Context7", summary: "Current documentation for code libraries",
                     endpoint: "https://mcp.context7.com/mcp", symbol: "books.vertical", signIn: false, preferredTools: []),
        CatalogEntry(id: "deepwiki", name: "DeepWiki", summary: "Ask questions about public GitHub projects",
                     endpoint: "https://mcp.deepwiki.com/mcp", symbol: "questionmark.bubble", signIn: false, preferredTools: []),
        CatalogEntry(id: "microsoft_learn", name: "Microsoft Learn", summary: "Search Microsoft and Azure documentation",
                     endpoint: "https://learn.microsoft.com/api/mcp", symbol: "graduationcap", signIn: false, preferredTools: []),
    ]
}
