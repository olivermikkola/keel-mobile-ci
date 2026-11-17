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
    @EnvironmentObject private var models: ModelLibrary
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
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    #endif
    @State private var isProcessingAttachment = false
    @State private var processingStatusText = ""
    @State private var voiceOn = false
    @State private var showingCamera = false
    @State private var processingTask: Task<Void, Never>? = nil
    @FocusState private var composing: Bool
    let chooseModel: () -> Void
    let openMenu: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chatHeaderBanners
                transcriptScrollView
                if let error = chat.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).font(.footnote)
                        Spacer(minLength: 0)
                        Button { chat.error = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                    }.foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 12)
                }
                if voiceOn {
                    VoiceBar { voiceOn = false }
                } else {
                    composer
                }
            }
            .background(KeelStyle.background)
            .navigationTitle(chat.activeTitle == "New task" ? "Keel" : chat.activeTitle).navigationBarTitleDisplayMode(.inline)
            .onAppear { if models.switchMode(chat.chatMode) { Task { await chat.inference.unload() } } }
            .onChange(of: chat.chatMode) { _, mode in
                // Each mode brings back the model the user last picked for it.
                if models.switchMode(mode) { Task { await chat.inference.unload() } }
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
            .onChange(of: scenePhase) { _, phase in
                speech.sceneDidChange(phase)
            }
            .onChange(of: chat.running) { _, running in
                if running { speech.stop() }
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
            .onChange(of: selectedPhotoItem) { _, item in
                if let item {
                    handleSelectedPhoto(item)
                }
            }
            #endif
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
            .sheet(isPresented: Binding(get: { reviewingEditID != nil }, set: { if !$0 { reviewingEditID = nil } })) {
                if let id = reviewingEditID, let record = chat.fileEdits.first(where: { $0.id == id }) {
                    FileEditReviewView(proposal: record.proposal, decision: record.decision, applying: chat.applyingEditID == id,
                                       error: chat.error, apply: { chat.applyEdit(id) }, discard: { chat.discardEdit(id) },
                                       preview: record.proposal.kind != .delete && FileView.kind(path: record.proposal.afterPath, text: record.proposal.after) != nil
                                           ? { chat.previewDocument(for: record.proposal) } : nil)
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
                                    Text(models.current.name).font(.headline)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).disabled(chat.running).accessibilityIdentifier("modelPicker")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if chat.newChat(app: chat.activeApp) {
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
        if models.isTransferring, let snapshot = KeelLiveActivitySnapshot.current(models: models, chat: chat) {
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
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// What the model said before a tool call, as one quiet line; the full text is a tap away.
    private func stepNote(for message: ChatMessage) -> some View {
        DisclosureGroup {
            Text(StepNote.narration(message.text))
                .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(StepNote.summary(message.text) ?? "", systemImage: "sparkle")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .tint(.secondary)
        .accessibilityIdentifier("stepNote")
    }

    @ViewBuilder
    private func transcriptRow(for message: ChatMessage) -> some View {
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
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous).strokeBorder(KeelStyle.hairline))
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
                }.padding(14).background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: KeelStyle.cardRadius, style: .continuous))
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
        HStack(spacing: 18) {
            let copied = copiedMessageID == message.id
            Button {
                UIPasteboard.general.string = message.text
                copiedMessageID = message.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if copiedMessageID == message.id { copiedMessageID = nil }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(minWidth: 28, minHeight: 32)
            }
            .accessibilityLabel(copied ? "Reply copied" : "Copy reply")
            .accessibilityIdentifier("copyReplyButton")
            if !SpeechText.spoken(from: message.text).isEmpty {
                let speaking = speech.speakingMessageID == message.id
                Button {
                    speech.toggle(messageID: message.id, text: message.text)
                } label: {
                    Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2").frame(minWidth: 28, minHeight: 32)
                        .foregroundStyle(speaking ? KeelStyle.detail : Color.secondary)
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

    private func icon(for kind: FileEditKind) -> String {
        switch kind {
        case .replace: return "doc.badge.ellipsis"
        case .create: return "doc.badge.plus"
        case .delete: return "trash"
        case .rename: return "arrow.right.doc.on.clipboard"
        }
    }

    /// A suggestion on the empty chat: tapping it starts the message.
    private struct Starter {
        let text: String
        let symbol: String
        static let general = [Starter(text: "Write or edit", symbol: "pencil.line"), Starter(text: "Explain something", symbol: "lightbulb"),
                              Starter(text: "Work with a file", symbol: "doc.text"), Starter(text: "Plan something", symbol: "checklist")]
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            KeelMark().frame(width: 72, height: 72).padding(.leading, -12)
            let app = chat.repository == nil ? chat.activeApp : nil
            VStack(alignment: .leading, spacing: 10) {
                Text(app.map { $0.title.uppercased() } ?? "ON THIS IPHONE").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(KeelStyle.accent)
                Text(app.map { $0.summary } ?? "What should we\nwork on?")
                    .font(.system(.largeTitle, design: .rounded).weight(.medium)).tracking(-0.8)
            }
            Text("Ask questions, write, and work with your files. Responses and file tools run on this iPhone.")
                .foregroundStyle(.secondary)
            if !models.installed.contains(models.selected) {
                Button(action: chooseModel) {
                    Text("Choose and download a model").foregroundStyle(KeelStyle.background)
                }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("setupLocalModel")
                Text("Download once, then chat offline. Keep Keel open while it replies.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                let starters = app.map { app in app.starters.map { Starter(text: $0, symbol: app.symbol) } } ?? Starter.general
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(starters, id: \.text) { starter in
                        Button { draft = app == nil ? starter.text + ": " : starter.text; composing = true } label: {
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
            }
            if chat.repository != nil {
                Label("Keel can read this project and propose edits. Review each change before applying it. Publishing is a separate step.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                .padding(.horizontal, 10).padding(.top, 6)
                .accessibilityIdentifier("prefillProgress")
            }

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
                    Button { showingDictation = true } label: {
                        Label("Dictate offline", systemImage: "mic")
                    }.accessibilityIdentifier("offlineDictationMenuOption")
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
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
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

                if !chat.running, draft.isEmpty, pendingAttachments.isEmpty, !isProcessingAttachment {
                    Button { showingDictation = true } label: {
                        Image(systemName: "mic").font(.body.weight(.medium)).frame(width: 40, height: 40)
                            .foregroundStyle(KeelStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dictate")
                    .accessibilityIdentifier("dictateButton")
                }
                if chat.running {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").frame(width: 40, height: 40)
                            .foregroundStyle(KeelStyle.detail)
                            .background(KeelStyle.detail.opacity(0.10), in: Circle())
                    }
                    .accessibilityLabel("Stop reply")
                } else {
                    Button {
                        let text = draft
                        let attachments = pendingAttachments
                        chat.send(text, attachments: attachments, model: models.current, path: models.path(models.current))
                        if chat.running {
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
            .padding(.horizontal).padding(.top, 6).padding(.bottom, 12)
            .background(KeelStyle.background)
            .sensoryFeedback(.impact(weight: .light), trigger: chat.running) { _, running in running }
            .sensoryFeedback(.success, trigger: chat.running) { was, running in was && !running }
    }

    private var canSend: Bool {
        !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
            && !isProcessingAttachment && models.installed.contains(models.selected)
    }

    private func handleImportedFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            chat.error = "Could not access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let limit = models.current.visionFile == nil ? AttachmentLimits.maxFileSizeBytes : 32 * 1024 * 1024
            if let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > limit {
                throw AttachmentError.fileTooLarge(bytes: bytes, limit: limit)
            }
            let data = try Data(contentsOf: url)
            #if canImport(PDFKit)
            let pdfExtractor: (any PDFTextExtractor)? = PDFKitTextExtractor()
            #else
            let pdfExtractor: (any PDFTextExtractor)? = nil
            #endif
            let filename = url.lastPathComponent
            if models.current.visionFile != nil, ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(url.pathExtension.lowercased()) {
                pendingAttachments.append(try PhotoAttachment.make(data, filename: filename))
                return
            }
            let text = try AttachmentParser.extractText(from: data, filename: filename, pdfExtractor: pdfExtractor)
            let mime = AttachmentMIMEDetector.detectMIME(filename: filename, data: data)
            let attachment = Attachment(
                filename: filename,
                mimeType: mime,
                extractedText: text,
                byteSize: data.count,
                source: .file
            )
            pendingAttachments.append(attachment)
        } catch {
            chat.error = error.localizedDescription
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
    @EnvironmentObject private var chat: LocalChat
    @State private var removal: String?
    @State private var discardPartial = false
    @State private var choosingFile = false
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss
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
                ForEach(models.catalog) { model in
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(model.name).font(.headline)
                                if models.isRecommended(model) {
                                    Text("Good for \(models.mode.title)")
                                        .font(.caption2.weight(.semibold)).foregroundStyle(KeelStyle.accent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(KeelStyle.accent.opacity(0.12), in: Capsule())
                                        .accessibilityIdentifier("recommended-\(model.id)")
                                }
                                Spacer()
                                if models.installed.contains(model.id) {
                                    Image(systemName: models.selected == model.id ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                        .foregroundStyle(KeelStyle.accent)
                                }
                            }
                            Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                            Text(model.isSystem ? "No download · On-device · Built into iOS"
                                 : ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file) + " · On-device · " + model.quantization)
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
                                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) saved on this iPhone")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button(bytes >= model.downloadBytes ? "Verify download" : "Resume download") { models.install(model) }
                                        .accessibilityIdentifier("resumeModel-\(model.id)")
                                        .disabled(models.isTransferring || chat.running)
                                    Button("Discard partial download", role: .destructive) { discardPartial = true; removal = model.id }
                                        .accessibilityIdentifier("discardModel-\(model.id)")
                                        .disabled(models.isTransferring || chat.running)
                                } else {
                                    Button("Download \(model.name)") { models.install(model) }
                                        .disabled(models.isTransferring || chat.running)
                                }
                            }
                        }.padding(.vertical, 8).buttonStyle(.borderless)
                    }.listRowBackground(KeelStyle.surface)
                }
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
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) saved on this iPhone")
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
                    Text("Import a .gguf file from Files or a public Hugging Face link. Keel reads its header first: Qwen, LFM and MiniCPM models that fit this iPhone's memory can be added. How well a model uses tools is up to the model.")
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
                Section("Compare runtimes") {
                    NavigationLink {
                        RuntimeBenchmarkView()
                    } label: {
                        Label("Runtime benchmark (llama.cpp vs MLX)", systemImage: "speedometer")
                    }.accessibilityIdentifier("openRuntimeBenchmark")
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
                if let reason = AppleModelRunner.unavailableReason, !models.catalog.contains(where: \.isSystem) {
                    Section("Apple on-device model") {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }.listRowBackground(KeelStyle.surface)
                }
                Section {
                    Label("Downloads keep running for up to ~30 seconds if you briefly switch apps; return here to resume if paused. Keep Keel open while it replies.", systemImage: "iphone")
                    Text("Try the small models on the same tasks. Speed, tool reliability and heat depend on the model and your iPhone.")
                }.font(.footnote).foregroundStyle(.secondary)
            }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Models")
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "gguf", conformingTo: .data) ?? .data]) { result in
                    if case .success(let url) = result { models.importModel(from: url) }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .alert(discardPartial ? "Discard this partial download? You will need to download it again." : "Remove this downloaded model?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { identifier in
                    Button(discardPartial ? "Discard download" : "Remove model", role: .destructive) {
                        if let model = (models.catalog + [.search]).first(where: { $0.id == identifier }) {
                            if discardPartial { models.discardPartial(model) }
                            else if model.isImported { Task { await chat.inference.unload(); models.removeImported(model.id) } }
                            else { Task { await chat.inference.unload(); models.remove(model) } }
                        }
                        removal = nil
                    }
                    Button("Cancel", role: .cancel) { removal = nil }
                }
        }
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
