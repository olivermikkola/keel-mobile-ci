import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

struct ChatMessage: Codable, Identifiable {
    var id: UUID
    let role: String
    var text: String
    var note: String?
    var isToolCall: Bool?
    var activity: String?
    var edit: TaskFileEdit?
    var attachments: [Attachment]?

    init(id: UUID = UUID(), role: String, text: String, note: String? = nil, isToolCall: Bool? = nil, activity: String? = nil, edit: TaskFileEdit? = nil, attachments: [Attachment]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.note = note
        self.isToolCall = isToolCall
        self.activity = activity
        self.edit = edit
        self.attachments = attachments
    }
}

private enum ChatEvent: Sendable {
    case text(String)
    case prefill(Int, Int)
    case generated(Int)
}

@MainActor
final class LocalChat: ObservableObject {
    @Published private(set) var tasks: [SavedTask] = []
    @Published private(set) var activeTaskID = UUID()
    @Published private(set) var storageUnreadable = false
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var repository: RepositorySnapshot?
    @Published private(set) var running = false {
        didSet { updateIdleTimer() }
    }
    private var scenePhase: ScenePhase = .active
    @Published private(set) var applyingEditID: UUID?
    @Published private(set) var publishState: PublishState?
    @Published private(set) var publishWorkflows: [GitHubRepository.Workflow] = []
    @Published private(set) var publishLogs: String?
    @Published private(set) var publishing = false
    @Published private(set) var phase = ""
    @Published private(set) var directorMode = false
    @Published private(set) var thinkingEnabled = false
    /// Chat or Work for the chat on screen; apps and repository chats are Work.
    @Published private(set) var chatMode: ChatMode = .work
    /// Facts about the user kept across chats, each saved with their yes.
    @Published private(set) var memory = UserMemory()
    struct MemoryApproval: Identifiable {
        let id = UUID()
        let fact: String
    }
    @Published private(set) var pendingMemory: MemoryApproval?
    /// The reply paused at a tool-call check-in, waiting for "Keep going?".
    struct ContinueApproval: Identifiable {
        let id = UUID()
        let calls: Int
        let more: Int
    }
    @Published private(set) var pendingContinue: ContinueApproval?
    private var continueDecision: CheckedContinuation<Bool, Never>?
    private var memoryDecision: CheckedContinuation<Bool, Never>?
    /// Projects: groups of chats with shared instructions and read-only files.
    @Published private(set) var projects: [ChatProject] = []
    @Published private(set) var customInstructions = ""
    @Published private(set) var connectors: [MCPConnector.Server] = []
    @Published private(set) var enabledConnectorIDs: [String] = []
    @Published var error: String?
    struct SearchApproval: Identifiable {
        let id = UUID()
        let query: String
    }
    @Published private(set) var pendingWebSearch: SearchApproval?
    private var searchDecision: CheckedContinuation<Bool, Never>?
    /// A connector action waiting for the user's yes: which service, which
    /// tool, and exactly what would be sent.
    struct ConnectorApproval: Identifiable {
        let id = UUID()
        let service: String
        let tool: String
        let details: String
    }
    enum ConnectorDecision { case deny, once, always }
    @Published private(set) var pendingConnectorCall: ConnectorApproval?
    private var connectorDecision: CheckedContinuation<ConnectorDecision, Never>?
    private let connectorClient: MCPConnectorClient
    /// The user's repositories for `github_repos`; nil when GitHub is not connected.
    /// Folds kept between model steps, so a long chat is not re-read in full on every tool call.
    private var compaction: StickyCompaction?
    private let githubRepositories: () -> (@Sendable () async throws -> [GitHubTools.Repository])?
    private var searchLinksTaskID: UUID?
    private var searchLinks: [String] = []
    private let searchKey: () throws -> String
    private let connectorsURL: URL
    let inference: LocalInference
    private let generator: any LocalGenerating
    private let repositoryClient: (RepositoryID) throws -> GitHubRepository
    /// Session settings for read_url; tests swap in a stub transport.
    private let webConfiguration: URLSessionConfiguration
    private struct DirectorBinding: Equatable {
        let taskID: UUID
        let snapshot: RepositorySnapshot
    }
    private var directorSession: DirectorSession?
    private var directorBinding: DirectorBinding?
    private var operation: Task<Void, Never>?
    private var cancellation: InferenceCancellation?
    private var transcript: URL
    private let workspaceDirectory: URL
    private let archiveWriter: ArchiveWriter
    private let backgroundAllowance: BackgroundAllowance
    var isHoldingBackgroundGrace: Bool { backgroundAllowance.isHoldingBackgroundTime }
    private var unreadable: Bool { storageUnreadable }
    var activeTitle: String { tasks.first(where: { $0.id == activeTaskID })?.title ?? "New task" }
    /// The project of the chat on screen, if any.
    var activeProject: ChatProject? {
        tasks.first(where: { $0.id == activeTaskID })?.projectID.flatMap { id in projects.first { $0.id == id } }
    }
    /// Beside the saved chats and named after them, so UI fixtures keep their own projects.
    private var projectsURL: URL { Self.projectsURL(beside: transcript) }
    private static func projectsURL(beside transcript: URL) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent(transcript.deletingPathExtension().lastPathComponent + "-projects.json")
    }
    /// The app the current chat was opened in, if any.
    var activeApp: AppPreset? { tasks.first(where: { $0.id == activeTaskID })?.app }
    /// Connectors currently switched on for this chat.
    var activeConnectors: [MCPConnector.Server] {
        guard repository == nil, activeApp == nil else { return [] }
        let enabled = Set(enabledConnectorIDs)
        return connectors.filter { enabled.contains($0.id) }
    }

    init(transcript: URL? = nil, generator: (any LocalGenerating)? = nil,
         repositoryClient: @escaping (RepositoryID) throws -> GitHubRepository = {
             try GitHubRepository(repository: $0, token: GitHubCredential.load())
         }, webConfiguration: URLSessionConfiguration = .ephemeral,
         searchKey: @escaping () throws -> String = { try WebSearchCredential.load() },
         connectorToken: (@Sendable (String) throws -> String)? = nil,
         githubRepositories: (@Sendable () async throws -> [GitHubTools.Repository])? = nil,
         backgroundAllowance: BackgroundAllowance? = nil) {
        self.searchKey = searchKey
        if let githubRepositories {
            self.githubRepositories = { githubRepositories }
        } else {
            // Offered only while a GitHub connection is saved on this iPhone.
            self.githubRepositories = { GitHubCredential.contains() ? LocalChat.connectedRepositories : nil }
        }
        #if DEBUG && targetEnvironment(simulator)
        let connectorConfiguration = ConnectorUITestTransport.configuration() ?? webConfiguration
        #else
        let connectorConfiguration = webConfiguration
        #endif
        var secrets = MCPConnectorClient.Secrets.keychain
        if let connectorToken {
            // Tests supply the token and keep sign-in grants out of the device Keychain.
            secrets = MCPConnectorClient.Secrets(token: connectorToken, grant: { _ in nil }, saveGrant: { _, _ in })
        }
        connectorClient = MCPConnectorClient(transport: { [connectorConfiguration] request, limit in
            try await ReadURLTransfer.fetch(request, configuration: connectorConfiguration, limit: limit)
        }, secrets: secrets)
        self.webConfiguration = webConfiguration
        self.backgroundAllowance = backgroundAllowance ?? BackgroundAllowance()
        let runtime = LocalInference()
        inference = runtime; self.generator = generator ?? RuntimeRouter(llama: runtime)
        self.repositoryClient = repositoryClient
        #if DEBUG && targetEnvironment(simulator)
        let fixture = transcript == nil ? (FileEditUITestFixture.transcript() ?? SearchActivityUITestFixture.transcript()) : nil
        #else
        let fixture: URL? = nil
        #endif
        self.transcript = transcript ?? fixture ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat.json")
        #if DEBUG && targetEnvironment(simulator)
        if transcript == nil, ProcessInfo.processInfo.arguments.contains("--saved-task-fixture") {
            self.transcript = self.transcript.deletingLastPathComponent().appendingPathComponent("saved-task-ui-fixture.json")
            if ProcessInfo.processInfo.arguments.contains("--reset-saved-task-fixture") {
                var first = SavedTask(title: "Explain the README", automaticTitle: false,
                                      messages: [ChatMessage(role: "user", text: "Explain the README"),
                                                 ChatMessage(role: "assistant", text: "Saved partial reply", note: "Responding")],
                                      repository: RepositorySnapshot(repository: try! RepositoryID("octocat/Hello-World"), branch: "master",
                                                                     commit: "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d",
                                                                     tree: String(repeating: "b", count: 40)))
                first.updatedAt = Date(timeIntervalSince1970: 1000)
                var archive = SavedTasks(task: first)
                archive.tasks.append(SavedTask(title: "Plan a small change", automaticTitle: false,
                                               messages: [ChatMessage(role: "user", text: "Plan a small change")]))
                try? archive.write(to: self.transcript)
                try? FileManager.default.removeItem(at: Self.projectsURL(beside: self.transcript))
            }
        }
        #endif
        workspaceDirectory = TaskWorkspaceStore.directory(beside: self.transcript)
        #if DEBUG && targetEnvironment(simulator)
        if ConnectorUITestTransport.configuration() != nil {
            // Recorded UI runs start with no connectors and leave the real list alone.
            connectorsURL = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-connectors.json")
            try? FileManager.default.removeItem(at: connectorsURL)
        } else {
            connectorsURL = MCPConnectorStore.defaultURL(beside: self.transcript)
        }
        #else
        connectorsURL = MCPConnectorStore.defaultURL(beside: self.transcript)
        #endif
        connectors = MCPConnectorStore.load(from: connectorsURL)
        archiveWriter = ArchiveWriter(destination: self.transcript)
        if let savedInstructions = try? String(contentsOf: self.customInstructionsURL, encoding: .utf8) {
            customInstructions = CustomInstructions.sanitize(savedInstructions)
        }
        if let data = try? Data(contentsOf: self.memoryURL) { memory = UserMemory.load(data) }
        if let data = try? Data(contentsOf: self.projectsURL), let saved = try? JSONDecoder().decode([ChatProject].self, from: data) {
            projects = saved
        }
        do {
            let archive = FileManager.default.fileExists(atPath: self.transcript.path)
                ? try SavedTasks.load(Data(contentsOf: self.transcript)) : SavedTasks()
            activate(archive)
        } catch {
            storageUnreadable = true
            self.error = "Saved tasks could not be opened. They have been kept unchanged. Open the menu to reset safely."
        }
        #if DEBUG && targetEnvironment(simulator)
        // Recorded approval visual only: no generator, key or network operation.
        if ProcessInfo.processInfo.arguments.contains("--web-search-approval-fixture") {
            pendingWebSearch = SearchApproval(query: "Turku museum opening hours · recorded UI fixture")
        }
        #endif
    }

    @discardableResult
    func attach(_ snapshot: RepositorySnapshot) -> Bool {
        guard !running else { return false }
        guard !unreadable else { error = RepositoryAgentError.storage.localizedDescription; return false }
        guard messages.isEmpty || repository == snapshot else { error = RepositoryAgentError.binding.localizedDescription; return false }
        if repository != snapshot { resetDirector() }
        repository = snapshot; error = nil
        return save()
    }

    @discardableResult
    func setDirectorMode(_ enabled: Bool) -> Bool {
        guard !running, !unreadable, !enabled || repository != nil else { return false }
        guard directorMode != enabled else { return true }
        // Save the setting before changing the visible mode. A failed write
        // must not leave a UI choice that will disappear on relaunch.
        guard save(), let index = tasks.firstIndex(where: { $0.id == activeTaskID }) else { return false }
        var archive = currentArchive()
        archive.tasks[index].editProposalsEnabled = enabled
        return commit(archive)
    }

    /// Beside the saved chats and named after them, so UI fixtures keep their own memory.
    private var memoryURL: URL {
        transcript.deletingLastPathComponent().appendingPathComponent(transcript.deletingPathExtension().lastPathComponent + "-memory.json")
    }
    private func saveMemory(_ next: UserMemory) -> Bool {
        do {
            try FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: memoryURL, options: [.atomic, .completeFileProtection])
            memory = next
            return true
        } catch {
            self.error = "Memory could not be saved on this device."
            return false
        }
    }
    @discardableResult
    func setMemoryEnabled(_ enabled: Bool) -> Bool {
        guard !running else { return false }
        var next = memory; next.enabled = enabled
        return saveMemory(next)
    }
    @discardableResult
    func forget(_ id: UUID) -> Bool {
        guard !running else { return false }
        var next = memory; next.remove(id)
        return saveMemory(next)
    }
    @discardableResult
    func forgetAll() -> Bool {
        guard !running else { return false }
        return saveMemory(UserMemory(enabled: memory.enabled))
    }
    /// Memory applies to plain chats, not apps or repositories.
    private var memoryActive: Bool { memory.enabled && repository == nil && activeApp == nil }

    private var customInstructionsURL: URL {
        transcript.deletingLastPathComponent().appendingPathComponent("custom-instructions.txt")
    }

    /// Whether the chat on screen can switch between Chat and Work.
    var canSwitchMode: Bool { repository == nil && activeApp == nil }
    /// The mode a new plain chat starts in: the one the user last chose,
    /// kept next to the saved chats so tests and fixtures stay separate.
    private var lastModeURL: URL { transcript.deletingLastPathComponent().appendingPathComponent("chat-mode.txt") }
    private var lastMode: ChatMode? {
        (try? String(contentsOf: lastModeURL, encoding: .utf8)).flatMap { ChatMode(rawValue: $0) }
    }

    @discardableResult
    func setChatMode(_ mode: ChatMode) -> Bool {
        guard !running, !unreadable, canSwitchMode else { return false }
        guard chatMode != mode else { return true }
        guard save(), let index = tasks.firstIndex(where: { $0.id == activeTaskID }) else { return false }
        var archive = currentArchive()
        archive.tasks[index].mode = mode
        guard commit(archive) else { return false }
        try? Data(mode.rawValue.utf8).write(to: lastModeURL, options: .atomic)
        return true
    }

    @discardableResult
    func setThinkingEnabled(_ enabled: Bool) -> Bool {
        guard !running, !unreadable else { return false }
        guard thinkingEnabled != enabled else { return true }
        guard save(), let index = tasks.firstIndex(where: { $0.id == activeTaskID }) else { return false }
        var archive = currentArchive()
        archive.tasks[index].thinkingEnabled = enabled
        return commit(archive)
    }

    @discardableResult
    func saveCustomInstructions(_ text: String) -> Bool {
        guard !running, !unreadable else { return false }
        let sanitized = CustomInstructions.sanitize(text)
        do {
            try FileManager.default.createDirectory(at: customInstructionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sanitized.isEmpty {
                try? FileManager.default.removeItem(at: customInstructionsURL)
            } else {
                try Data(sanitized.utf8).write(to: customInstructionsURL, options: [.atomic, .completeFileProtection])
            }
            customInstructions = sanitized
            error = nil
            return true
        } catch {
            self.error = "Your standing instructions could not be saved on this device."
            return false
        }
    }

    @discardableResult
    func setConnectorEnabled(_ serverID: String, enabled: Bool) -> Bool {
        guard !running, !unreadable, connectors.contains(where: { $0.id == serverID }) else { return false }
        var next = enabledConnectorIDs.filter { $0 != serverID }
        if enabled { next.append(serverID) }
        guard next != enabledConnectorIDs else { return true }
        let previous = enabledConnectorIDs
        enabledConnectorIDs = next
        guard save() else {
            enabledConnectorIDs = previous
            return false
        }
        return true
    }

    func isConnectorEnabled(_ serverID: String) -> Bool {
        enabledConnectorIDs.contains(serverID)
    }

    @discardableResult
    func saveConnector(_ server: MCPConnector.Server, token: String? = nil) throws -> MCPConnector.Server {
        let slug = try MCPConnector.slug(for: server.id.isEmpty ? server.name : server.id)
        let url = try MCPConnector.validateEndpoint(server.endpoint)
        var list = connectors
        let saved = MCPConnector.Server(id: slug, name: server.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                        endpoint: url.absoluteString,
                                        tools: Array(server.tools.prefix(MCPConnector.maxToolsPerConnector)),
                                        available: server.available, trusted: server.trusted)
        if let existingIndex = list.firstIndex(where: { $0.id == slug }) {
            list[existingIndex] = saved
        } else {
            guard list.count < MCPConnector.maxConnectors else { throw MCPConnector.Problem.limitReached }
            list.append(saved)
        }
        if let token {
            try MCPConnectorCredential.save(token, serverID: slug)
        }
        try MCPConnectorStore.save(list, to: connectorsURL)
        connectors = list
        return saved
    }

    func removeConnector(_ serverID: String) throws {
        let list = connectors.filter { $0.id != serverID }
        try MCPConnectorStore.save(list, to: connectorsURL)
        try? MCPConnectorCredential.remove(serverID: serverID)
        Task { await connectorClient.forget(serverID) }
        connectors = list
        if enabledConnectorIDs.contains(serverID) {
            enabledConnectorIDs.removeAll { $0 == serverID }
            _ = save()
        }
    }

    /// Adds a service and switches it on for this chat. Keel greets the
    /// service, and if it asks for an account, opens the service's own sign-in
    /// page in `browser`; the user never handles a token. `token` is only for a
    /// custom connector whose owner hands out access tokens.
    @discardableResult
    func connect(id: String? = nil, name: String, endpoint: String, token: String = "",
                 preferred: [String] = [], browser: ConnectorBrowser) async throws -> MCPConnector.Server {
        let slug = try MCPConnector.slug(for: id ?? name)
        let url = try MCPConnector.validateEndpoint(endpoint)
        let pasted = try MCPConnector.validateToken(token)
        let existing = connectors.first(where: { $0.id == slug })
        guard existing != nil || connectors.count < MCPConnector.maxConnectors else { throw MCPConnector.Problem.limitReached }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            try MCPConnectorCredential.remove(serverID: slug)
            try MCPConnectorCredential.save(pasted, serverID: slug)
        }
        await connectorClient.forget(slug)
        var found: MCPConnector.Server
        do {
            do {
                found = try await connectorClient.discover(id: slug, name: label, endpoint: url, preferred: preferred)
            } catch let needed as MCPConnectorClient.SignInRequired {
                // A pasted token the service refuses is wrong; do not sign in over it.
                guard pasted.isEmpty else { throw MCPConnector.Problem.unauthorized }
                let plan = try await connectorClient.planSignIn(endpoint: url, challenge: needed.challenge)
                let challenge = try ConnectorSignInChallenge()
                let page = try MCPConnectorAuth.authorizeURL(plan.metadata, clientID: plan.clientID, state: challenge.state,
                                                             challenge: challenge.challenge, scopes: plan.scopes, resource: plan.resource)
                let returned = try await browser.authorize(page)
                let code = try MCPConnectorAuth.code(from: returned, state: challenge.state)
                try await connectorClient.finishSignIn(id: slug, plan: plan, code: code, verifier: challenge.verifier)
                do {
                    found = try await connectorClient.discover(id: slug, name: label, endpoint: url, preferred: preferred)
                } catch is MCPConnectorClient.SignInRequired { throw MCPConnector.Problem.unauthorized }
            }
        } catch {
            // Nothing half-connected is left behind.
            if existing == nil { try? MCPConnectorCredential.remove(serverID: slug) }
            throw error
        }
        found.trusted = existing?.trusted
        let saved = try saveConnector(found)
        setConnectorEnabled(saved.id, enabled: true)
        return saved
    }

    /// Chooses which of a connector's tools the model is offered (up to five).
    func setConnectorTools(_ serverID: String, remoteNames: [String]) throws {
        guard !running, var server = connectors.first(where: { $0.id == serverID }) else { return }
        let pool = server.available ?? server.tools
        let chosen = pool.filter { remoteNames.contains($0.remoteName) }
        guard !chosen.isEmpty, chosen.count <= MCPConnector.maxToolsPerConnector else { return }
        server.available = pool
        server.tools = chosen
        try saveConnector(server)
    }

    /// Lets a tool run without asking each time, or takes that back.
    func setConnectorToolTrusted(_ serverID: String, remoteName: String, trusted: Bool) throws {
        guard var server = connectors.first(where: { $0.id == serverID }) else { return }
        var names = (server.trusted ?? []).filter { $0 != remoteName }
        if trusted { names.append(remoteName) }
        server.trusted = names.isEmpty ? nil : names
        try saveConnector(server)
    }

    /// The connected account's repositories, most recently changed first.
    private static let connectedRepositories: @Sendable () async throws -> [GitHubTools.Repository] = {
        let token: String
        if let stored = try GitHubCredential.oauthSession() {
            token = try await GitHubOAuthStore.shared.token(for: stored.user.id)
        } else {
            token = try GitHubCredential.load()
        }
        guard !token.isEmpty else { throw GitHubConnectionError.expired }
        return try await GitHubAccountAPI().repositories(token: token, page: 1).map {
            GitHubTools.Repository(fullName: $0.full_name, isPrivate: $0.private, defaultBranch: $0.default_branch)
        }
    }

    func send(_ text: String, model: LocalModel, path: URL) {
        send(text, attachments: [], model: model, path: path)
    }

    func send(_ text: String, attachments: [Attachment] = [], model: LocalModel, path: URL) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, (!text.isEmpty || !attachments.isEmpty) else { return }
        guard !unreadable else { error = RepositoryAgentError.storage.localizedDescription; return }
        let photos = (messages.flatMap { $0.attachments ?? [] } + attachments).compactMap(\.imageID)
        guard photos.isEmpty || model.visionFile != nil else { error = LocalModelError.vision.localizedDescription; return }
        guard photos.count <= AttachmentLimits.maxImages else {
            error = "Use up to three photos per chat. Start a new chat to work with more photos."; return
        }
        guard text.utf8.count <= 16_384 else { error = LocalModelError.tooLong.localizedDescription; return }
        error = nil
        messages.append(ChatMessage(role: "user", text: text, attachments: attachments.isEmpty ? nil : attachments))
        guard save() else { return }
        run(model: model, path: path)
    }

    /// Lets the model answer the chat as it stands. Runs again by itself when
    /// the model opened a repository, because that changes the chat's tools.
    private func run(model: LocalModel, path: URL) {
        let photos = messages.flatMap { $0.attachments ?? [] }.compactMap(\.imageID)
        running = true; phase = "Loading model and reading your message…"
        let flag = InferenceCancellation(); cancellation = flag
        operation = Task {
            let started = Date()
            var activeReply: UUID?
            var openedRepository = false
            do {
                let director: DirectorSession?
                let tools: RepositoryTools?
                var opened: TaskWorkspace?
                if let repository {
                    let client = try repositoryClient(repository.repository)
                    // The task's own copy of the repository gives search across
                    // every file. If it cannot be prepared (very large repository,
                    // no connection), the tools below still read GitHub one file
                    // at a time, as before.
                    phase = "Preparing the repository on your iPhone…"
                    do {
                        opened = try await TaskWorkspaceStore.open(task: activeTaskID, snapshot: repository, client: client,
                                                                   edits: TaskFileEdit.applied(in: messages), in: workspaceDirectory)
                        for message in messages {
                            if let msgAttachments = message.attachments {
                                for attachment in msgAttachments {
                                    try? opened?.ingestAttachment(attachment)
                                }
                            }
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    }
                    if directorMode {
                        // A cached session carries edits, branch and credentials.
                        // Never reuse it outside this exact task and pinned snapshot,
                        // even if a future navigation path forgets to reset it.
                        let binding = DirectorBinding(taskID: activeTaskID, snapshot: repository)
                        if directorBinding != binding {
                            directorSession = nil
                            directorBinding = binding
                        }
                        let session = directorSession ?? DirectorSession(client: client, snapshot: repository, appliedEdits: TaskFileEdit.applied(in: messages))
                        directorSession = session
                        director = session
                        tools = nil
                    } else {
                        director = nil
                        var repositoryTools = RepositoryTools(client: client, snapshot: repository, appliedEdits: TaskFileEdit.applied(in: messages))
                        repositoryTools.readBytes = ReadBudget.bytes(contextSize: model.contextSize)
                        tools = repositoryTools
                    }
                } else {
                    director = nil
                    tools = nil
                    // No repository: the chat's own files, with the same tools.
                    // If they cannot be opened, the chat still answers without tools.
                    // Auto-apply any valid pending local proposals from earlier turns so
                    // follow-up instructions ("make it professional") see the latest files.
                    phase = "Opening this chat's files…"
                    do {
                        await autoApplyPendingLocalEditsIfNeeded()
                        opened = try await TaskWorkspaceStore.openLocal(task: activeTaskID, attachments: messages.flatMap { $0.attachments ?? [] },
                                                                        edits: TaskFileEdit.applied(in: messages), project: activeProject, in: workspaceDirectory)
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    }
                }
                let files = opened
                // What proposals are made against: the repository in director
                // mode, or the chat's own files when there is no repository.
                let editSnapshot: RepositorySnapshot? = director?.snapshot ?? (repository == nil && files != nil ? .localFiles : nil)
                let agentic = tools != nil || editSnapshot != nil
                // Chat mode applies to the chat's own files only: apps and
                // repositories are always Work.
                let mode: ChatMode = repository == nil ? chatMode : .work
                let baseReplyLimit = mode.replyTokens(writing: editSnapshot != nil)
                let replyLimit = baseReplyLimit + (thinkingEnabled ? AgentPrompt.thinkingBudgetTokens : 0)
                // No hard cap: at each check-in the user decides whether it keeps going.
                let checkIn = mode.toolCheckIn
                var toolBudget = checkIn
                let map = repository == nil ? nil : files?.repoMap()
                var toolCount = 0
                var readPaths = Set<String>()
                var turnTelemetry: InferenceTelemetry?
                // Keel harness: loop reminders and failure advice for this request.
                let repeatGuard = RepeatGuard()
                let breaker = CircuitBreaker()
                while true {
                    try Task.checkCancellation()
                    var history = messages.filter { !$0.text.isEmpty || ($0.attachments != nil && !$0.attachments!.isEmpty) }.map { msg -> ChatMessage in
                        guard let attachments = msg.attachments, !attachments.isEmpty else { return msg }
                        let formattedAttachments = AttachmentPromptFormatter.formatAll(attachments)
                        let combinedText = msg.text.isEmpty ? formattedAttachments : "\(msg.text)\n\n\(formattedAttachments)"
                        return ChatMessage(id: msg.id, role: msg.role, text: combinedText, note: msg.note,
                                           isToolCall: msg.isToolCall, activity: msg.activity, edit: msg.edit,
                                           attachments: msg.attachments)
                    }
                    if agentic {
                        history = HarnessBridge.promptHistory(history, compaction: &compaction, contextSize: model.contextSize,
                                                              replyTokens: replyLimit, imageTokens: photos.count * 1024)
                    }
                    let prompt: String
                    if director != nil, let repository {
                        let system = map.map { AgentPrompt.director(name: repository.repository.fullName, branch: repository.branch, map: $0) }
                            ?? DirectorSession.systemPrompt(snapshot: repository)
                        prompt = LocalInference.prompt(history, system: system, model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                    } else if let tools {
                        if let map {
                            prompt = LocalInference.prompt(history, system: AgentPrompt.repository(
                                name: tools.snapshot.repository.fullName, commit: tools.snapshot.commit, map: map), model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                        } else {
                            prompt = RepositoryTools.prompt(history, snapshot: tools.snapshot, model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                        }
                    } else if editSnapshot != nil {
                        let local = AgentPrompt.local(app: activeApp, mode: mode,
                            webSearch: activeApp == nil && (try? searchKey().isEmpty) == false,
                            connectors: activeConnectors, github: activeApp == nil && githubRepositories() != nil, memory: memoryActive)
                        let remembered = memoryActive ? memory.apply(to: local) : local
                        prompt = LocalInference.prompt(history, system: activeProject?.apply(to: remembered) ?? remembered,
                                                       model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                    } else if memoryActive || activeProject != nil {
                        let remembered = memoryActive ? memory.apply(to: LocalInference.plainSystem) : LocalInference.plainSystem
                        prompt = LocalInference.prompt(history, system: activeProject?.apply(to: remembered) ?? remembered, model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                    } else {
                        prompt = LocalInference.prompt(history, model: model, customInstructions: customInstructions, thinking: thinkingEnabled)
                    }
                    let reply = ChatMessage(role: "assistant", text: "", note: "Responding")
                    messages.append(reply); activeReply = reply.id
                    guard save() else { throw RepositoryAgentError.saving }
                    phase = toolCount == 0 ? "Loading model and reading your message…" : "Thinking with the tool results…"
                    var output = ""
                    var tokenCount = 0
                    var checkpoint = Date()
                    let runtime = generator
                    let imageData = try history.flatMap { $0.attachments ?? [] }.compactMap { try PhotoAttachment.load($0) }
                    // Stopping a looping reply ends only this step, not the turn.
                    let stepFlag = InferenceCancellation(parent: flag)
                    var loopGuard = RepetitionGuard()
                    var looped = false
                    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
                        let producer = Task {
                            do {
                                let request = LocalGenerationRequest(path: path.path, prompt: prompt, limit: replyLimit,
                                    contextSize: model.contextSize, model: model,
                                    images: imageData,
                                    projectorPath: model.visionFile.map { path.deletingLastPathComponent().appendingPathComponent($0.fileName).path },
                                    grammar: agentic ? ToolCallGrammar.make(prompt: prompt, family: model.family) : nil)
                                let count = try await runtime.generate(request, cancellation: stepFlag,
                                                                       onPrefill: { done, total in
                                                                           continuation.yield(.prefill(done, total))
                                                                       }) {
                                    continuation.yield(.text($0))
                                }
                                continuation.yield(.generated(count)); continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        continuation.onTermination = { termination in
                            if case .cancelled = termination { stepFlag.cancel(); producer.cancel() }
                        }
                    }
                    events: for try await event in stream {
                        switch event {
                        case .text(let chunk):
                            output += chunk
                            if loopGuard.feed(chunk) {
                                // Small fine-tunes can repeat one phrase until the reply
                                // limit. Stop the step and keep a single copy.
                                looped = true
                                stepFlag.cancel()
                                output = RepetitionGuard.collapse(output, period: loopGuard.period)
                                break events
                            }
                            if thinkingEnabled && !output.contains("</think>") {
                                phase = "Thinking on your iPhone…"
                            } else {
                                let visible = ToolCallText.visibleReply(output)
                                // Hold XML calls out of the reply bubble. Plain answers
                                // still stream; tool requests become activity rows.
                                if !agentic || (!visible.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") && !visible.contains("<tool_call") && !visible.contains("<function")) {
                                    update(reply.id) { $0.text = visible }
                                    phase = "Writing on your iPhone…"
                                    if Date().timeIntervalSince(checkpoint) >= 2 {
                                        saveCheckpoint()
                                        checkpoint = Date()
                                    }
                                }
                            }
                        case .prefill(let done, let total):
                            let elapsed = Int(Date().timeIntervalSince(started))
                            phase = done >= total
                                ? "Prompt ready · generating on your iPhone…"
                                : "Reading prompt \(done)/\(total) · \(elapsed)s"
                        case .generated(let count): tokenCount = count
                        }
                    }
                    try Task.checkCancellation()
                    guard !flag.isCancelled, looped || !stepFlag.isCancelled else { throw CancellationError() }
                    if let stepTelemetry = await runtime.latestTelemetry() {
                        turnTelemetry = turnTelemetry?.combined(with: stepTelemetry) ?? stepTelemetry
                    }
                    if agentic {
                        // Strip a code fence or trailing prose around exactly one call.
                        // Arguments are untouched; the strict parsers still decide.
                        do { output = try NativeToolCall.normalize(output, family: model.family) }
                        catch { output = "<tool_call>" + output + "</tool_call>" }
                        let normalized = ToolCallText.normalize(output)
                        if normalized.repaired { output = normalized.text }
                    }
                    update(reply.id) { $0.text = output }

                    if let editSnapshot {
                        let parsed: DirectorCall?
                        do { parsed = try DirectorCall.parse(output) }
                        catch {
                            guard tokenCount < replyLimit else { throw RepositoryAgentError.call }
                            guard await keepGoing(after: toolCount, budget: &toolBudget, checkIn: checkIn) else { throw RepositoryAgentError.steps }
                            toolCount += 1
                            update(reply.id) { $0.isToolCall = true; $0.note = "Rejected" }
                            messages.append(ChatMessage(role: "tool", text: "Not executed: \(error.localizedDescription) Correct the tool format and try again.",
                                                        note: "Not executed", activity: "Correct tool request"))
                            guard save() else { throw RepositoryAgentError.saving }
                            continue
                        }
                        if let dCall = parsed {
                            guard tokenCount < replyLimit else { throw RepositoryAgentError.call }
                            update(reply.id) { $0.isToolCall = true; $0.note = "Requested" }
                            guard await keepGoing(after: toolCount, budget: &toolBudget, checkIn: checkIn) else {
                                messages.append(ChatMessage(role: "tool", text: "Not executed: the user stopped here after \(toolCount) tool calls.", note: "Stopped", activity: dCall.label))
                                throw RepositoryAgentError.steps
                            }
                            toolCount += 1
                            let reminder = repeatGuard.observe(name: dCall.name, arguments: dCall.arguments) ?? ""
                            let result = ChatMessage(role: "tool", text: "", note: "Executing…", activity: dCall.label)
                            messages.append(result); activeReply = result.id; phase = dCall.label
                            guard save() else { throw RepositoryAgentError.saving }
                            do {
                                if repository == nil, let app = activeApp, !app.tools.contains(dCall.name) {
                                    throw DirectorToolError.invalidCall("The \(app.title) app does not offer \(dCall.name). Use one of the tools in its prompt.")
                                }
                                if repository == nil, !mode.offers(dCall.name) {
                                    throw DirectorToolError.invalidCall("Chat mode does not offer \(dCall.name). Answer from what you have, or tell the user that Work mode does that.")
                                }
                                if ["propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file"].contains(dCall.name) {
                                    guard messages.compactMap(\.edit).count < 16 else { throw FileEditError.limit }
                                    if repository == nil {
                                        try ChatProject.checkWritable([dCall.arguments["path"], dCall.arguments["destination_path"]].compactMap { $0 })
                                    }
                                    let proposal: ProposedFileEdit
                                    if let files {
                                        proposal = try await Task.detached {
                                            try DirectorSession.propose(dCall, snapshot: editSnapshot, workspace: files)
                                        }.value
                                    } else if let director {
                                        proposal = try await director.propose(dCall)
                                    } else {
                                        throw RepositoryAgentError.call
                                    }
                                    let record = TaskFileEdit(proposal: proposal)
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = record.observation + reminder; $0.note = "Needs review"; $0.edit = record }
                                } else if dCall.name == "run_sql" {
                                    guard Set(dCall.arguments.keys) == Set(["sql"]), let sql = dCall.arguments["sql"],
                                          sql.utf8.count <= 64 * 1024, !sql.utf8.contains(0) else {
                                        throw DirectorToolError.invalidCall("Expected sql.")
                                    }
                                    // In a chat with no repository, its CSV files are tables too.
                                    let sqlResult = try await executeSQL(sql, files: editSnapshot.isLocalFiles ? files : nil)
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = sqlResult.text + reminder; $0.note = sqlResult.isError ? "Error" : "Completed" }
                                } else if dCall.name == "remember" {
                                    guard editSnapshot.isLocalFiles, memoryActive, Set(dCall.arguments.keys) == ["fact"] else {
                                        throw DirectorToolError.invalidCall("Expected fact. Memory is available only in a plain chat with memory on.")
                                    }
                                    let fact = try memory.validate(dCall.arguments["fact"] ?? "")
                                    phase = "Waiting for your memory decision…"
                                    let approved = await approveMemory(fact)
                                    try Task.checkCancellation()
                                    if approved {
                                        var next = memory
                                        try next.add(fact)
                                        guard saveMemory(next) else { throw RepositoryAgentError.saving }
                                        update(result.id) { $0.text = "Saved to memory: \(fact)" + reminder; $0.note = "Completed" }
                                    } else {
                                        update(result.id) { $0.text = "Not saved: the user declined. Do not ask again for this fact."; $0.note = "Not saved" }
                                    }
                                } else if dCall.name == "web_search" {
                                    guard editSnapshot.isLocalFiles, Set(dCall.arguments.keys).isSubset(of: ["query", "count"]) else {
                                        throw DirectorToolError.invalidCall("Expected query and optional count in a local chat.")
                                    }
                                    let arguments = try WebSearch.arguments(dCall.arguments)
                                    let request = try WebSearch.request(query: arguments.query, count: arguments.count, key: searchKey())
                                    phase = "Waiting for your search decision…"
                                    let approved = await approveSearchQuery(arguments.query)
                                    try Task.checkCancellation()
                                    guard approved else {
                                        update(result.id) { $0.text = "Not searched: the user declined this query."; $0.note = "Not sent" }
                                        guard save() else { throw RepositoryAgentError.saving }
                                        continue
                                    }
                                    phase = "Searching the web…"
                                    let data: Data, response: HTTPURLResponse
                                    do {
                                        (data, response) = try await ReadURLTransfer.fetch(request, configuration: webConfiguration, limit: WebSearch.responseLimit)
                                    } catch {
                                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                        throw WebSearch.Problem.unavailable(0)
                                    }
                                    let results = try WebSearch.results(from: data, status: response.statusCode, count: arguments.count)
                                    try Task.checkCancellation()
                                    if searchLinksTaskID != activeTaskID { searchLinks = []; searchLinksTaskID = activeTaskID }
                                    searchLinks = Array((searchLinks + results.map { $0.url.absoluteString }).suffix(80))
                                    update(result.id) { $0.text = WebSearch.render(results, query: arguments.query) + reminder; $0.note = "Completed" }
                                } else if dCall.name == "read_url" {
                                    // Only in a chat's own files, and only addresses the user wrote.
                                    guard editSnapshot.isLocalFiles, Set(dCall.arguments.keys) == ["url"],
                                          let address = dCall.arguments["url"] else { throw DirectorToolError.invalidCall("Expected url.") }
                                    let written = messages.filter { $0.role == "user" }.map(\.text)
                                    guard WebAddress.userWrote(address, in: written)
                                        || (searchLinksTaskID == activeTaskID && WebAddress.userWrote(address, in: searchLinks)) else {
                                        update(result.id) { $0.text = WebAddress.refusal + reminder; $0.note = "Not opened" }
                                        guard save() else { throw RepositoryAgentError.saving }
                                        continue
                                    }
                                    phase = "Reading a web page…"
                                    let page = try await ReadURL().execute(RepositoryCall(name: "read_url", path: "", offset: 0, count: 0,
                                                                                         query: nil, url: address),
                                                                          configuration: webConfiguration)
                                    try Task.checkCancellation()
                                    let text = "Text of \(address) (untrusted web page text\(page.truncated ? ", cut to the first 6000 characters" : "")):\n" + page.text
                                    update(result.id) { $0.text = text + reminder; $0.note = "Completed" }
                                } else if dCall.name == "run_js" {
                                    guard Set(dCall.arguments.keys) == Set(["code"]), let code = dCall.arguments["code"],
                                          code.utf8.count <= 64 * 1024, !code.utf8.contains(0) else {
                                        throw DirectorToolError.invalidCall("Expected code.")
                                    }
                                    let jsResult = try await executeJS(code, allowWrites: true, files: files, snapshot: editSnapshot)
                                    try Task.checkCancellation()
                                    let summary = jsResult.edits.isEmpty
                                        ? jsResult.text
                                        : jsResult.text + "\nPrepared \(jsResult.edits.count) change\(jsResult.edits.count == 1 ? "" : "s") for review."
                                    update(result.id) { $0.text = summary + reminder; $0.note = jsResult.isError ? "Error" : "Completed" }
                                    for record in jsResult.edits {
                                        messages.append(ChatMessage(
                                            role: "tool",
                                            text: record.observation,
                                            note: "Needs review",
                                            activity: "Propose \(record.proposal.kind.rawValue) · \(record.proposal.path)",
                                            edit: record
                                        ))
                                    }
                                } else if dCall.name == "github_repos" {
                                    guard editSnapshot.isLocalFiles, activeApp == nil, let list = githubRepositories() else {
                                        throw DirectorToolError.invalidCall("GitHub is not connected. The user can connect it under Connections.")
                                    }
                                    let query = try GitHubTools.query(dCall.arguments)
                                    phase = "Looking at your GitHub repositories…"
                                    let found = try await list()
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = GitHubTools.render(found, query: query) + reminder; $0.note = "Completed" }
                                } else if dCall.name == "github_open" {
                                    guard editSnapshot.isLocalFiles, activeApp == nil, githubRepositories() != nil else {
                                        throw DirectorToolError.invalidCall("GitHub is not connected. The user can connect it under Connections.")
                                    }
                                    let name = try GitHubTools.repository(dCall.arguments)
                                    // A chat that already has files of its own keeps them.
                                    guard fileEdits.isEmpty, messages.allSatisfy({ ($0.attachments ?? []).isEmpty }) else {
                                        throw DirectorToolError.invalidCall(GitHubTools.busy)
                                    }
                                    phase = "Opening \(name)…"
                                    let snapshot = try await repositoryClient(try RepositoryID(name)).snapshot(branch: "")
                                    try Task.checkCancellation()
                                    resetDirector()
                                    repository = snapshot
                                    openedRepository = true
                                    update(result.id) {
                                        $0.text = GitHubTools.opened(repository: snapshot.repository.fullName, branch: snapshot.branch, commit: snapshot.commit)
                                        $0.note = "Completed"
                                    }
                                } else if MCPConnector.isConnectorCall(dCall.name) {
                                    guard editSnapshot.isLocalFiles, activeApp == nil else {
                                        throw MCPConnector.Problem.unknownTool(dCall.name)
                                    }
                                    guard let match = activeConnectors.lazy.compactMap({ server -> (MCPConnector.Server, MCPConnector.Tool)? in
                                        guard let tool = server.tools.first(where: { $0.callName == dCall.name }) else { return nil }
                                        return (server, tool)
                                    }).first else {
                                        throw MCPConnector.Problem.unknownTool(dCall.name)
                                    }
                                    let (server, tool) = match
                                    // Check the call before asking the user about it.
                                    _ = try MCPConnector.callToolRequest(server: server, tool: tool, arguments: dCall.arguments)
                                    if server.needsApproval(tool) {
                                        phase = "Waiting for your decision…"
                                        let decision = await approveConnectorCall(ConnectorApproval(
                                            service: server.name, tool: tool.remoteName,
                                            details: MCPConnector.approvalSummary(arguments: dCall.arguments)))
                                        try Task.checkCancellation()
                                        guard decision != .deny else {
                                            update(result.id) { $0.text = "Not run: the user declined this action."; $0.note = "Not sent" }
                                            guard save() else { throw RepositoryAgentError.saving }
                                            continue
                                        }
                                        if decision == .always {
                                            try? setConnectorToolTrusted(server.id, remoteName: tool.remoteName, trusted: true)
                                        }
                                    }
                                    phase = "Using \(server.name)…"
                                    let mcpResult = try await connectorClient.call(server: server, tool: tool, arguments: dCall.arguments)
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = mcpResult.text + reminder; $0.note = mcpResult.isError ? "Error" : "Completed" }
                                } else {
                                    let text: String
                                    if let files, ["list_files", "read_file", "search_file", "search_repo"].contains(dCall.name) {
                                        let read = try dCall.readCall()
                                        text = try await Task.detached { try WorkspaceTools(workspace: files, readBytes: ReadBudget.bytes(contextSize: model.contextSize)).execute(read).text }.value
                                    } else if let director {
                                        text = try await director.execute(dCall)
                                    } else {
                                        throw RepositoryAgentError.call
                                    }
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = text + reminder; $0.note = "Completed" }
                                }
                                breaker.recordSuccess()
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                let advice = breaker.recordFailure(HarnessBridge.failure(error)) ?? ""
                                let message = WorkspaceTools.recoverableMessage(error) ?? "Tool error: \(error.localizedDescription)"
                                update(result.id) { $0.text = message + reminder + advice; $0.note = "Error" }
                            }
                            guard save() else { throw RepositoryAgentError.saving }
                            // The chat is a repository chat from here on: start over with its tools.
                            if openedRepository { break }
                            continue
                        }
                    }

                    let call: RepositoryCall?
                    do {
                        if tools != nil { call = try RepositoryCall.parse(output) }
                        else { call = nil }
                    }
                    catch let error as RepositoryArgumentError {
                        // Only a structurally valid, known tool reaches typed
                        // numeric validation. Reject without I/O, then let the
                        // model correct it within the same request budget.
                        guard tokenCount < replyLimit else { throw RepositoryAgentError.call }
                        update(reply.id) { $0.isToolCall = true; $0.note = "Rejected" }
                        guard await keepGoing(after: toolCount, budget: &toolBudget, checkIn: checkIn) else { throw RepositoryAgentError.steps }
                        toolCount += 1
                        let result = ChatMessage(role: "tool", text: error.localizedDescription,
                                                 note: "Not executed", activity: "Correct request arguments")
                        messages.append(result); activeReply = result.id
                        guard save() else { throw RepositoryAgentError.saving }
                        continue
                    }
                    if let tools, let call {
                        // A token-limited response is never executable, even if
                        // its closing XML happened to fit at the boundary.
                        guard tokenCount < replyLimit else { throw RepositoryAgentError.call }
                        update(reply.id) { $0.isToolCall = true; $0.note = "Requested" }
                        guard await keepGoing(after: toolCount, budget: &toolBudget, checkIn: checkIn) else {
                            messages.append(ChatMessage(role: "tool", text: "Not executed: the user stopped here after \(toolCount) tool calls.", note: "Stopped", activity: call.label))
                            throw RepositoryAgentError.steps
                        }
                        toolCount += 1
                        let reminder = repeatGuard.observe(name: call.name, arguments: HarnessBridge.arguments(call)) ?? ""
                        let initialNote = ["run_sql", "run_js"].contains(call.name) ? "Executing…" : "Reading…"
                        let result = ChatMessage(role: "tool", text: "", note: initialNote, activity: call.label)
                        messages.append(result); activeReply = result.id; phase = call.label
                        guard save() else { throw RepositoryAgentError.saving }
                        do {
                            if call.name == "run_sql" {
                                let sqlResult = try await executeSQL(call.sql ?? "")
                                try Task.checkCancellation()
                                breaker.recordSuccess()
                                update(result.id) { $0.text = sqlResult.text + reminder; $0.note = sqlResult.isError ? "Error" : "Completed" }
                            } else if call.name == "run_js" {
                                if files == nil {
                                    breaker.recordSuccess()
                                    update(result.id) {
                                        $0.text = "JavaScript sandbox needs the downloaded task workspace, which is unavailable for this task. Use read_file, list_files, or search_file instead." + reminder
                                        $0.note = "Error"
                                    }
                                } else {
                                    let jsResult = try await executeJS(call.code ?? "", allowWrites: false, files: files, snapshot: nil)
                                    try Task.checkCancellation()
                                    breaker.recordSuccess()
                                    readPaths.formUnion(jsResult.readPaths)
                                    update(result.id) { $0.text = jsResult.text + reminder; $0.note = jsResult.isError ? "Error" : "Completed" }
                                }
                            } else {
                                let text: String
                                let changed: Bool
                                if let files {
                                    let output = try await Task.detached { () -> (String, [String], Bool) in
                                        let output = try WorkspaceTools(workspace: files, readBytes: ReadBudget.bytes(contextSize: model.contextSize)).execute(call)
                                        return (output.text, output.paths, output.includesLocalChanges)
                                    }.value
                                    text = output.0; changed = output.2
                                    readPaths.formUnion(output.1)
                                } else {
                                    text = try await tools.execute(call)
                                    changed = tools.hasLocalChanges(at: call.path)
                                    if ["read_file", "search_file"].contains(call.name) { readPaths.insert(call.path) }
                                }
                                try Task.checkCancellation()
                                breaker.recordSuccess()
                                let local = changed ? " · with approved task changes" : ""
                                update(result.id) { $0.text = text + reminder; $0.note = "Verified base \(tools.snapshot.commit.prefix(7))\(local)" }
                            }
                        } catch {
                            if !Task.isCancelled, let message = files == nil ? RepositoryTools.recoverableMessage(error) : WorkspaceTools.recoverableMessage(error) {
                                // A missing path/range is an observation the
                                // model can correct. It is never verified data.
                                let advice = breaker.recordFailure(HarnessBridge.failure(error)) ?? ""
                                update(result.id) { $0.text = message + reminder + advice; $0.note = "Not read" }
                            } else {
                                update(result.id) { $0.text = Task.isCancelled ? "Request stopped; no result was obtained." : agentMessage(error); $0.note = "Stopped" }
                                throw error
                            }
                        }
                        guard save() else { throw RepositoryAgentError.saving }
                        continue
                    }
                    let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
                    let telemetry = turnTelemetry?.summary.map { " · \($0)" } ?? ""
                    let usedMLX = (generator as? RuntimeRouter)?.lastReplyUsedMLX == true
                    let limit = looped ? " · stopped: the model was repeating itself"
                        : tokenCount >= replyLimit ? " · reply limit reached" : ""
                    let evidence = tools == nil ? "" : " · \(readPaths.count) file\(readPaths.count == 1 ? "" : "s") read this turn"
                    let answer = ToolCallText.cleanReply(output)
                    let hidden = answer.removed ? " · broken tool text hidden" : ""
                    update(reply.id) {
                        $0.text = answer.text
                        $0.note = "\(model.name)\(usedMLX ? " · MLX" : "") · \(elapsed)\(telemetry)\(limit)\(hidden)\(evidence)"
                    }
                    break
                }
            } catch is CancellationError {
                if let activeReply { update(activeReply) { $0.note = "Stopped · partial reply" } }
            } catch {
                if let activeReply { update(activeReply) { $0.note = "Interrupted · partial reply" } }
                self.error = agentMessage(error)
            }
            running = false; phase = ""; operation = nil; cancellation = nil
            save()
            if openedRepository, !Task.isCancelled, error == nil, repository != nil { run(model: model, path: path) }
        }
    }

    private func executeSQL(_ sql: String, files: TaskWorkspace? = nil) async throws -> SQLResult {
        let taskID = activeTaskID
        let directory = workspaceDirectory
        return try await Task.detached {
            let tables = files.map { FileTables.tables(from: $0.textFiles()) } ?? []
            return try TaskWorkspaceStore.runSQL(sql, tables: tables, task: taskID, in: directory)
        }.value
    }

    private func executeJS(
        _ code: String,
        allowWrites: Bool,
        files: TaskWorkspace?,
        snapshot: RepositorySnapshot?
    ) async throws -> (text: String, isError: Bool, readPaths: [String], edits: [TaskFileEdit]) {
        guard let files else {
            throw DirectorToolError.invalidCall("JavaScript sandbox needs the downloaded task workspace.")
        }
        let applied = TaskFileEdit.applied(in: messages)
        // The workspace is restored after the script; keep this chat's attachments in it too.
        let attachments = messages.flatMap { $0.attachments ?? [] }
        var approvedKey = applied.map(\.id.uuidString).joined(separator: ",")
            + (attachments.isEmpty ? "" : "|" + attachments.map(\.id.uuidString).joined(separator: ","))
        var approvedOps = applied.flatMap(TaskWorkspaceStore.operations(for:))
            + attachments.map { .write(path: AttachmentPromptFormatter.sanitizeWorkspacePath($0.filename), text: $0.extractedText) }
        if repository == nil {
            (approvedKey, approvedOps) = TaskWorkspaceStore.localOverlay(attachments: attachments, edits: applied, project: activeProject)
        }
        let existingCount = messages.compactMap(\.edit).count
        let execution = try await ScriptRunner.run(
            code: code, workspace: files, allowWrites: allowWrites,
            approvedKey: approvedKey, approvedOperations: approvedOps
        )
        try Task.checkCancellation()
        var records: [TaskFileEdit] = []
        let isError: Bool
        switch execution.outcome {
        case .finished:
            isError = false
            if allowWrites, let snapshot, !execution.netChanges.isEmpty {
                if snapshot.isLocalFiles { try ChatProject.checkWritable(execution.netChanges.map { $0.path }) }
                let planned = try await Task.detached {
                    try EditPlanner.planChanges(execution.netChanges, workspace: files, newFolders: snapshot.isLocalFiles)
                }.value
                guard existingCount + planned.count <= 16 else { throw FileEditError.limit }
                records = try planned.map {
                    TaskFileEdit(proposal: try DirectorSession.proposal(for: $0, snapshot: snapshot))
                }
            }
        case .failed, .timedOut:
            isError = true
        }
        var text = ScriptResultFormatter.format(
            execution.outcome,
            output: execution.output,
            changedFiles: isError ? [] : execution.changedFiles
        )
        if isError, allowWrites, !execution.netChanges.isEmpty {
            text += "\nNo file proposals were created because the script did not finish."
        }
        return (text, isError, execution.readPaths, records)
    }

    private func parentPath(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }
    var fileEdits: [TaskFileEdit] { messages.compactMap(\.edit) }

    /// Every file the agent made in a chat of its own, across all saved chats.
    var libraryItems: [Library.Item] {
        Library.items(tasks.filter { $0.repository == nil }.map { task in
            let current = task.id == activeTaskID ? messages : task.messages
            return Library.Chat(taskID: task.id, title: task.title, updatedAt: task.updatedAt,
                                operations: TaskFileEdit.applied(in: current).flatMap(TaskWorkspaceStore.operations(for:)))
        })
    }

    /// The page that shows a proposal's file (a web page, document, table or
    /// flashcards). A web page sees this chat's proposals (except discarded
    /// ones) over the task's workspace, for its stylesheets and scripts.
    func previewDocument(for proposal: ProposedFileEdit) -> String {
        var changed: [String: String?] = [:]
        for record in fileEdits where record.decision != .discarded {
            for operation in TaskWorkspaceStore.operations(for: record.proposal) {
                switch operation {
                case .write(let path, let text): changed[path] = .some(text)
                case .delete(let path): changed[path] = .some(nil)
                }
            }
        }
        let location = TaskWorkspaceStore.url(for: activeTaskID, in: workspaceDirectory)
        let workspace = FileManager.default.fileExists(atPath: location.path) ? try? TaskWorkspace(path: location.path) : nil
        return FileView.document(path: proposal.afterPath, text: proposal.after) { path in
            if let text = changed[path] { return text }
            return try? workspace?.read(path).text
        } ?? ""
    }

    func applyEdit(_ id: UUID) {
        if repository == nil { applyLocalEdit(id); return }
        guard !running, !unreadable, let snapshot = repository,
              let index = messages.firstIndex(where: { $0.edit?.id == id }),
              let record = messages[index].edit, record.decision == .pending else { return }
        error = nil; running = true; applyingEditID = id; phase = "Checking current content before applying…"
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                // A moved source branch must not quietly turn approval of an
                // old diff into approval against a different repository base.
                guard try await client.snapshot(branch: snapshot.branch) == snapshot else { throw FileEditError.stale }
                let tools = RepositoryTools(client: client, snapshot: snapshot, appliedEdits: TaskFileEdit.applied(in: messages))
                let proposal = record.proposal
                switch proposal.kind {
                case .create:
                    guard try await tools.directoryExists(parentPath(proposal.path)),
                          try await tools.currentFileIfPresent(proposal.path) == nil else {
                        throw FileEditError.path
                    }
                    _ = try proposal.applying(to: "", snapshot: snapshot,
                                               originalBlobSHA: ProposedFileEdit.emptyBlobSHA)
                case .delete, .replace:
                    let current = try await tools.currentFile(proposal.path)
                    _ = try proposal.applying(to: current.text, snapshot: snapshot,
                                               originalBlobSHA: current.entry.sha)
                case .rename:
                    guard let destination = proposal.destinationPath,
                          try await tools.directoryExists(parentPath(destination)),
                          try await tools.currentFileIfPresent(destination) == nil else {
                        throw FileEditError.path
                    }
                    let current = try await tools.currentFile(proposal.path)
                    _ = try proposal.applying(to: current.text, snapshot: snapshot,
                                               originalBlobSHA: current.entry.sha)
                }
                try Task.checkCancellation()
                var approved = record; approved.decision = .applied
                approved.appliedOrder = TaskFileEdit.applied(in: messages).count + 1
                let original = messages[index]
                messages[index].edit = approved; messages[index].text = approved.observation; messages[index].note = "Applied to task"
                if !save() { messages[index] = original; throw RepositoryAgentError.saving }
                directorSession = nil
            } catch is CancellationError {
                self.error = "The review check stopped. The proposal is still pending; review it again to apply."
            } catch {
                self.error = Task.isCancelled ? "The review check stopped. The proposal is still pending; review it again to apply." : agentMessage(error)
            }
            running = false; applyingEditID = nil; phase = ""; operation = nil
        }
    }

    /// Applies a change to the chat's own files, after checking they still
    /// hold what the proposal was made against.
    private func applyLocalEdit(_ id: UUID) {
        guard !running, !unreadable, let index = messages.firstIndex(where: { $0.edit?.id == id }),
              let record = messages[index].edit, record.decision == .pending, record.proposal.snapshot.isLocalFiles,
              let kind = PlannedEdit.Kind(rawValue: record.proposal.kind.rawValue) else { return }
        error = nil; running = true; applyingEditID = id; phase = "Checking current content before applying…"
        let task = activeTaskID, directory = workspaceDirectory
        let attachments = messages.flatMap { $0.attachments ?? [] }
        let applied = TaskFileEdit.applied(in: messages)
        let project = activeProject
        operation = Task {
            do {
                let files = try await TaskWorkspaceStore.openLocal(task: task, attachments: attachments, edits: applied, project: project, in: directory)
                let proposal = record.proposal
                let fresh = await Task.detached {
                    LocalFiles.stillApplies(kind, path: proposal.path, destinationPath: proposal.destinationPath,
                                            before: proposal.before, in: files)
                }.value
                guard fresh else { throw FileEditError.stale }
                try Task.checkCancellation()
                guard let index = messages.firstIndex(where: { $0.edit?.id == id }) else { throw FileEditError.stale }
                var approved = record; approved.decision = .applied
                approved.appliedOrder = applied.count + 1
                let original = messages[index]
                messages[index].edit = approved; messages[index].text = approved.observation; messages[index].note = "Applied to this chat's files"
                if !save() { messages[index] = original; throw RepositoryAgentError.saving }
            } catch is CancellationError {
                self.error = "The review check stopped. The proposal is still pending; review it again to apply."
            } catch {
                self.error = Task.isCancelled ? "The review check stopped. The proposal is still pending; review it again to apply." : agentMessage(error)
            }
            running = false; applyingEditID = nil; phase = ""; operation = nil
        }
    }

    /// Applies all valid pending local proposals in order. Used both when the user
    /// taps "Apply all" in a local chat and before opening a follow-up turn's files.
    func applyAllLocalEdits() {
        guard !running, !unreadable, repository == nil else { return }
        let pendingIDs = messages.compactMap { $0.edit?.decision == .pending ? $0.edit?.id : nil }
        guard !pendingIDs.isEmpty else { return }
        error = nil; running = true; phase = "Applying changes to this chat's files…"
        operation = Task {
            await autoApplyPendingLocalEditsIfNeeded()
            running = false; phase = ""; operation = nil
        }
    }

    private func autoApplyPendingLocalEditsIfNeeded() async {
        guard repository == nil else { return }
        let pendingIndices = messages.indices.filter {
            guard let edit = messages[$0].edit else { return false }
            return edit.decision == .pending && edit.proposal.snapshot.isLocalFiles
        }
        guard !pendingIndices.isEmpty else { return }
        let task = activeTaskID, directory = workspaceDirectory
        let attachments = messages.flatMap { $0.attachments ?? [] }
        var changed = false
        for index in pendingIndices {
            guard !Task.isCancelled,
                  let record = messages[index].edit,
                  record.decision == .pending,
                  let kind = PlannedEdit.Kind(rawValue: record.proposal.kind.rawValue) else { continue }
            let applied = TaskFileEdit.applied(in: messages)
            guard let files = try? await TaskWorkspaceStore.openLocal(
                task: task, attachments: attachments, edits: applied, project: activeProject, in: directory
            ) else { break }
            let proposal = record.proposal
            let fresh = await Task.detached {
                LocalFiles.stillApplies(kind, path: proposal.path, destinationPath: proposal.destinationPath,
                                        before: proposal.before, in: files)
            }.value
            guard fresh else { continue }
            var approved = record
            approved.decision = .applied
            approved.appliedOrder = applied.count + 1
            messages[index].edit = approved
            messages[index].text = approved.observation
            messages[index].note = "Applied to this chat's files"
            changed = true
        }
        if changed { _ = save() }
    }

    func discardEdit(_ id: UUID) {
        guard !running, !unreadable, let index = messages.firstIndex(where: { $0.edit?.id == id }),
              var record = messages[index].edit, record.decision == .pending else { return }
        let original = messages[index]
        record.decision = .discarded
        messages[index].edit = record; messages[index].text = record.observation; messages[index].note = "Discarded"
        if !save() { messages[index] = original }
        else { error = nil }
    }
    var publishEdits: [ProposedFileEdit] { TaskFileEdit.applied(in: messages) }
    var publishBranch: String { PublishingFlow.branch(for: activeTaskID) }
    var publishIsStale: Bool {
        guard let state = publishState, let repository = repository else { return false }
        return !state.matches(edits: publishEdits, snapshot: repository)
    }

    func loadPublishWorkflows() {
        guard !running, !publishing, !unreadable, let snapshot = repository else { return }
        running = true; publishing = true; phase = "Loading GitHub workflows…"; error = nil
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                let list = try await client.workflows()
                try Task.checkCancellation()
                publishWorkflows = list
                if list.isEmpty { self.error = PublishError.noWorkflow.localizedDescription }
            } catch is CancellationError {
            } catch { self.error = agentMessage(error) }
            backgroundAllowance.release()
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    func startPublish(workflow: GitHubRepository.Workflow) {
        guard !running, !unreadable, let snapshot = repository else { return }
        let edits = TaskFileEdit.applied(in: messages)
        guard !edits.isEmpty else { error = PublishError.noAppliedEdits.localizedDescription; return }
        let previous = publishState
        running = true; publishing = true; phase = "Pushing the reviewed commit…"; error = nil; publishLogs = nil
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                var state = try await PublishingFlow.prepare(
                    client: client, snapshot: snapshot, edits: edits,
                    branch: PublishingFlow.branch(for: activeTaskID),
                    previous: previous, workflow: workflow, commitMessage: activeTitle)
                publishState = state
                guard save() else { throw RepositoryAgentError.saving }
                phase = "Dispatching the selected CI workflow…"
                state = try await PublishingFlow.dispatch(client: client, state: state)
                publishState = state; _ = save()
                phase = "Waiting for the exact CI run…"
                state = try await PublishingFlow.waitForRun(client: client, state: state)
                publishState = state
                _ = save()
            } catch is CancellationError {
                // The pushed commit is already saved; a later Check CI resumes.
            } catch { self.error = agentMessage(error) }
            backgroundAllowance.release()
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    func retryPublish() {
        guard let state = publishState, !running else { return }
        let workflow = publishWorkflows.first { $0.id == state.workflowID }
            ?? GitHubRepository.Workflow(id: state.workflowID, name: state.workflowName, path: "", state: "active")
        startPublish(workflow: workflow)
    }

    func checkPublish() {
        guard !running, !unreadable, let snapshot = repository,
              let state = publishState, state.commit != nil else { return }
        running = true; publishing = true
        phase = "Checking CI on \(state.commit?.prefix(7) ?? "the commit")…"; error = nil
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                let next = try await PublishingFlow.refresh(client: client, state: state)
                publishState = next; _ = save()
            } catch is CancellationError {
            } catch { self.error = agentMessage(error) }
            backgroundAllowance.release()
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    func openPublishPullRequest() {
        guard !running, !unreadable, let snapshot = repository,
              let state = publishState, state.canOpenPullRequest else { return }
        guard !publishIsStale else { error = PublishError.reviewChanged.localizedDescription; return }
        running = true; publishing = true; phase = "Opening the pull request…"; error = nil
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                let next = try await PublishingFlow.pullRequest(
                    client: client, state: state, baseBranch: snapshot.branch, title: activeTitle)
                publishState = next; _ = save()
            } catch is CancellationError {
            } catch { self.error = agentMessage(error) }
            backgroundAllowance.release()
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    func loadPublishLogs() {
        guard !running, let snapshot = repository,
              let state = publishState, state.runID != nil else { return }
        running = true; publishing = true; phase = "Reading failed CI logs…"; error = nil
        operation = Task {
            do {
                let client = try repositoryClient(snapshot.repository)
                publishLogs = try await PublishingFlow.failureLogs(client: client, state: state)
            } catch is CancellationError {
            } catch { self.error = agentMessage(error) }
            backgroundAllowance.release()
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    private func approveSearchQuery(_ query: String) async -> Bool {
        let approval = SearchApproval(query: query)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                searchDecision = continuation
                pendingWebSearch = approval
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingWebSearch?.id == approval.id else { return }
                self?.decideWebSearch(false)
            }
        }
    }

    private func approveConnectorCall(_ approval: ConnectorApproval) async -> ConnectorDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .deny); return }
                connectorDecision = continuation
                pendingConnectorCall = approval
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingConnectorCall?.id == approval.id else { return }
                self?.decideConnectorCall(.deny)
            }
        }
    }

    func decideConnectorCall(_ decision: ConnectorDecision) {
        let waiting = connectorDecision
        connectorDecision = nil; pendingConnectorCall = nil
        waiting?.resume(returning: decision)
    }

    /// True while the turn is within its allowance. At a check-in it pauses and
    /// asks the user; a yes allows `checkIn` more calls.
    private func keepGoing(after calls: Int, budget: inout Int, checkIn: Int) async -> Bool {
        guard calls >= budget else { return true }
        let before = phase
        phase = "Waiting for you: keep going?"
        let approval = ContinueApproval(calls: calls, more: checkIn)
        let yes = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                continueDecision = continuation
                pendingContinue = approval
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingContinue?.id == approval.id else { return }
                self?.decideContinue(false)
            }
        }
        phase = before
        if yes { budget += checkIn }
        return yes
    }

    func decideContinue(_ yes: Bool) {
        let decision = continueDecision
        continueDecision = nil; pendingContinue = nil
        decision?.resume(returning: yes)
    }

    private func approveMemory(_ fact: String) async -> Bool {
        let approval = MemoryApproval(fact: fact)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                memoryDecision = continuation
                pendingMemory = approval
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingMemory?.id == approval.id else { return }
                self?.decideMemory(false)
            }
        }
    }

    func decideMemory(_ save: Bool) {
        let decision = memoryDecision
        memoryDecision = nil; pendingMemory = nil
        decision?.resume(returning: save)
    }

    func decideWebSearch(_ approved: Bool) {
        let decision = searchDecision
        searchDecision = nil; pendingWebSearch = nil
        decision?.resume(returning: approved)
    }

    func stop(reason: String? = nil) {
        guard running else { return }
        backgroundAllowance.release()
        cancellation?.cancel(); operation?.cancel()
        decideWebSearch(false)
        decideConnectorCall(.deny)
        // Persist the visible partial immediately, while the scene is still
        // active. Relaunch marks Responding as interrupted even if iOS suspends
        // us before the asynchronous cancellation cleanup gets to run.
        save()
        if let reason { error = reason }
    }
    func sceneDidChange(_ phase: ScenePhase) {
        scenePhase = phase
        updateIdleTimer()
        if phase == .active {
            backgroundAllowance.release()
        }
        // Control Center and system prompts temporarily make the scene
        // inactive. They do not mean the user has left the app.
        if phase == .background {
            if publishing {
                // Network-only GitHub publish / CI dispatch has no Metal GPU work.
                // Hold the ~30s iOS background task window so branch pushes and CI
                // dispatches can finish if the user briefly switches apps.
                backgroundAllowance.acquire(name: "KeelGitHubPublish") { [weak self] in
                    self?.leaveForeground()
                }
            } else {
                leaveForeground()
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = running && scenePhase == .active
    }

    func leaveForeground() {
        stop(reason: applyingEditID == nil ? "On-device work stops when you leave the app. Your partial reply is kept. CI already dispatched continues on GitHub; return and check it before continuing." :
                "The review check stopped. The proposal is still pending; review it again to apply.")
        unloadModels()
    }
    /// Frees whichever runtime holds a model (llama.cpp, or MLX in an experimental chat).
    func unloadModels() {
        Task { await unloadModelsNow() }
    }

    func unloadModelsNow() async {
        await inference.unload()
        await (generator as? RuntimeRouter)?.mlx.unload()
    }

    /// Persist the chat identity before the system stores a reminder for it.
    func prepareForScheduling(_ id: UUID) -> Bool {
        guard !running, !unreadable, activeTaskID == id else { return false }
        return save()
    }

    /// Starts an empty chat, in `app` when one is given.
    @discardableResult
    func newChat(app: AppPreset? = nil, project: ChatProject? = nil) -> Bool {
        guard !running, !unreadable, save() else { return false }
        guard tasks.count < 200 else { error = "You have 200 saved tasks. Delete a task before starting another."; return false }
        let task = SavedTask(app: app, mode: app == nil ? lastMode : nil, projectID: project?.id)
        var archive = currentArchive(); archive.tasks.append(task); archive.activeID = task.id
        return commit(archive)
    }

    @discardableResult
    func selectTask(_ id: UUID) -> Bool {
        guard !running, !unreadable, tasks.contains(where: { $0.id == id }), save() else { return false }
        var archive = currentArchive(); archive.activeID = id
        return commit(archive)
    }

    @discardableResult
    func renameTask(_ id: UUID, title: String) -> Bool {
        guard !running, !unreadable else { return false }
        let title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !title.isEmpty, title.count <= 80 else { error = "Use a task name from 1 to 80 characters."; return false }
        guard save(), let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        var archive = currentArchive(); archive.tasks[index].title = title; archive.tasks[index].automaticTitle = false
        return commit(archive)
    }

    // MARK: Projects

    private func saveProjects(_ list: [ChatProject]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: projectsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: projectsURL, options: [.atomic, .completeFileProtection])
            projects = list
            return true
        } catch {
            self.error = "Your projects could not be saved on this device."
            return false
        }
    }

    /// Makes a project and opens a new chat in it.
    @discardableResult
    func createProject(name: String) -> ChatProject? {
        guard !running, !unreadable else { return nil }
        guard projects.count < ChatProject.maxProjects else { error = ChatProject.Problem.tooManyProjects.localizedDescription; return nil }
        do {
            let project = try ChatProject(name: name)
            guard saveProjects(projects + [project]), newChat(project: project) else { return nil }
            return project
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Applies a change to one project and saves. Files and instructions
    /// reach every chat of the project from its next message.
    @discardableResult
    func updateProject(_ id: UUID, _ change: (inout ChatProject) throws -> Void) -> Bool {
        guard !running, !unreadable, let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        var list = projects
        do { try change(&list[index]) } catch { self.error = error.localizedDescription; return false }
        error = nil
        return saveProjects(list)
    }

    func renameProject(_ id: UUID, name: String) -> Bool {
        updateProject(id) { $0.name = try ChatProject.cleanName(name) }
    }

    func chats(in project: ChatProject) -> [SavedTask] {
        tasks.filter { $0.projectID == project.id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Deletes the project and its files. Its chats are kept as plain chats.
    @discardableResult
    func deleteProject(_ id: UUID) -> Bool {
        guard !running, !unreadable, projects.contains(where: { $0.id == id }), save() else { return false }
        var archive = currentArchive()
        for index in archive.tasks.indices where archive.tasks[index].projectID == id { archive.tasks[index].projectID = nil }
        guard commit(archive) else { return false }
        return saveProjects(projects.filter { $0.id != id })
    }

    /// Moves a plain chat into a project, or out of one with nil.
    @discardableResult
    func moveTask(_ taskID: UUID, to project: ChatProject?) -> Bool {
        guard !running, !unreadable, let index = tasks.firstIndex(where: { $0.id == taskID }), save() else { return false }
        guard tasks[index].repository == nil else { error = "A repository chat cannot join a project."; return false }
        var archive = currentArchive(); archive.tasks[index].projectID = project?.id
        return commit(archive)
    }

    @discardableResult
    func deleteTask(_ id: UUID) -> Bool {
        guard !running, !unreadable, tasks.contains(where: { $0.id == id }), save() else { return false }
        var archive = currentArchive()
        let removed = archive.tasks.first { $0.id == id }?.messages.flatMap { $0.attachments ?? [] } ?? []
        archive.tasks.removeAll { $0.id == id }
        if archive.tasks.isEmpty { archive = SavedTasks() }
        else if archive.activeID == id {
            archive.activeID = archive.tasks.max(by: { $0.updatedAt < $1.updatedAt })!.id
        }
        guard commit(archive) else { return false }
        let retained = Set(archive.tasks.flatMap(\.messages).flatMap { $0.attachments ?? [] }.compactMap(\.imageID))
        PhotoAttachment.discard(removed, retaining: retained)
        TaskWorkspaceStore.remove(task: id, in: workspaceDirectory)
        return true
    }

    func discardPendingPhotos(_ attachments: [Attachment]) {
        let saved = tasks.flatMap(\.messages) + messages
        let retained = Set(saved.flatMap { $0.attachments ?? [] }.compactMap(\.imageID))
        PhotoAttachment.discard(attachments, retaining: retained)
    }

    // Only the explicit reset UI uses this. Preserve unreadable bytes in a
    // protected sibling before replacing the archive; never silently erase them.
    @discardableResult
    func resetUnreadableStorage() -> Bool {
        guard !running, unreadable else { return false }
        do {
            let backup = transcript.deletingLastPathComponent().appendingPathComponent("unreadable-tasks-\(UUID().uuidString).json")
            try Data(contentsOf: transcript).write(to: backup, options: [.atomic, .completeFileProtection])
            var url = backup; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            let archive = SavedTasks(); try archive.write(to: transcript)
            try? FileManager.default.removeItem(at: workspaceDirectory)
            storageUnreadable = false; activate(archive); error = nil
            return true
        } catch { self.error = "Saved tasks could not be reset safely. Your original file was kept."; return false }
    }

    private func resetDirector() {
        directorSession = nil
        directorBinding = nil
        directorMode = false
    }

    private func currentArchive() -> SavedTasks {
        var archive = SavedTasks(); archive.tasks = tasks; archive.activeID = activeTaskID
        return archive
    }
    private func activate(_ archive: SavedTasks) {
        let task = archive.tasks.first(where: { $0.id == archive.activeID })!
        let mode = task.repository != nil && task.editProposalsEnabled == true
        if activeTaskID != task.id || repository != task.repository || directorMode != mode { resetDirector() }
        tasks = archive.tasks; activeTaskID = archive.activeID
        messages = task.messages; repository = task.repository
        publishState = task.publish; publishWorkflows = []; publishLogs = nil
        directorMode = mode
        thinkingEnabled = task.thinkingEnabled == true
        chatMode = ChatMode.resolve(saved: task.mode, app: task.app != nil, repository: task.repository != nil)
        let validIDs = Set(connectors.map(\.id))
        enabledConnectorIDs = (task.enabledConnectorIDs ?? []).filter { validIDs.contains($0) }
    }
    private func commit(_ archive: SavedTasks) -> Bool {
        guard archiveWriter.writeNow(archive) else {
            self.error = "Your tasks could not be saved on this device."
            return false
        }
        activate(archive); error = nil
        return true
    }

    private func archiveForCurrentTask() -> SavedTasks? {
        guard !unreadable, let index = tasks.firstIndex(where: { $0.id == activeTaskID }) else { return nil }
        var archive = currentArchive()
        archive.tasks[index].messages = messages; archive.tasks[index].repository = repository
        archive.tasks[index].publish = publishState
        archive.tasks[index].editProposalsEnabled = directorMode
        archive.tasks[index].thinkingEnabled = thinkingEnabled
        archive.tasks[index].enabledConnectorIDs = enabledConnectorIDs.isEmpty ? nil : enabledConnectorIDs
        archive.tasks[index].updatedAt = Date()
        if archive.tasks[index].automaticTitle { archive.tasks[index].title = SavedTask.title(for: messages) }
        return archive
    }

    @discardableResult
    private func save() -> Bool {
        guard let archive = archiveForCurrentTask() else { return false }
        guard archiveWriter.writeNow(archive) else {
            self.error = "Your tasks could not be saved on this device."
            return false
        }
        tasks = archive.tasks
        return true
    }

    // Streaming progress is checkpointed off the main actor. The final save()
    // waits for any in-flight checkpoint, so an older snapshot cannot win.
    private func saveCheckpoint() {
        guard let archive = archiveForCurrentTask() else { return }
        archiveWriter.writeCheckpoint(archive)
    }

    func flushPersistence() {
        guard let archive = archiveForCurrentTask() else { return }
        archiveWriter.writeNow(archive)
    }
}
