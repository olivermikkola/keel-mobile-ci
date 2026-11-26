import Foundation

/// GitHub in a plain chat. Once the user has connected their GitHub account,
/// the model can list their repositories and open one in the chat. Opening
/// turns the chat into a repository chat, with the tools that read it.
///
/// No network code here: the app fetches the list and the repository, and
/// these functions check the call and write what the model reads.
enum GitHubTools {
    /// Repositories shown to the model in one list.
    static let maxListed = 30

    static let listTool = #"{"type":"function","function":{"name":"github_repos","description":"List the user's GitHub repositories, most recently changed first. Optional query keeps only names that contain it.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":[]}}}"#
    static let openTool = #"{"type":"function","function":{"name":"github_open","description":"Open one of the user's GitHub repositories in this chat, so its files can be listed, read and searched. repository is owner/name exactly as github_repos shows it.","parameters":{"type":"object","properties":{"repository":{"type":"string"}},"required":["repository"]}}}"#

    struct Repository: Equatable, Sendable {
        let fullName: String
        let isPrivate: Bool
        let defaultBranch: String
    }

    /// The optional name filter of a `github_repos` call.
    static func query(_ arguments: [String: String]) throws -> String {
        guard Set(arguments.keys).isSubset(of: ["query"]) else {
            throw DirectorToolError.invalidCall("github_repos takes only an optional query.")
        }
        let query = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 100, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DirectorToolError.invalidCall("query must be one short line.")
        }
        return query
    }

    /// The `owner/name` of a `github_open` call. A pasted github.com address
    /// is accepted too, because small models often copy one.
    static func repository(_ arguments: [String: String]) throws -> String {
        guard Set(arguments.keys) == ["repository"] else {
            throw DirectorToolError.invalidCall("github_open takes exactly one parameter: repository.")
        }
        var name = (arguments["repository"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "github.com/"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if name.hasSuffix(".git") { name.removeLast(4) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else {
            throw DirectorToolError.invalidCall("repository must be owner/name, for example octocat/hello-world. Call github_repos to see the names.")
        }
        return name
    }

    /// What the model reads after `github_repos`.
    static func render(_ repositories: [Repository], query: String) -> String {
        let matching = query.isEmpty ? repositories
            : repositories.filter { $0.fullName.range(of: query, options: .caseInsensitive) != nil }
        guard !matching.isEmpty else {
            return query.isEmpty
                ? "The connected GitHub account has no repositories Keel may access."
                : "No repository name contains \"\(query)\". Call github_repos without a query to see all \(repositories.count)."
        }
        var lines = ["The user's GitHub repositories\(query.isEmpty ? "" : " matching \"\(query)\""), most recently changed first:"]
        for repository in matching.prefix(maxListed) {
            lines.append("- \(clean(repository.fullName)) (\(repository.isPrivate ? "private" : "public"), default branch \(clean(repository.defaultBranch)))")
        }
        if matching.count > maxListed { lines.append("…and \(matching.count - maxListed) more. Add a query to narrow the list.") }
        lines.append("To work with one, call github_open with its owner/name.")
        return lines.joined(separator: "\n")
    }

    /// What the model reads after `github_open` succeeds.
    static func opened(repository: String, branch: String, commit: String) -> String {
        "Opened \(clean(repository)) at branch \(clean(branch)), commit \(commit.prefix(7)). This chat now works on that repository: its files are this chat's files. Continue with what the user asked, using list_files, read_file and the search tools."
    }

    /// Why a chat that already has files of its own cannot switch to a repository.
    static let busy = "This chat already has its own files, so it cannot switch to a repository. Tell the user to start a new chat and ask there."

    /// Names come from GitHub, not from the user: keep them from reading as tool markup.
    private static func clean(_ text: String) -> String {
        String(text.filter { !$0.isNewline && $0 != "<" && $0 != ">" }.prefix(140))
    }
}
