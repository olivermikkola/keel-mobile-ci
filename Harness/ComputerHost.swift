import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Parsed contents of a `keelpair://v1?...` QR code shown by Keel Desktop or `keel-desktop-cli host`.
public struct ComputerPairingBundle: Equatable, Sendable, Codable {
    public let version: Int
    public let hostName: String
    public let urls: [String]
    public let fingerprint: String
    public let token: String

    public init(version: Int = 1, hostName: String, urls: [String], fingerprint: String, token: String) {
        self.version = version
        self.hostName = hostName
        self.urls = urls
        self.fingerprint = fingerprint.lowercased()
        self.token = token
    }

    /// Strict fail-closed parser for `keelpair://v1?n=...&u=...&f=...&t=...`.
    public static func parse(_ raw: String) throws -> ComputerPairingBundle {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("keelpair://v1?") else {
            throw ComputerHostError.invalidPairingLink("Pairing code must start with keelpair://v1?")
        }
        guard let components = URLComponents(string: trimmed), let items = components.queryItems else {
            throw ComputerHostError.invalidPairingLink("Could not read the pairing code.")
        }
        var map: [String: String] = [:]
        for item in items {
            if let value = item.value {
                map[item.name] = value
            }
        }
        let hostName = (map["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostName.isEmpty, hostName.count <= 64 else {
            throw ComputerHostError.invalidPairingLink("Missing or invalid computer name.")
        }
        let rawURLs = (map["u"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        guard !rawURLs.isEmpty, rawURLs.count <= 6 else {
            throw ComputerHostError.invalidPairingLink("Pairing code must include 1 to 6 HTTPS addresses.")
        }
        var validated: [String] = []
        for candidate in rawURLs {
            guard let parts = URLComponents(string: candidate),
                  parts.scheme?.lowercased() == "https",
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/" else {
                throw ComputerHostError.invalidPairingLink("Every computer address must be a clean https:// origin.")
            }
            if !validated.contains(candidate) {
                validated.append(candidate)
            }
        }
        let fingerprint = (map["f"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard fingerprint.count == 64,
              fingerprint.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw ComputerHostError.invalidPairingLink("Invalid certificate fingerprint.")
        }
        let token = (map["t"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 16, token.count <= 256,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ComputerHostError.invalidPairingLink("Invalid pairing token.")
        }
        return ComputerPairingBundle(
            version: 1,
            hostName: hostName,
            urls: validated,
            fingerprint: fingerprint,
            token: token
        )
    }
}

public enum ComputerHostError: LocalizedError, Equatable {
    case invalidPairingLink(String)
    case notPaired
    case unreachable(String)
    case unauthorized
    case http(Int, String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidPairingLink(let detail): return detail
        case .notPaired: return "No computer is paired yet. Scan the QR code in Keel Desktop."
        case .unreachable(let detail): return "Could not reach your computer (\(detail)). Check that Keel Desktop is open and you are on the same Wi-Fi or Tailscale."
        case .unauthorized: return "Your computer rejected the pairing token. Scan a fresh QR code in Keel Desktop."
        case .http(let code, let msg): return msg ?? "Computer host returned HTTP \(code)."
        case .invalidResponse: return "Your computer returned an unexpected response."
        }
    }
}

public struct ComputerAvailableModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let installed: Bool
}

public struct ComputerHostInfo: Codable, Equatable, Sendable {
    public let protocol_version: Int
    public let host_name: String
    public let desktop_version: String
    public let model_name: String
    public let model_id: String?
    public let runtime_state: String
    public let available_models: [ComputerAvailableModel]
    public let active_turns: Int
    public let pending_approvals: Int
    public let schedule_count: Int
}

public struct ComputerThreadSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let app_preset: String
    public let workspace_path: String?
    public let status: String
    public let pending_approvals: Int
    public let message_count: Int
    public let updated_at: UInt64
}

public struct ComputerToolLog: Codable, Equatable, Sendable {
    public let name: String
    public let result: String?
    public let is_error: Bool
}

public struct ComputerMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let thinking: String?
    public let tool_calls: [ComputerToolLog]?
    public let status: String?
}

public struct ComputerStagedEdit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let path: String
    public let new_path: String?
    public let summary: String
    public let diff: String
    public let added_lines: Int
    public let removed_lines: Int
    public let status: String
}

public struct ComputerApproval: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tool: String
    public let summary: String
    public let arguments_json: String
}

public struct ComputerThreadDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let app_preset: String
    public let workspace_path: String?
    public let status: String
    public let messages: [ComputerMessage]
    public let staged_edits: [ComputerStagedEdit]
    public let pending_approvals: [ComputerApproval]
    public let latest_seq: UInt64
    public let error: String?
    public let updated_at: UInt64
}

public struct ComputerSendReply: Codable, Equatable, Sendable {
    public let thread_id: String
    public let turn_id: String
    public let status: String
    public let after_seq: UInt64
}

public struct ComputerSchedule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let prompt: String
    public let app_preset: String
    public let workspace_path: String?
    public let interval_minutes: UInt64
    public let repeat_enabled: Bool
    public let enabled: Bool
    public let watch_path: String?
    public let last_run_at: UInt64?
    public let next_run_at: UInt64
    public let last_thread_id: String?
    public let last_status: String

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, app_preset, workspace_path, interval_minutes, enabled
        case repeat_enabled = "repeat"
        case watch_path, last_run_at, next_run_at, last_thread_id, last_status
    }
}

public struct ComputerSSEFrame: Equatable, Sendable {
    public let seq: UInt64
    public let event: String
    public let data: String

    public init(seq: UInt64, event: String, data: String) {
        self.seq = seq
        self.event = event
        self.data = data
    }
}

/// Incremental SSE parser for `id: ...\nevent: ...\ndata: ...\n\n` frames.
public struct ComputerSSEParser: Sendable {
    private var currentID: UInt64 = 0
    private var currentEvent = ""
    private var currentData: [String] = []

    public init() {}

    public mutating func feed(line rawLine: String) -> ComputerSSEFrame? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line.isEmpty {
            defer {
                currentID = 0
                currentEvent = ""
                currentData = []
            }
            guard !currentEvent.isEmpty || !currentData.isEmpty else { return nil }
            return ComputerSSEFrame(
                seq: currentID,
                event: currentEvent.isEmpty ? "message" : currentEvent,
                data: currentData.joined(separator: "\n")
            )
        }
        if line.hasPrefix(":") {
            return nil
        }
        if let v = line.stripPrefix("id:") {
            currentID = UInt64(v.trimmingCharacters(in: .whitespaces)) ?? currentID
        } else if let v = line.stripPrefix("event:") {
            currentEvent = v.trimmingCharacters(in: .whitespaces)
        } else if let v = line.stripPrefix("data:") {
            let trimmed = v.hasPrefix(" ") ? String(v.dropFirst()) : v
            currentData.append(trimmed)
        }
        return nil
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Non-secret metadata persisted in UserDefaults; token + cert fingerprint live only in Keychain.
public struct SavedComputerProfile: Codable, Equatable, Sendable {
    public let hostName: String
    public let urls: [String]
    public var preferredURL: String?

    public init(hostName: String, urls: [String], preferredURL: String? = nil) {
        self.hostName = hostName
        self.urls = urls
        self.preferredURL = preferredURL
    }

    public var orderedURLs: [String] {
        guard let preferred = preferredURL, urls.contains(preferred) else { return urls }
        return [preferred] + urls.filter { $0 != preferred }
    }
}

/// URLSession delegate enforcing leaf-certificate SHA-256 pinning and refusing redirects.
public final class PinnedHostDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    public let expectedFingerprint: String

    public init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint.lowercased()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    #if canImport(Security) && canImport(CryptoKit)
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    #endif
}

private struct ThreadsEnvelope: Decodable { let threads: [ComputerThreadSummary] }
private struct SchedulesEnvelope: Decodable { let schedules: [ComputerSchedule] }
private struct ErrorEnvelope: Decodable { let error: String? }

/// Pinned-TLS client for communicating with a QR-paired Keel Desktop host.
public final class ComputerHostClient: @unchecked Sendable {
    public let urls: [String]
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var activeBaseURL: String

    public init(urls: [String], fingerprint: String, token: String, timeoutSeconds: TimeInterval = 30) throws {
        guard let first = urls.first else {
            throw ComputerHostError.invalidPairingLink("No computer address provided.")
        }
        self.urls = urls
        self.activeBaseURL = first
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        let delegate = PinnedHostDelegate(expectedFingerprint: fingerprint)
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public var currentBaseURL: String {
        lock.lock()
        defer { lock.unlock() }
        return activeBaseURL
    }

    private func setActiveBaseURL(_ url: String) {
        lock.lock()
        activeBaseURL = url
        lock.unlock()
    }

    private func candidateBases() -> [String] {
        let current = currentBaseURL
        return [current] + urls.filter { $0 != current }
    }

    private func makeRequest(base: String, path: String, method: String = "GET", jsonBody: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: base + path) else {
            throw ComputerHostError.invalidPairingLink("Invalid host URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return req
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        var lastError: Error = ComputerHostError.unreachable("no address responded")
        for base in candidateBases() {
            let req = try makeRequest(base: base, path: path, method: method, jsonBody: body)
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw ComputerHostError.invalidResponse
                }
                if http.statusCode == 401 {
                    throw ComputerHostError.unauthorized
                }
                guard (200..<300).contains(http.statusCode) else {
                    let msg = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
                    throw ComputerHostError.http(http.statusCode, msg)
                }
                setActiveBaseURL(base)
                return try JSONDecoder().decode(T.self, from: data)
            } catch let hostErr as ComputerHostError {
                throw hostErr
            } catch {
                lastError = error
                continue
            }
        }
        throw ComputerHostError.unreachable(lastError.localizedDescription)
    }

    public func info() async throws -> ComputerHostInfo {
        try await request("/api/v1/info")
    }

    public func listThreads() async throws -> [ComputerThreadSummary] {
        let env: ThreadsEnvelope = try await request("/api/v1/threads")
        return env.threads
    }

    public func createThread(title: String? = nil, appPreset: String = "chat", workspacePath: String? = nil) async throws -> ComputerThreadDetail {
        var body: [String: Any] = ["app_preset": appPreset]
        if let title { body["title"] = title }
        if let workspacePath { body["workspace_path"] = workspacePath }
        return try await request("/api/v1/threads", method: "POST", body: body)
    }

    public func threadDetail(id: String) async throws -> ComputerThreadDetail {
        try await request("/api/v1/threads/\(id)")
    }

    public func sendMessage(threadID: String, prompt: String, enableThinking: Bool = false) async throws -> ComputerSendReply {
        try await request(
            "/api/v1/threads/\(threadID)/messages",
            method: "POST",
            body: ["prompt": prompt, "enable_thinking": enableThinking]
        )
    }

    public func cancelThread(id: String) async throws {
        struct CancelReply: Decodable { let cancelled: Bool }
        let _: CancelReply = try await request("/api/v1/threads/\(id)/cancel", method: "POST", body: [:])
    }

    public func respondApproval(threadID: String, approvalID: String, decision: String) async throws {
        struct Reply: Decodable { let resolved: Bool }
        let _: Reply = try await request(
            "/api/v1/threads/\(threadID)/approvals/\(approvalID)",
            method: "POST",
            body: ["decision": decision]
        )
    }

    public func resolveEdit(threadID: String, editID: String, action: String) async throws {
        struct Reply: Decodable { let status: String }
        let _: Reply = try await request(
            "/api/v1/threads/\(threadID)/edits/\(editID)",
            method: "POST",
            body: ["action": action]
        )
    }

    public func listSchedules() async throws -> [ComputerSchedule] {
        let env: SchedulesEnvelope = try await request("/api/v1/schedules")
        return env.schedules
    }

    public func createSchedule(
        name: String,
        prompt: String,
        appPreset: String = "chat",
        intervalMinutes: UInt64 = 60,
        repeatEnabled: Bool = true,
        nextRunAt: UInt64? = nil,
        watchPath: String? = nil
    ) async throws -> ComputerSchedule {
        var body: [String: Any] = [
            "name": name,
            "prompt": prompt,
            "app_preset": appPreset,
            "interval_minutes": intervalMinutes,
            "repeat": repeatEnabled
        ]
        if let nextRunAt { body["next_run_at"] = nextRunAt }
        if let watchPath, !watchPath.isEmpty { body["watch_path"] = watchPath }
        return try await request("/api/v1/schedules", method: "POST", body: body)
    }

    public func deleteSchedule(id: String) async throws {
        struct Reply: Decodable { let deleted: Bool }
        let _: Reply = try await request("/api/v1/schedules/\(id)", method: "DELETE")
    }

    public func runScheduleNow(id: String) async throws -> String {
        struct Reply: Decodable { let thread_id: String }
        let reply: Reply = try await request("/api/v1/schedules/\(id)/run", method: "POST", body: [:])
        return reply.thread_id
    }

    #if !os(Linux)
    /// Streams live and replayed SSE events for `threadID` starting after `afterSeq`.
    public func streamEvents(threadID: String, afterSeq: UInt64) -> AsyncThrowingStream<ComputerSSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try self.makeRequest(base: self.currentBaseURL, path: "/api/v1/threads/\(threadID)/events?after=\(afterSeq)")
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ComputerHostError.invalidResponse
                    }
                    if http.statusCode == 401 { throw ComputerHostError.unauthorized }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ComputerHostError.http(http.statusCode, nil)
                    }
                    var parser = ComputerSSEParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let frame = parser.feed(line: line) {
                            continuation.yield(frame)
                        }
                    }
                    if let tail = parser.feed(line: "") {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}
