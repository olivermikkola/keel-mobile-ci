import SwiftUI
import UniformTypeIdentifiers
#if canImport(KeelHarness)
import KeelHarness
#endif

/// One project: its chats, the instructions every chat in it follows, and the
/// files every chat in it can read under `project/`.
struct ProjectView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    /// Called after a chat of this project was opened, so the menu can close.
    let opened: () -> Void
    @State private var instructions = ""
    @State private var name = ""
    @State private var choosingFile = false
    @State private var importingFile = false
    @State private var importTask: Task<Void, Never>?
    @State private var confirmDelete = false
    @AppStorage(PinnedProjects.key) private var pinnedRaw = ""

    private var project: ChatProject? { chat.projects.first { $0.id == projectID } }

    var body: some View {
        NavigationStack {
            Form { Group {
                if let project {
                    Section {
                        Button {
                            if chat.newChat(project: project) { dismiss(); opened() }
                        } label: { Label("New chat in this project", systemImage: "square.and.pencil") }
                            .accessibilityIdentifier("projectNewChat")
                        ForEach(chat.chats(in: project)) { task in
                            Button {
                                if chat.selectTask(task.id) { dismiss(); opened() }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.shownTitle).foregroundStyle(.primary)
                                    Text(task.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("projectChat-\(task.title)")
                        }
                    } header: { Text("Chats") }
                    Section {
                        TextField("For example: This is my thesis on Baltic herring. Use APA citations.", text: $instructions, axis: .vertical)
                            .lineLimit(3...8).accessibilityIdentifier("projectInstructionsField")
                        Button("Save instructions") { _ = chat.updateProject(projectID) { $0.setInstructions(instructions) } }
                            .disabled(chat.running || instructions == project.instructions)
                            .accessibilityIdentifier("saveProjectInstructions")
                    } header: { Text("Instructions") } footer: {
                        Text("Every chat in this project follows these, after your standing instructions.")
                    }
                    Section {
                        ForEach(project.files) { file in
                            HStack {
                                Label(ChatProject.path(for: file.filename), systemImage: "doc.text")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.extractedText.utf8.count), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    _ = chat.updateProject(projectID) { $0.files.removeAll { $0.id == file.id } }
                                }
                            }
                        }
                        if importingFile {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Reading file…").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Button { choosingFile = true } label: { Label("Add file", systemImage: "plus") }
                                .disabled(chat.running || project.files.count >= ChatProject.maxFiles)
                                .accessibilityIdentifier("addProjectFile")
                        }
                    } header: { Text("Files") } footer: {
                        Text("Text, CSV, Markdown and PDF text. Every chat in the project can read these in project/; chats cannot change them. Up to \(ChatProject.maxFiles) files, 1 MB of text.")
                    }
                    Section {
                        Toggle("Pin to menu", isOn: Binding(
                            get: { PinnedProjects.ids(pinnedRaw).contains(projectID) },
                            set: { _ in pinnedRaw = PinnedProjects.toggled(projectID, in: pinnedRaw) }
                        )).accessibilityIdentifier("pinProject")
                        TextField("Project name", text: $name).accessibilityIdentifier("projectNameField")
                        Button("Rename") { _ = chat.renameProject(projectID, name: name) }
                            .disabled(chat.running || name == project.name)
                        Button("Delete project", role: .destructive) { confirmDelete = true }
                            .disabled(chat.running)
                    } footer: { Text("Deleting a project keeps its chats as ordinary chats.") }
                    if let error = chat.error {
                        Section { Text(error).font(.footnote).foregroundStyle(.orange) }
                    }
                }
                }.listRowBackground(KeelStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle(project?.name ?? "Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { instructions = project?.instructions ?? ""; name = project?.name ?? "" }
            .onDisappear { importTask?.cancel() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .commaSeparatedText, .pdf, .json, .data]) { result in
                guard case .success(let url) = result else { return }
                addFile(url)
            }
            .alert("Delete \(project?.name ?? "project")?", isPresented: $confirmDelete) {
                Button("Delete project", role: .destructive) { if chat.deleteProject(projectID) { dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its files and instructions are removed. Its chats are kept.") }
        }
    }

    private func addFile(_ url: URL) {
        importingFile = true
        importTask?.cancel()
        importTask = Task {
            defer { importingFile = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) { () throws -> Attachment in
                    guard url.startAccessingSecurityScopedResource() else {
                        throw AttachmentError.extractionFailed("Could not access the selected file.")
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let limit = AttachmentLimits.maxFileSizeBytes
                    if let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > limit {
                        throw AttachmentError.fileTooLarge(bytes: bytes, limit: limit)
                    }
                    let data = try Data(contentsOf: url)
                    try Task.checkCancellation()
                    #if canImport(PDFKit)
                    let pdfExtractor: (any PDFTextExtractor)? = PDFKitTextExtractor()
                    #else
                    let pdfExtractor: (any PDFTextExtractor)? = nil
                    #endif
                    let filename = url.lastPathComponent
                    let text = try AttachmentParser.extractText(from: data, filename: filename, pdfExtractor: pdfExtractor)
                    try Task.checkCancellation()
                    return Attachment(filename: filename, mimeType: AttachmentMIMEDetector.detectMIME(filename: filename, data: data),
                                      extractedText: text, byteSize: data.count, source: .file)
                }.value
                guard !Task.isCancelled else { return }
                _ = chat.updateProject(projectID) { try $0.add(file) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                chat.error = error.localizedDescription
            }
        }
    }
}
