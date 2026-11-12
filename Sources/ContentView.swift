import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = "chat"
    @State private var command = "git status --short"
    @State private var pty = false
    @State private var confirmation: Approval?

    var body: some View {
        TabView(selection: $selectedTab) {
            LocalChatView { selectedTab = "models" }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            ModelLibraryView().tabItem { Label("Models", systemImage: "square.stack.3d.up") }.tag("models")
            connection.tabItem { Label("Connect", systemImage: "network") }.tag("connect")
            if workspace.status != nil {
                terminal.tabItem { Label("Workspace", systemImage: "terminal") }.tag("workspace")
                approvals.tabItem { Label("Approvals", systemImage: "checkmark.shield") }
                    .badge(workspace.approvals.count).tag("approvals")
            }
        }
        .tint(KeelStyle.accent)
        .toolbarBackground(KeelStyle.background, for: .tabBar, .navigationBar)
        .onChange(of: workspace.status != nil) { _, connected in
            if !connected && ["workspace", "approvals"].contains(selectedTab) { selectedTab = "connect" }
        }
        .onChange(of: scenePhase) { _, phase in
            chat.sceneDidChange(phase)
            if phase == .background { models.cancel() }
        }
        .onAppear { chat.sceneDidChange(scenePhase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.stop(reason: "Your iPhone is low on memory. Try the smaller model or close other apps.")
            Task { await chat.inference.unload() }
        }
        .alert("Gateway", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(item: $confirmation) { approval in
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

    private var connection: some View {
        NavigationStack {
            Form {
                Section {
                    Label("On this iPhone", systemImage: "iphone")
                        .font(.headline).padding(.vertical, 8)
                    Text("Chat, models and GitHub all work from this iPhone. No computer needed.")
                        .foregroundStyle(.secondary)
                }
                Section("Local model") {
                    Button("Choose a local model") { selectedTab = "models" }
                }
                Section("GitHub") {
                    NavigationLink { RepositoryView() } label: {
                        Label("Open a GitHub repository", systemImage: "folder")
                    }.accessibilityIdentifier("openGitHubRepository")
                    Text("Browse repository files directly from this iPhone.").font(.footnote).foregroundStyle(.secondary)
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
            }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Connections")
        }
    }

    /// Paired mode: an advanced option for people who own a computer running a
    /// Keel gateway. No core feature depends on it.
    private var pairing: some View {
        Form {
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
        }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Pair a computer")
    }

    private func disconnectHost() {
        selectedTab = "connect"
        workspace.disconnect()
    }

    private var terminal: some View {
        NavigationStack {
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
        }
    }

    private var approvals: some View {
        NavigationStack {
            List {
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
            }
            .refreshable { await workspace.refresh() }
            .toolbar { Button("Refresh") { Task { await workspace.refresh() } }.disabled(workspace.busy || workspace.status == nil) }
            .toolbar { NavigationLink("Changes") { diff } }
            .navigationTitle("Host approvals")
        }
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
