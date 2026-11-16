import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class MCPConnectorAuthTests: XCTestCase {
    private let metadataJSON = """
    {"issuer":"https://mcp.example.com","authorization_endpoint":"https://mcp.example.com/authorize",
     "token_endpoint":"https://mcp.example.com/token","registration_endpoint":"https://mcp.example.com/register",
     "code_challenge_methods_supported":["S256"]}
    """

    func testFindsSignInFromTheUnauthorizedReply() throws {
        // Header copied from a live 401 reply.
        let header = #"Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write""#
        XCTAssertEqual(MCPConnectorAuth.resourceMetadataURL(wwwAuthenticate: header)?.absoluteString,
                       "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(MCPConnectorAuth.challengeScopes(wwwAuthenticate: header), ["read", "write"])
        XCTAssertEqual(MCPConnectorAuth.challengeScopes(wwwAuthenticate: #"Bearer error="insufficient_scope""#), [])
        XCTAssertNil(MCPConnectorAuth.resourceMetadataURL(wwwAuthenticate: #"Bearer realm="OAuth""#))
        XCTAssertNil(MCPConnectorAuth.resourceMetadataURL(wwwAuthenticate: #"Bearer resource_metadata="http://plain.example.com/x""#))
        XCTAssertEqual(MCPConnectorAuth.resourceMetadataURLs(endpoint: URL(string: "https://mcp.example.com/v1/mcp")!).map(\.absoluteString),
                       ["https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp",
                        "https://mcp.example.com/.well-known/oauth-protected-resource"])

        let resource = try MCPConnectorAuth.parseResource(from: Data("""
        {"resource":"https://mcp.example.com/mcp","authorization_servers":["http://bad.example.com","https://auth.example.com/tenant"],
         "scopes_supported":["read","write","bad scope"]}
        """.utf8), status: 200)
        XCTAssertEqual(resource.issuer.absoluteString, "https://auth.example.com/tenant")
        XCTAssertEqual(resource.scopes, ["read", "write"])
        XCTAssertEqual(MCPConnectorAuth.metadataURLs(issuer: resource.issuer).map(\.absoluteString),
                       ["https://auth.example.com/.well-known/oauth-authorization-server/tenant",
                        "https://auth.example.com/.well-known/openid-configuration/tenant",
                        "https://auth.example.com/tenant/.well-known/openid-configuration"])
        XCTAssertThrowsError(try MCPConnectorAuth.parseResource(from: Data("{}".utf8), status: 200))
    }

    func testMetadataRequiresHTTPSAndS256() throws {
        let metadata = try MCPConnectorAuth.parseMetadata(from: Data(metadataJSON.utf8), status: 200)
        XCTAssertEqual(metadata.registrationEndpoint?.absoluteString, "https://mcp.example.com/register")
        XCTAssertThrowsError(try MCPConnectorAuth.parseMetadata(
            from: Data(metadataJSON.replacingOccurrences(of: "\"S256\"", with: "\"plain\"").utf8), status: 200)) {
            XCTAssertEqual($0 as? MCPConnectorAuth.Problem, .notSupported)
        }
        XCTAssertThrowsError(try MCPConnectorAuth.parseMetadata(
            from: Data(metadataJSON.replacingOccurrences(of: "https://mcp.example.com/token", with: "http://mcp.example.com/token").utf8), status: 200))
    }

    func testRegistersAsPublicAppAndBuildsTheSignInPage() throws {
        let metadata = try MCPConnectorAuth.parseMetadata(from: Data(metadataJSON.utf8), status: 200)
        let registration = try MCPConnectorAuth.registrationRequest(metadata)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(registration.httpBody)) as? [String: Any])
        XCTAssertEqual(body["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(body["redirect_uris"] as? [String], ["keelmobile://connector/callback"])
        XCTAssertEqual(try MCPConnectorAuth.parseRegistration(from: Data(#"{"client_id":"abc","client_secret":"ignored"}"#.utf8), status: 201), "abc")
        XCTAssertThrowsError(try MCPConnectorAuth.parseRegistration(from: Data("{}".utf8), status: 403)) {
            XCTAssertEqual($0 as? MCPConnectorAuth.Problem, .notSupported)
        }

        let page = try MCPConnectorAuth.authorizeURL(metadata, clientID: "abc", state: "st", challenge: "ch",
                                                     scopes: ["read", "write"], resource: "https://mcp.example.com/mcp")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(page.host, "mcp.example.com")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "read write")
        XCTAssertEqual(items["redirect_uri"], MCPConnectorAuth.redirectURI)
        XCTAssertEqual(items["resource"], "https://mcp.example.com/mcp")
        XCTAssertFalse(page.absoluteString.contains("verifier"))
    }

    func testCallbackMustMatchStateAndAddress() throws {
        let good = URL(string: "keelmobile://connector/callback?code=C0de-1_2&state=st")!
        XCTAssertEqual(try MCPConnectorAuth.code(from: good, state: "st"), "C0de-1_2")
        for bad in ["keelmobile://connector/callback?code=x&state=other",
                    "keelmobile://github/callback?code=x&state=st",
                    "other://connector/callback?code=x&state=st",
                    "keelmobile://connector/callback?state=st",
                    "keelmobile://connector/callback?code=x&code=y&state=st"] {
            XCTAssertThrowsError(try MCPConnectorAuth.code(from: URL(string: bad)!, state: "st"), bad) {
                XCTAssertEqual($0 as? MCPConnectorAuth.Problem, .callback)
            }
        }
        XCTAssertThrowsError(try MCPConnectorAuth.code(from: URL(string: "keelmobile://connector/callback?error=access_denied&state=st")!, state: "st")) {
            XCTAssertEqual($0 as? MCPConnectorAuth.Problem, .cancelled)
        }
    }

    func testTokenExchangeRefreshAndGrant() throws {
        let metadata = try MCPConnectorAuth.parseMetadata(from: Data(metadataJSON.utf8), status: 200)
        let exchange = MCPConnectorAuth.tokenRequest(metadata, clientID: "abc", code: "c/1+2", verifier: "ver", resource: "https://mcp.example.com/mcp")
        let form = String(decoding: try XCTUnwrap(exchange.httpBody), as: UTF8.self)
        XCTAssertEqual(exchange.url, metadata.tokenEndpoint)
        XCTAssertTrue(form.contains("code=c%2F1%2B2"))
        XCTAssertTrue(form.contains("code_verifier=ver"))
        XCTAssertTrue(form.contains("redirect_uri=keelmobile%3A%2F%2Fconnector%2Fcallback"))
        XCTAssertNil(exchange.value(forHTTPHeaderField: "Authorization"))

        let now = Date(timeIntervalSince1970: 1_000)
        let tokens = try MCPConnectorAuth.parseTokens(from: Data(#"{"access_token":"at1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt1"}"#.utf8), status: 200)
        var grant = MCPConnectorAuth.grant(from: tokens, clientID: "abc", tokenEndpoint: metadata.tokenEndpoint, resource: nil, now: now)
        XCTAssertFalse(grant.needsRefresh(now: now))
        XCTAssertTrue(grant.needsRefresh(now: now.addingTimeInterval(3_550)))

        let refresh = String(decoding: try XCTUnwrap(try MCPConnectorAuth.refreshRequest(grant).httpBody), as: UTF8.self)
        XCTAssertTrue(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=rt1") && refresh.contains("client_id=abc"))
        // A renewal without a new refresh token keeps the old one.
        let renewed = try MCPConnectorAuth.parseTokens(from: Data(#"{"access_token":"at2"}"#.utf8), status: 200)
        grant = MCPConnectorAuth.grant(from: renewed, clientID: "abc", tokenEndpoint: metadata.tokenEndpoint, resource: nil, previous: grant, now: now)
        XCTAssertEqual(grant.accessToken, "at2")
        XCTAssertEqual(grant.refreshToken, "rt1")
        XCTAssertNil(grant.expiresAt)
        XCTAssertEqual(try JSONDecoder().decode(MCPConnectorAuth.Grant.self, from: JSONEncoder().encode(grant)), grant)

        XCTAssertThrowsError(try MCPConnectorAuth.parseTokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)) {
            XCTAssertEqual($0 as? MCPConnectorAuth.Problem, .refused)
        }
        XCTAssertThrowsError(try MCPConnectorAuth.parseTokens(from: Data(#"{"access_token":"a\nb"}"#.utf8), status: 200))
    }
}

/// Real services, real network. Skipped unless `KEEL_LIVE_CONNECTORS=1`:
/// `KEEL_LIVE_CONNECTORS=1 swift test --filter MCPConnectorLiveTests`.
/// Read-only: a handshake, a tool list, one lookup, and sign-in address discovery.
/// It does not register Keel with any service and does not sign in.
final class MCPConnectorLiveTests: XCTestCase {
    // One session for the whole run: on Linux a session freed mid-run aborts the process.
    private static let session = URLSession(configuration: .ephemeral)

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEEL_LIVE_CONNECTORS"] == "1", "set KEEL_LIVE_CONNECTORS=1 to run")
    }

    func testOpenServicesHandshakeListToolsAndAnswer() async throws {
        try live()
        for entry in MCPConnector.catalog where !entry.signIn {
            let endpoint = try MCPConnector.validateEndpoint(entry.endpoint)
            let (hello, helloResponse) = try await send(MCPConnector.initializeRequest(endpoint: endpoint))
            let session = try MCPConnector.parseInitialize(
                from: hello, status: helloResponse.statusCode,
                contentType: helloResponse.value(forHTTPHeaderField: "Content-Type"),
                sessionHeader: helloResponse.value(forHTTPHeaderField: "Mcp-Session-Id"))
            let (_, ready) = try await send(MCPConnector.initializedRequest(endpoint: endpoint, session: session))
            XCTAssertTrue((200...299).contains(ready.statusCode), entry.name)
            let (list, listResponse) = try await send(MCPConnector.listToolsRequest(endpoint: endpoint, session: session))
            let tools = try MCPConnector.parseTools(from: list, status: listResponse.statusCode, serverID: entry.id,
                                                    contentType: listResponse.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertFalse(tools.isEmpty, entry.name)
            for tool in tools { XCTAssertNotNil(ToolSchema(tool.schemaLine), tool.callName) }
            print("LIVE \(entry.name): protocol \(session.protocolVersion), session \(session.sessionID == nil ? "none" : "yes"), tools: "
                  + tools.map { "\($0.callName)(\($0.parameters.map(\.name).joined(separator: ",")))" }.joined(separator: " "))

            guard entry.id == "microsoft_learn", let search = tools.first(where: { $0.remoteName == "microsoft_docs_search" }) else { continue }
            let server = MCPConnector.Server(id: entry.id, name: entry.name, endpoint: entry.endpoint, tools: tools)
            let (answer, answerResponse) = try await send(MCPConnector.callToolRequest(
                server: server, tool: search, arguments: ["query": "Swift on Azure Functions"], session: session))
            let result = try MCPConnector.parseCallResult(from: answer, status: answerResponse.statusCode, serverName: entry.name,
                                                          toolName: search.remoteName,
                                                          contentType: answerResponse.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertFalse(result.isError)
            XCTAssertGreaterThan(result.text.count, 200)
            print("LIVE call \(search.callName): \(result.text.count) characters, starts: \(result.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    func testSignInServicesPublishEverythingOneTapNeeds() async throws {
        try live()
        for entry in MCPConnector.catalog where entry.signIn {
            let endpoint = try MCPConnector.validateEndpoint(entry.endpoint)
            let (_, refused) = try await send(MCPConnector.initializeRequest(endpoint: endpoint))
            XCTAssertEqual(refused.statusCode, 401, entry.name)
            let named = MCPConnectorAuth.resourceMetadataURL(wwwAuthenticate: refused.value(forHTTPHeaderField: "WWW-Authenticate"))
            var found: (resource: String?, issuer: URL, scopes: [String])?
            for url in [named].compactMap({ $0 }) + MCPConnectorAuth.resourceMetadataURLs(endpoint: endpoint) where found == nil {
                let (data, response) = try await send(URLRequest(url: url))
                found = try? MCPConnectorAuth.parseResource(from: data, status: response.statusCode)
            }
            let resource = try XCTUnwrap(found, entry.name)
            var metadata: MCPConnectorAuth.Metadata?
            for url in MCPConnectorAuth.metadataURLs(issuer: resource.issuer) where metadata == nil {
                let (data, response) = try await send(URLRequest(url: url))
                metadata = try? MCPConnectorAuth.parseMetadata(from: data, status: response.statusCode)
            }
            let signIn = try XCTUnwrap(metadata, entry.name)
            XCTAssertNotNil(signIn.registrationEndpoint, "\(entry.name) has no app registration")
            print("LIVE \(entry.name): sign-in at \(signIn.authorizationEndpoint.host ?? "?"), registration \(signIn.registrationEndpoint == nil ? "missing" : "open"), scopes \(resource.scopes.count)")
        }
    }
}
