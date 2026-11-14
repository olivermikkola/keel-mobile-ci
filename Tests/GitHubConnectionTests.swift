import XCTest
@testable import KeelMobile

final class GitHubConnectionTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    private func api() -> GitHubAccountAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubAccountAPI(configuration: configuration)
    }
    func testPKCEUsesRFC7636VectorAndNeverSendsVerifierInStartURL() throws {
        let proof = GitHubSignInChallenge(state: String(repeating: "s", count: 43),
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(proof.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = URLComponents(url: proof.startURL, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(url.host, GitHubAccountAPI.broker.host)
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "challenge" })?.value, proof.challenge)
        XCTAssertFalse(proof.startURL.absoluteString.contains(proof.verifier))
        let other = try GitHubSignInChallenge()
        XCTAssertEqual(other.state.utf8.count, 43); XCTAssertEqual(other.verifier.utf8.count, 43)
        XCTAssertNotEqual(other.state, try GitHubSignInChallenge().state)
    }
    func testCallbackRequiresExactOriginStateAndSingleCode() throws {
        let proof = GitHubSignInChallenge(state: String(repeating: "s", count: 43), verifier: "unused")
        let valid = "keelmobile://github/callback?state=\(proof.state)&code=abcdef1234567890"
        XCTAssertEqual(try proof.code(from: URL(string: valid)!), "abcdef1234567890")
        for bad in [valid.replacingOccurrences(of: "keelmobile:", with: "https:"),
                    valid.replacingOccurrences(of: "github/", with: "attacker/"),
                    valid.replacingOccurrences(of: proof.state, with: "wrong"),
                    valid + "&state=\(proof.state)", valid + "&code=abcdef1234567890",
                    valid + "#fragment", valid.replacingOccurrences(of: "github/", with: "user@github/"),
                    valid.replacingOccurrences(of: "github/", with: "github:123/"),
                    valid.replacingOccurrences(of: "abcdef1234567890", with: "short")] {
            XCTAssertThrowsError(try proof.code(from: URL(string: bad)!))
        }
        XCTAssertThrowsError(try proof.code(from: URL(string: "keelmobile://github/callback?state=\(proof.state)&error=access_denied")!))
    }
    func testRepositoryPickerUsesAuthenticatedGitHubAPIAndDefaultBranch() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/user/repos")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value, "2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access-token")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-access-token"))
            return (200, Data(#"[{"id":42,"full_name":"owner/private-repo","default_branch":"develop","private":true}]"#.utf8))
        }
        let repos = try await api().repositories(token: "fixture-access-token", page: 2)
        XCTAssertEqual(repos.first?.full_name, "owner/private-repo")
        XCTAssertEqual(repos.first?.default_branch, "develop"); XCTAssertEqual(repos.first?.private, true)
    }
    func testAPIRejectsCredentialLeaksAndUnsafeURLsBeforeNetwork() async throws {
        var requests = 0
        StubProtocol.handler = { _ in requests += 1; return (200, Data("{}".utf8)) }
        let api = api()
        for url in ["http://api.github.com/user", "https://attacker.example/user", "https://user@api.github.com/user", "https://api.github.com:443/user", "https://api.github.com/user#fragment", GitHubAccountAPI.broker.appendingPathComponent("config").absoluteString] {
            do { let _: GitHubUser = try await api.request(URL(string: url)!, token: "fixture-access-token"); XCTFail("Unsafe request accepted") }
            catch { }
        }
        XCTAssertEqual(requests, 0)
    }
    func testRefreshPinsIdentityAndDoesNotReplaceReconnectedCredential() async throws {
        let user = GitHubUser(id: 7, login: "owner")
        let original = GitHubOAuthSession(user: user, accessToken: "old-access-token", refreshToken: "ghr_fixture_refresh", expiresAt: .distantPast)
        let box = SessionBox(original)
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url, GitHubAccountAPI.broker.appendingPathComponent("refresh"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.query)
            return (200, Data(#"{"access_token":"new-access-token","refresh_token":"ghr_replacement_refresh","expires_in":28800,"token_type":"bearer"}"#.utf8))
        }
        let store = GitHubOAuthStore(api: api(), read: { box.value }, write: { box.value = $0 })
        do { _ = try await store.token(for: 9); XCTFail("Wrong identity accepted") } catch { }
        XCTAssertEqual(calls, 0)
        async let first = store.token(for: 7)
        async let second = store.token(for: 7)
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["new-access-token", "new-access-token"])
        XCTAssertEqual(calls, 1); XCTAssertEqual(box.value?.refreshToken, "ghr_replacement_refresh")
        box.value = original
        StubProtocol.handler = { _ in
            box.value = GitHubOAuthSession(user: user, accessToken: "reconnected-token", refreshToken: nil, expiresAt: nil)
            return (200, Data(#"{"access_token":"stale-refresh-token","expires_in":28800,"token_type":"bearer"}"#.utf8))
        }
        do { _ = try await store.token(for: 7); XCTFail("Old refresh replaced a new connection") } catch { }
        XCTAssertEqual(box.value?.accessToken, "reconnected-token")
    }
    func testTokenResponseRejectsInvalidExpiryAndHeaderValues() throws {
        let user = GitHubUser(id: 7, login: "owner")
        for token in ["", "short", "fixture\r\ninvalid"] {
            XCTAssertThrowsError(try GitHubBrokerTokens(access_token: token, refresh_token: nil, expires_in: nil, token_type: "bearer").session(user: user))
        }
        for expiry in [-1.0, 0, .infinity, .nan, 1e12] {
            XCTAssertThrowsError(try GitHubBrokerTokens(access_token: "fixture-access-token", refresh_token: nil, expires_in: expiry, token_type: "bearer").session(user: user))
        }
    }
}
private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GitHubOAuthSession?
    init(_ value: GitHubOAuthSession?) { stored = value }
    var value: GitHubOAuthSession? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
