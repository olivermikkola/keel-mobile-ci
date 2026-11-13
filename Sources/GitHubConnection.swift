import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct GitHubUser: Codable { let id: Int; let login: String }
struct GitHubRepositoryChoice: Decodable, Identifiable {
    let id: Int
    let full_name: String
    let default_branch: String
    let `private`: Bool
}
struct GitHubOAuthSession: Codable {
    let user: GitHubUser
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}
enum GitHubConnectionError: LocalizedError {
    case unavailable, response, cancelled, expired, callback
    var errorDescription: String? {
        switch self {
        case .unavailable: return "GitHub sign-in is temporarily unavailable. Try again shortly."
        case .response: return "GitHub could not be reached. Check your connection and try again."
        case .cancelled: return "GitHub sign-in was cancelled. Your previous connection is unchanged."
        case .expired: return "Your GitHub connection has expired. Connect GitHub again."
        case .callback: return "GitHub sign-in could not be verified. Tap Connect GitHub to try again."
        }
    }
}

struct GitHubBrokerTokens: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let token_type: String
    func session(user: GitHubUser) throws -> GitHubOAuthSession {
        guard token_type == "bearer", (10...512).contains(access_token.utf8.count),
              access_token.utf8.allSatisfy({ (33...126).contains($0) }),
              expires_in.map({ $0.isFinite && $0 > 0 && $0 <= 86_400 }) ?? true,
              refresh_token.map({ (10...512).contains($0.utf8.count) && $0.utf8.allSatisfy({ (33...126).contains($0) }) }) ?? true else { throw GitHubConnectionError.response }
        return GitHubOAuthSession(user: user, accessToken: access_token, refreshToken: refresh_token,
                                  expiresAt: expires_in.map { Date().addingTimeInterval($0) })
    }
}

final class GitHubAccountAPI {
    static let broker = URL(string: "https://keel-mobile-github.oliver-e-mikkola.workers.dev")!
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let configuration = configuration ?? Self.configuration()
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: GitHubSignInNoRedirects(), delegateQueue: nil)
    }
    private static func configuration() -> URLSessionConfiguration {
        #if DEBUG && targetEnvironment(simulator)
        if let recorded = RepositoryUITestTransport.configuration() { return recorded }
        #endif
        return .ephemeral
    }
    deinit { session.invalidateAndCancel() }

    func request<T: Decodable>(_ url: URL, token: String? = nil, body: [String: String]? = nil) async throws -> T {
        guard url.scheme == "https", ["api.github.com", Self.broker.host!].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { throw GitHubConnectionError.response }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("KeelMobile", forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token {
            guard url.host == "api.github.com", !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw GitHubConnectionError.response }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw GitHubConnectionError.response }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw GitHubConnectionError.expired }
            if http.statusCode == 503 { throw GitHubConnectionError.unavailable }
            throw GitHubConnectionError.response
        }
        guard http.expectedContentLength <= 1_048_576 else { throw GitHubConnectionError.response }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw GitHubConnectionError.response }
            data.append(byte)
        }
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubConnectionError.response }
    }
    func user(token: String) async throws -> GitHubUser {
        try await request(URL(string: "https://api.github.com/user")!, token: token)
    }
    func repositories(token: String, page: Int) async throws -> [GitHubRepositoryChoice] {
        guard page > 0, page <= 1000 else { throw GitHubConnectionError.response }
        return try await request(URL(string: "https://api.github.com/user/repos?sort=pushed&per_page=50&page=\(page)")!, token: token)
    }
}
private final class GitHubSignInNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// Refresh is serialized and pinned to the signed-in GitHub identity. Existing
// repository clients cannot silently inherit a different account after reconnect.
actor GitHubOAuthStore {
    static let shared = GitHubOAuthStore()
    private let api: GitHubAccountAPI
    private let read: () throws -> GitHubOAuthSession?
    private let write: (GitHubOAuthSession) throws -> Void
    private var refreshing: (userID: Int, task: Task<GitHubOAuthSession, Error>)?
    init(api: GitHubAccountAPI = GitHubAccountAPI(),
         read: @escaping () throws -> GitHubOAuthSession? = { try GitHubCredential.oauthSession() },
         write: @escaping (GitHubOAuthSession) throws -> Void = { try GitHubCredential.saveOAuthSession($0) }) {
        self.api = api; self.read = read; self.write = write
    }
    func token(for userID: Int) async throws -> String {
        guard let stored = try read(), stored.user.id == userID else { throw GitHubConnectionError.expired }
        guard let expiry = stored.expiresAt, expiry.timeIntervalSinceNow <= 60 else { return stored.accessToken }
        guard let refresh = stored.refreshToken else { throw GitHubConnectionError.expired }
        if let refreshing {
            guard refreshing.userID == userID else { throw GitHubConnectionError.expired }
            return try await refreshing.task.value.accessToken
        }
        let task = Task {
            let result: GitHubBrokerTokens = try await api.request(GitHubAccountAPI.broker.appendingPathComponent("refresh"), body: ["refresh_token": refresh])
            let session = try result.session(user: stored.user)
            guard let current = try read(), current.user.id == userID,
                  current.accessToken == stored.accessToken, current.refreshToken == stored.refreshToken else {
                throw GitHubConnectionError.expired
            }
            try write(session)
            return session
        }
        refreshing = (userID, task)
        defer { refreshing = nil }
        return try await task.value.accessToken
    }
}

struct GitHubSignInChallenge {
    let state: String
    let verifier: String
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().urlSafeBase64 }
    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GitHubConnectionError.unavailable }
            return Data(bytes).base64EncodedString().urlSafeBase64
        }
        state = try random(); verifier = try random()
    }
    init(state: String, verifier: String) {
        self.state = state; self.verifier = verifier
    }
    var startURL: URL {
        var url = URLComponents(url: GitHubAccountAPI.broker.appendingPathComponent("start"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "challenge", value: challenge)]
        return url.url!
    }
    func code(from callback: URL) throws -> String {
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let items = values?.queryItems ?? []
        guard callback.scheme == "keelmobile", callback.host == "github", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw GitHubConnectionError.callback }
        if items.contains(where: { $0.name == "error" }) { throw GitHubConnectionError.cancelled }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              (10...200).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw GitHubConnectionError.callback }
        return code
    }
}
private extension String {
    var urlSafeBase64: String { replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

@MainActor
final class GitHubConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var user: GitHubUser?
    @Published private(set) var repositories: [GitHubRepositoryChoice] = []
    @Published private(set) var working = false
    @Published private(set) var canLoadMore = false
    @Published var error: String?
    @Published private(set) var installURL: URL?
    private var page = 0
    private var operation: Task<Void, Never>?
    private var browser: ASWebAuthenticationSession?
    private var authorization: CheckedContinuation<URL, Error>?
    var hasCredential: Bool { isRecordedAccount || GitHubCredential.contains() }
    private var isRecordedAccount: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--recorded-github-account") && RepositoryUITestTransport.configuration() != nil
        #else
        return false
        #endif
    }

    override init() {
        super.init()
        user = try? GitHubCredential.oauthSession()?.user
        if isRecordedAccount { user = GitHubUser(id: 7, login: "fixture-owner") }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func signIn() {
        guard !working else { return }
        error = nil; working = true
        operation = Task {
            defer { working = false; operation = nil }
            do {
                let api = GitHubAccountAPI()
                let config: GitHubConnectorConfiguration = try await api.request(GitHubAccountAPI.broker.appendingPathComponent("config"))
                guard config.configured else { throw GitHubConnectionError.unavailable }
                let challenge = try GitHubSignInChallenge()
                let returned = try await authenticate(challenge.startURL)
                let code = try challenge.code(from: returned)
                let tokens: GitHubBrokerTokens = try await api.request(GitHubAccountAPI.broker.appendingPathComponent("exchange"),
                    body: ["state": challenge.state, "verifier": challenge.verifier, "code": code])
                let identity = try await api.user(token: tokens.access_token)
                let stored = try tokens.session(user: identity)
                try Task.checkCancellation()
                try GitHubCredential.saveOAuthSession(stored)
                user = identity; page = 0; repositories = []
                try await loadPage()
            } catch is CancellationError { }
            catch { self.error = connectionMessage(error) }
        }
    }
    func reload() {
        guard !working, hasCredential else { return }
        error = nil; working = true
        operation = Task {
            defer { working = false; operation = nil }
            do {
                let api = GitHubAccountAPI()
                let token = try await credential()
                user = try await api.user(token: token)
                page = 0; repositories = []
                try await loadPage()
            } catch is CancellationError { }
            catch { self.error = connectionMessage(error) }
        }
    }
    func loadMore() {
        guard !working, canLoadMore else { return }
        error = nil; working = true
        operation = Task {
            defer { working = false; operation = nil }
            do { try await loadPage() }
            catch is CancellationError { }
            catch { self.error = connectionMessage(error) }
        }
    }
    private func credential() async throws -> String {
        if isRecordedAccount { return "ghu_recorded_ui_fixture" }
        if let stored = try GitHubCredential.oauthSession() { return try await GitHubOAuthStore.shared.token(for: stored.user.id) }
        return try GitHubCredential.load()
    }
    private func loadPage() async throws {
        let api = GitHubAccountAPI()
        let token = try await credential()
        let result = try await api.repositories(token: token, page: page + 1)
        let config: GitHubConnectorConfiguration? = try? await api.request(GitHubAccountAPI.broker.appendingPathComponent("config"))
        try Task.checkCancellation()
        let existing = Set(repositories.map(\.id))
        repositories += result.filter { !existing.contains($0.id) }
        page += 1; canLoadMore = result.count == 50
        installURL = config?.install_url
    }
    func disconnect() {
        guard !working else { return }
        do { try GitHubCredential.remove(); user = nil; repositories = []; page = 0; canLoadMore = false; error = nil }
        catch { self.error = connectionMessage(error) }
    }
    func cancel() {
        operation?.cancel(); browser?.cancel(); browser = nil
        authorization?.resume(throwing: CancellationError()); authorization = nil
    }
    private func authenticate(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                authorization = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "keelmobile") { [weak self] returned, error in
                    Task { @MainActor in
                        guard let self, let pending = self.authorization else { return }
                        self.authorization = nil; self.browser = nil
                        if let returned { pending.resume(returning: returned) }
                        else { pending.resume(throwing: error ?? GitHubConnectionError.cancelled) }
                    }
                }
                browser = session; session.presentationContextProvider = self
                if !session.start() { authorization = nil; browser = nil; continuation.resume(throwing: GitHubConnectionError.unavailable) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
}
private struct GitHubConnectorConfiguration: Decodable { let configured: Bool; let install_url: URL? }
func connectionMessage(_ error: Error) -> String {
    if error is GitHubConnectionError || error is RepositoryError { return error.localizedDescription }
    if let web = error as? ASWebAuthenticationSessionError, web.code == .canceledLogin { return GitHubConnectionError.cancelled.localizedDescription }
    return GitHubConnectionError.response.localizedDescription
}
