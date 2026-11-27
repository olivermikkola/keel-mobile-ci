import SwiftUI

/// Screens reached from the menu. Each opens as a sheet over the chat.
enum ShellDestination: String, Identifiable {
    case models, customize, connections, about, hostWorkspace, hostApprovals, library, apps, projects, scheduled, images, videos, carousels, decide
    var id: String { rawValue }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var imageModels: ImageModelStore
    @EnvironmentObject private var decide: DecideSession
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var notifications: TaskNotifications
    @ObservedObject private var intents = IntentInbox.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var destination: ShellDestination?
    @State private var menuOpen = false
    @State private var command = "git status --short"
    @State private var pty = false
    @State private var confirmation: Approval?
    /// Photos shared from another app for the Videos screen.
    @State private var sharedVideo: (photos: [Data], about: String)?

    var body: some View {
        ZStack(alignment: .leading) {
            LocalChatView(chooseModel: { destination = .models }, openMenu: { setMenu(true) })
            if menuOpen {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { setMenu(false) }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                SidebarView(hostConnected: workspace.status != nil, approvals: workspace.approvals.count,
                            open: { target in setMenu(false); destination = target },
                            close: { setMenu(false) })
                    .frame(maxWidth: 320)
                    .transition(.move(edge: .leading))
            }
        }
        .tint(KeelStyle.accent)
        .sheet(item: $destination) { target in
            switch target {
            case .models: ModelLibraryView()
            case .customize: CustomizeView { destination = .about }
            case .library: LibraryView()
            case .apps: AppsView(opened: { setMenu(false) }, openStudio: { destination = $0 })
            case .projects: ProjectsView { setMenu(false) }
            case .scheduled: ScheduledView { setMenu(false) }
            case .images: ImagesView()
            case .videos: VideosView(shared: sharedVideo?.photos ?? [], sharedAbout: sharedVideo?.about ?? "")
            case .carousels: CarouselsView()
            case .decide: DecideView()
            case .connections: connection
            case .about: AboutView()
            case .hostWorkspace: terminal
            case .hostApprovals: approvals
            }
        }
        .onChange(of: workspace.status != nil) { _, connected in
            if !connected, let current = destination, [.hostWorkspace, .hostApprovals].contains(current) {
                destination = .connections
            }
        }
        .onChange(of: scenePhase) { _, phase in
            chat.sceneDidChange(phase)
            models.sceneDidChange(phase)
            imageModels.sceneDidChange(phase)
            startTappedTask()
            startIntent()
        }
        .onAppear {
            chat.sceneDidChange(scenePhase)
            openShare(chat.incomingShare)
            models.sceneDidChange(scenePhase)
            imageModels.sceneDidChange(scenePhase)
            startTappedTask()
            startIntent()
        }
        .onChange(of: notifications.pending) { _, _ in startTappedTask() }
        .onChange(of: intents.pending) { _, _ in startIntent() }
        .onChange(of: chat.incomingShare) { _, item in openShare(item) }
        .onChange(of: chat.running) { _, _ in startTappedTask(); startIntent() }
        .onChange(of: models.selected) { _, _ in startTappedTask(); startIntent() }
        .onChange(of: models.installed) { _, _ in startTappedTask(); startIntent() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.stop(reason: "Your \(KeelDevice.name) is low on memory. Try the smaller model or close other apps.")
            chat.unloadModels()
            decide.handleMemoryWarning()
        }
    }

    /// Something sent from another app's share sheet: photos for a video
    /// open Videos with them picked; anything else opens in a new chat.
    private func openShare(_ item: SharedItem?) {
        guard let item else { return }
        chat.incomingShare = nil
        menuOpen = false
        if item.action == .video, let root = chat.sharedInboxRoot {
            let folder = SharedInbox.folder(item.id, in: root)
            let photos = item.photos.compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
            if !photos.isEmpty {
                sharedVideo = (photos, item.text ?? "")
                destination = nil
                DispatchQueue.main.async { destination = .videos }
                return
            }
        }
        destination = nil
        chat.openShareInChat(item)
    }

    private func startTappedTask() {
        guard scenePhase == .active, let launch = notifications.pending, !chat.running else { return }
        guard chat.tasks.contains(where: { $0.id == launch.taskID }) else {
            notifications.pending = nil
            chat.error = "This scheduled chat no longer exists."
            return
        }
        guard models.installed.contains(models.selected) else {
            chat.error = "Install or select a downloaded model to start your scheduled task."
            return
        }
        menuOpen = false; destination = nil
        notifications.startPending(in: chat, model: models.current, path: models.path(models.current), active: true)
    }

    /// Siri, Spotlight or the Shortcuts app asked for a chat. Waits for a running
    /// reply to finish; a question needs a downloaded model.
    private func startIntent() {
        guard scenePhase == .active, let request = intents.pending, !chat.running else { return }
        if case .ask = request, !models.installed.contains(models.selected) {
            intents.pending = nil
            chat.error = "Download a model in Models, then ask again."
            return
        }
        intents.pending = nil
        menuOpen = false; destination = nil
        guard chat.newChat() else { return }
        if case .ask(let question) = request {
            chat.send(question, model: models.current, path: models.path(models.current))
        }
    }

    private func setMenu(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { menuOpen = open }
    }

    /// Gateway errors are shown from inside each sheet: an alert attached to
    /// the chat underneath cannot appear while a sheet covers it.
    private func gatewayAlert<Content: View>(_ content: Content) -> some View {
        content.alert("Gateway", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }

    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } }
    }

    private var approvalReview: some View {
        Group {
            if let approval = confirmation {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Review this action").font(.title2.bold())
                            Text(approval.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            if let reason = approval.reason { Text(reason).foregroundStyle(.secondary) }
                            Text("This will run on your connected gateway’s workspace.")
                            Button("Approve action", role: .destructive) {
                                confirmation = nil
                                Task { await workspace.decide(approval, approved: true) }
                            }.buttonStyle(.borderedProminent)
                        }.padding()
                    }
                    .toolbar { Button("Cancel") { confirmation = nil } }
                }
            }
        }
    }

    private var connection: some View {
        gatewayAlert(NavigationStack {
            Form { Group {
                Section {
                    Label("On this \(KeelDevice.name)", systemImage: KeelDevice.symbol)
                        .font(.headline).padding(.vertical, 8)
                    Text("Chat and work with your files on this \(KeelDevice.name). Connect other tools when you need them.")
                        .foregroundStyle(.secondary)
                }
                Section("Local model") {
                    Button("Choose a local model") { destination = .models }
                }
                Section {
                    NavigationLink { MCPConnectorsView() } label: {
                        connectionRow("Connectors", "puzzlepiece.extension",
                                      chat.connectors.isEmpty ? "Notion, Linear, Jira and more"
                                          : chat.connectors.map(\.name).joined(separator: ", "))
                    }.accessibilityIdentifier("openMCPConnectors")
                    NavigationLink {
                        githubRepository
                    } label: {
                        connectionRow("GitHub", "chevron.left.forwardslash.chevron.right", "Work on a repository in a chat")
                    }.accessibilityIdentifier("openGitHubRepository")
                    NavigationLink { WebSearchSettingsView() } label: {
                        connectionRow("Web search", "magnifyingglass", "Let a chat look things up")
                    }.accessibilityIdentifier("openWebSearchSettings")
                } header: {
                    Text("Services")
                } footer: {
                    Text("All optional. You sign in on each service's own page; Keel keeps the connection in Keychain.")
                }
                Section {
                    NavigationLink { pairing } label: {
                        Label("Pair a computer", systemImage: "desktopcomputer")
                    }.accessibilityIdentifier("advancedPairing")
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Only if you have your own computer running a Keel gateway. Everything else works without one.")
                }
                if let status = workspace.status {
                    Section("Connected host") {
                        Button { destination = .hostWorkspace } label: {
                            Label("Host workspace", systemImage: "terminal")
                        }.accessibilityIdentifier("hostWorkspace")
                        Button { destination = .hostApprovals } label: {
                            Label("Host approvals", systemImage: "checkmark.shield")
                        }.badge(workspace.approvals.count).accessibilityIdentifier("hostApprovals")
                        LabeledContent("Gateway", value: status.status)
                        LabeledContent("Execution", value: status.execution_mode)
                        LabeledContent("Policy", value: status.approval_policy)
                        Text(status.workspace_path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if !status.workspace_safe { Label("Gateway workspace needs configuration", systemImage: "exclamationmark.triangle") }
                        Button("Refresh status") { Task { await workspace.refresh() } }.disabled(workspace.busy)
                        Button("Disconnect", action: disconnectHost).disabled(workspace.busy)
                    }
                }
                if !workspace.token.isEmpty {
                    Button("Forget saved connection", role: .destructive) { workspace.forget() }.disabled(workspace.busy)
                }
                }.listRowBackground(KeelStyle.surface)
            }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Connections")
                .toolbar { done }
        })
    }

    private func connectionRow(_ title: String, _ symbol: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: { Image(systemName: symbol) }
    }

    @ViewBuilder private var githubRepository: some View {
        if chat.messages.isEmpty && !chat.running && !chat.storageUnreadable {
            RepositoryView { snapshot in
                if chat.attach(snapshot) { destination = nil }
            }
        } else {
            RepositoryView()
        }
    }

    /// Paired mode: an advanced option for people who own a computer running a
    /// Keel gateway. No core feature depends on it.
    private var pairing: some View {
        Form { Group {
            Section {
                Text("Pair a gateway to run commands, review approvals and inspect changes on its workspace.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("https://your-gateway.ts.net", text: $workspace.address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().accessibilityIdentifier("gatewayAddress")
                SecureField("Gateway pairing token", text: $workspace.token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("gatewayToken")
                Button(workspace.busy ? "Connecting…" : "Connect") {
                    Task { await workspace.connect() }
                }.disabled(workspace.busy).accessibilityIdentifier("connectGateway")
            }.disabled(workspace.status != nil)
            }.listRowBackground(KeelStyle.surface)
        }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Pair a computer")
            .toolbar { done }
    }

    private func disconnectHost() {
        destination = .connections
        workspace.disconnect()
    }

    private var terminal: some View {
        gatewayAlert(NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Commands execute on the connected host.").foregroundStyle(.secondary)
                TextField("Command", text: $command, axis: .vertical)
                    .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                Toggle("Use host PTY", isOn: $pty)
                Button("Run command") { Task { await workspace.execute(command: command, pty: pty) } }
                    .buttonStyle(.borderedProminent).disabled(workspace.busy || workspace.status == nil || command.isEmpty)
                ScrollView([.horizontal, .vertical]) {
                    Text(workspace.output).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }.padding().navigationTitle("Host workspace")
                .toolbar { Button("Disconnect", action: disconnectHost).disabled(workspace.busy) }
                .toolbar { done }
        })
    }

    private var approvals: some View {
        gatewayAlert(NavigationStack {
            List { Group {
                Section {
                    Text("Requests apply to the gateway’s shared workspace, including Keel sessions started elsewhere.")
                        .foregroundStyle(.secondary)
                }
                if workspace.approvals.isEmpty { Text("No pending approvals") }
                ForEach(workspace.approvals) { approval in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(approval.kind).font(.caption).foregroundStyle(KeelStyle.accent)
                        Text(approval.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if let reason = approval.reason { Text(reason).foregroundStyle(.secondary) }
                        HStack {
                            Button("Review & approve") { confirmation = approval }.buttonStyle(.bordered)
                            Button("Deny", role: .destructive) { Task { await workspace.decide(approval, approved: false) } }
                                .buttonStyle(.bordered)
                        }.disabled(workspace.busy)
                    }.padding(.vertical, 8)
                }
                }.listRowBackground(KeelStyle.surface)
            }.scrollContentBackground(.hidden).background(KeelStyle.background)
            .refreshable { await workspace.refresh() }
            .toolbar { Button("Refresh") { Task { await workspace.refresh() } }.disabled(workspace.busy || workspace.status == nil) }
            .toolbar { NavigationLink("Changes") { diff } }
            .toolbar { done }
            .navigationTitle("Host approvals")
        }.sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) { approvalReview })
    }

    private var diff: some View {
        ScrollView([.horizontal, .vertical]) {
                Text(workspace.diff.isEmpty ? "No tracked-file changes." : workspace.diff)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
            }
            .toolbar { Button("Refresh") { Task { await workspace.loadDiff() } }.disabled(workspace.busy || workspace.status == nil) }
            .navigationTitle("Workspace diff")
    }
}
