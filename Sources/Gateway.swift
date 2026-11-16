import Foundation

struct GatewayStatus: Decodable {
    let status: String
    let execution_mode: String
    let workspace_path: String
    let workspace_safe: Bool
    let approval_policy: String
}

struct Approval: Decodable, Identifiable {
    let id: String
    let kind: String
    let command: String
    let reason: String?
    let status: String
}

struct CommandResult: Decodable {
    let command: String
    let exit_code: Int?
    let stdout: String
    let stderr: String
    let timed_out: Bool

    var display: String {
        "$ \(command)\n\(stdout)\(stderr)\nExit: \(exit_code.map(String.init) ?? "unknown")\(timed_out ? " (timed out)" : "")"
    }
}

struct ExecutionReply: Decodable {
    let status: String
    let result: CommandResult?
    let approval: Approval?
    let error: String?

    private enum CodingKeys: String, CodingKey { case status, result, approval, error }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(String.self, forKey: .status)
        // Keel acknowledgements and PR results have different shapes from shell output.
        result = try? values.decode(CommandResult.self, forKey: .result)
        approval = try values.decodeIfPresent(Approval.self, forKey: .approval)
        error = try values.decodeIfPresent(String.self, forKey: .error)
    }
}

struct DiffReply: Decodable { let diff: String }

enum GatewayError: LocalizedError {
    case invalidAddress, missingToken, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Use an HTTPS gateway address without a path, query, or embedded credentials."
        case .missingToken: return "Enter the gateway pairing token."
        case .http(let code):
            return code == 401 ? "Pairing token rejected. Check the token and reconnect." : "Gateway request failed (HTTP \(code))."
        }
    }
}

// Refuse redirects: a gateway credential must never follow a redirect to another host.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class Gateway {
    let baseURL: URL
    private let token: String
    private let session: URLSession

    static func address(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw GatewayError.invalidAddress
        }
        return url
    }

    init(address: String, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        baseURL = try Self.address(address)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.token.isEmpty else { throw GatewayError.missingToken }
        configuration.timeoutIntervalForRequest = 90
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private func call<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GatewayError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func status() async throws -> GatewayStatus { try await call("api/status") }
    func approvals() async throws -> [Approval] { try await call("api/approvals") }
    func diff() async throws -> String {
        let reply: DiffReply = try await call("api/git/diff")
        return reply.diff
    }
    func execute(_ command: String, pty: Bool) async throws -> ExecutionReply {
        try await call("api/exec", body: ["command": command, "pty": pty, "reason": "Requested from the native iOS app"])
    }
    func decide(_ approval: Approval, approved: Bool) async throws -> ExecutionReply {
        // UUID validation prevents an identifier from modifying the request path.
        guard UUID(uuidString: approval.id) != nil else { throw GatewayError.invalidAddress }
        return try await call("api/approvals/\(approval.id)/decide", body: ["approved": approved])
    }
}
