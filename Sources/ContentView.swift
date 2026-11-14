import SwiftUI

/// Screens reached from the menu. Each opens as a sheet over the chat.
enum ShellDestination: String, Identifiable {
    case models, connections, hostWorkspace, hostApprovals
    var id: String { rawValue }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.scenePhase) private var scenePhase
    @State private var destination: ShellDestination?
    @State private var menuOpen = false
    @State private var command = "git status --short"
    @State private var pty = false
    @State private var confirmation: Approval?

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
            case .connections: connection
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
            if phase == .background { models.cancel() }
        }
        .onAppear { chat.sceneDidChange(scenePhase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.stop(reason: "Your iPhone is low on memory. Try the smaller model or close other apps.")
            Task { await chat.inference.unload() }
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
            Form {
                Section {
                    Label("On this iPhone", systemImage: "iphone")
                        .font(.headline).padding(.vertical, 8)
                    Text("Chat and work with your files on this iPhone. Connect other tools when you need them.")
                        .foregroundStyle(.secondary)
                }
                Section("Local model") {
                    Button("Choose a local model") { destination = .models }
                }
                Section("GitHub") {
                    NavigationLink {
                        githubRepository
                    } label: {
                        Label("Open a GitHub repository", systemImage: "folder")
                    }.accessibilityIdentifier("openGitHubRepository")
                    Text("Optional. Browse files or use a repository in an empty chat.").font(.footnote).foregroundStyle(.secondary)
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
                .toolbar { done }
        })
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
