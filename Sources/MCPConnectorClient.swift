import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Talks to connector services for the chat: the opening handshake, the tool
/// list, tool calls, browser sign-in and token renewal. The request and reply
/// formats live in the harness (`MCPConnector`, `MCPConnectorAuth`).
actor MCPConnectorClient {
    typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    /// The service wants the user to sign in. Carries its `WWW-Authenticate` header.
    struct SignInRequired: Error { let challenge: String? }

    struct SignInPlan: Sendable {
        let metadata: MCPConnectorAuth.Metadata
        let clientID: String
        let scopes: [String]
        let resource: String?
    }

    /// Where tokens are kept. Keychain in the app; memory in tests.
    struct Secrets: Sendable {
        var token: @Sendable (String) throws -> String
        var grant: @Sendable (String) throws -> MCPConnectorAuth.Grant?
        var saveGrant: @Sendable (MCPConnectorAuth.Grant, String) throws -> Void

        static let keychain = Secrets(
            token: { try MCPConnectorCredential.load(serverID: $0) },
            grant: { try MCPConnectorCredential.loadGrant(serverID: $0) },
            saveGrant: { try MCPConnectorCredential.saveGrant($0, serverID: $1) })
    }

    private let transport: Transport
    private let secrets: Secrets
    private var sessions: [String: MCPConnector.Session] = [:]
    private var renewing: [String: Task<String, Error>] = [:]

    init(transport: @escaping Transport, secrets: Secrets = .keychain) {
        self.transport = transport
        self.secrets = secrets
    }

    /// Handshake, then the tools a small model can call. Throws `SignInRequired`
    /// when the service asks for an account.
    func discover(id: String, name: String, endpoint: URL, preferred: [String]) async throws -> MCPConnector.Server {
        let token = try await token(for: id)
        let session = try await open(id: id, endpoint: endpoint, token: token)
        let (data, response) = try await send(MCPConnector.listToolsRequest(endpoint: endpoint, token: token, session: session))
        if response.statusCode == 401 { throw SignInRequired(challenge: response.value(forHTTPHeaderField: "WWW-Authenticate")) }
        let all = try MCPConnector.parseTools(from: data, status: response.statusCode, serverID: id,
                                              contentType: response.value(forHTTPHeaderField: "Content-Type"))
        guard !all.isEmpty else { throw MCPConnector.Problem.remoteError("this service has no tools Keel can use yet.") }
        return MCPConnector.Server(id: id, name: name, endpoint: endpoint.absoluteString,
                                   tools: MCPConnector.defaultSelection(from: all, preferred: preferred), available: all)
    }

    func call(server: MCPConnector.Server, tool: MCPConnector.Tool, arguments: [String: String]) async throws -> (text: String, isError: Bool) {
        let endpoint = try MCPConnector.validateEndpoint(server.endpoint)
        let token = try await token(for: server.id)
        var retried = false
        while true {
            let session: MCPConnector.Session
            if let saved = sessions[server.id] {
                session = saved
            } else {
                do { session = try await open(id: server.id, endpoint: endpoint, token: token) }
                catch is SignInRequired { throw MCPConnector.Problem.unauthorized }
            }
            let request = try MCPConnector.callToolRequest(server: server, tool: tool, arguments: arguments, token: token, session: session)
            let (data, response) = try await send(request)
            do {
                return try MCPConnector.parseCallResult(from: data, status: response.statusCode, serverName: server.name,
                                                        toolName: tool.remoteName,
                                                        contentType: response.value(forHTTPHeaderField: "Content-Type"))
            } catch MCPConnector.Problem.sessionExpired where !retried {
                // The service dropped its session. Start a new one, once.
                retried = true
                sessions[server.id] = nil
            }
        }
    }

    /// Finds the service's sign-in and registers Keel with it as a public app.
    func planSignIn(endpoint: URL, challenge: String?) async throws -> SignInPlan {
        var places = MCPConnectorAuth.resourceMetadataURLs(endpoint: endpoint)
        if let named = MCPConnectorAuth.resourceMetadataURL(wwwAuthenticate: challenge) { places.insert(named, at: 0) }
        var scopes = MCPConnectorAuth.challengeScopes(wwwAuthenticate: challenge)
        var resource: String?
        var issuer: URL?
        for place in places {
            try Task.checkCancellation()
            guard let (data, response) = try? await send(get(place), limit: MCPConnectorAuth.responseLimit),
                  let found = try? MCPConnectorAuth.parseResource(from: data, status: response.statusCode) else { continue }
            // The description must be about this connector, not another address.
            if let named = found.resource {
                guard URL(string: named)?.host == endpoint.host else { throw MCPConnectorAuth.Problem.response }
                resource = named
            }
            issuer = found.issuer
            if scopes.isEmpty { scopes = found.scopes }
            break
        }
        // Older services publish their sign-in on the connector's own host.
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = endpoint.host; origin.port = endpoint.port
        guard let base = issuer ?? origin.url else { throw MCPConnectorAuth.Problem.notSupported }
        var metadata: MCPConnectorAuth.Metadata?
        for place in MCPConnectorAuth.metadataURLs(issuer: base) where metadata == nil {
            try Task.checkCancellation()
            guard let (data, response) = try? await send(get(place), limit: MCPConnectorAuth.responseLimit) else { continue }
            do { metadata = try MCPConnectorAuth.parseMetadata(from: data, status: response.statusCode) }
            catch MCPConnectorAuth.Problem.notSupported { throw MCPConnectorAuth.Problem.notSupported }
            catch { continue }
        }
        try Task.checkCancellation()
        guard let metadata else { throw MCPConnectorAuth.Problem.notSupported }
        let (data, response) = try await send(MCPConnectorAuth.registrationRequest(metadata), limit: MCPConnectorAuth.responseLimit)
        let clientID = try MCPConnectorAuth.parseRegistration(from: data, status: response.statusCode)
        return SignInPlan(metadata: metadata, clientID: clientID, scopes: scopes, resource: resource)
    }

    /// Swaps the browser's one-time code for tokens and keeps them.
    func finishSignIn(id: String, plan: SignInPlan, code: String, verifier: String) async throws {
        let request = MCPConnectorAuth.tokenRequest(plan.metadata, clientID: plan.clientID, code: code, verifier: verifier, resource: plan.resource)
        let (data, response) = try await send(request, limit: MCPConnectorAuth.responseLimit)
        let tokens = try MCPConnectorAuth.parseTokens(from: data, status: response.statusCode)
        try secrets.saveGrant(MCPConnectorAuth.grant(from: tokens, clientID: plan.clientID, tokenEndpoint: plan.metadata.tokenEndpoint,
                                                     resource: plan.resource), id)
        sessions[id] = nil
    }

    func forget(_ id: String) {
        sessions[id] = nil
        renewing[id]?.cancel()
        renewing[id] = nil
    }

    private func open(id: String, endpoint: URL, token: String) async throws -> MCPConnector.Session {
        let (data, response) = try await send(MCPConnector.initializeRequest(endpoint: endpoint, token: token))
        if response.statusCode == 401 { throw SignInRequired(challenge: response.value(forHTTPHeaderField: "WWW-Authenticate")) }
        let session: MCPConnector.Session
        do {
            session = try MCPConnector.parseInitialize(from: data, status: response.statusCode,
                                                       contentType: response.value(forHTTPHeaderField: "Content-Type"),
                                                       sessionHeader: response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        } catch MCPConnector.Problem.sessionExpired {
            // 404 on the very first request: nothing is served at this address.
            throw MCPConnector.Problem.unavailable(404)
        }
        // The service answers 202 with no body. If this is lost, the next request says so.
        _ = try? await send(MCPConnector.initializedRequest(endpoint: endpoint, token: token, session: session))
        try Task.checkCancellation()
        sessions[id] = session
        return session
    }

    /// The access token for a connector, renewed first when it is about to expire.
    private func token(for id: String) async throws -> String {
        guard let grant = try secrets.grant(id) else { return try secrets.token(id) }
        guard grant.needsRefresh() else { return grant.accessToken }
        guard grant.refreshToken != nil else { throw MCPConnector.Problem.unauthorized }
        if let running = renewing[id] { return try await running.value }
        let transport = self.transport, secrets = self.secrets
        let task = Task<String, Error> {
            let (data, response) = try await transport(try MCPConnectorAuth.refreshRequest(grant), MCPConnectorAuth.responseLimit)
            let tokens: MCPConnectorAuth.Tokens
            do { tokens = try MCPConnectorAuth.parseTokens(from: data, status: response.statusCode) }
            catch MCPConnectorAuth.Problem.refused { throw MCPConnector.Problem.unauthorized }
            let renewed = MCPConnectorAuth.grant(from: tokens, clientID: grant.clientID, tokenEndpoint: grant.tokenEndpoint,
                                                 resource: grant.resource, previous: grant)
            try secrets.saveGrant(renewed, id)
            return renewed.accessToken
        }
        renewing[id] = task
        defer { renewing[id] = nil }
        do { return try await task.value }
        catch let problem as MCPConnector.Problem { throw problem }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPConnector.Problem.unavailable(0) }
    }

    private func send(_ request: URLRequest, limit: Int = MCPConnector.responseLimit) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport(request, limit) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw MCPConnector.Problem.unavailable(0)
        }
    }

    private func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: MCPConnectorAuth.timeout)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// The one-time values for a browser sign-in. The verifier never leaves the
/// app; the service only sees its SHA-256 until the code is exchanged.
struct ConnectorSignInChallenge {
    let state: String
    let verifier: String
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw MCPConnectorAuth.Problem.response
            }
            return Self.base64URL(Data(bytes))
        }
        state = try random(); verifier = try random()
    }

    init(state: String, verifier: String) { self.state = state; self.verifier = verifier }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Opens a service's own sign-in page in the system browser sheet and returns
/// the address it sends back to Keel. Keel never sees the password.
@MainActor
final class ConnectorBrowser: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var waiting: CheckedContinuation<URL, Error>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    func authorize(_ url: URL) async throws -> URL {
        cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "keelmobile") { [weak self] returned, error in
                    Task { @MainActor in
                        guard let self, let pending = self.waiting else { return }
                        self.waiting = nil; self.session = nil
                        if let returned { pending.resume(returning: returned) }
                        else if let web = error as? ASWebAuthenticationSessionError, web.code == .canceledLogin {
                            pending.resume(throwing: MCPConnectorAuth.Problem.cancelled)
                        } else { pending.resume(throwing: MCPConnectorAuth.Problem.response) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                if !session.start() {
                    waiting = nil; self.session = nil
                    continuation.resume(throwing: MCPConnectorAuth.Problem.response)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() {
        session?.cancel(); session = nil
        waiting?.resume(throwing: CancellationError()); waiting = nil
    }
}

#if DEBUG && targetEnvironment(simulator)
/// UI tests run in another process and must not reach real services. With
/// `--recorded-connector` the app answers connector requests itself, through
/// the same handshake, parsing and saving code a real service exercises.
/// Never included on a phone.
final class ConnectorUITestTransport: URLProtocol {
    static func configuration() -> URLSessionConfiguration? {
        guard ProcessInfo.processInfo.arguments.contains("--recorded-connector") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        } ?? Data()
        let method = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String
        let reply: String
        switch method {
        case "initialize":
            reply = #"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"Recorded"}}}"#
        case "tools/list":
            reply = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search_notes","description":"Search your notes.","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},{"name":"create_note","description":"Create a note.","inputSchema":{"type":"object","properties":{"noteTitle":{"type":"string"},"text":{"type":"string"}},"required":["noteTitle"]}}]}}"#
        default:
            reply = ""
        }
        // Real services answer with an event stream; the recording does too.
        let data = Data(reply.isEmpty ? "".utf8 : "event: message\ndata: \(reply)\n\n".utf8)
        let http = HTTPURLResponse(url: url, statusCode: reply.isEmpty ? 202 : 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
