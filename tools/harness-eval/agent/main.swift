import Foundation

// Multi-turn agent eval. Runs real tasks against a real Bonsai model through
// the same prompt rendering, call parsers, tool code, compaction and guards
// the app uses (the harness package), and scores the outcome without a model.
// See tools/harness-eval/README.md.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var server = URL(string: "http://127.0.0.1:8080")!
    var context = 16_384
    var tools = "workspace"
    var samples = 1
    var only: Set<String> = []
    var kind: String?
    var out: String?
    var mapBudget = 2_400
    var sampling = ModelServer.Sampling()
    var verbose = false
    /// Prompt template, call format and default sampler of this model family.
    var family = ModelFamily.bonsai
    /// Constrain tool calls with the grammar built from the offered tools.
    var grammar = false
    var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value() -> String {
        guard arguments.count >= 2 else { fatalError("missing value for \(arguments[0])") }
        let result = arguments[1]
        arguments.removeFirst(2)
        return result
    }
    while let flag = arguments.first {
        switch flag {
        case "--server": options.server = URL(string: value())!
        case "--context": options.context = Int(value())!
        case "--tools": options.tools = value()
        case "--samples": options.samples = Int(value())!
        case "--tasks": options.only = Set(value().split(separator: ",").map(String.init))
        case "--kind": options.kind = value()
        case "--out": options.out = value()
        case "--map-budget": options.mapBudget = Int(value())!
        case "--top-k": options.sampling.topK = Int(value())!
        case "--top-p": options.sampling.topP = Double(value())!
        case "--temperature": options.sampling.temperature = Double(value())!
        case "--presence-penalty": options.sampling.presencePenalty = Double(value())!
        case "--stop-on-call": options.sampling.stop = ["</tool_call>"]; arguments.removeFirst()
        case "--root": options.root = URL(fileURLWithPath: value())
        case "--verbose": options.verbose = true; arguments.removeFirst()
        case "--family":
            guard let family = ModelFamily(rawValue: value()) else { fatalError("--family is bonsai, lfm3 or miniCPM5") }
            options.family = family
            if family != .bonsai {
                options.sampling.topK = family.sampling.topK; options.sampling.topP = family.sampling.topP
                options.sampling.temperature = family.sampling.temperature
                options.sampling.minP = family.sampling.minP; options.sampling.repeatPenalty = family.sampling.repeatPenalty
            }
        case "--grammar": options.grammar = true; arguments.removeFirst()
        case "--print-grammar":
            // Writes the GBNF for one tool set (director, local, repository), for llama.cpp's validator.
            let set: AgentPrompt.ToolSet = ["director": .director, "local": .local, "repository": .repository][value()]!
            print(ToolCallGrammar.make(tools: AgentPrompt.toolLines(for: set), family: options.family)!.text, terminator: "")
            exit(0)
        default: fatalError("unknown argument \(flag)")
        }
    }
    return options
}

let options = parseOptions()
let server = ModelServer(base: options.server)
let evalRoot = options.root.appendingPathComponent("tools/harness-eval")

// MARK: - Fixtures

func shell(_ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil) throws -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

struct Fixture {
    let name: String
    let commit: String
    let entries: [TaskWorkspace.TreeEntry]
    /// Either a gzip tarball of the commit, or the files themselves.
    var archive: Data?
    var files: [(path: String, data: Data)] = []

    func workspace() throws -> TaskWorkspace {
        let workspace = try TaskWorkspace(path: ":memory:")
        try workspace.setBase(.init(repository: name, commit: commit, tree: String(repeating: "0", count: 40)), entries: entries)
        if let archive { _ = try workspace.importArchive(archive) }
        for file in files { _ = try workspace.store(path: file.path, data: file.data) }
        guard workspace.isComplete else { fatalError("fixture \(name) did not import completely") }
        return workspace
    }
}

func repositoryFixture() throws -> Fixture {
    let root = options.root.path
    let listing = try shell(["git", "-C", root, "ls-tree", "-r", "-l", "-z", pinnedRepositoryCommit])
    guard listing.status == 0 else { fatalError("git ls-tree failed: is \(pinnedRepositoryCommit) in this checkout?") }
    var entries: [TaskWorkspace.TreeEntry] = []
    for row in listing.output.split(separator: 0) {
        guard let tab = row.firstIndex(of: 9) else { continue }
        let meta = String(decoding: row[row.startIndex..<tab], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
        entries.append(.init(path: String(decoding: row[row.index(after: tab)...], as: UTF8.self),
                             mode: String(meta[0]), type: String(meta[1]), sha: String(meta[2]), size: Int(meta[3])))
    }
    let tar = FileManager.default.temporaryDirectory.appendingPathComponent("keel-eval-\(UUID().uuidString).tgz")
    defer { try? FileManager.default.removeItem(at: tar) }
    let archive = try shell(["git", "-C", root, "archive", "--format=tar.gz", "--prefix=repo/", "-o", tar.path, pinnedRepositoryCommit])
    guard archive.status == 0 else { fatalError("git archive failed") }
    return Fixture(name: "olivermikkola/keel-mobile", commit: pinnedRepositoryCommit, entries: entries, archive: try Data(contentsOf: tar))
}

func directoryFixture(_ name: String) throws -> Fixture {
    let base = evalRoot.appendingPathComponent("fixtures/\(name)")
    var files: [(String, Data)] = []
    let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              !url.path.contains("__pycache__") else { continue }
        let path = String(url.path.dropFirst(base.path.count + 1))
        files.append((path, try Data(contentsOf: url)))
    }
    files.sort { $0.0 < $1.0 }
    let entries = files.map { TaskWorkspace.TreeEntry(path: $0.0, mode: "100644", type: "blob", sha: GitBlob.sha($0.1), size: $0.1.count) }
    return Fixture(name: "example/\(name)", commit: String(repeating: "f", count: 40), entries: entries, files: files)
}

var fixtures: [String: Fixture] = [:]
func fixture(_ name: String) throws -> Fixture {
    if let cached = fixtures[name] { return cached }
    let made = name == "repo" ? try repositoryFixture()
        : name == "local" ? Fixture(name: "local", commit: LocalFiles.identity.commit, entries: [])
        : try directoryFixture(name)
    fixtures[name] = made
    return made
}

// MARK: - One conversation

struct Step: Encodable {
    var output: String
    var call: String?
    var result: String?
    var prefill: Int
    var generated: Int
}

struct Outcome: Encodable {
    var task: String
    var sample: Int
    var success = false
    var answered = false
    var grounded = false
    var fatal: String?
    var steps = 0
    var rejected = 0
    var toolErrors = 0
    var proposals = 0
    var staleProposals = 0
    /// run_js calls; the eval cannot run JavaScript on Linux, so the model gets a tool error.
    var scriptCalls = 0
    var userTurns = 0
    /// Prompt tokens the phone would have to evaluate, under the app's exact-prefix cache rule.
    var prefillTokens = 0
    var cacheMisses = 0
    var generatedTokens = 0
    /// Calls that put every argument as JSON inside one `parameters` or `arguments` parameter.
    var wrappedCalls = 0
    var seconds = 0.0
    var answer = ""
    var checkOutput = ""
    var transcript: [Step] = []
}

enum Fatal: Error { case stop(String) }

final class Conversation {
    let task: EvalTask
    let fixture: Fixture
    let workspace: TaskWorkspace
    let seed: Int
    var messages: [(role: String, text: String)] = []
    var outcome: Outcome
    var cached: [Int] = []
    var pending: [PlannedEdit] = []
    var applied: [TaskWorkspace.Operation] = []
    var appliedCount = 0
    var openedPaths: [String] = []
    var generation = 0
    let system: String
    /// The app's reply cap: room for a whole file when the task can write.
    var replyTokens: Int { task.kind == .read ? AgentPrompt.readingReplyTokens : AgentPrompt.writingReplyTokens }
    let sqlPath = FileManager.default.temporaryDirectory.appendingPathComponent("keel-eval-\(UUID().uuidString).sqlite").path

    init(task: EvalTask, sample: Int) throws {
        self.task = task
        fixture = try FixtureStore.get(task.fixture)
        if task.kind == .local {
            workspace = try TaskWorkspace(path: ":memory:")
            applied = LocalFiles.operations(attachments: task.attachments, changes: [])
            try LocalFiles.prepare(workspace, key: "attachments", operations: applied)
        } else {
            workspace = try fixture.workspace()
        }
        seed = 1_000 * (evalTasks.firstIndex { $0.id == task.id } ?? 0) + sample
        outcome = Outcome(task: task.id, sample: sample)
        let director = task.kind == .edit
        if task.kind == .local {
            system = AgentPrompt.local()
        } else if options.tools == "legacy" {
            system = director
                ? try Legacy.prompt(root: options.root, file: "Sources/DirectorTools.swift", marker: "static func systemPrompt(",
                                    replacing: ["\\(snapshot.repository.fullName)": fixture.name, "\\(snapshot.branch)": "main"])
                : try Legacy.prompt(root: options.root, file: "Sources/RepositoryAgent.swift", marker: "let system = ",
                                    replacing: ["\\(snapshot.repository.fullName)": fixture.name, "\\(snapshot.commit)": fixture.commit])
        } else {
            let map = workspace.repoMap(maxCharacters: options.mapBudget)
            system = director ? AgentPrompt.director(name: fixture.name, branch: "main", map: map)
                : AgentPrompt.repository(name: fixture.name, commit: fixture.commit, map: map)
        }
    }

    func generate() throws -> (text: String, predicted: Int) {
        var history = messages.filter { !$0.text.isEmpty }
        // Same budget as the app's HarnessBridge.
        let reply = replyTokens
        if let compacted = ContextBudget(maxContextTokens: options.context).compactPrompt(history, reservedTokens: 1_536 + reply) { history = compacted }
        // The rendered text carries its own beginning-of-text token where the
        // family needs one; llama-server adds none for these vocabularies.
        let prompt = ModelPrompt.render(family: options.family, system: system, messages: history)
        let tokens = try server.tokenize(prompt)
        guard tokens.count + reply < options.context else { throw Fatal.stop("context overflow") }
        // The phone reuses its decoded tokens only when they are an exact prefix of the next prompt.
        let hit = cached.count <= tokens.count && Array(tokens.prefix(cached.count)) == cached
        let prefill = hit ? tokens.count - cached.count : tokens.count
        if !hit { outcome.cacheMisses += 1 }
        generation += 1
        // As LocalChat: the grammar of the tools this prompt shows.
        let grammar = options.grammar ? ToolCallGrammar.make(prompt: prompt, family: options.family) : nil
        let completion = try server.complete(prompt, limit: reply, seed: seed * 100 + generation, sampling: options.sampling, grammar: grammar)
        cached = tokens + completion.tokens
        outcome.prefillTokens += prefill
        outcome.generatedTokens += completion.predicted
        outcome.transcript.append(Step(output: completion.text, call: nil, result: nil, prefill: prefill, generated: completion.predicted))
        return (completion.text, completion.predicted)
    }

    func note(call: String, result: String) {
        outcome.transcript[outcome.transcript.count - 1].call = call
        outcome.transcript[outcome.transcript.count - 1].result = result
        messages.append(("tool", result))
        outcome.steps += 1
    }

    func read(_ call: RepositoryCall) throws -> String {
        let output: WorkspaceTools.Output
        if options.tools == "legacy" {
            guard call.name != "search_repo" else { throw RepositoryAgentError.call }
            output = try Legacy.execute(call, workspace: workspace, commit: fixture.commit)
        } else {
            output = try WorkspaceTools(workspace: workspace).execute(call)
        }
        openedPaths.append(contentsOf: output.paths)
        return output.text
    }

    func observation(_ edit: PlannedEdit) -> String {
        // The app's TaskFileEdit.observation, field for field.
        var value = ["result_type": "edit_proposal", "proposal_id": UUID().uuidString, "kind": edit.kind.rawValue, "path": edit.path,
                     "commit": fixture.commit, "status": "pending", "before_sha": edit.beforeSHA, "after_sha": GitBlob.sha(edit.after),
                     "note": "Prepared only. The user must review and apply this change in the UI. No file was changed."]
        if task.kind == .local { value["commit"] = nil }
        if let destination = edit.destinationPath { value["destination_path"] = destination }
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// One user message through to the model's final reply, as LocalChat.send runs it.
    func turn() throws -> String {
        var toolCount = 0
        let repeatGuard = RepeatGuard()
        let breaker = CircuitBreaker()
        let limit = task.kind == .read ? 8 : 16
        while true {
            var (output, predicted) = try generate()
            if output.range(of: "<parameter=(parameters|arguments)>", options: .regularExpression) != nil
                || output.range(of: "<param name=\"(parameters|arguments)\">", options: .regularExpression) != nil {
                outcome.wrappedCalls += 1
            }
            // As LocalChat: native calls become the strict format, or fail the strict parser.
            do { output = try NativeToolCall.normalize(output, family: options.family) }
            catch { output = "<tool_call>" + output + "</tool_call>" }
            let normalized = ToolCallText.normalize(output)
            if normalized.repaired { output = normalized.text }
            messages.append(("assistant", output))

            if task.kind != .read {
                let parsed: DirectorCall?
                do { parsed = try DirectorCall.parse(output) } catch {
                    guard predicted < replyTokens, toolCount < limit else { throw Fatal.stop("invalid call at limit") }
                    toolCount += 1
                    outcome.rejected += 1
                    note(call: "rejected", result: "Not executed: \(error.localizedDescription) Correct the tool format and try again.")
                    continue
                }
                guard let call = parsed else { return output }
                guard predicted < replyTokens else { throw Fatal.stop("call cut off by the reply limit") }
                guard toolCount < limit else { throw Fatal.stop("tool limit") }
                toolCount += 1
                let reminder = repeatGuard.observe(name: call.name, arguments: call.arguments) ?? ""
                do {
                    let text: String
                    if ["propose_edit", "stage_file_edit", "create_file", "delete_file", "rename_file"].contains(call.name) {
                        let edit = try EditPlanner.plan(call, workspace: workspace, newFolders: task.kind == .local)
                        pending.append(edit)
                        outcome.proposals += 1
                        text = observation(edit)
                    } else if ["list_files", "read_file", "search_file", "search_repo"].contains(call.name) {
                        text = try read(try call.readCall())
                    } else if call.name == "run_sql" {
                        let tables = task.kind == .local ? FileTables.tables(from: workspace.textFiles()) : []
                        text = try SQLSandbox(path: sqlPath, limits: SQLLimits()).run(call.arguments["sql"] ?? "", tables: tables).text
                    } else if call.name == "run_js" {
                        outcome.scriptCalls += 1
                        throw DirectorToolError.invalidCall("JavaScript cannot run in this eval.")
                    } else {
                        throw DirectorToolError.approvalRequired
                    }
                    breaker.recordSuccess()
                    note(call: call.label, result: text + reminder)
                } catch {
                    outcome.toolErrors += 1
                    let advice = breaker.recordFailure(.other(String(describing: type(of: error)))) ?? ""
                    let message = WorkspaceTools.recoverableMessage(error) ?? "Tool error: \(error.localizedDescription)"
                    note(call: call.label, result: message + reminder + advice)
                }
                continue
            }

            let call: RepositoryCall?
            do { call = try RepositoryCall.parse(output) } catch let error as RepositoryArgumentError {
                guard predicted < replyTokens else { throw Fatal.stop("call cut off by the reply limit") }
                guard toolCount < limit else { throw Fatal.stop("tool limit") }
                toolCount += 1
                outcome.rejected += 1
                note(call: "rejected", result: error.localizedDescription)
                continue
            } catch {
                outcome.rejected += 1
                throw Fatal.stop("invalid call: \(output.prefix(160))")
            }
            guard let call else { return output }
            guard predicted < replyTokens else { throw Fatal.stop("call cut off by the reply limit") }
            guard toolCount < limit else { throw Fatal.stop("tool limit") }
            toolCount += 1
            let arguments = ["path": call.path, "offset": String(call.offset), "count": String(call.count), "query": call.query ?? ""]
            let reminder = repeatGuard.observe(name: call.name, arguments: arguments) ?? ""
            do {
                let text = try read(call)
                breaker.recordSuccess()
                note(call: call.label, result: text + reminder)
            } catch {
                guard let message = WorkspaceTools.recoverableMessage(error) else { throw Fatal.stop("tool failure: \(error)") }
                outcome.toolErrors += 1
                let advice = breaker.recordFailure(.notFound) ?? ""
                note(call: call.label, result: message + reminder + advice)
            }
        }
    }

    /// The user taps Apply on every pending proposal, in order.
    func applyPending() throws -> (applied: Int, stale: Int) {
        var done = 0, stale = 0
        for edit in pending {
            let current = try? workspace.read(edit.path)
            let fresh = edit.kind == .create ? current == nil : current?.text == edit.before
            let free = edit.destinationPath.map { (try? workspace.read($0)) == nil } ?? true
            guard fresh, free else { stale += 1; continue }
            applied.append(contentsOf: edit.operations)
            appliedCount += 1
            try workspace.setOverlay(key: "applied-\(appliedCount)", operations: applied)
            done += 1
        }
        pending.removeAll()
        outcome.staleProposals += stale
        return (done, stale)
    }

    func run() -> Outcome {
        let started = Date()
        do {
            var first = task.prompt
            if !task.attachments.isEmpty {
                // As LocalChat sends an attachment: the text after the message, and the file in the workspace.
                let attached = task.attachments.map { Attachment(filename: $0.path, mimeType: "text/plain", extractedText: $0.text, byteSize: $0.text.utf8.count) }
                first += "\n\n" + AttachmentPromptFormatter.formatAll(attached)
            }
            messages.append(("user", first))
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: sqlPath + suffix) } }
            for round in 1...4 {
                outcome.userTurns = round
                outcome.answer = try turn()
                guard task.kind != .read, !pending.isEmpty else { break }
                let result = try applyPending()
                var reply = "I reviewed and applied \(result.applied) proposed change\(result.applied == 1 ? "" : "s")."
                if result.stale > 0 { reply += " \(result.stale) could not be applied because the file had already changed; read it again and propose that change again." }
                reply += " If the task is finished, reply DONE. Otherwise continue."
                messages.append(("user", reply))
            }
            if !pending.isEmpty { _ = try applyPending() }
        } catch Fatal.stop(let reason) {
            outcome.fatal = reason
            if !pending.isEmpty { _ = try? applyPending() }
        } catch {
            outcome.fatal = "error: \(error)"
        }
        outcome.seconds = Date().timeIntervalSince(started)
        score()
        return outcome
    }

    func score() {
        switch task.kind {
        case .read:
            let answer = outcome.answer.lowercased()
            outcome.answered = outcome.fatal == nil && task.answer.allSatisfy { group in group.contains { answer.contains($0.lowercased()) } }
            outcome.grounded = task.evidence.contains { evidence in openedPaths.contains(evidence) }
            outcome.success = outcome.answered && outcome.grounded
        case .local:
            outcome.success = outcome.fatal == nil && (task.check?(workspace, outcome.answer, outcome.steps) ?? false)
            outcome.answered = outcome.success
            outcome.grounded = true
        case .edit:
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-eval-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                for file in workspace.textFiles() {
                    let url = directory.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(file.text.utf8).write(to: url)
                }
                let check = evalRoot.appendingPathComponent("checks/\(task.id).py").path
                let result = try shell(["python3", "-B", check], directory: directory,
                                     environment: ["PYTHONPATH": directory.path, "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"])
                outcome.success = result.status == 0
                outcome.checkOutput = String(String(decoding: result.output, as: UTF8.self).suffix(400))
            } catch {
                outcome.checkOutput = "check could not run: \(error)"
            }
            outcome.answered = outcome.success
            outcome.grounded = outcome.appliedChanges
        }
    }
}

extension Outcome {
    var appliedChanges: Bool { proposals - staleProposals > 0 }
}

enum FixtureStore {
    static func get(_ name: String) throws -> Fixture { try fixture(name) }
}

// MARK: - Run

let selected = evalTasks.filter { (options.only.isEmpty || options.only.contains($0.id)) && (options.kind == nil || $0.kind.rawValue == options.kind) }
let model = server.modelName()
print("model: \(model)  family: \(options.family.rawValue)  grammar: \(options.grammar ? "on" : "off")  tools: \(options.tools)  context: \(options.context)  samples: \(options.samples)  tasks: \(selected.count)")
print("sampler: top_k \(options.sampling.topK), top_p \(options.sampling.topP), temperature \(options.sampling.temperature), presence_penalty \(options.sampling.presencePenalty), min_p \(options.sampling.minP.map { "\($0)" } ?? "off"), repeat_penalty \(options.sampling.repeatPenalty.map { "\($0)" } ?? "off")\(options.sampling.stop.isEmpty ? "" : ", stop on </tool_call>")")

var outcomes: [Outcome] = []
let output = options.out.flatMap { path -> FileHandle? in
    _ = FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }

for task in selected {
    for sample in 0..<options.samples {
        let conversation: Conversation
        do { conversation = try Conversation(task: task, sample: sample) } catch { fatalError("cannot prepare \(task.id): \(error)") }
        let outcome = conversation.run()
        outcomes.append(outcome)
        let mark = outcome.success ? "PASS" : "FAIL"
        var detail = "steps \(outcome.steps), prefill \(outcome.prefillTokens), generated \(outcome.generatedTokens), \(Int(outcome.seconds))s"
        if outcome.rejected > 0 { detail += ", rejected \(outcome.rejected)" }
        if outcome.wrappedCalls > 0 { detail += ", JSON-wrapped calls \(outcome.wrappedCalls)" }
        if outcome.toolErrors > 0 { detail += ", tool errors \(outcome.toolErrors)" }
        if outcome.scriptCalls > 0 { detail += ", run_js \(outcome.scriptCalls)" }
        if task.kind == .read, !outcome.success { detail += outcome.answered ? ", not grounded" : (outcome.grounded ? ", wrong answer" : ", wrong answer, not grounded") }
        if let fatal = outcome.fatal { detail += ", stopped: \(fatal.prefix(80))" }
        print("\(mark)  \(pad(task.id, 20)) #\(sample)  \(detail)")
        if options.verbose {
            for step in outcome.transcript {
                print("    > \(step.output.replacingOccurrences(of: "\n", with: "⏎").prefix(300))")
                if let result = step.result { print("    < \(result.replacingOccurrences(of: "\n", with: "⏎").prefix(300))") }
            }
            if !outcome.checkOutput.isEmpty { print("    check: \(outcome.checkOutput.replacingOccurrences(of: "\n", with: "⏎").suffix(300))") }
        }
        if let output, let line = try? JSONEncoder().encode(outcome) {
            output.write(line)
            output.write(Data("\n".utf8))
        }
    }
}

func summary(_ label: String, _ rows: [Outcome]) {
    guard !rows.isEmpty else { return }
    let passed = rows.filter(\.success).count
    func mean(_ value: (Outcome) -> Int) -> String { String(format: "%.1f", Double(rows.reduce(0) { $0 + value($1) }) / Double(rows.count)) }
    print("\(pad(label, 8)) \(passed)/\(rows.count) passed · mean steps \(mean { $0.steps }) · mean prefill tokens \(mean { $0.prefillTokens }) · mean generated \(mean { $0.generatedTokens }) · rejected calls \(rows.reduce(0) { $0 + $1.rejected }) · JSON-wrapped calls \(rows.reduce(0) { $0 + $1.wrappedCalls }) · tool errors \(rows.reduce(0) { $0 + $1.toolErrors }) · stopped \(rows.filter { $0.fatal != nil }.count) · cache misses \(rows.reduce(0) { $0 + $1.cacheMisses }) · mean seconds \(mean { Int($0.seconds) })")
}
print("")
let kinds = Dictionary(grouping: outcomes) { outcome in evalTasks.first { $0.id == outcome.task }!.kind.rawValue }
summary("read", kinds["read"] ?? [])
summary("edit", kinds["edit"] ?? [])
summary("local", kinds["local"] ?? [])
summary("all", outcomes)
