import SwiftUI

struct LocalChatView: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @State private var draft = ""
    @State private var showingTasks = false
    @State private var reviewingEditID: UUID?
    @State private var showingPublish = false
    @State private var choosingRepository = false
    @FocusState private var composing: Bool
    let chooseModel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button(action: chooseModel) {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu").foregroundStyle(KeelStyle.accent)
                            .frame(width: 36, height: 36)
                            .background(KeelStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(models.current.name).fontWeight(.medium)
                            Text(models.installed.contains(models.selected) ? "Ready on this iPhone" : "Download a model to start")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption)
                    }.font(.subheadline).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(chat.running)
                    .background(KeelStyle.surface)
                Divider()
                Button { choosingRepository = true } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder")
                        if let repository = chat.repository {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(repository.repository.fullName).fontWeight(.medium)
                                Text("\(repository.branch) · \(repository.commit.prefix(7)) · \(chat.directorMode ? "Reviewed edits" : "GitHub reads")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(chat.messages.isEmpty ? "Attach a repository" : "New chat to attach a repository")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if chat.messages.isEmpty { Image(systemName: "plus").font(.caption) }
                    }.font(.subheadline).padding(.horizontal).padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(chat.running || !chat.messages.isEmpty)
                    .accessibilityIdentifier("attachRepository")
                if chat.repository != nil {
                    HStack {
                        Toggle(isOn: Binding(get: { chat.directorMode }, set: { _ = chat.setDirectorMode($0) })) {
                            Label(chat.directorMode ? "Director · reviewed edits" : "Enable edit proposals", systemImage: "bolt.fill")
                                .font(.caption.weight(.medium))
                        }
                        .disabled(chat.running)
                        .toggleStyle(.button)
                        .tint(KeelStyle.accent)
                        .accessibilityIdentifier("directorModeToggle")
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                Divider()
                if !chat.fileEdits.isEmpty {
                    HStack {
                        let applied = chat.fileEdits.filter { $0.decision == .applied }.count
                        let pending = chat.fileEdits.filter { $0.decision == .pending }.count
                        Text("\(applied) applied · \(pending) awaiting review").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review changes") {
                            reviewingEditID = (chat.fileEdits.first { $0.decision == .pending } ?? chat.fileEdits.last)?.id
                        }.font(.caption).disabled(chat.running).accessibilityIdentifier("openTaskChanges")
                    }.padding(.horizontal).padding(.vertical, 8)
                    Divider()
                }
                if !chat.publishEdits.isEmpty || chat.publishState != nil {
                    publishBanner
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if chat.messages.isEmpty { welcome }
                            ForEach(chat.messages.filter { $0.isToolCall != true }) { message in
                                if message.role == "tool" {
                                    if let record = message.edit {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Label {
                                                Text(record.proposal.kind == .rename
                                                     ? "\(record.proposal.path) → \(record.proposal.destinationPath ?? "")"
                                                     : record.proposal.path)
                                            } icon: {
                                                Image(systemName: icon(for: record.proposal.kind))
                                            }.font(.subheadline)
                                            Text(message.note ?? "Needs review").font(.caption).foregroundStyle(.secondary)
                                            Button(record.decision == .pending ? "Review change" : "View change") {
                                                reviewingEditID = record.id
                                            }.disabled(chat.running).accessibilityIdentifier("reviewFileEdit")
                                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                    } else {
                                    DisclosureGroup {
                                        Text(message.text.isEmpty ? chat.phase : repositoryActivityText(message.text))
                                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label(message.activity ?? "Repository read", systemImage: "doc.text.magnifyingglass")
                                                .font(.subheadline)
                                            Text(message.note ?? "").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(14).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        if message.role == "assistant" { KeelMark().frame(width: 20, height: 20) }
                                        Text(message.role == "user" ? "YOU" : "KEEL")
                                            .font(.caption2.weight(.semibold)).tracking(1.5)
                                            .foregroundStyle(message.role == "user" ? Color.secondary : KeelStyle.accent)
                                    }
                                    if message.text.isEmpty {
                                        Text(chat.running ? chat.phase : "No reply generated.")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        if message.role == "assistant" {
                                            ChatMessageContent(text: message.text)
                                        } else {
                                            Text(message.text).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    if let note = message.note, note != "Responding" {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(message.role == "user" ? 16 : 0)
                                    .background(message.role == "user" ? KeelStyle.accent.opacity(0.08) : .clear,
                                                in: RoundedRectangle(cornerRadius: 16))
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.last?.text) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if let error = chat.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).font(.footnote)
                        Spacer(minLength: 0)
                        Button { chat.error = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                    }.foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 12)
                }
                composer
            }
            .background(KeelStyle.background)
            .navigationTitle(chat.activeTitle == "New task" ? "Keel" : chat.activeTitle).navigationBarTitleDisplayMode(.inline)
            .onChange(of: chat.activeTaskID) { _, _ in draft = ""; composing = false; reviewingEditID = nil; showingPublish = false }
            .sheet(isPresented: $showingTasks) {
                NavigationStack { SavedTasksView() }
            }
            .sheet(isPresented: Binding(get: { reviewingEditID != nil }, set: { if !$0 { reviewingEditID = nil } })) {
                if let id = reviewingEditID, let record = chat.fileEdits.first(where: { $0.id == id }) {
                    FileEditReviewView(proposal: record.proposal, decision: record.decision, applying: chat.applyingEditID == id,
                                       error: chat.error, apply: { chat.applyEdit(id) }, discard: { chat.discardEdit(id) })
                }
            }
            .sheet(isPresented: $showingPublish) {
                PublishView(chat: chat)
            }
            .sheet(isPresented: $choosingRepository) {
                NavigationStack {
                    RepositoryView { snapshot in
                        if chat.attach(snapshot) { choosingRepository = false }
                    }.toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { choosingRepository = false } }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingTasks = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Saved tasks").disabled(chat.running)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if chat.newChat() { draft = "" } } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat").disabled(chat.running || chat.storageUnreadable)
                }
            }
        }
    }

    private var publishBanner: some View {
        Button { showingPublish = true } label: {
            HStack(spacing: 8) {
                Image(systemName: chat.publishState == nil ? "arrow.up.circle" : "arrow.up.right.square")
                    .foregroundStyle(KeelStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.publishState?.statusText ?? "Publish reviewed changes")
                        .font(.caption.weight(.medium)).foregroundStyle(.primary)
                    if chat.publishIsStale {
                        Text("Changes changed since this publish")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if chat.publishState == nil {
                        Text("Push a branch and run the exact CI gate")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text("Publish").font(.caption.weight(.semibold)).foregroundStyle(KeelStyle.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KeelStyle.accent.opacity(0.35)))
            .padding(.horizontal).padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .disabled(chat.running)
        .accessibilityIdentifier("openPublish")
    }

    private func icon(for kind: FileEditKind) -> String {
        switch kind {
        case .replace: return "doc.badge.ellipsis"
        case .create: return "doc.badge.plus"
        case .delete: return "trash"
        case .rename: return "arrow.right.doc.on.clipboard"
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            KeelMark().frame(width: 88, height: 88).padding(.leading, -14)
            VStack(alignment: .leading, spacing: 12) {
                Text("ON THIS IPHONE").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(KeelStyle.accent)
                Text("A clearer way\nto work through code.")
                    .font(.system(.largeTitle, design: .rounded).weight(.medium)).tracking(-0.8)
            }
            Text("Untangle an error, explore a repository, or think through your next change. Your conversation stays here.")
                .foregroundStyle(.secondary)
            if !models.installed.contains(models.selected) {
                Button("Choose and download a model", action: chooseModel)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("setupLocalModel")
                Text("Download once, then chat offline. Keep Keel open while it replies.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(["Explain an error", "Think through a change"], id: \.self) { suggestion in
                    Button { draft = suggestion + ": "; composing = true } label: {
                        HStack { Text(suggestion); Spacer(); Image(systemName: "arrow.up.left") }
                            .padding(16).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
            }
            Label(chat.repository == nil ? "Attach a repository to ask about its files and propose changes." :
                    "Keel can read this snapshot and propose edits. Review each diff before applying it to this task. Publishing is a separate step.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chat.running {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(KeelStyle.accent)
                    Text(chat.phase.isEmpty ? "Working on your iPhone…" : chat.phase)
                        .font(.caption).foregroundStyle(KeelStyle.accent).lineLimit(2)
                }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("prefillProgress")
            }
            HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask about your code…", text: $draft, axis: .vertical)
                .lineLimit(1...6).focused($composing).accessibilityIdentifier("localChatInput")
            if chat.running {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 44, height: 44)
                        .foregroundStyle(KeelStyle.detail)
                        .background(KeelStyle.detail.opacity(0.10), in: Circle())
                }
                    .accessibilityLabel("Stop reply")
            } else {
                Button {
                    let text = draft
                    chat.send(text, model: models.current, path: models.path(models.current))
                    if chat.running { draft = ""; composing = false; reviewingEditID = nil }
                } label: { Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 28, height: 28) }
                    .buttonStyle(.borderedProminent).clipShape(Circle())
                    .accessibilityLabel("Send message")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !models.installed.contains(models.selected))
            }
            }
        }.padding(12).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(KeelStyle.accent.opacity(0.18)))
            .padding(.horizontal).padding(.bottom, 12)
    }
}

private func repositoryActivityText(_ text: String) -> String {
    guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return text }
    if let content = value["content"] as? String, let start = value["start_line"] as? Int {
        return content.components(separatedBy: "\n").enumerated().map { "\(start + $0.offset)  \($0.element)" }.joined(separator: "\n")
    }
    if let entries = value["entries"] as? [[String: String]] {
        let names = entries.map { ($0["name"] ?? "") + ($0["kind"] == "directory" ? "/" : "") }.joined(separator: "\n")
        return names.isEmpty ? "Empty directory" : names
    }
    if value["result_type"] as? String == "file_search", let matches = value["matches"] as? [[String: Any]] {
        let lines = matches.map { "\($0["line"] as? Int ?? 0)  \($0["content"] as? String ?? "")" }.joined(separator: "\n")
        let scope = "\(value["path"] as? String ?? "File") · literal search from line \(value["search_start_line"] as? Int ?? 1)"
        let continuation = (value["next_start_line"] as? Int).map { "\nMore matches from line \($0)." } ?? ""
        return scope + "\n\n" + (lines.isEmpty ? "No matching lines in this file range." : lines) + continuation
    }
    return text
}

struct ModelLibraryView: View {
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @State private var removal: String?
    @State private var discardPartial = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        KeelMark().frame(width: 40, height: 40)
                        Text("Your models. Your iPhone.").font(.title2.weight(.semibold))
                    }
                    Text("Download a model, then chat without a connection. Models run here and never send your prompts to a server.")
                        .foregroundStyle(.secondary)
                }.listRowBackground(KeelStyle.surface)
                ForEach(LocalModel.catalog) { model in
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(model.name).font(.headline)
                                Spacer()
                                if models.installed.contains(model.id) {
                                    Image(systemName: models.selected == model.id ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                        .foregroundStyle(KeelStyle.accent)
                                }
                            }
                            Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file) + " · On-device · Q2")
                                .font(.caption).foregroundStyle(.secondary)
                            if models.downloading == model.id {
                                ProgressView(value: models.progress)
                                HStack {
                                    Text(models.verifying ? "Verifying download…" : models.restarting ? "Retrying a damaged download · \(Int(models.progress * 100))%" : "Downloading \(Int(models.progress * 100))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Pause") { models.cancel() }
                                        .accessibilityIdentifier("pauseModelDownload")
                                }
                            } else if models.installed.contains(model.id) {
                                HStack {
                                    Button(models.selected == model.id ? "Selected" : "Use model") {
                                        models.selected = model.id
                                        Task { await chat.inference.unload() }
                                    }.disabled(chat.running || models.downloading != nil || models.selected == model.id)
                                    Spacer()
                                    Button("Remove", role: .destructive) { discardPartial = false; removal = model.id }
                                        .disabled(chat.running || models.downloading != nil)
                                }
                            } else {
                                if let bytes = models.partialBytes[model.id] {
                                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) saved on this iPhone")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button(bytes >= model.bytes ? "Verify download" : "Resume download") { models.install(model) }
                                        .accessibilityIdentifier("resumeModel-\(model.id)")
                                        .disabled(models.downloading != nil || chat.running)
                                    Button("Discard partial download", role: .destructive) { discardPartial = true; removal = model.id }
                                        .accessibilityIdentifier("discardModel-\(model.id)")
                                        .disabled(models.downloading != nil || chat.running)
                                } else {
                                    Button("Download \(model.name)") { models.install(model) }
                                        .disabled(models.downloading != nil || chat.running)
                                }
                            }
                        }.padding(.vertical, 8).buttonStyle(.borderless)
                    }.listRowBackground(KeelStyle.surface)
                }
                if let error = models.error {
                    Section {
                        Text(error).foregroundStyle(.orange).accessibilityIdentifier("modelDownloadError")
                        if let model = models.failedModel {
                            Button("Retry \(model.name)") { models.install(model) }
                                .disabled(models.downloading != nil || chat.running)
                                .accessibilityIdentifier("retryModel-\(model.id)")
                        }
                        if let detail = models.failureDetail {
                            DisclosureGroup("Download details") { Text(detail).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
                Section {
                    Label("Downloads pause when you leave Keel; return here to resume. Keep Keel open while it replies.", systemImage: "iphone")
                    Text("Start with 4B. A model’s download size does not predict whether it will fit in your iPhone’s available memory.")
                }.font(.footnote).foregroundStyle(.secondary)
            }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Models")
                .alert(discardPartial ? "Discard this partial download? You will need to download it again." : "Remove this downloaded model?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { identifier in
                    Button(discardPartial ? "Discard download" : "Remove model", role: .destructive) {
                        if let model = LocalModel.catalog.first(where: { $0.id == identifier }) {
                            if discardPartial { models.discardPartial(model) }
                            else { Task { await chat.inference.unload(); models.remove(model) } }
                        }
                        removal = nil
                    }
                    Button("Cancel", role: .cancel) { removal = nil }
                }
        }
    }
}
