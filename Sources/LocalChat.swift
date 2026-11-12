import SwiftUI

struct ChatMessage: Codable, Identifiable {
    var id: UUID
    let role: String
    var text: String
    var note: String?
    var isToolCall: Bool?
    var activity: String?
    var edit: TaskFileEdit?

    init(id: UUID = UUID(), role: String, text: String, note: String? = nil, isToolCall: Bool? = nil, activity: String? = nil, edit: TaskFileEdit? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.note = note
        self.isToolCall = isToolCall
        self.activity = activity
        self.edit = edit
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
    @Published var error: String?
    let inference: LocalInference
    private let generator: any LocalGenerating
    private let repositoryClient: (RepositoryID) throws -> GitHubRepository
    private struct DirectorBinding: Equatable {
        let taskID: UUID
        let snapshot: RepositorySnapshot
    }
    private var directorSession: DirectorSession?
    private var directorBinding: DirectorBinding?
    private var operation: Task<Void, Never>?
    private var cancellation: InferenceCancellation?
    private var transcript: URL
    private let archiveWriter: ArchiveWriter
    private var unreadable: Bool { storageUnreadable }
    var activeTitle: String { tasks.first(where: { $0.id == activeTaskID })?.title ?? "New task" }

    init(transcript: URL? = nil, generator: (any LocalGenerating)? = nil,
         repositoryClient: @escaping (RepositoryID) throws -> GitHubRepository = {
             try GitHubRepository(repository: $0, token: GitHubCredential.load())
         }) {
        let runtime = LocalInference()
        inference = runtime; self.generator = generator ?? runtime
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
            }
        }
        #endif
        archiveWriter = ArchiveWriter(destination: self.transcript)
        do {
            let archive = FileManager.default.fileExists(atPath: self.transcript.path)
                ? try SavedTasks.load(Data(contentsOf: self.transcript)) : SavedTasks()
            activate(archive)
        } catch {
            storageUnreadable = true
            self.error = "Saved tasks could not be opened. They have been kept unchanged. Open Saved tasks to reset safely."
        }
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

    func send(_ text: String, model: LocalModel, path: URL) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !text.isEmpty else { return }
        guard !unreadable else { error = RepositoryAgentError.storage.localizedDescription; return }
        guard text.utf8.count <= 16_384 else { error = LocalModelError.tooLong.localizedDescription; return }
        error = nil
        messages.append(ChatMessage(role: "user", text: text))
        guard save() else { return }
        running = true; phase = "Loading model and reading your message…"
        let flag = InferenceCancellation(); cancellation = flag
        operation = Task {
            let started = Date()
            var activeReply: UUID?
            do {
                let director: DirectorSession?
                let tools: RepositoryTools?
                if let repository {
                    let client = try repositoryClient(repository.repository)
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
                        tools = RepositoryTools(client: client, snapshot: repository, appliedEdits: TaskFileEdit.applied(in: messages))
                    }
                } else {
                    director = nil
                    tools = nil
                }
                var toolCount = 0
                var readPaths = Set<String>()
                // Keel harness: loop reminders and failure advice for this request.
                let repeatGuard = RepeatGuard()
                let breaker = CircuitBreaker()
                while true {
                    try Task.checkCancellation()
                    var history = messages.filter { !$0.text.isEmpty }
                    if tools != nil || director != nil {
                        history = HarnessBridge.promptHistory(history, contextSize: model.contextSize)
                    }
                    let prompt: String
                    if let director, let repository {
                        prompt = LocalInference.prompt(history, system: DirectorSession.systemPrompt(snapshot: repository))
                    } else if let tools {
                        prompt = RepositoryTools.prompt(history, snapshot: tools.snapshot)
                    } else {
                        prompt = LocalInference.prompt(history)
                    }
                    let reply = ChatMessage(role: "assistant", text: "", note: "Responding")
                    messages.append(reply); activeReply = reply.id
                    guard save() else { throw RepositoryAgentError.saving }
                    phase = toolCount == 0 ? "Loading model and reading your message…" : "Thinking with the repository results…"
                    var output = ""
                    var tokenCount = 0
                    var checkpoint = Date()
                    let runtime = generator
                    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
                        let producer = Task {
                            do {
                                let count = try await runtime.generate(path: path.path, prompt: prompt, limit: 512,
                                                                       contextSize: model.contextSize,
                                                                       cancellation: flag,
                                                                       onPrefill: { done, total in
                                                                           continuation.yield(.prefill(done, total))
                                                                       }) {
                                    continuation.yield(.text($0))
                                }
                                continuation.yield(.generated(count)); continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        continuation.onTermination = { termination in
                            if case .cancelled = termination { flag.cancel(); producer.cancel() }
                        }
                    }
                    for try await event in stream {
                        switch event {
                        case .text(let chunk):
                            output += chunk
                            // Hold XML calls out of the reply bubble. Plain answers
                            // still stream; tool requests become activity rows.
                            if (tools == nil && director == nil) || (!output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") && !output.contains("<tool_call")) {
                                update(reply.id) { $0.text = output }
                                phase = "Writing on your iPhone…"
                                if Date().timeIntervalSince(checkpoint) >= 2 {
                                    saveCheckpoint()
                                    checkpoint = Date()
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
                    guard !flag.isCancelled else { throw CancellationError() }
                    if tools != nil || director != nil {
                        // Strip a code fence or trailing prose around exactly one call.
                        // Arguments are untouched; the strict parsers still decide.
                        let normalized = ToolCallText.normalize(output)
                        if normalized.repaired { output = normalized.text }
                    }
                    update(reply.id) { $0.text = output }

                    if let director {
                        let parsed: DirectorCall?
                        do { parsed = try DirectorCall.parse(output) }
                        catch {
                            guard tokenCount < 512, toolCount < 16 else { throw RepositoryAgentError.call }
                            toolCount += 1
                            update(reply.id) { $0.isToolCall = true; $0.note = "Rejected" }
                            messages.append(ChatMessage(role: "tool", text: "Not executed: \(error.localizedDescription) Correct the tool format and try again.",
                                                        note: "Not executed", activity: "Correct tool request"))
                            guard save() else { throw RepositoryAgentError.saving }
                            continue
                        }
                        if let dCall = parsed {
                            guard tokenCount < 512 else { throw RepositoryAgentError.call }
                            update(reply.id) { $0.isToolCall = true; $0.note = "Requested" }
                            guard toolCount < 16 else {
                                messages.append(ChatMessage(role: "tool", text: "Not executed: 16-tool limit reached.", note: "Stopped", activity: dCall.label))
                                throw RepositoryAgentError.steps
                            }
                            toolCount += 1
                            let reminder = repeatGuard.observe(name: dCall.name, arguments: dCall.arguments) ?? ""
                            let result = ChatMessage(role: "tool", text: "", note: "Executing…", activity: dCall.label)
                            messages.append(result); activeReply = result.id; phase = dCall.label
                            guard save() else { throw RepositoryAgentError.saving }
                            do {
                                if ["propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file"].contains(dCall.name) {
                                    guard messages.compactMap(\.edit).count < 16 else { throw FileEditError.limit }
                                    let record = TaskFileEdit(proposal: try await director.propose(dCall))
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = record.observation + reminder; $0.note = "Needs review"; $0.edit = record }
                                } else {
                                    let text = try await director.execute(dCall)
                                    try Task.checkCancellation()
                                    update(result.id) { $0.text = text + reminder; $0.note = "Completed" }
                                }
                                breaker.recordSuccess()
                            } catch {
                                let advice = breaker.recordFailure(HarnessBridge.failure(error)) ?? ""
                                update(result.id) { $0.text = "Tool error: \(error.localizedDescription)" + reminder + advice; $0.note = "Error" }
                            }
                            guard save() else { throw RepositoryAgentError.saving }
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
                        guard tokenCount < 512 else { throw RepositoryAgentError.call }
                        update(reply.id) { $0.isToolCall = true; $0.note = "Rejected" }
                        guard toolCount < 8 else { throw RepositoryAgentError.steps }
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
                        guard tokenCount < 512 else { throw RepositoryAgentError.call }
                        update(reply.id) { $0.isToolCall = true; $0.note = "Requested" }
                        guard toolCount < 8 else {
                            messages.append(ChatMessage(role: "tool", text: "Not executed: eight-tool limit reached.", note: "Stopped", activity: call.label))
                            throw RepositoryAgentError.steps
                        }
                        toolCount += 1
                        let reminder = repeatGuard.observe(name: call.name, arguments: HarnessBridge.arguments(call)) ?? ""
                        let result = ChatMessage(role: "tool", text: "", note: "Reading…", activity: call.label)
                        messages.append(result); activeReply = result.id; phase = call.label
                        guard save() else { throw RepositoryAgentError.saving }
                        do {
                            let text = try await tools.execute(call)
                            try Task.checkCancellation()
                            breaker.recordSuccess()
                            let local = tools.hasLocalChanges(at: call.path) ? " · with approved task changes" : ""
                            update(result.id) { $0.text = text + reminder; $0.note = "Verified base \(tools.snapshot.commit.prefix(7))\(local)" }
                            if ["read_file", "search_file"].contains(call.name) { readPaths.insert(call.path) }
                        } catch {
                            if !Task.isCancelled, let message = RepositoryTools.recoverableMessage(error) {
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
                    let limit = tokenCount >= 512 ? " · reply limit reached" : ""
                    let evidence = tools == nil ? "" : " · \(readPaths.count) file\(readPaths.count == 1 ? "" : "s") read this turn"
                    update(reply.id) { $0.note = "\(model.name) · \(elapsed)\(limit)\(evidence)" }
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
        }
    }

    private func parentPath(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }
    var fileEdits: [TaskFileEdit] { messages.compactMap(\.edit) }

    func applyEdit(_ id: UUID) {
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
            running = false; publishing = false; phase = ""; operation = nil
        }
    }

    func stop(reason: String? = nil) {
        guard running else { return }
        cancellation?.cancel(); operation?.cancel()
        // Persist the visible partial immediately, while the scene is still
        // active. Relaunch marks Responding as interrupted even if iOS suspends
        // us before the asynchronous cancellation cleanup gets to run.
        save()
        if let reason { error = reason }
    }
    func sceneDidChange(_ phase: ScenePhase) {
        scenePhase = phase
        updateIdleTimer()
        // Control Center and system prompts temporarily make the scene
        // inactive. They do not mean the user has left the app.
        if phase == .background { leaveForeground() }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = running && scenePhase == .active
    }

    func leaveForeground() {
        stop(reason: applyingEditID == nil ? "On-device work stops when you leave the app. Your partial reply is kept. CI already dispatched continues on GitHub; return and check it before continuing." :
                "The review check stopped. The proposal is still pending; review it again to apply.")
        Task { await inference.unload() }
    }
    @discardableResult
    func newChat() -> Bool {
        guard !running, !unreadable, save() else { return false }
        guard tasks.count < 200 else { error = "You have 200 saved tasks. Delete a task before starting another."; return false }
        let task = SavedTask()
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

    @discardableResult
    func deleteTask(_ id: UUID) -> Bool {
        guard !running, !unreadable, tasks.contains(where: { $0.id == id }), save() else { return false }
        var archive = currentArchive(); archive.tasks.removeAll { $0.id == id }
        if archive.tasks.isEmpty { archive = SavedTasks() }
        else if archive.activeID == id {
            archive.activeID = archive.tasks.max(by: { $0.updatedAt < $1.updatedAt })!.id
        }
        return commit(archive)
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
