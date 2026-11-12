import Foundation
import CryptoKit

enum RepositoryError: LocalizedError, Equatable {
    case address, branch, response, tooLarge, unsupported, credential, http(Int), rateLimited(Date), permission(String?)
    var errorDescription: String? {
        switch self {
        case .address: return "Enter owner/repository or its HTTPS github.com address, without credentials, a query, or a fragment."
        case .branch: return "Enter a valid branch name, or leave it empty for the default branch."
        case .response: return "GitHub returned incomplete or inconsistent repository data. Try again."
        case .tooLarge: return "This file or directory is too large to open. Files are limited to 256 KB; partial content is never shown."
        case .unsupported: return "Only UTF-8 text files can be opened. Binary files, symlinks, and submodules are not followed."
        case .credential: return "The GitHub token could not be accessed in Keychain. Unlock your device and try again."
        case .rateLimited(let reset):
            return "GitHub’s request limit has been reached. Try again after \(reset.formatted(date: .omitted, time: .shortened)), or add a GitHub token when opening the repository."
        case .permission(let accepted):
            if let accepted, !accepted.isEmpty {
                return "GitHub needs additional permission for this action: \(accepted). Update the fine-grained token, then try again."
            }
            return "GitHub denied this action. The token needs Contents, Pull requests and Actions write access for publishing."
        case .http(let code):
            switch code {
            case 301, 302, 307, 308: return "This repository has moved. Use its current GitHub address."
            case 401: return "GitHub rejected the token. Replace it, or forget the saved token and try again."
            case 403, 429: return "GitHub denied this request or reached a rate limit. Check repository access or try later."
            case 404: return "GitHub could not open this repository or branch. If it’s private, connect GitHub and grant Keel access to it. Check that the selected branch still exists."
            default: return "GitHub request failed (HTTP \(code)). Try again."
            }
        }
    }
}

struct RepositoryID: Equatable, Codable {
    let owner: String
    let name: String
    var fullName: String { "\(owner)/\(name)" }

    init(_ input: String) throws {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.contains("://") {
            guard let url = URLComponents(string: path), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw RepositoryError.address
            }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw RepositoryError.address
        }
        owner = parts[0]; name = parts[1]
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(fullName)
    }
}

struct RepositorySnapshot: Codable, Equatable {
    let repository: RepositoryID
    let branch: String
    let commit: String
    let tree: String

    static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.repository == rhs.repository &&
        Data(lhs.branch.utf8) == Data(rhs.branch.utf8) &&
        lhs.commit == rhs.commit &&
        lhs.tree == rhs.tree
    }
}

extension RepositorySnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repository = try values.decode(RepositoryID.self, forKey: .repository)
        branch = try values.decode(String.self, forKey: .branch)
        commit = try values.decode(String.self, forKey: .commit)
        tree = try values.decode(String.self, forKey: .tree)
        guard !branch.isEmpty, branch.utf8.count <= 1024,
              !branch.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              GitHubRepository.validSHA(commit), GitHubRepository.validSHA(tree) else { throw RepositoryError.response }
    }
}

struct RepositoryEntry: Decodable, Identifiable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?
    var id: String { Data(path.utf8).map { String(format: "%02x", $0) }.joined() }
    var isDirectory: Bool { type == "tree" && mode == "040000" }
    var isTextCandidate: Bool { type == "blob" && ["100644", "100755"].contains(mode) }
}

final class GitHubRepository {
    let repository: RepositoryID
    private let token: String
    private let oauthUserID: Int?
    private let session: URLSession
    // Blob SHAs are content hashes. Cache only fully verified text, bounded by
    // count and bytes, so repeated tool reads do not refetch the same file.
    private let blobCache = NSCache<NSString, NSString>()
    static let fileLimit = 262_144

    init(repository: RepositoryID, token: String = "", configuration: URLSessionConfiguration = .ephemeral) throws {
        self.repository = repository
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let oauth = try? GitHubCredential.oauthSession(), oauth.accessToken == self.token { oauthUserID = oauth.user.id }
        else { oauthUserID = nil }
        guard !self.token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RepositoryError.credential }
        #if DEBUG && targetEnvironment(simulator)
        let configuration = RepositoryUITestTransport.configuration() ?? configuration
        #endif
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        blobCache.countLimit = 64
        blobCache.totalCostLimit = 8 * 1_024 * 1_024
    }
    deinit { session.invalidateAndCancel() }

    private func authorizationToken() async throws -> String {
        if let oauthUserID { return try await GitHubOAuthStore.shared.token(for: oauthUserID) }
        return token
    }

    private func get<T: Decodable>(_ components: [String], queryItems: [URLQueryItem]? = nil, limit: Int = 2_097_152) async throws -> T {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var url = URLComponents(); url.scheme = "https"; url.host = "api.github.com"
        url.percentEncodedPath = (["repos", repository.owner, repository.name] + components)
            .map { "/" + $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined()
        if let queryItems { url.queryItems = queryItems }
        var request = URLRequest(url: url.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KeelMobile", forHTTPHeaderField: "User-Agent")
        let credential = try await authorizationToken()
        if !credential.isEmpty { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await BoundedHTTPTransfer.fetch(
            request, configuration: session.configuration, limit: limit)
        guard response.statusCode == 200 else {
            if [403, 429].contains(response.statusCode), response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = TimeInterval(value), reset.isFinite {
                throw RepositoryError.rateLimited(Date(timeIntervalSince1970: reset))
            }
            if response.statusCode == 403,
               let accepted = response.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"), !accepted.isEmpty {
                throw RepositoryError.permission(accepted)
            }
            throw RepositoryError.http(response.statusCode)
        }
        guard data.count <= limit else { throw RepositoryError.tooLarge }
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RepositoryError.response }
    }

    // MARK: - Mutating GitHub API Methods

    private func send<T: Decodable, B: Encodable>(
        method: String,
        components: [String],
        body: B? = nil,
        expectedStatus: Set<Int> = [200, 201],
        limit: Int = 2_097_152
    ) async throws -> T {
        guard !token.isEmpty else { throw RepositoryError.credential }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var url = URLComponents(); url.scheme = "https"; url.host = "api.github.com"
        url.percentEncodedPath = (["repos", repository.owner, repository.name] + components)
            .map { "/" + $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined()
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KeelMobile", forHTTPHeaderField: "User-Agent")
        let credential = try await authorizationToken()
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, http) = try await BoundedHTTPTransfer.fetch(
            request, configuration: session.configuration, limit: limit)
        guard expectedStatus.contains(http.statusCode) else {
            if [403, 429].contains(http.statusCode), http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let value = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = TimeInterval(value), reset.isFinite {
                throw RepositoryError.rateLimited(Date(timeIntervalSince1970: reset))
            }
            if http.statusCode == 403,
               let accepted = http.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions"), !accepted.isEmpty {
                throw RepositoryError.permission(accepted)
            }
            throw RepositoryError.http(http.statusCode)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        guard data.count <= limit else { throw RepositoryError.tooLarge }
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RepositoryError.response }
    }

    private struct EmptyResponse: Decodable {}

    func createBlob(content: String) async throws -> String {
        struct BlobReq: Encodable { let content: String; let encoding: String = "utf-8" }
        struct BlobRes: Decodable { let sha: String }
        let res: BlobRes = try await send(method: "POST", components: ["git", "blobs"], body: BlobReq(content: content), expectedStatus: [201])
        guard Self.validSHA(res.sha) else { throw RepositoryError.response }
        return res.sha
    }

    struct TreeEntryItem: Encodable {
        let path: String
        let mode: String
        let type: String
        // nil deletes the path from the base tree. GitHub needs an explicit
        // JSON null for that, which synthesized Encodable would omit.
        let sha: String?

        init(path: String, sha: String?, mode: String = "100644", type: String = "blob") {
            self.path = path; self.sha = sha; self.mode = mode; self.type = type
        }

        private enum CodingKeys: String, CodingKey { case path, mode, type, sha }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(mode, forKey: .mode)
            try container.encode(type, forKey: .type)
            if let sha { try container.encode(sha, forKey: .sha) } else { try container.encodeNil(forKey: .sha) }
        }
    }

    func createTree(baseTree: String, entries: [TreeEntryItem]) async throws -> String {
        struct TreeReq: Encodable {
            let base_tree: String
            let tree: [TreeEntryItem]
        }
        struct TreeRes: Decodable { let sha: String }
        guard Self.validSHA(baseTree) else { throw RepositoryError.response }
        let res: TreeRes = try await send(method: "POST", components: ["git", "trees"], body: TreeReq(base_tree: baseTree, tree: entries), expectedStatus: [201])
        guard Self.validSHA(res.sha) else { throw RepositoryError.response }
        return res.sha
    }

    func createCommit(message: String, tree: String, parents: [String]) async throws -> String {
        struct CommitReq: Encodable {
            let message: String
            let tree: String
            let parents: [String]
        }
        struct CommitRes: Decodable { let sha: String }
        guard Self.validSHA(tree), parents.allSatisfy(Self.validSHA) else { throw RepositoryError.response }
        let res: CommitRes = try await send(method: "POST", components: ["git", "commits"], body: CommitReq(message: message, tree: tree, parents: parents), expectedStatus: [201])
        guard Self.validSHA(res.sha) else { throw RepositoryError.response }
        return res.sha
    }

    func createBranch(name: String, commit: String) async throws {
        struct RefReq: Encodable { let ref: String; let sha: String }
        guard Self.validSHA(commit), Self.validBranch(name) else { throw RepositoryError.branch }
        let _: EmptyResponse = try await send(method: "POST", components: ["git", "refs"],
            body: RefReq(ref: "refs/heads/\(name)", sha: commit), expectedStatus: [201])
    }

    // Returns false when the branch moved. Publishing must re-read and ask the
    // user again rather than force a ref update over someone else's commit.
    func updateBranch(name: String, commit: String, expected: String) async throws -> Bool {
        struct RefRes: Decodable {
            struct Object: Decodable { let sha: String }
            let object: Object
        }
        struct UpdateRefReq: Encodable { let sha: String; let force: Bool }
        guard Self.validSHA(commit), Self.validSHA(expected), Self.validBranch(name) else { throw RepositoryError.branch }
        let parts = ["git", "ref", "heads"] + name.split(separator: "/").map(String.init)
        let head: RefRes = try await get(parts)
        guard head.object.sha == expected else { return false }
        let _: EmptyResponse = try await send(method: "PATCH",
            components: ["git", "refs", "heads"] + name.split(separator: "/").map(String.init),
            body: UpdateRefReq(sha: commit, force: false), expectedStatus: [200])
        return true
    }

    func branchSnapshot(_ name: String) async throws -> RepositorySnapshot? {
        do { return try await snapshot(branch: name) }
        catch RepositoryError.http(404) { return nil }
    }

    struct Workflow: Decodable, Identifiable, Equatable {
        let id: Int
        let name: String
        let path: String
        let state: String
        var isActive: Bool { state == "active" }
    }

    func workflows() async throws -> [Workflow] {
        struct Reply: Decodable {
            let total_count: Int
            let workflows: [Workflow]
        }
        let reply: Reply = try await get(["actions", "workflows"], queryItems: [
            URLQueryItem(name: "per_page", value: "100")
        ])
        return reply.workflows.filter {
            $0.isActive && ($0.path.hasSuffix(".yml") || $0.path.hasSuffix(".yaml"))
        }
    }

    struct WorkflowRun: Decodable, Identifiable {
        let id: Int
        let name: String?
        let status: String
        let conclusion: String?
        let html_url: String?
        let head_sha: String?
        let workflow_id: Int?
        let event: String?

        var isCompleted: Bool { status == "completed" }
        var isSuccess: Bool { conclusion == "success" }
        var isFailure: Bool { conclusion == "failure" }
    }

    func dispatchWorkflow(workflowID: String, ref: String) async throws {
        struct DispatchReq: Encodable { let ref: String }
        guard Self.validBranch(ref) else { throw RepositoryError.branch }
        let _: EmptyResponse = try await send(method: "POST", components: ["actions", "workflows", workflowID, "dispatches"], body: DispatchReq(ref: ref), expectedStatus: [204])
    }

    func workflowRuns(workflowID: Int, branch: String) async throws -> [WorkflowRun] {
        struct RunsRes: Decodable {
            let total_count: Int
            let workflow_runs: [WorkflowRun]
        }
        let reply: RunsRes = try await get(["actions", "workflows", String(workflowID), "runs"], queryItems: [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: "100")
        ])
        return reply.workflow_runs
    }

    // The run must belong to the dispatched workflow and exactly the commit we
    // pushed. A previous green run on the same branch is never a substitute.
    func findWorkflowRun(workflowID: Int, branch: String, headSHA: String) async throws -> WorkflowRun? {
        guard Self.validSHA(headSHA), Self.validBranch(branch) else { throw RepositoryError.response }
        let runs = try await workflowRuns(workflowID: workflowID, branch: branch)
        return runs.first {
            $0.id > 0 && $0.head_sha == headSHA && $0.workflow_id == workflowID
        }
    }

    func latestWorkflowRun(branch: String) async throws -> WorkflowRun? {
        struct RunsRes: Decodable {
            let total_count: Int
            let workflow_runs: [WorkflowRun]
        }
        let reply: RunsRes = try await get(["actions", "runs"], queryItems: [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: "5")
        ])
        return reply.workflow_runs.first
    }

    func workflowRun(id: Int) async throws -> WorkflowRun {
        try await get(["actions", "runs", String(id)])
    }

    func fetchFailedJobLogs(runID: Int) async throws -> String {
        struct Step: Decodable {
            let number: Int
            let name: String
            let conclusion: String?
        }
        struct Job: Decodable {
            let id: Int
            let name: String
            let conclusion: String?
            let steps: [Step]?
        }
        struct Page: Decodable { let total_count: Int?; let jobs: [Job] }
        guard runID > 0 else { throw RepositoryError.response }
        let failures: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        var failed: [Job] = []
        var seen = Set<Int>()
        var listingComplete = false
        // Bound metadata and network work even for very large matrix builds.
        for page in 1...5 {
            let reply: Page = try await get(["actions", "runs", String(runID), "jobs"], queryItems: [
                URLQueryItem(name: "filter", value: "latest"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ])
            guard reply.jobs.count <= 100, reply.jobs.allSatisfy({ $0.id > 0 }),
                  reply.total_count.map({ $0 >= 0 }) ?? true else { throw RepositoryError.response }
            for job in reply.jobs where seen.insert(job.id).inserted {
                if failures.contains(job.conclusion ?? "") { failed.append(job) }
            }
            if reply.jobs.count < 100 || reply.total_count.map({ seen.count >= $0 }) == true {
                listingComplete = true; break
            }
        }
        var sections = ["Workflow run #\(runID): \(failed.count) unsuccessful job(s) found\(listingComplete ? "" : " in the first 500 jobs")."]
        if !listingComplete { sections.append("Job listing is incomplete. Open the CI run on GitHub for remaining jobs.") }
        guard !failed.isEmpty else { return sections.joined(separator: "\n") }
        for job in failed.prefix(8) {
            try Task.checkCancellation()
            var details: [String] = []
            let steps = (job.steps ?? []).filter { $0.number > 0 && failures.contains($0.conclusion ?? "") }
            if steps.isEmpty {
                details.append(try await availableJobLog(job.id))
            } else {
                for step in steps.prefix(3) {
                    let label = String(step.name.prefix(120))
                    do {
                        let text = try await downloadLog(["actions", "jobs", String(job.id), "steps", String(step.number), "logs"])
                        details.append("Step \(step.number): \(label)\n\(text)")
                    } catch RepositoryError.http(404) {
                        // Older GitHub installations may not serve step logs.
                        // Fall back once and label the content as a job log.
                        details.append(try await availableJobLog(job.id)); break
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        details.append("Step \(step.number): \(label) — logs unavailable. Open the CI run on GitHub.")
                    }
                }
                if steps.count > 3 { details.append("Additional failed steps omitted; open the CI run on GitHub.") }
            }
            let body = details.joined(separator: "\n\n")
            let bounded = body.utf8.count > 6_144
                ? String(decoding: Data(body.utf8).prefix(6_000), as: UTF8.self) + "\n[Job excerpt truncated; open the CI run on GitHub.]"
                : body
            sections.append("Job #\(job.id): \(String(job.name.prefix(120))) (\(job.conclusion ?? "unknown"))\n\(bounded)")
        }
        if failed.count > 8 { sections.append("Logs for \(failed.count - 8) additional unsuccessful jobs omitted; open the CI run on GitHub.") }
        try Task.checkCancellation()
        let text = sections.joined(separator: "\n\n")
        return token.isEmpty ? text : text.replacingOccurrences(of: token, with: "[redacted]")
    }

    private func availableJobLog(_ jobID: Int) async throws -> String {
        do { return "Job log:\n" + (try await downloadLog(["actions", "jobs", String(jobID), "logs"])) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return "Job logs unavailable. Open the CI run on GitHub."
        }
    }

    private func downloadLog(_ components: [String]) async throws -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var url = URLComponents(); url.scheme = "https"; url.host = "api.github.com"
        url.percentEncodedPath = (["repos", repository.owner, repository.name] + components)
            .map { "/" + $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined()
        var request = URLRequest(url: url.url!)
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("KeelMobile", forHTTPHeaderField: "User-Agent")
        let credential = try await authorizationToken()
        if !credential.isEmpty { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RepositoryError.response }
        if http.statusCode == 302 {
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let parts = URLComponents(string: location), parts.scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.fragment == nil, let redirectURL = parts.url else {
                throw RepositoryError.response
            }
            var logRequest = URLRequest(url: redirectURL)
            logRequest.setValue("KeelMobile", forHTTPHeaderField: "User-Agent")
            // The signed download URL carries its own authorization. Never
            // forward the GitHub credential, and never follow another redirect.
            let (logBytes, raw) = try await session.bytes(for: logRequest)
            defer { logBytes.task.cancel() }
            guard let result = raw as? HTTPURLResponse else { throw RepositoryError.response }
            guard result.statusCode == 200 else { throw RepositoryError.http(result.statusCode) }
            return try await logExcerpt(logBytes)
        }
        guard http.statusCode == 200 else { throw RepositoryError.http(http.statusCode) }
        return try await logExcerpt(bytes)
    }

    private func logExcerpt(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        var truncated = false
        for try await byte in bytes {
            if data.count == 131_072 { truncated = true; break }
            data.append(byte)
        }
        try Task.checkCancellation()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        var excerpt = lines.suffix(60).joined(separator: "\n")
        if !token.isEmpty { excerpt = excerpt.replacingOccurrences(of: token, with: "[redacted]") }
        if truncated { excerpt += "\n[Download truncated at 128 KB. These are lines from the beginning, not the end of the full log.]" }
        else if lines.count > 60 { excerpt = "[Last 60 lines of this log]\n" + excerpt }
        return excerpt
    }

    struct PullRequestInfo: Decodable {
        let number: Int
        let title: String
        let html_url: String
    }

    func pullRequest(head: String, base: String) async throws -> PullRequestInfo? {
        guard Self.validBranch(head), Self.validBranch(base) else { throw RepositoryError.branch }
        let items: [PullRequestInfo] = try await get(["pulls"], queryItems: [
            URLQueryItem(name: "head", value: "\(repository.owner):\(head)"),
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "per_page", value: "1")
        ])
        return items.first
    }

    func createPullRequest(title: String, head: String, base: String, body: String) async throws -> PullRequestInfo {
        struct PRReq: Encodable {
            let title: String
            let head: String
            let base: String
            let body: String
        }
        return try await send(method: "POST", components: ["pulls"], body: PRReq(title: title, head: head, base: base, body: body), expectedStatus: [201])
    }

    func snapshot(branch requested: String) async throws -> RepositorySnapshot {
        struct Info: Decodable { let default_branch: String }
        struct Branch: Decodable {
            struct Commit: Decodable {
                struct Body: Decodable { let tree: Reference }
                let sha: String
                let commit: Body
            }
            let name: String
            let commit: Commit
        }
        var branch = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty {
            let info: Info = try await get([], limit: 262_144)
            branch = info.default_branch
        }
        guard !branch.isEmpty, branch.utf8.count <= 1024,
              !branch.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RepositoryError.branch }
        let reply: Branch = try await get(["branches", branch], limit: 262_144)
        guard Data(reply.name.utf8) == Data(branch.utf8), Self.validSHA(reply.commit.sha), Self.validSHA(reply.commit.commit.tree.sha) else { throw RepositoryError.response }
        return RepositorySnapshot(repository: repository, branch: branch, commit: reply.commit.sha, tree: reply.commit.commit.tree.sha)
    }

    func entries(snapshot: RepositorySnapshot, tree: String) async throws -> [RepositoryEntry] {
        struct Tree: Decodable { let sha: String; let truncated: Bool; let tree: [RepositoryEntry] }
        guard snapshot.repository == repository, Self.validSHA(tree) else { throw RepositoryError.response }
        // Traverse one directory at a time; recursive GitHub trees can be truncated.
        let reply: Tree = try await get(["git", "trees", tree])
        guard !reply.truncated else { throw RepositoryError.tooLarge }
        guard reply.sha == tree, Set(reply.tree.map { Data($0.path.utf8) }).count == reply.tree.count,
              reply.tree.allSatisfy({ Self.validSHA($0.sha) && !$0.path.isEmpty && !$0.path.contains("/") &&
                  $0.path != "." && $0.path != ".." && !$0.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw RepositoryError.response
        }
        return reply.tree.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    func read(snapshot: RepositorySnapshot, entry: RepositoryEntry) async throws -> String {
        struct Blob: Decodable { let sha: String; let size: Int; let encoding: String; let content: String }
        guard snapshot.repository == repository, Self.validSHA(entry.sha) else { throw RepositoryError.response }
        guard entry.isTextCandidate else { throw RepositoryError.unsupported }
        guard let size = entry.size, size >= 0, size <= Self.fileLimit else { throw RepositoryError.tooLarge }
        if let cached = blobCache.object(forKey: entry.sha as NSString) { return cached as String }
        let reply: Blob = try await get(["git", "blobs", entry.sha], limit: Self.fileLimit * 2)
        guard reply.sha == entry.sha, reply.size == size, reply.encoding == "base64",
              let data = Data(base64Encoded: reply.content.filter { !$0.isWhitespace }), data.count == size else { throw RepositoryError.response }
        var gitObject = Data("blob \(data.count)\0".utf8); gitObject.append(data)
        let hash = Insecure.SHA1.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
        guard hash == entry.sha else { throw RepositoryError.response }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw RepositoryError.unsupported }
        blobCache.setObject(text as NSString, forKey: entry.sha as NSString, cost: data.count)
        return text
    }

    private struct Reference: Decodable { let sha: String }
    static func validSHA(_ sha: String) -> Bool {
        sha.count == 40 && sha.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validBranch(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200
            && !name.hasPrefix("/") && !name.hasSuffix("/")
            && !name.contains("..") && !name.contains(" ")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
