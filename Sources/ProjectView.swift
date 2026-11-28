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
    @FocusState private var editingInstructions: Bool
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
                            .lineLimit(3...8).focused($editingInstructions).accessibilityIdentifier("projectInstructionsField")
                        Button("Save instructions") { _ = saveInstructions() }
                            .disabled(chat.running || !instructionsChanged)
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
                        Text("Text, CSV, Markdown, PDF text and photos with text. Every chat in the project can read these in project/; chats cannot change them. Up to \(ChatProject.maxFiles) files, 1 MB of text.")
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
            .toolbar {
                // Done keeps what was typed: the Save button sits under the keyboard while typing.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if instructionsChanged, !chat.running, !saveInstructions() { return }
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if editingInstructions {
                        Spacer()
                        Button("Save") { if saveInstructions() { editingInstructions = false } }
                            .disabled(chat.running || !instructionsChanged)
                            .accessibilityIdentifier("keyboardSaveProjectInstructions")
                    }
                }
            }
            .onAppear { instructions = project?.instructions ?? ""; name = project?.name ?? "" }
            .onDisappear { importTask?.cancel() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .commaSeparatedText, .pdf, .json, .image, .data]) { result in
                guard case .success(let url) = result else { return }
                addFile(url)
            }
            .alert("Delete \(project?.name ?? "project")?", isPresented: $confirmDelete) {
                Button("Delete project", role: .destructive) { if chat.deleteProject(projectID) { dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its files and instructions are removed. Its chats are kept.") }
        }
    }

    private var instructionsChanged: Bool { project.map { CustomInstructions.sanitize(instructions) != $0.instructions } ?? false }

    private func saveInstructions() -> Bool {
        chat.updateProject(projectID) { $0.setInstructions(instructions) }
    }

    private func addFile(_ url: URL) {
        importingFile = true
        importTask?.cancel()
        importTask = Task {
            defer { importingFile = false }
            do {
                let file = try await Self.loadProjectFile(from: url)
                guard !Task.isCancelled else { return }
                _ = chat.updateProject(projectID) { try $0.add(file) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                chat.error = error.localizedDescription
            }
        }
    }

    nonisolated static func loadProjectFile(
        from url: URL,
        pdfExtractor: (any PDFTextExtractor)? = nil,
        ocr: (any TextRecognizer)? = nil
    ) async throws -> Attachment {
        let maxImageBytes = 32 * 1024 * 1024
        let filename = url.lastPathComponent
        let isImageByType = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        let rawData: Data = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let limit = isImageByType ? maxImageBytes : AttachmentLimits.maxFileSizeBytes
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > limit {
                throw AttachmentError.fileTooLarge(bytes: bytes, limit: limit)
            }
            let data = try Data(contentsOf: url)
            if data.count > limit {
                throw AttachmentError.fileTooLarge(bytes: data.count, limit: limit)
            }
            try Task.checkCancellation()
            return data
        }.value

        if isImageByType || Self.looksLikeImage(rawData) {
            let recognizer: any TextRecognizer = ocr ?? VisionTextRecognizer()
            let recognized = try await recognizer.recognizeText(from: rawData, options: TextRecognitionOptions())
            try Task.checkCancellation()
            let normalized = AttachmentTextNormalizer.normalize(recognized)
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AttachmentError.zeroTextRecognized
            }
            return Attachment(
                filename: filename,
                mimeType: "text/plain",
                extractedText: normalized,
                byteSize: rawData.count,
                source: .photoOCR
            )
        }

        return try await Task.detached(priority: .userInitiated) {
            let extractor: (any PDFTextExtractor)?
            if let pdfExtractor {
                extractor = pdfExtractor
            } else {
                #if canImport(PDFKit)
                extractor = PDFKitTextExtractor()
                #else
                extractor = nil
                #endif
            }
            let text = try AttachmentParser.extractText(from: rawData, filename: filename, pdfExtractor: extractor)
            try Task.checkCancellation()
            return Attachment(
                filename: filename,
                mimeType: AttachmentMIMEDetector.detectMIME(filename: filename, data: rawData),
                extractedText: text,
                byteSize: rawData.count,
                source: .file
            )
        }.value
    }

    private nonisolated static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true } // PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true } // JPEG
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true } // GIF
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return true } // WEBP
        if bytes.count >= 12,
           bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1", "avif"].contains(brand) { return true }
        }
        return false
    }
}
