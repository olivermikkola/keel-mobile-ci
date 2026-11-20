import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os
#if canImport(KeelHarness)
import KeelHarness
#endif

/// A document added to Decide: its name and the text the model reads.
struct DecideDocument: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let name: String
    let text: String
    var words: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// What Decide found for one document.
enum DecideOutcome: Equatable, Codable {
    case done(answers: [DecisionAnswer], fractionRead: Double, seconds: Double)
    case failed(String)
}

/// Asks the same questions about every document with the d1 decision model,
/// one document at a time, on this iPhone.
@MainActor
final class DecideSession: ObservableObject {
    private struct PersistedState: Codable {
        let documents: [DecideDocument]
        let outcomes: [String: [DecideOutcome]]
        let asked: [DecisionQuestion]
    }

    @Published var documents: [DecideDocument] = []
    @Published var questions: [DecisionQuestion] = [] { didSet { saveQuestions() } }
    /// One outcome per part of each document; a document that fits is one part.
    @Published private(set) var outcomes: [UUID: [DecideOutcome]] = [:]
    /// The questions the outcomes answer, kept as they were when asked.
    @Published private(set) var asked: [DecisionQuestion] = []
    @Published private(set) var phase: String?
    @Published var error: String?
    private let runtime = DecisionRuntime()
    private var work: Task<Void, Never>?
    private let defaults: UserDefaults
    private let storageURL: URL

    nonisolated static let maxDocuments = 50
    nonisolated static let maxQuestions = 10
    nonisolated static let maxPDFBytes = 50 * 1024 * 1024
    nonisolated static let maxPastedCharacters = 400_000
    nonisolated static let unsure = 0.6
    private static let questionsKey = "decideQuestions"

    nonisolated static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("decide-session.json")
    }

    var busy: Bool { work != nil }

    init(defaults: UserDefaults = .standard, storageURL: URL? = nil) {
        self.defaults = defaults
        let resolvedURL = storageURL ?? Self.defaultStorageURL
        self.storageURL = resolvedURL
        #if DEBUG && targetEnvironment(simulator)
        if storageURL == nil, ProcessInfo.processInfo.arguments.contains("--reset-saved-task-fixture") {
            try? FileManager.default.removeItem(at: resolvedURL)
        }
        #endif
        if let data = defaults.data(forKey: Self.questionsKey),
           let saved = try? JSONDecoder().decode([DecisionQuestion].self, from: data) {
            questions = saved
        }
        if let data = try? Data(contentsOf: resolvedURL),
           let saved = try? JSONDecoder().decode(PersistedState.self, from: data) {
            documents = saved.documents
            asked = saved.asked
            var restored: [UUID: [DecideOutcome]] = [:]
            for (key, value) in saved.outcomes {
                if let id = UUID(uuidString: key) { restored[id] = value }
            }
            outcomes = restored
        }
    }

    private func saveQuestions() {
        if let data = try? JSONEncoder().encode(questions) { defaults.set(data, forKey: Self.questionsKey) }
    }

    private func saveState() {
        var encodedOutcomes: [String: [DecideOutcome]] = [:]
        for (id, value) in outcomes { encodedOutcomes[id.uuidString] = value }
        let state = PersistedState(documents: documents, outcomes: encodedOutcomes, asked: asked)
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
            var file = storageURL
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            try? file.setResourceValues(excluded)
        } catch {
            self.error = "Decide results could not be saved on this device."
        }
    }

    static let examples: [DecisionQuestion] = [
        .yesNo("Do I have to pay money because of this document?"),
        .choice("What kind of document is this?", options: ["Bill", "Receipt", "Contract", "Letter", "Other"].map { DecisionOption(key: $0) }),
        .scale("How soon must I act on it?", levels: ["No action needed", "Some time later", "Within a few weeks", "Now, it is late or urgent"]),
    ]

    func add(files urls: [URL]) {
        error = nil
        Task {
            for url in urls {
                guard documents.count < Self.maxDocuments else { error = "Decide reads up to \(Self.maxDocuments) documents at a time."; return }
                do {
                    documents.append(try await Self.read(url))
                    saveState()
                }
                catch { self.error = "\(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }

    func add(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, documents.count < Self.maxDocuments else { return }
        let name = String(trimmed.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        documents.append(DecideDocument(name: name, text: String(trimmed.prefix(Self.maxPastedCharacters))))
        saveState()
    }

    func remove(_ document: DecideDocument) {
        documents.removeAll { $0.id == document.id }
        outcomes[document.id] = nil
        saveState()
    }

    func clearResults() {
        guard !busy else { return }
        outcomes = [:]
        asked = []
        saveState()
    }

    func clearDocuments() {
        guard !busy else { return }
        documents = []
        outcomes = [:]
        asked = []
        saveState()
    }

    nonisolated private static func read(_ url: URL) async throws -> DecideDocument {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard data.count <= maxPDFBytes else { throw AttachmentError.fileTooLarge(bytes: data.count, limit: maxPDFBytes) }
                #if canImport(PDFKit)
                do { text = try PDFKitTextExtractor().extractText(from: data) }
                catch AttachmentError.noTextInPDF { throw DecideError.scanned }
                #else
                throw AttachmentError.extractionFailed("No PDF reader on this platform.")
                #endif
            } else {
                text = try AttachmentParser.extractText(from: data, filename: name)
            }
            return DecideDocument(name: name, text: text)
        }.value
    }

    /// Why Decide cannot run now, or nil.
    func blocker(models: ModelLibrary, chat: LocalChat) -> String? {
        if !models.installed.contains(LocalModel.decide.id) { return "Download the decision model first." }
        if documents.isEmpty { return "Add a document." }
        if questions.isEmpty { return "Add a question." }
        if let problem = questions.lazy.compactMap(\.problem).first { return problem }
        if chat.running { return "Wait for the chat's reply to finish." }
        if models.isTransferring { return "Wait for the download to finish." }
        return nil
    }

    func run(models: ModelLibrary, chat: LocalChat) {
        guard work == nil, blocker(models: models, chat: chat) == nil else { return }
        let documents = self.documents, questions = self.questions
        let path = models.path(LocalModel.decide).path
        error = nil; outcomes = [:]; asked = questions
        saveState()
        phase = "Making room for the decision model…"
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            defer { work = nil; phase = nil; UIApplication.shared.isIdleTimerDisabled = false; saveState() }
            // The chat model and the decision model do not fit in memory together.
            await chat.unloadModelsNow()
            if let reason = Self.memoryProblem() { error = reason; return }
            documents: for (index, document) in documents.enumerated() {
                if Task.isCancelled { break }
                let parts: [String]
                do { parts = try await runtime.parts(of: document.text, questions: questions, modelPath: path) }
                catch { outcomes[document.id] = [.failed(error.localizedDescription)]; saveState(); continue }
                var results: [DecideOutcome] = []
                for (number, part) in parts.enumerated() {
                    phase = parts.count == 1 ? "Reading \(document.name) · \(index + 1) of \(documents.count)"
                        : "Reading \(document.name), part \(number + 1) of \(parts.count) · document \(index + 1) of \(documents.count)"
                    let began = Date()
                    do {
                        let result = try await runtime.ask(document: part, questions: questions, modelPath: path,
                                                           between: { try await DecideSession.cool() })
                        results.append(.done(answers: result.answers, fractionRead: result.fractionRead,
                                             seconds: Date().timeIntervalSince(began)))
                    } catch is CancellationError {
                        break documents
                    } catch DecideError.hot {
                        error = DecideError.hot.localizedDescription
                        break documents
                    } catch {
                        results.append(.failed(error.localizedDescription))
                    }
                    outcomes[document.id] = results
                    saveState()
                }
            }
            await runtime.unload()
        }
    }

    func cancel(_ reason: String? = nil) {
        guard let work else { return }
        work.cancel()
        if let reason { error = reason }
    }

    func handleMemoryWarning() {
        cancel("Your iPhone is low on memory. Decide stopped; close other apps and try again.")
        Task { await runtime.unload() }
    }

    /// Between batches: pause briefly when iOS says the phone is hot, stop when critical.
    nonisolated static func cool() async throws {
        switch ThermalPolicy.currentDecision() {
        case .proceed: return
        case .throttle(let pause): try await Task.sleep(nanoseconds: pause)
        case .stop: throw DecideError.hot
        }
    }

    private static func memoryProblem() -> String? {
        #if !targetEnvironment(simulator)
        // Weights, the reading buffer (about 0.55 MB per token of the batch,
        // measured with llama.cpp b12367) and the app's own headroom.
        let required = UInt64(LocalModel.decide.bytes) + UInt64(DecisionRuntime.Settings().contextSize) * 600_000 + 384_000_000
        if os_proc_available_memory() < required { return DecisionRuntimeError.context.localizedDescription }
        #endif
        return nil
    }

    /// A document's answer to question `index`: from its only part, or from
    /// the part the model is most sure about (`DecisionModel.combine`), with
    /// that part's number when there are several.
    func combined(_ document: DecideDocument, _ index: Int) -> (answer: DecisionAnswer, part: Int?)? {
        let parts = outcomes[document.id] ?? []
        let answers = parts.compactMap { outcome -> DecisionAnswer? in
            if case .done(let answers, _, _) = outcome, answers.indices.contains(index) { return answers[index] }
            return nil
        }
        guard let best = DecisionModel.combine(answers) else { return nil }
        // Map back to the part number, counting failed parts too.
        let done = parts.indices.filter { if case .done = parts[$0] { return true } else { return false } }
        return (best.answer, parts.count > 1 ? done[best.part] : nil)
    }

    /// The results as a table to paste into a spreadsheet (tab-separated):
    /// one row per document with its combined answers.
    func table() -> String {
        let header = (["Document"] + asked.map(\.instructions)).map(Self.cell).joined(separator: "\t")
        let rows = documents.compactMap { document -> String? in
            guard let parts = outcomes[document.id] else { return nil }
            let cells = asked.indices.map { index -> String in
                guard let best = combined(document, index) else {
                    if case .failed(let reason) = parts.first { return reason }
                    return ""
                }
                let from = best.part.map { " (part \($0 + 1) of \(parts.count))" } ?? ""
                return "\(Self.label(best.answer, for: asked[index])) \(Self.percent(best.answer))\(from)"
            }
            return ([document.name] + cells).map(Self.cell).joined(separator: "\t")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func label(_ answer: DecisionAnswer, for question: DecisionQuestion) -> String {
        label(index: answer.index, for: question)
    }

    static func label(index: Int, for question: DecisionQuestion) -> String {
        guard question.options.indices.contains(index) else { return "?" }
        switch question.kind {
        case .yesNo: return index == 0 ? "Yes" : "No"
        case .choice, .scale:
            let option = question.options[index]
            return option.description?.isEmpty == false ? option.description! : option.key
        }
    }

    /// The chance of the answer shown.
    static func chance(_ answer: DecisionAnswer) -> Double {
        answer.probabilities.indices.contains(answer.index) ? answer.probabilities[answer.index] : 0
    }

    static func percent(_ answer: DecisionAnswer) -> String { "\(Int((chance(answer) * 100).rounded()))%" }

    /// One line per question across all documents, e.g. "Yes in 3 of 8".
    func summary(_ index: Int) -> String {
        let question = asked[index]
        let answers = documents.compactMap { combined($0, index)?.answer }
        guard !answers.isEmpty else { return "" }
        if question.kind == .yesNo {
            return "Yes in \(answers.filter { $0.index == 0 }.count) of \(answers.count)"
        }
        var counts: [Int: Int] = [:]
        for answer in answers { counts[answer.index, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(Self.label(index: $0.key, for: question)) \($0.value)" }
            .joined(separator: " · ")
    }
}

enum DecideError: LocalizedError {
    case hot, scanned
    var errorDescription: String? {
        switch self {
        case .hot: return "Your iPhone is too hot. Decide stopped; let it cool down and try again."
        case .scanned: return "This PDF has no text, probably a scan. Decide reads text only for now."
        }
    }
}

struct DecideView: View {
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var session: DecideSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFiles = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var editing: DecisionQuestion?
    @State private var confirmRemove = false

    private let model = LocalModel.decide

    var body: some View {
        NavigationStack {
            List {
                if !models.installed.contains(model.id) { modelSection }
                documentsSection
                questionsSection
                runSection
                if !session.outcomes.isEmpty { resultsSection }
            }
            .scrollContentBackground(.hidden).background(KeelStyle.background)
            .navigationTitle("Decide").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if models.installed.contains(model.id) || !session.documents.isEmpty || !session.outcomes.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if !session.outcomes.isEmpty {
                                Button("Clear results") { session.clearResults() }
                                    .disabled(session.busy)
                            }
                            if !session.documents.isEmpty {
                                Button("Clear all documents", role: .destructive) { session.clearDocuments() }
                                    .disabled(session.busy)
                            }
                            if models.installed.contains(model.id) {
                                Button("Remove decision model", role: .destructive) { confirmRemove = true }
                                    .disabled(session.busy || models.isTransferring)
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
                    }
                }
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.pdf, .plainText, .text, .commaSeparatedText],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { session.add(files: urls) }
            }
            .sheet(isPresented: $pasting) { pasteSheet }
            .sheet(item: $editing) { question in
                DecideQuestionEditor(question: question) { saved in
                    if let index = session.questions.firstIndex(where: { $0.id == saved.id }) { session.questions[index] = saved }
                    else { session.questions.append(saved) }
                }
            }
            .alert("Remove the decision model?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { models.remove(model) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("You can download it again later.") }
            .onChange(of: scenePhase) { _, phase in
                // iOS does not let the graphics processor work in the background.
                if phase == .background { session.cancel("Decide stops when you leave Keel. Tap Decide again to finish.") }
            }
        }
        .interactiveDismissDisabled(session.busy)
        .onDisappear { session.cancel() }
    }

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.detail).font(.subheadline)
                Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " · On-device · LiquidAI d1")
                    .font(.caption).foregroundStyle(.secondary)
                if models.downloading == model.id {
                    ProgressView(value: models.progress)
                    HStack {
                        Text(models.verifying ? "Verifying download…" : "Downloading \(Int(models.progress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Pause") { models.cancel() }
                    }
                } else {
                    Button(models.partialBytes[model.id] == nil ? "Download decision model" : "Resume download") { models.install(model) }
                        .buttonStyle(.bordered)
                        .disabled(models.isTransferring || chat.running)
                        .accessibilityIdentifier("decideDownloadModel")
                }
                if let error = models.error, models.failedModel?.id == model.id {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }.padding(.vertical, 4)
        } header: { Text("Decision model") }
        .listRowBackground(KeelStyle.surface)
    }

    private var documentsSection: some View {
        Section {
            ForEach(session.documents) { document in
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name).lineLimit(1)
                    Text("\(document.words) words").font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { session.remove(document) } }
                .accessibilityIdentifier("decideDocument")
            }
            Button { choosingFiles = true } label: { Label("Add PDFs or text files", systemImage: "doc.badge.plus") }
                .disabled(session.busy).accessibilityIdentifier("decideAddFiles")
            Button { pasted = ""; pasting = true } label: { Label("Paste text", systemImage: "doc.on.clipboard") }
                .disabled(session.busy).accessibilityIdentifier("decidePaste")
        } header: {
            Text("Documents")
        } footer: {
            Text("Each document is read on its own and gets an answer to every question.")
        }
        .listRowBackground(KeelStyle.surface)
    }

    private var questionsSection: some View {
        Section {
            ForEach(session.questions) { question in
                Button { editing = question } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.instructions).foregroundStyle(.primary).lineLimit(2)
                        Text(Self.describe(question)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .disabled(session.busy)
                .swipeActions { Button("Delete", role: .destructive) { session.questions.removeAll { $0.id == question.id } } }
                .accessibilityIdentifier("decideQuestion")
            }
            if session.questions.count < DecideSession.maxQuestions {
                Button { editing = .yesNo("") } label: { Label("Add a question", systemImage: "plus") }
                    .disabled(session.busy).accessibilityIdentifier("decideAddQuestion")
            }
            if session.questions.isEmpty {
                Button { session.questions = DecideSession.examples } label: { Label("Use example questions", systemImage: "sparkles") }
                    .accessibilityIdentifier("decideExamples")
            }
        } header: {
            Text("Questions")
        } footer: {
            Text("Yes or no, pick one, or a scale. The answer comes with how sure the model is.")
        }
        .listRowBackground(KeelStyle.surface)
    }

    private var runSection: some View {
        Section {
            if let phase = session.phase {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(phase).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Stop") { session.cancel() }.accessibilityIdentifier("decideStop")
                }
            } else {
                Button { session.run(models: models, chat: chat) } label: {
                    Label("Decide", systemImage: "checklist").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.blocker(models: models, chat: chat) != nil)
                .accessibilityIdentifier("decideRun")
                if let blocker = session.blocker(models: models, chat: chat) {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = session.error {
                Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("decideError")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var resultsSection: some View {
        Section {
            ForEach(session.asked.indices, id: \.self) { index in
                let line = session.summary(index)
                if !line.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.asked[index].instructions).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(line).font(.subheadline.weight(.medium))
                    }
                }
            }
            ForEach(session.documents) { document in
                if let parts = session.outcomes[document.id] { documentCard(document, parts) }
            }
            ShareLink(item: session.table()) { Label("Share results as a table", systemImage: "tablecells") }
            Button { UIPasteboard.general.string = session.table() } label: { Label("Copy as table", systemImage: "doc.on.doc") }
        } header: {
            Text("Results")
        } footer: {
            Text("Under \(Int(DecideSession.unsure * 100))% means the model is unsure: check that document yourself. Long documents are read in parts of about six pages; a document's answer comes from the part the model is most sure about.")
        }
        .listRowBackground(KeelStyle.surface)
    }

    @ViewBuilder private func documentCard(_ document: DecideDocument, _ parts: [DecideOutcome]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.name).font(.headline).lineLimit(1)
            ForEach(session.asked.indices, id: \.self) { index in
                if let best = session.combined(document, index) {
                    answerRow(session.asked[index], best.answer, from: best.part.map { "part \($0 + 1) of \(parts.count)" })
                }
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, outcome in
                if case .failed(let reason) = outcome { Text(reason).font(.footnote).foregroundStyle(.orange) }
            }
            if parts.count > 1 {
                DisclosureGroup("Each part (\(parts.count))") {
                    ForEach(Array(parts.enumerated()), id: \.offset) { number, outcome in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Part \(number + 1)").font(.caption.weight(.semibold))
                            if case .done(let answers, _, _) = outcome {
                                ForEach(Array(zip(session.asked, answers).enumerated()), id: \.offset) { _, pair in
                                    answerRow(pair.0, pair.1, from: nil)
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                }.font(.caption)
            }
            if parts.contains(where: { if case .done(_, let fraction, _) = $0 { return fraction < 1 }; return false }) {
                Text("Some of this document was too long to read and was left out.").font(.caption).foregroundStyle(.orange)
            }
            let seconds = parts.reduce(0.0) { if case .done(_, _, let s) = $1 { return $0 + s }; return $0 }
            Text(String(format: "%.1f s", seconds)).font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 4)
    }

    private func answerRow(_ question: DecisionQuestion, _ answer: DecisionAnswer, from part: String?) -> some View {
        let unsure = DecideSession.chance(answer) < DecideSession.unsure
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(question.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let part { Text("from \(part)").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 8)
            Text(DecideSession.label(answer, for: question)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
            Text(DecideSession.percent(answer)).font(.caption.monospacedDigit())
                .foregroundStyle(unsure ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("decideAnswer")
    }

    private var pasteSheet: some View {
        NavigationStack {
            TextEditor(text: $pasted)
                .padding()
                .scrollContentBackground(.hidden).background(KeelStyle.background)
                .accessibilityIdentifier("decidePasteText")
                .navigationTitle("Paste text").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pasting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { session.add(pasted: pasted); pasting = false }
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("decidePasteAdd")
                    }
                }
        }
    }

    static func describe(_ question: DecisionQuestion) -> String {
        switch question.kind {
        case .yesNo: return "Yes or no"
        case .choice: return "Pick one: " + question.options.map { $0.description ?? $0.key }.joined(separator: ", ")
        case .scale: return "Scale: " + question.options.compactMap(\.description).joined(separator: " → ")
        }
    }
}

/// Writes or changes one question.
struct DecideQuestionEditor: View {
    private struct DraftOption: Identifiable {
        let id = UUID()
        var text: String
    }

    @Environment(\.dismiss) private var dismiss
    let question: DecisionQuestion
    let save: (DecisionQuestion) -> Void
    @State private var kind: DecisionKind
    @State private var text: String
    @State private var choices: [DraftOption]
    @State private var levels: [DraftOption]

    init(question: DecisionQuestion, save: @escaping (DecisionQuestion) -> Void) {
        self.question = question; self.save = save
        _kind = State(initialValue: question.kind)
        _text = State(initialValue: question.instructions)
        let initialChoices = question.kind == .choice ? question.options.map { $0.description ?? $0.key } : ["", ""]
        let initialLevels = question.kind == .scale ? question.options.compactMap(\.description) : ["Low", "Medium", "High"]
        _choices = State(initialValue: initialChoices.map { DraftOption(text: $0) })
        _levels = State(initialValue: initialLevels.map { DraftOption(text: $0) })
    }

    private var built: DecisionQuestion {
        let instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .yesNo: return .yesNo(instructions, id: question.id)
        case .choice:
            return .choice(instructions, options: choices.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.map { DecisionOption(key: $0) }, id: question.id)
        case .scale:
            return .scale(instructions, levels: levels.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, id: question.id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask about each document", text: $text, axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("decideQuestionText")
                    Picker("Answer", selection: $kind) {
                        Text("Yes or no").tag(DecisionKind.yesNo)
                        Text("Pick one").tag(DecisionKind.choice)
                        Text("Scale").tag(DecisionKind.scale)
                    }.pickerStyle(.segmented).accessibilityIdentifier("decideQuestionKind")
                }
                if kind == .choice { list("Options", items: $choices, limit: DecisionQuestion.maxChoices, add: "Add option") }
                if kind == .scale { list("Levels, lowest first", items: $levels, limit: DecisionQuestion.scaleLevels.upperBound, add: "Add level") }
                if let problem = built.problem, !text.isEmpty {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
            }
            .scrollContentBackground(.hidden).background(KeelStyle.background)
            .navigationTitle(question.instructions.isEmpty ? "New question" : "Question").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(built); dismiss() }.disabled(built.problem != nil)
                        .accessibilityIdentifier("decideQuestionSave")
                }
            }
        }
    }

    private func list(_ title: String, items: Binding<[DraftOption]>, limit: Int, add: String) -> some View {
        Section(title) {
            ForEach(items) { $item in
                let index = items.wrappedValue.firstIndex(where: { $0.id == item.id }) ?? 0
                TextField(title == "Options" ? "Option \(index + 1)" : "Level \(index + 1)", text: $item.text)
                    .accessibilityIdentifier("decideOption\(index)")
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            if items.wrappedValue.count < limit {
                Button(add) { items.wrappedValue.append(DraftOption(text: "")) }
            }
        }
    }
}
