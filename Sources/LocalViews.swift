import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

struct LocalChatView: View {
    /// The run-shortcut question, built outside the view body: as one inline
    /// expression it was too slow for the compiler to type-check.
    static func shortcutQuestion(name: String, input: String?) -> String {
        var text = "Keel will open Shortcuts and run \"\(name)\""
        if let input { text += " with this input:\n\n" + input } else { text += "." }
        return text + "\n\nShortcuts brings you back here with the result."
    }

    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var hardware: HardwareRecommendationStore
    @EnvironmentObject private var imageModels: ImageModelStore
    @EnvironmentObject private var chat: LocalChat
    @State private var draft = ""
    @State private var reviewingEditID: UUID?
    @State private var showingPublish = false
    @State private var choosingRepository = false
    @State private var pendingAttachments: [Attachment] = []
    @State private var showingFileImporter = false
    @State private var showingSchedule = false
    @State private var showingDictation = false
    @State private var copiedMessageID: UUID?
    @StateObject private var speech = ReplySpeech()
    @Environment(\.scenePhase) private var scenePhase
    #if canImport(PhotosUI)
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    #endif
    @State private var isProcessingAttachment = false
    @State private var processingStatusText = ""
    @State private var voiceOn = false
    @State private var showingCamera = false
    @State private var processingTask: Task<Void, Never>? = nil
    @State private var thinkingStarted: Date?
    @FocusState private var composing: Bool
    let chooseModel: () -> Void
    let openMenu: () -> Void

    var body: some View {
        NavigationStack {
            approvalAlerts(on: presentedSheets(on: chatScreen))
        }
    }

    // The chat screen and its approval alerts are built in separate pieces:
    // as one modifier chain it grew past the compiler's type-check limit.
    private var chatScreen: some View {
        VStack(spacing: 0) {
            chatHeaderBanners
            transcriptScrollView
            if let previousModel = chat.memoryFailureModelID {
                memoryRecovery(previousModel: previousModel)
            } else if let error = chat.error {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Image(systemName: chat.canContinueReply ? "pause.circle" : "exclamationmark.circle")
                        Text(error).font(.footnote)
                        Spacer(minLength: 0)
                        Button { chat.error = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                    }.foregroundStyle(chat.canContinueReply ? KeelStyle.accent : Color.orange)
                    if chat.canContinueReply, models.installed.contains(models.selected) {
                        Button {
                            chat.continueReply(model: models.current, path: models.path(models.current))
                        } label: {
                            Label("Continue", systemImage: "play.fill").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("continueReplyButton")
                    }
                }
                .padding(.horizontal).padding(.bottom, 12)
            } else if chat.canContinueReply, models.installed.contains(models.selected) {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Reply paused.").font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        chat.continueReply(model: models.current, path: models.path(models.current))
                    } label: {
                        Label("Continue", systemImage: "play.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("continueReplyButton")
                }
                .padding(.horizontal).padding(.bottom, 12)
            }
            if voiceOn {
                VoiceBar { voiceOn = false }
            } else {
                composer
            }
        }
        .background(KeelStyle.background)
        .navigationTitle(chat.activeTitle == "New task" ? "Keel" : chat.activeTitle).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if models.switchMode(chat.chatMode) { Task { await chat.unloadModelsNow() } }
            if chat.running, thinkingStarted == nil { thinkingStarted = Date() }
        }
        .onChange(of: chat.chatMode) { _, mode in
            // Each mode brings back the model the user last picked for it.
            if models.switchMode(mode) { Task { await chat.unloadModelsNow() } }
        }
        .onChange(of: chat.activeTaskID) { _, _ in
            speech.stop()
            processingTask?.cancel()
            #if canImport(PhotosUI)
            selectedPhotoItem = nil
            #endif
            draft = ""
            chat.discardPendingPhotos(pendingAttachments)
            pendingAttachments = []
            isProcessingAttachment = false
            composing = false
            reviewingEditID = nil
            showingPublish = false
        }
        .onChange(of: scenePhase) { _, phase in
            speech.sceneDidChange(phase)
        }
        .onChange(of: chat.running) { _, running in
            if running {
                speech.stop()
                if thinkingStarted == nil { thinkingStarted = Date() }
            } else {
                thinkingStarted = nil
            }
        }
        .onChange(of: showingDictation) { _, showing in
            if showing { speech.stop() }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                handleImportedFile(url)
            case .failure(let error):
                chat.error = error.localizedDescription
            }
        }
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in
            if let item {
                handleSelectedPhoto(item)
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openMenu) { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Menu")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    if chat.activeTitle != "New task" {
                        Text(chat.activeTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if let app = chat.activeApp, chat.repository == nil {
                        Text(app.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if chat.canSwitchMode {
                            Menu {
                                ForEach(ChatMode.allCases, id: \.self) { mode in
                                    Button { _ = chat.setChatMode(mode) } label: {
                                        Label {
                                            Text(mode.title); Text(mode.summary)
                                        } icon: { Image(systemName: chat.chatMode == mode ? "checkmark" : mode.symbol) }
                                    }.accessibilityIdentifier("mode-\(mode.rawValue)")
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: chat.chatMode.symbol)
                                    Text(chat.chatMode.title)
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(KeelStyle.surface, in: Capsule())
                            }
                            .disabled(chat.running)
                            .accessibilityLabel("Mode: \(chat.chatMode.title)")
                            .accessibilityIdentifier("modePicker")
                        }
                        Button(action: chooseModel) {
                            HStack(spacing: 4) {
                                Text(models.installed.contains(models.selected) ? models.current.name : "Models").font(.headline)
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).disabled(chat.running).accessibilityIdentifier("modelPicker")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Always a plain chat, like the sidebar's New chat: an app is
                    // opened from Apps, and leaving one must be one tap.
                    if chat.newChat() {
                        draft = ""
                        chat.discardPendingPhotos(pendingAttachments)
                        pendingAttachments = []
                        isProcessingAttachment = false
                    }
                } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat").disabled(chat.running || chat.storageUnreadable)
            }
        }
    }

    /// Sheets and full-screen covers the chat screen can open.
    private func presentedSheets(on content: some View) -> some View {
        content
            .sheet(isPresented: $showingSchedule) {
                ScheduleTaskView(taskID: chat.activeTaskID, prompt: draft)
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCapture { data in handleCapturedPhoto(data) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showingDictation) {
                OfflineDictationView { text in
                    guard !text.isEmpty else { return }
                    draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
                }
            }
            .sheet(isPresented: Binding<Bool>(get: { reviewingEditID != nil }, set: { shown in if !shown { reviewingEditID = nil } })) {
                editReviewSheet
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
    }

    /// Every approval the model can ask for while working.
    private func approvalAlerts(on content: some View) -> some View {
        content
            .alert("Keep going?", isPresented: Binding(
                get: { chat.pendingContinue != nil },
                set: { _ in }
            )) {
                Button("Keep going") { chat.decideContinue(true) }.accessibilityIdentifier("keepGoing")
                Button("Stop here", role: .cancel) { chat.decideContinue(false) }
            } message: {
                if let ask = chat.pendingContinue {
                    Text("Keel has made \(ask.calls) tool calls for this message. Let it continue for up to \(ask.more) more?")
                }
            }
            .alert("Remember this?", isPresented: Binding(
                get: { chat.pendingMemory != nil },
                set: { _ in }
            )) {
                Button("Remember") { chat.decideMemory(true) }.accessibilityIdentifier("approveMemory")
                Button("Don't save", role: .cancel) { chat.decideMemory(false) }
            } message: {
                Text((chat.pendingMemory?.fact ?? "") + "\n\nKeel will use this in future chats. You can delete it in Customize.")
            }
            .alert("Search the web?", isPresented: Binding(
                get: { chat.pendingWebSearch != nil },
                set: { _ in }
            )) {
                Button("Search") { chat.decideWebSearch(true) }
                Button("Cancel", role: .cancel) { chat.decideWebSearch(false) }
            } message: {
                Text("Send this query to Brave Search:\n\n" + (chat.pendingWebSearch?.query ?? ""))
            }
            .alert("Run this shortcut?", isPresented: Binding(
                get: { chat.pendingShortcut != nil },
                set: { _ in }
            )) {
                Button("Run") { chat.decideShortcut(true) }.accessibilityIdentifier("approveShortcut")
                Button("Cancel", role: .cancel) { chat.decideShortcut(false) }
            } message: {
                if let run = chat.pendingShortcut {
                    Text(Self.shortcutQuestion(name: run.name, input: run.input))
                }
            }
            .alert("Allow this action?", isPresented: Binding(
                get: { chat.pendingConnectorCall != nil },
                set: { _ in }
            )) {
                Button("Allow once") { chat.decideConnectorCall(.once) }
                Button("Always allow this tool") { chat.decideConnectorCall(.always) }
                Button("Don’t allow", role: .cancel) { chat.decideConnectorCall(.deny) }
            } message: {
                if let call = chat.pendingConnectorCall {
                    Text("\(call.service) · \(call.tool)" + (call.details.isEmpty ? "" : "\n\n" + call.details))
                }
            }
    }

    /// The file-edit review sheet, kept out of the body's modifier chain: inline,
    /// its optional preview closure pushed that chain past the compiler's
    /// type-check limit on Xcode Cloud.
    @ViewBuilder
    private var editReviewSheet: some View {
        if let id = reviewingEditID, let record = chat.fileEdits.first(where: { $0.id == id }) {
            let proposal = record.proposal
            let previewable = proposal.kind != .delete
                && FileView.kind(path: proposal.afterPath, text: proposal.after) != nil
            let preview: (() -> String)? = previewable ? { chat.previewDocument(for: proposal) } : nil
            FileEditReviewView(proposal: proposal, decision: record.decision, applying: chat.applyingEditID == id,
                               error: chat.error, apply: { chat.applyEdit(id) }, discard: { chat.discardEdit(id) },
                               preview: preview)
        }
    }

    @ViewBuilder
    private var chatHeaderBanners: some View {
        if let repository = chat.repository {
            Button { choosingRepository = true } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repository.repository.fullName).fontWeight(.medium)
                        Text("\(repository.branch) · \(repository.commit.prefix(7)) · \(chat.directorMode ? "Reviewed edits" : "GitHub reads")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if chat.messages.isEmpty { Image(systemName: "plus").font(.caption) }
                }.font(.subheadline).padding(.horizontal).padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(chat.running || !chat.messages.isEmpty)
                .accessibilityIdentifier("attachRepository")
        }
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
            HStack(spacing: 12) {
                let applied = chat.fileEdits.filter { $0.decision == .applied }.count
                let pending = chat.fileEdits.filter { $0.decision == .pending }.count
                Text("\(applied) applied · \(pending) awaiting review").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if chat.repository == nil, pending > 0 {
                    Button("Apply all") {
                        chat.applyAllLocalEdits()
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(chat.running)
                    .accessibilityIdentifier("applyAllTaskChanges")
                }
                Button("Review changes") {
                    reviewingEditID = (chat.fileEdits.first { $0.decision == .pending } ?? chat.fileEdits.last)?.id
                }.font(.caption).disabled(chat.running).accessibilityIdentifier("openTaskChanges")
            }.padding(.horizontal).padding(.vertical, 8)
            Divider()
        }
        if chat.repository != nil, (!chat.publishEdits.isEmpty || chat.publishState != nil) {
            publishBanner
            Divider()
        }
        if (models.isTransferring || imageModels.downloading),
           let snapshot = KeelLiveActivitySnapshot.current(models: models, chat: chat, imageModels: imageModels) {
            LiveStatusBannerView(snapshot: snapshot) { chooseModel() }
            Divider()
        }
    }

    @ViewBuilder
    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if chat.messages.isEmpty { welcome }
                    // A tool-call step shows only its one-line update, if it wrote one.
                    ForEach(chat.messages.filter { $0.isToolCall != true || StepNote.summary($0.text) != nil }) { message in
                        if message.isToolCall == true {
                            stepNote(for: message)
                        } else {
                            transcriptRow(for: message)
                        }
                    }
                    if chat.running {
                        ThinkingStatusLine(phase: chat.phase, started: thinkingStarted ?? Date())
                    }
                    if !chat.messages.isEmpty, !chat.running, !models.installed.contains(models.selected),
                       chat.memoryFailureModelID == nil, chat.error == nil {
                        Divider()
                        modelSetup
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.running) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// What the model said before a tool call, as one quiet line; the full text is a tap away.
    private func stepNote(for message: ChatMessage) -> some View {
        DisclosureGroup {
            Text(StepNote.narration(message.text))
                .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                Text(StepNote.summary(message.text) ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .tint(.secondary)
        .accessibilityIdentifier("stepNote")
    }

    /// A tool step as one line. The label keeps the activity text so a search
    /// can still be found by the path it read.
    private func activityRow(_ message: ChatMessage) -> some View {
        let title = message.activity ?? "Repository read"
        let busy = message.note == "Executing…"
        return DisclosureGroup {
            Text(message.text.isEmpty ? (message.note ?? chat.phase) : repositoryActivityText(message.text))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(busy ? KeelStyle.accent : Color.secondary.opacity(0.55), lineWidth: 1.5)
                    .background(Circle().fill(busy ? Color.clear : Color.secondary.opacity(0.18)))
                    .frame(width: 14, height: 14)
                Text(WorkLook.stepTitle(title, busy: busy))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            // The label goes on the header only: on the whole DisclosureGroup it
            // also replaced the expanded result text, hiding it from VoiceOver.
            // It keeps the activity text so a search can be found by its path.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(WorkLook.stepTitle(title, busy: busy)). \(title)")
        }
        .tint(.secondary)
    }

    private func workLook(for message: ChatMessage) -> WorkLook.Spec? {
        let path = message.edit?.proposal.afterPath ?? message.activity.flatMap(WorkLook.path(from:))
        guard let path else { return nil }
        return WorkLook.spec(path: path, study: chat.activeApp == .study)
    }

    @ViewBuilder
    private func transcriptRow(for message: ChatMessage) -> some View {
        if message.role == "tool" {
            if let picture = message.image, message.edit == nil {
                GeneratedImageView(name: picture, caption: message.text)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    activityRow(message)
                    if let look = workLook(for: message) {
                        let building = chat.running && (message.note == "Executing…" || message.edit?.decision == .pending)
                        WorkPreviewCard(
                            title: building ? look.buildingTitle : look.doneTitle,
                            footer: look.footer,
                            symbol: look.symbol,
                            kind: look.kind,
                            progress: building ? nil : 1
                        )
                    }
                    if let record = message.edit {
                        Button(record.decision == .pending ? "Review change" : "View change") {
                            reviewingEditID = record.id
                        }
                        .disabled(chat.running)
                        .accessibilityIdentifier("reviewFileEdit")
                    }
                }
            }
        } else if message.role == "user" {
            // What the user wrote: a compact bubble on the right.
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { attachment in
                                AttachmentChipView(attachment: attachment, onRemove: nil)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(KeelStyle.bubble, in: RoundedRectangle(cornerRadius: KeelStyle.bubbleRadius, style: .continuous))
                }
                if let note = message.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 44)
            .accessibilityElement(children: .contain)
        } else {
            let responding = message.note == "Responding"
            VStack(alignment: .leading, spacing: 10) {
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        KeelMark().frame(width: 20, height: 20)
                        Text(chat.running ? (chat.phase.isEmpty ? "Thinking…" : chat.phase) : "No reply generated.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // While a step is still being written, a tool call it starts is not shown as text.
                    ChatMessageContent(text: responding ? StepNote.narration(message.text) : message.text)
                        .equatable()
                }
                if let note = message.note, !responding {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if !responding, !message.text.isEmpty {
                    replyActions(for: message)
                }
            }
        }
    }

    /// Copy and Listen under a finished reply.
    private func replyActions(for message: ChatMessage) -> some View {
        HStack(spacing: 4) {
            let copied = copiedMessageID == message.id
            Button {
                // Pasteboard sync can block for seconds on slow hosts;
                // the chat must never wait on it.
                let text = message.text
                Task.detached(priority: .userInitiated) { UIPasteboard.general.string = text }
                copiedMessageID = message.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if copiedMessageID == message.id { copiedMessageID = nil }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(copied ? "Reply copied" : "Copy reply")
            .accessibilityIdentifier("copyReplyButton")
            if !SpeechText.spoken(from: message.text).isEmpty {
                let speaking = speech.speakingMessageID == message.id
                Button {
                    speech.toggle(messageID: message.id, text: message.text)
                } label: {
                    Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2")
                        .foregroundStyle(speaking ? KeelStyle.detail : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(speaking ? "Stop reading reply" : "Read reply aloud")
                .accessibilityIdentifier("speakReplyButton")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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

    /// A suggestion on the empty chat: tapping it starts the message.
    private struct Starter {
        let text: String
        let symbol: String
        var prompt: String? = nil
        var opensFiles = false
        static let general = [
            Starter(text: "Write a text", symbol: "pencil.line",
                    prompt: "Write a short, friendly text saying I'll be 10 minutes late."),
            Starter(text: "Explain something", symbol: "lightbulb",
                    prompt: "Explain why leaves change colour in autumn in two short sentences."),
            Starter(text: "Plan something", symbol: "checklist",
                    prompt: "Give me a short packing list for a weekend trip."),
            Starter(text: "Add a file", symbol: "doc.text", opensFiles: true)
        ]
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            KeelMark().frame(width: 72, height: 72).padding(.leading, -12)
            let app = chat.repository == nil ? chat.activeApp : nil
            VStack(alignment: .leading, spacing: 10) {
                Text(app.map { $0.title.uppercased() } ?? "ON THIS \(KeelDevice.uppercaseName)").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(KeelStyle.accent)
                Text(app.map { $0.summary } ?? "What should we\nwork on?")
                    .font(.system(.largeTitle, design: .rounded).weight(.medium)).tracking(-0.8)
            }
            Text("Ask questions, write, and work with your files. Responses and file tools run on this \(KeelDevice.name).")
                .foregroundStyle(.secondary)
            if !models.installed.contains(models.selected) {
                modelSetup
            } else {
                let starters = app.map { app in app.starters.map { Starter(text: $0, symbol: app.symbol) } } ?? Starter.general
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(starters, id: \.text) { starter in
                        Button {
                            if starter.opensFiles {
                                composing = false
                                showingFileImporter = true
                            } else {
                                draft = starter.prompt ?? (app == nil ? starter.text + ": " : starter.text)
                                composing = true
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: starter.symbol).font(.title3).foregroundStyle(KeelStyle.accent)
                                Text(starter.text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                            .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous).strokeBorder(KeelStyle.hairline))
                        }.buttonStyle(.plain)
                    }
                }
                if models.current.isSystem && !models.hasDownloadedChatModel {
                    HStack(spacing: 12) {
                        Text("Using Apple's built-in model. Download a Keel model for longer chats, coding and file tools.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Models", action: chooseModel)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("upgradeFromSystemModel")
                    }
                    .padding(12)
                    .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous).strokeBorder(KeelStyle.hairline))
                }
            }
            if app == nil, chat.repository == nil,
               !models.installed.contains(models.selected), pendingAttachments.isEmpty {
                Button("Try a calculation") {
                    draft = "What is 17 × 23?"
                    composing = true
                }
                .accessibilityIdentifier("tryCalculation")
            }
            if chat.repository != nil {
                Label("Keel can read this project and propose edits. Review each change before applying it. Publishing is a separate step.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memoryRecovery(previousModel: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This model ran out of memory. Your message is saved.", systemImage: "exclamationmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
            if models.selected == previousModel || !models.installed.contains(models.selected) {
                Button("Choose another model", action: chooseModel)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Retry with \(models.current.name)") {
                    chat.continueReply(model: models.current, path: models.path(models.current))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("continueReplyButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.bottom, 12)
    }

    private var modelSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = models.downloading, let model = models.catalog.first(where: { $0.id == id }) {
                Text(models.verifying ? "Checking the download…" : "Downloading \(model.name)…")
                    .font(.subheadline.weight(.medium))
                ProgressView(value: models.progress)
                    .accessibilityLabel("Download progress")
                Text("Keep Keel open. You can chat offline once the download is ready.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pause download") { models.cancel() }
            } else if let ready = models.catalog.first(where: { models.installed.contains($0.id) }) {
                if ready.isSystem {
                    Text("Apple’s built-in model is ready. You can chat offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button {
                    models.selected = ready.id
                    Task { await chat.unloadModelsNow() }
                } label: {
                    Text(ready.isSystem ? "Start chatting" : "Use \(ready.name)")
                        .foregroundStyle(KeelStyle.background)
                }
                .buttonStyle(.borderedProminent)
                .disabled(models.isTransferring)
            } else if let model = hardware.setupModel(for: models) {
                if let error = models.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                let size = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
                Text("Download \(model.name) once (\(size)), then chat offline.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    models.install(model)
                } label: {
                    Text(models.partialBytes[model.id] == nil ? "Download and get started" : "Resume download")
                        .foregroundStyle(KeelStyle.background)
                }
                .buttonStyle(.borderedProminent)
                .disabled(models.isTransferring)
                .accessibilityIdentifier("downloadRecommendedModel")
            } else {
                Text("Keel couldn't find a built-in download that fits this device.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Browse models", action: chooseModel)
                .accessibilityIdentifier("setupLocalModel")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty || isProcessingAttachment {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            AttachmentChipView(attachment: attachment) {
                                chat.discardPendingPhotos([attachment])
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            }
                        }
                        if isProcessingAttachment {
                            AttachmentLoadingChipView(title: processingStatusText) {
                                processingTask?.cancel()
                                isProcessingAttachment = false
                                processingStatusText = ""
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("pendingAttachmentsTray")
            }

            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button { showingSchedule = true } label: {
                        Label("Schedule task", systemImage: "clock")
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
                    .accessibilityIdentifier("scheduleTaskMenuOption")
                    Button {
                        _ = chat.setThinkingEnabled(!chat.thinkingEnabled)
                    } label: {
                        Label(chat.thinkingEnabled ? "Thinking on" : "Thinking off",
                              systemImage: chat.thinkingEnabled ? "brain.head.profile.fill" : "brain.head.profile")
                    }
                    .accessibilityIdentifier("thinkingToggleMenuOption")
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Attach file", systemImage: "doc")
                    }
                    .accessibilityIdentifier("attachFileMenuOption")
                    Button { composing = false; voiceOn = true } label: {
                        Label("Talk with Keel", systemImage: "waveform")
                    }
                    .disabled(!models.installed.contains(models.selected) || !pendingAttachments.isEmpty)
                    .accessibilityIdentifier("voiceConversationMenuOption")
                    if CameraCapture.isAvailable {
                        Button { showingCamera = true } label: {
                            Label(models.current.visionFile == nil ? "Take photo as text" : "Take photo", systemImage: "camera")
                        }
                        .accessibilityIdentifier("takePhotoMenuOption")
                    }

                    #if canImport(PhotosUI)
                    let photoLabel = models.current.visionFile == nil ? "Photo as text" : "Attach photo"
                    Button { showingPhotoPicker = true } label: {
                        Label(photoLabel, systemImage: "camera.viewfinder")
                    }
                    .accessibilityIdentifier("photoAsTextMenuOption")
                    #endif
                } label: {
                    Image(systemName: "plus").fontWeight(.semibold).frame(width: 40, height: 40)
                }
                .disabled(chat.running || isProcessingAttachment)
                .accessibilityLabel("Add to chat")
                .accessibilityIdentifier("composerAddMenu")

                TextField(pendingAttachments.isEmpty ? "Ask anything" : "Ask about attachments…", text: $draft, axis: .vertical)
                    .lineLimit(1...6).focused($composing).padding(.vertical, 9).accessibilityIdentifier("localChatInput")

                if !chat.running, !isProcessingAttachment {
                    Button { showingDictation = true } label: {
                        Image(systemName: "mic").font(.body.weight(.medium))
                            .foregroundStyle(KeelStyle.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dictate")
                    .accessibilityIdentifier("dictateButton")
                }
                if chat.running {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").font(.caption2.weight(.black)).frame(width: 40, height: 40)
                            .foregroundStyle(KeelStyle.background)
                            .background(KeelStyle.accent, in: Circle())
                    }
                    .accessibilityLabel("Stop reply")
                } else {
                    Button {
                        let text = draft
                        let attachments = pendingAttachments
                        if chat.send(text, attachments: attachments, model: models.current, path: models.path(models.current)) {
                            draft = ""
                            pendingAttachments = []
                            composing = false
                            reviewingEditID = nil
                        }
                    } label: {
                        Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 40, height: 40)
                            .foregroundStyle(canSend ? KeelStyle.background : Color.secondary)
                            .background(canSend ? KeelStyle.accent : Color.secondary.opacity(0.15), in: Circle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send message")
                        .disabled(!canSend)
                        .accessibilityIdentifier("sendMessageButton")
                }
            }
        }.padding(8).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(KeelStyle.hairline))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            .overlay(alignment: .top) {
                if !chat.running {
                    Text("On this \(KeelDevice.name)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(KeelStyle.background, in: Capsule())
                        .offset(y: -10)
                        .accessibilityIdentifier("onThisiPhone")
                }
            }
            .padding(.horizontal).padding(.top, 14).padding(.bottom, 12)
            .background(KeelStyle.background)
            .sensoryFeedback(.impact(weight: .light), trigger: chat.running) { _, running in running }
            .sensoryFeedback(.success, trigger: chat.running) { was, running in was && !running }
    }

    private var canSend: Bool {
        !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
            && !isProcessingAttachment
            && (models.installed.contains(models.selected)
                || chat.quickArithmeticAnswer(draft, attachments: pendingAttachments) != nil)
    }

    private func handleImportedFile(_ url: URL) {
        let taskID = chat.activeTaskID
        let hasVision = models.current.visionFile != nil
        let limit = hasVision ? 32 * 1024 * 1024 : AttachmentLimits.maxFileSizeBytes
        isProcessingAttachment = true
        processingStatusText = "Reading file…"
        processingTask?.cancel()
        processingTask = Task {
            do {
                let attachment = try await Task.detached(priority: .userInitiated) { () throws -> Attachment in
                    guard url.startAccessingSecurityScopedResource() else {
                        throw AttachmentError.extractionFailed("Could not access the selected file.")
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > limit {
                        throw AttachmentError.fileTooLarge(bytes: bytes, limit: limit)
                    }
                    let data = try Data(contentsOf: url)
                    try Task.checkCancellation()
                    let filename = url.lastPathComponent
                    if hasVision, ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(url.pathExtension.lowercased()) {
                        return try PhotoAttachment.make(data, filename: filename)
                    }
                    #if canImport(PDFKit)
                    let pdfExtractor: (any PDFTextExtractor)? = PDFKitTextExtractor()
                    #else
                    let pdfExtractor: (any PDFTextExtractor)? = nil
                    #endif
                    let text = try AttachmentParser.extractText(from: data, filename: filename, pdfExtractor: pdfExtractor)
                    try Task.checkCancellation()
                    let mime = AttachmentMIMEDetector.detectMIME(filename: filename, data: data)
                    return Attachment(
                        filename: filename,
                        mimeType: mime,
                        extractedText: text,
                        byteSize: data.count,
                        source: .file
                    )
                }.value
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                pendingAttachments.append(attachment)
                isProcessingAttachment = false
                processingStatusText = ""
            } catch is CancellationError {
                guard chat.activeTaskID == taskID else { return }
                isProcessingAttachment = false
                processingStatusText = ""
            } catch {
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                chat.error = error.localizedDescription
                isProcessingAttachment = false
                processingStatusText = ""
            }
        }
    }

    /// A photo just taken with the camera: attached as an image when the
    /// model can see, otherwise read for its text, like a photo from the library.
    private func handleCapturedPhoto(_ data: Data) {
        let taskID = chat.activeTaskID
        if models.current.visionFile != nil {
            do { pendingAttachments.append(try PhotoAttachment.make(data)) }
            catch { chat.error = error.localizedDescription }
            return
        }
        isProcessingAttachment = true
        processingStatusText = "Recognizing text…"
        processingTask = Task {
            do {
                #if canImport(Vision)
                let recognizer: any TextRecognizer = VisionTextRecognizer()
                #else
                let recognizer: any TextRecognizer = MockTextRecognizer()
                #endif
                let text = try await recognizer.recognizeText(from: data)
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                await MainActor.run {
                    pendingAttachments.append(Attachment(
                        filename: "Photo \(Date().formatted(date: .omitted, time: .shortened)).txt",
                        mimeType: "text/plain", extractedText: text, byteSize: data.count, source: .photoOCR))
                    isProcessingAttachment = false
                }
            } catch {
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                await MainActor.run {
                    chat.error = error.localizedDescription
                    isProcessingAttachment = false
                }
            }
        }
    }

    #if canImport(PhotosUI)
    private func handleSelectedPhoto(_ item: PhotosPickerItem) {
        let taskID = chat.activeTaskID
        let usesVision = models.current.visionFile != nil
        isProcessingAttachment = true
        processingStatusText = "Reading photo…"
        processingTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        chat.error = "Could not load photo data."
                        isProcessingAttachment = false
                        selectedPhotoItem = nil
                    }
                    return
                }
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                if usesVision {
                    let photo = try PhotoAttachment.make(data)
                    pendingAttachments.append(photo)
                    isProcessingAttachment = false; selectedPhotoItem = nil
                    return
                }
                await MainActor.run {
                    processingStatusText = "Recognizing text…"
                }

                #if canImport(Vision)
                let recognizer: any TextRecognizer = VisionTextRecognizer()
                #else
                let recognizer: any TextRecognizer = MockTextRecognizer()
                #endif

                let text = try await recognizer.recognizeText(from: data)
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }

                await MainActor.run {
                    let filename = "Photo \(Date().formatted(date: .omitted, time: .shortened)).txt"
                    let attachment = Attachment(
                        filename: filename,
                        mimeType: "text/plain",
                        extractedText: text,
                        byteSize: data.count,
                        source: .photoOCR
                    )
                    pendingAttachments.append(attachment)
                    isProcessingAttachment = false
                    selectedPhotoItem = nil
                }
            } catch {
                guard !Task.isCancelled, chat.activeTaskID == taskID else { return }
                await MainActor.run {
                    chat.error = error.localizedDescription
                    isProcessingAttachment = false
                    selectedPhotoItem = nil
                }
            }
        }
    }
    #endif
}

func repositoryActivityText(_ text: String) -> String {
    guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return text }
    if let content = value["content"] as? String, let start = value["start_line"] as? Int {
        return content.components(separatedBy: "\n").enumerated().map { "\(start + $0.offset)  \($0.element)" }.joined(separator: "\n")
    }
    if let entries = value["entries"] as? [String] {
        let next = (value["next_offset"] as? Int).map { "\nMore from offset \($0)." } ?? ""
        return (entries.isEmpty ? "Empty directory" : entries.joined(separator: "\n")) + next
    }
    if let entries = value["entries"] as? [[String: String]] {
        let names = entries.map { ($0["name"] ?? "") + ($0["kind"] == "directory" ? "/" : "") }.joined(separator: "\n")
        return names.isEmpty ? "Empty directory" : names
    }
    if value["result_type"] as? String == "repository_search", let matches = value["matches"] as? [String] {
        let scope = (value["path"] as? String).map { "\($0) · " } ?? ""
        let query = value["query"] as? String ?? ""
        var parts = ["\(scope)search: \(query)"]
        parts.append(matches.isEmpty ? (value["note"] as? String ?? "No matches.") : matches.joined(separator: "\n"))
        if let related = value["related"] as? [String], !related.isEmpty {
            parts.append("Related:\n" + related.joined(separator: "\n"))
        }
        if let named = value["files_named_like_query"] as? [String], !named.isEmpty {
            parts.append("Matching filenames:\n" + named.joined(separator: "\n"))
        }
        if let pending = value["files_not_searched"] as? Int, pending > 0 {
            parts.append("\(pending) file(s) could not be searched.")
        }
        if let next = value["next_offset"] as? Int {
            parts.append("More matches from offset \(next).")
        }
        return parts.joined(separator: "\n\n")
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
    @EnvironmentObject private var images: ImageModelStore
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var hardware: HardwareRecommendationStore
    @AppStorage(RuntimeRouter.useMLXKey) private var useMLXInChats = false
    @State private var removal: String?
    @State private var discardPartial = false
    @State private var choosingFile = false
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss

    private var catalogByID: [String: LocalModel] {
        Dictionary(uniqueKeysWithValues: models.catalog.map { ($0.id, $0) })
    }

    var body: some View {
        let recommendations = hardware.recommendations(for: models, mode: models.mode, usesMLXForLFM3: useMLXInChats)
        let hasReadyModel = models.catalog.contains { models.installed.contains($0.id) }
        let starterID = hasReadyModel ? nil : hardware.setupModel(for: models)?.id
        let starter = recommendations.first { $0.id == starterID && $0.fits }
        let fitting = [starter].compactMap { $0 }
            + recommendations.filter { $0.fits && $0.id != starter?.id }
        let tooLarge = recommendations.filter { !$0.fits }
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        KeelMark().frame(width: 40, height: 40)
                        Text("Your models. Your \(KeelDevice.name).").font(.title2.weight(.semibold))
                    }
                    Text("Download a model, then chat without a connection. Models run here and never send your prompts to a server.")
                        .foregroundStyle(.secondary)
                }.listRowBackground(KeelStyle.surface)
                ForEach(fitting) { rec in
                    if let model = catalogByID[rec.id] {
                        Section {
                            modelCard(model, recommendation: rec, featured: rec.id == fitting.first?.id)
                        }.listRowBackground(KeelStyle.surface)
                    }
                }
                if !tooLarge.isEmpty {
                    Section("Needs more memory") {
                        ForEach(tooLarge) { rec in
                            if let model = catalogByID[rec.id] {
                                modelCard(model, recommendation: rec, featured: false)
                            }
                        }
                    }.listRowBackground(KeelStyle.surface)
                }
                Section("Images") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Make images").font(.headline)
                            Spacer()
                            if images.installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(KeelStyle.accent) }
                        }
                        Text("Lets Keel draw a picture from a description in Work chats. Stable Diffusion 2.1 in Apple's Core ML build. The chat model steps aside while it draws; the first picture after a download takes longest.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: ImageModelStore.pack.totalBytes, countStyle: .file) + " · On-device · Core ML")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = ImageModelStore.unsupportedReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        } else if let progress = images.progress {
                            ProgressView(value: progress)
                            HStack {
                                Text("Downloading \(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Pause") { images.pause() }
                            }
                        } else if images.installed {
                            Button("Remove", role: .destructive) { images.remove() }.disabled(chat.running)
                        } else {
                            Button("Download image model") { images.download() }
                                .disabled(chat.running || models.isTransferring)
                                .accessibilityIdentifier("downloadImageModel")
                        }
                        if let error = images.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 8).buttonStyle(.borderless)
                }.listRowBackground(KeelStyle.surface)
                Section("Search") {
                    let model = LocalModel.search
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            if models.installed.contains(model.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(KeelStyle.accent)
                            }
                        }
                        Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " · On-device · EmbeddingGemma")
                            .font(.caption).foregroundStyle(.secondary)
                        if models.downloading == model.id {
                            ProgressView(value: models.progress)
                            HStack {
                                Text(models.verifying ? "Verifying download…" : "Downloading \(Int(models.progress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Pause") { models.cancel() }
                            }
                        } else if models.installed.contains(model.id) {
                            HStack {
                                Text("On. Keel can look through earlier chats and files in plain chats.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Remove", role: .destructive) { discardPartial = false; removal = model.id }
                                    .disabled(chat.running || models.isTransferring)
                            }
                        } else if let bytes = models.partialBytes[model.id] {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) saved on this \(KeelDevice.name)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(bytes >= model.downloadBytes ? "Verify download" : "Resume download") { models.install(model) }
                                .disabled(models.isTransferring || chat.running)
                            Button("Discard partial download", role: .destructive) { discardPartial = true; removal = model.id }
                                .disabled(models.isTransferring || chat.running)
                        } else {
                            Button("Download search model") { models.install(model) }
                                .disabled(models.isTransferring || chat.running)
                                .accessibilityIdentifier("downloadSearchModel")
                        }
                    }.padding(.vertical, 8).buttonStyle(.borderless)
                }.listRowBackground(KeelStyle.surface)
                Section("Bring your own model") {
                    Text("Import a .gguf file from Files or a public Hugging Face link. Keel reads its header first: Qwen, LFM and MiniCPM models that fit this \(KeelDevice.name)'s memory can be added. How well a model uses tools is up to the model.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let status = models.importing {
                        HStack {
                            ProgressView().tint(KeelStyle.accent)
                            Text(status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { models.cancel() }
                        }
                    } else {
                        Button { choosingFile = true } label: { Label("Import a .gguf file", systemImage: "square.and.arrow.down") }
                            .disabled(chat.running || models.isTransferring)
                            .accessibilityIdentifier("importModelFile")
                        HStack {
                            TextField("Or paste a Hugging Face .gguf link", text: $link)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("modelLink")
                            Button("Add") {
                                models.importModel(link: link)
                                if models.importing != nil { link = "" }
                            }
                                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.running || models.isTransferring)
                                .accessibilityIdentifier("addModelLink")
                        }
                    }
                }.listRowBackground(KeelStyle.surface)
                if let error = models.error {
                    Section {
                        Text(error).foregroundStyle(.orange).accessibilityIdentifier("modelDownloadError")
                        if let model = models.failedModel {
                            Button("Retry \(model.name)") { models.install(model) }
                                .disabled(models.isTransferring || chat.running)
                                .accessibilityIdentifier("retryModel-\(model.id)")
                        }
                        if let detail = models.failureDetail {
                            DisclosureGroup("Download details") { Text(detail).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
                Section("Discover") {
                    NavigationLink {
                        HardwareTrendingView()
                    } label: {
                        Label("Trending for your hardware", systemImage: "flame")
                    }.accessibilityIdentifier("openHardwareTrending")
                }.listRowBackground(KeelStyle.surface)
                Section {
                    NavigationLink {
                        RuntimeBenchmarkView()
                    } label: {
                        Label("Runtime benchmark (llama.cpp vs MLX)", systemImage: "speedometer")
                    }.accessibilityIdentifier("openRuntimeBenchmark")
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Compare llama.cpp and MLX speed on this \(KeelDevice.name), or try the experimental MLX option.")
                }.listRowBackground(KeelStyle.surface)
                if let reason = AppleModelRunner.unavailableReason, !models.catalog.contains(where: \.isSystem) {
                    Section("Apple on-device model") {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }.listRowBackground(KeelStyle.surface)
                }
                Section {
                    Label("Downloads resume from where they stopped if interrupted. On iOS 26, downloads and llama.cpp replies can continue in the background (replies move to the CPU and run slower); on older iOS, keep Keel open.", systemImage: KeelDevice.symbol)
                    Text("Try the small models on the same tasks. Speed, tool reliability and heat depend on the model and your \(KeelDevice.name).")
                }.font(.footnote).foregroundStyle(.secondary)
            }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Models")
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "gguf", conformingTo: .data) ?? .data]) { result in
                    if case .success(let url) = result { models.importModel(from: url) }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { hardware.reloadCalibration() }
                .alert(discardPartial ? "Discard this partial download? You will need to download it again." : "Remove this downloaded model?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { identifier in
                    Button(discardPartial ? "Discard download" : "Remove model", role: .destructive) {
                        if let model = (models.catalog + LocalModel.utilities).first(where: { $0.id == identifier }) {
                            if discardPartial { models.discardPartial(model) }
                            else if model.isImported { Task { await chat.unloadModelsNow(); models.removeImported(model.id) } }
                            else { Task { await chat.unloadModelsNow(); models.remove(model) } }
                        }
                        removal = nil
                    }
                    Button("Cancel", role: .cancel) { removal = nil }
                }
        }
    }

    @ViewBuilder
    private func modelCard(_ model: LocalModel, recommendation: ModelRecommendation, featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.name).font(.headline)
                if featured {
                    Text("Use this")
                        .font(.caption2.weight(.semibold)).foregroundStyle(KeelStyle.background)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(KeelStyle.accent, in: Capsule())
                        .accessibilityIdentifier("recommended-\(model.id)")
                }
                Spacer()
                if models.installed.contains(model.id) {
                    Image(systemName: models.selected == model.id ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(KeelStyle.accent)
                }
            }
            Text(recommendationSentence(recommendation))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("recommendationHeadline-\(model.id)")
            Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
            Text(model.isSystem ? "No download · On-device · Built into iOS"
                 : ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " · On-device")
                .font(.caption).foregroundStyle(.secondary)
            if models.downloading == model.id {
                ProgressView(value: models.progress).tint(KeelStyle.accent)
                HStack {
                    Text(downloadStatus(for: model))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { models.cancel() }
                        .accessibilityIdentifier("pauseModelDownload")
                }
            } else if models.installed.contains(model.id) {
                HStack {
                    Button(models.selected == model.id ? "Selected" : "Use model") {
                        models.selected = model.id
                        Task { await chat.unloadModelsNow() }
                    }.disabled(chat.running || models.isTransferring || models.selected == model.id)
                    Spacer()
                    if !model.isSystem {
                        Button("Remove", role: .destructive) { discardPartial = false; removal = model.id }
                            .disabled(chat.running || models.isTransferring)
                    }
                }
            } else if model.isImported {
                Text("The model file is missing. Remove it here and import it again.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Remove", role: .destructive) { discardPartial = false; removal = model.id }
                    .disabled(chat.running || models.isTransferring)
            } else {
                if let bytes = models.partialBytes[model.id] {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) saved on this \(KeelDevice.name)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(bytes >= model.downloadBytes ? "Verify download" : "Resume download") { models.install(model) }
                        .accessibilityIdentifier("resumeModel-\(model.id)")
                        .disabled(!recommendation.fits || models.isTransferring || chat.running)
                    Button("Discard partial download", role: .destructive) { discardPartial = true; removal = model.id }
                        .accessibilityIdentifier("discardModel-\(model.id)")
                        .disabled(models.isTransferring || chat.running)
                } else {
                    Button("Download \(model.name)") { models.install(model) }
                        .disabled(!recommendation.fits || models.isTransferring || chat.running)
                }
            }
        }.padding(.vertical, 8).buttonStyle(.borderless)
    }

    /// One sentence. The ranked list already picked a single model to lead with.
    private func recommendationSentence(_ recommendation: ModelRecommendation) -> String {
        guard recommendation.fits else { return recommendation.plainHeadline }
        let rate = max(1, Int(recommendation.calibratedSpeed.tokensPerSecond.rounded()))
        let measured = recommendation.calibratedSpeed.isMeasured ? " Measured on this \(KeelDevice.name)." : ""
        let device = recommendation.plainBadges.first { $0.hasPrefix("Fits your") } ?? "Fits your \(KeelDevice.name)"
        let memory = "Uses about \(ModelFitEstimator.formatGB(recommendation.fit.requiredBytes)) of \(ModelFitEstimator.formatGB(recommendation.fit.budgetBytes))."
        return "\(recommendation.capabilityLabel). \(recommendation.speedLabel). \(device). About \(rate) tokens a second.\(measured) \(memory)"
    }

    private func downloadStatus(for model: LocalModel) -> String {
        if models.verifying { return "Checking the download…" }
        if models.restarting { return "Starting the download again…" }
        let total = model.downloadBytes
        let have = Int64((min(max(models.progress, 0), 1) * Double(total)).rounded())
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: have)) of \(formatter.string(fromByteCount: total))"
    }
}

struct AttachmentChipView: View {
    let attachment: Attachment
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(KeelStyle.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)

                HStack(spacing: 4) {
                    Text(attachment.formattedByteSize)
                    Text("·")
                    Text("~\(estimatedTokens(attachment.extractedText)) tokens")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.filename)")
                .accessibilityIdentifier("removeAttachment_\(attachment.id.uuidString)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KeelStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KeelStyle.accent.opacity(0.22)))
    }

    private var iconName: String {
        if attachment.imageID != nil { return "photo" }
        switch attachment.kind {
        case .photoOCR:
            return "text.viewfinder"
        case .csv:
            return "tablecells"
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "doc.text"
        case .text:
            let ext = AttachmentMIMEDetector.fileExtension(attachment.filename)
            if ["swift", "js", "ts", "py", "json", "html", "css"].contains(ext) {
                return "curlybraces"
            }
            return "doc.text"
        case .unsupported:
            return "doc"
        }
    }

    private func estimatedTokens(_ text: String) -> String {
        let tokens = max(1, Int((Double(text.unicodeScalars.count) / 3.8).rounded(.up)) + 4)
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }
}

struct AttachmentLoadingChipView: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(KeelStyle.accent)

            Text(title.isEmpty ? "Processing…" : title)
                .font(.caption)
                .foregroundStyle(KeelStyle.accent)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel processing")
            .accessibilityIdentifier("cancelAttachmentProcessing")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KeelStyle.accent.opacity(0.35)))
    }
}
