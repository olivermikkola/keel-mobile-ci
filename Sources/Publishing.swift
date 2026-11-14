import Foundation

enum PublishError: LocalizedError, Equatable {
    case noAppliedEdits, noWorkflow, branchExists, branchMoved, staleBase
    case ciPending, ciNotGreen(String), invalidState, reviewChanged, response

    var errorDescription: String? {
        switch self {
        case .noAppliedEdits:
            return "Apply at least one reviewed change before publishing."
        case .noWorkflow:
            return "This repository has no active GitHub Actions workflow. Keel will not publish without CI."
        case .branchExists:
            return "The task branch already exists. Re-open the publish sheet to resume or choose a new task."
        case .branchMoved:
            return "The task branch moved since the reviewed commit. Nothing was pushed; re-read the branch and review again."
        case .staleBase:
            return "This task is pinned to a different repository base. Start a new task before publishing."
        case .reviewChanged:
            return "The reviewed changes differ from this published commit. Publish the current changes and check their CI before opening a pull request."
        case .ciPending:
            return "CI has not reported a result for the exact published commit yet."
        case .ciNotGreen(let detail):
            return detail.isEmpty ? "CI must pass on the exact published commit before a pull request can open." : detail
        case .invalidState:
            return "The saved publish state is inconsistent. Start a new publish from the reviewed changes."
        case .response:
            return "GitHub returned an unexpected publishing response. Nothing was opened as a pull request."
        }
    }
}

struct PublishState: Codable, Equatable {
    let branch: String
    let baseCommit: String
    let baseTree: String
    let workflowID: Int
    let workflowName: String
    let paths: [String]
    var commit: String?
    var runID: Int?
    var runURL: String?
    var conclusion: String?
    var prURL: String?
    var updatedAt: Date
    // A path list cannot distinguish two reviewed versions of the same file.
    // Older saved records remain readable, but cannot authorize a new PR.
    var contentIdentity: [String: String]? = nil

    enum Stage: String, Equatable {
        case ready, pushed, waitingForCI, ciPassed, ciFailed, published
    }

    var stage: Stage {
        if prURL != nil { return .published }
        if conclusion == "success" { return .ciPassed }
        if let conclusion, !conclusion.isEmpty { return .ciFailed }
        if commit == nil { return .ready }
        if runID != nil { return .waitingForCI }
        return .pushed
    }

    var canOpenPullRequest: Bool {
        stage == .ciPassed && commit != nil && runID != nil && contentIdentity != nil
    }

    func matches(edits: [ProposedFileEdit], snapshot: RepositorySnapshot) -> Bool {
        let final = PublishingFlow.finalContent(edits)
        return baseCommit == snapshot.commit && baseTree == snapshot.tree
            && paths == final.paths && contentIdentity == PublishingFlow.identity(final)
    }

    var statusText: String {
        switch stage {
        case .ready: return "Ready to publish"
        case .pushed: return "Commit pushed · waiting for CI to appear"
        case .waitingForCI: return "CI is running on the published commit"
        case .ciPassed: return "CI passed on \(commit?.prefix(7) ?? "the commit")"
        case .ciFailed: return "CI did not pass; no pull request was opened"
        case .published: return "Pull request opened"
        }
    }

    func isValid(for snapshot: RepositorySnapshot) -> Bool {
        guard GitHubRepository.validBranch(branch), branch.hasPrefix(PublishingFlow.branchPrefix),
              GitHubRepository.validSHA(baseCommit), GitHubRepository.validSHA(baseTree),
              baseCommit == snapshot.commit, baseTree == snapshot.tree,
              workflowID > 0, !workflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !paths.isEmpty, paths.count <= 64, paths == paths.sorted(), Set(paths).count == paths.count,
              paths.allSatisfy(Self.validPath),
              commit.map(GitHubRepository.validSHA) ?? true,
              runID == nil || commit != nil,
              conclusion == nil || runID != nil,
              runID.map({ $0 > 0 }) ?? true,
              contentIdentity.map({ identity in
                  identity.keys.sorted() == paths && identity.values.allSatisfy(GitHubRepository.validSHA)
              }) ?? true,
              prURL == nil || (conclusion == "success" && commit != nil),
              runURL == nil || runURL?.hasPrefix("https://github.com/") == true else { return false }
        return true
    }

    private static func validPath(_ path: String) -> Bool {
        let parts = gitPathComponents(path)
        return !path.isEmpty && path.utf8.count <= 1024 && parts.count <= 16
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

// The tree a publish writes: final text for each surviving path, and base
// paths the task deleted or renamed away.
struct PublishPlan: Equatable {
    // Git's all-zero object ID marks a deletion in the saved content identity.
    static let removedIdentity = String(repeating: "0", count: 40)
    var content: [String: String]
    var removed: Set<String>
    // Final path -> base path whose file mode it keeps. New files use 100644.
    var modeSource: [String: String]
    var paths: [String] { Set(content.keys).union(removed).sorted() }
}

// The model never calls this flow. It runs only from an explicit publish
// decision after reviewed edits have been applied to the saved task.
enum PublishingFlow {
    static let branchPrefix = "keel/task-"

    static func branch(for taskID: UUID) -> String {
        branchPrefix + String(taskID.uuidString.prefix(8)).lowercased()
    }

    // Replays the task's applied operations in order. A path with no final
    // content is deleted, but only if it existed at the pinned base: a file the
    // task created and then deleted is simply not published.
    static func finalContent(_ edits: [ProposedFileEdit]) -> PublishPlan {
        var content: [String: String] = [:]
        var existedAtBase: [String: Bool] = [:]
        var modeSource: [String: String] = [:]
        func touch(_ path: String, existed: Bool) {
            guard existedAtBase[path] == nil else { return }
            existedAtBase[path] = existed
            if existed { modeSource[path] = path }
        }
        for edit in edits {
            switch edit.kind {
            case .replace:
                touch(edit.path, existed: true)
                content[edit.path] = edit.after
            case .create:
                touch(edit.path, existed: false)
                content[edit.path] = edit.after
                modeSource[edit.path] = nil
            case .delete:
                touch(edit.path, existed: true)
                content[edit.path] = nil
                modeSource[edit.path] = nil
            case .rename:
                let destination = edit.afterPath
                touch(edit.path, existed: true)
                touch(destination, existed: false)
                content[destination] = edit.after
                modeSource[destination] = modeSource[edit.path]
                content[edit.path] = nil
                modeSource[edit.path] = nil
            }
        }
        let removed = Set(existedAtBase.filter { $0.value && content[$0.key] == nil }.keys)
        return PublishPlan(content: content, removed: removed, modeSource: modeSource)
    }

    static func identity(_ plan: PublishPlan) -> [String: String] {
        var identity = plan.content.mapValues(ProposedFileEdit.blobSHA)
        for path in plan.removed { identity[path] = PublishPlan.removedIdentity }
        return identity
    }

    // Git tree entries need an explicit mode. Look up each base file's mode one
    // directory at a time, so editing an executable script keeps it executable.
    static func baseModes(client: GitHubRepository, snapshot: RepositorySnapshot,
                          paths: Set<String>) async throws -> [String: String] {
        var directories: [String: [RepositoryEntry]] = [:]
        var modes: [String: String] = [:]
        for path in paths.sorted() {
            let parts = gitPathComponents(path)
            var tree = snapshot.tree
            for (index, part) in parts.enumerated() {
                let listing: [RepositoryEntry]
                if let cached = directories[tree] { listing = cached } else {
                    listing = try await client.entries(snapshot: snapshot, tree: tree)
                    directories[tree] = listing
                }
                guard let entry = listing.first(where: { Data($0.path.utf8) == Data(part.utf8) }) else {
                    throw PublishError.staleBase
                }
                if index == parts.count - 1 {
                    guard entry.isTextCandidate else { throw PublishError.staleBase }
                    modes[path] = entry.mode
                } else {
                    guard entry.isDirectory else { throw PublishError.staleBase }
                    tree = entry.sha
                }
            }
        }
        return modes
    }

    // Creates and fast-forwards the task branch, but does not dispatch CI.
    // The caller persists this commit before dispatch so leaving the app can
    // never lose the identity of a pushed commit.
    static func prepare(client: GitHubRepository, snapshot: RepositorySnapshot,
                        edits: [ProposedFileEdit], branch: String,
                        previous: PublishState?, workflow: GitHubRepository.Workflow,
                        commitMessage: String) async throws -> PublishState {
        guard !edits.isEmpty else { throw PublishError.noAppliedEdits }
        guard edits.allSatisfy({ $0.snapshot == snapshot }) else { throw PublishError.staleBase }
        guard workflow.isActive, workflow.id > 0 else { throw PublishError.noWorkflow }
        guard GitHubRepository.validBranch(branch), branch.hasPrefix(branchPrefix) else {
            throw PublishError.invalidState
        }
        let final = finalContent(edits)
        guard !final.paths.isEmpty else { throw PublishError.noAppliedEdits }

        let head = try await client.branchSnapshot(branch)
        let parent: String
        if let previous {
            // An opened PR already exposes this branch. Further edits need a
            // new task instead of changing an existing PR before CI passes.
            guard previous.prURL == nil else { throw PublishError.invalidState }
            guard previous.baseCommit == snapshot.commit, previous.baseTree == snapshot.tree,
                  previous.branch == branch else { throw PublishError.staleBase }
            guard let expected = previous.commit else { throw PublishError.branchMoved }
            guard head?.commit == expected else { throw PublishError.branchMoved }
            parent = expected
        } else {
            guard head == nil else { throw PublishError.branchExists }
            parent = snapshot.commit
        }

        let modes = try await baseModes(client: client, snapshot: snapshot,
                                        paths: Set(final.modeSource.values).union(final.removed))
        var entries: [GitHubRepository.TreeEntryItem] = []
        entries.reserveCapacity(final.paths.count)
        for path in final.paths {
            if let text = final.content[path] {
                let blob = try await client.createBlob(content: text)
                let mode = final.modeSource[path].flatMap { modes[$0] } ?? "100644"
                entries.append(GitHubRepository.TreeEntryItem(path: path, sha: blob, mode: mode))
            } else {
                guard final.removed.contains(path) else { throw PublishError.response }
                entries.append(GitHubRepository.TreeEntryItem(path: path, sha: nil))
            }
        }
        let tree = try await client.createTree(baseTree: snapshot.tree, entries: entries)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await client.createCommit(
            message: message.isEmpty ? "keel: publish reviewed changes" : String(message.prefix(120)),
            tree: tree, parents: [parent])

        if previous == nil {
            try await client.createBranch(name: branch, commit: commit)
        } else {
            guard try await client.updateBranch(name: branch, commit: commit, expected: parent) else {
                throw PublishError.branchMoved
            }
        }
        return PublishState(
            branch: branch, baseCommit: snapshot.commit, baseTree: snapshot.tree,
            workflowID: workflow.id, workflowName: workflow.name, paths: final.paths,
            commit: commit, runID: nil, runURL: nil, conclusion: nil, prURL: nil,
            updatedAt: Date(), contentIdentity: identity(final))
    }

    static func dispatch(client: GitHubRepository, state: PublishState) async throws -> PublishState {
        guard let commit = state.commit, GitHubRepository.validSHA(commit),
              state.workflowID > 0, GitHubRepository.validBranch(state.branch) else {
            throw PublishError.invalidState
        }
        try await client.dispatchWorkflow(workflowID: String(state.workflowID), ref: state.branch)
        return state
    }

    static func publish(client: GitHubRepository, snapshot: RepositorySnapshot,
                        edits: [ProposedFileEdit], branch: String,
                        previous: PublishState?, workflow: GitHubRepository.Workflow,
                        commitMessage: String) async throws -> PublishState {
        let state = try await prepare(client: client, snapshot: snapshot, edits: edits,
                                      branch: branch, previous: previous, workflow: workflow,
                                      commitMessage: commitMessage)
        return try await dispatch(client: client, state: state)
    }

    static func waitForRun(client: GitHubRepository, state: PublishState,
                           attempts: Int = 15) async throws -> PublishState {
        guard let commit = state.commit else { throw PublishError.ciPending }
        var next = state
        for _ in 0..<max(1, attempts) {
            try Task.checkCancellation()
            if let run = try await client.findWorkflowRun(workflowID: state.workflowID,
                                                          branch: state.branch, headSHA: commit) {
                next.runID = run.id
                next.runURL = run.html_url
                next.conclusion = run.isCompleted ? (run.conclusion ?? "unknown") : nil
                next.updatedAt = Date()
                return next
            }
            try await Task.sleep(for: .seconds(2))
        }
        return next
    }

    static func refresh(client: GitHubRepository, state: PublishState) async throws -> PublishState {
        guard let commit = state.commit else { throw PublishError.ciPending }
        var next = state
        let run: GitHubRepository.WorkflowRun?
        if let id = state.runID {
            run = try await client.workflowRun(id: id)
        } else {
            run = try await client.findWorkflowRun(workflowID: state.workflowID, branch: state.branch, headSHA: commit)
        }
        guard let run else { throw PublishError.ciPending }
        guard run.id > 0, state.runID == nil || run.id == state.runID,
              run.head_sha == commit, run.workflow_id == state.workflowID else {
            throw PublishError.response
        }
        next.runID = run.id
        next.runURL = run.html_url
        // A rerun keeps its run ID. Clear a cached success as soon as the
        // current attempt is queued/running instead of reusing the old result.
        next.conclusion = run.isCompleted ? (run.conclusion ?? "unknown") : nil
        next.updatedAt = Date()
        return next
    }

    static func pullRequest(client: GitHubRepository, state: PublishState,
                            baseBranch: String, title: String) async throws -> PublishState {
        if let existing = state.prURL {
            guard existing.hasPrefix("https://github.com/") else { throw PublishError.invalidState }
            return state
        }
        guard state.canOpenPullRequest, let commit = state.commit,
              state.runURL != nil else {
            throw PublishError.ciNotGreen("CI must pass on \(state.commit?.prefix(7) ?? "the exact commit") before a pull request can open.")
        }
        // Saved green state is display metadata. Recheck the current run and
        // branch immediately before the user-authorized PR operation.
        let verified = try await refresh(client: client, state: state)
        guard verified.canOpenPullRequest, let runURL = verified.runURL else {
            throw PublishError.ciNotGreen("The current CI attempt has not passed. Check CI again before opening the pull request.")
        }
        guard try await client.branchSnapshot(state.branch)?.commit == commit else {
            throw PublishError.branchMoved
        }
        if let existing = try await client.pullRequest(head: state.branch, base: baseBranch) {
            var next = verified; next.prURL = existing.html_url; next.updatedAt = Date(); return next
        }
        let body = """
        Published from Keel after reviewed changes and a green CI run.

        - Commit: `\(commit)`
        - Workflow: \(state.workflowName)
        - CI run: \(runURL)
        - Files: \(state.paths.map { "`\($0)`" }.joined(separator: ", "))

        Keel only opened this pull request because the exact commit above passed CI.
        """
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let pr = try await client.createPullRequest(
            title: cleanTitle.isEmpty ? "Keel: reviewed changes" : cleanTitle,
            head: state.branch, base: baseBranch, body: body)
        var next = verified; next.prURL = pr.html_url; next.updatedAt = Date(); return next
    }

    static func failureLogs(client: GitHubRepository, state: PublishState) async throws -> String {
        guard let id = state.runID else { throw PublishError.ciPending }
        return try await client.fetchFailedJobLogs(runID: id)
    }
}
