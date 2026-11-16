import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Connectors: pick a service and tap Connect. Addresses and tokens appear
/// only under "Custom connector".
struct MCPConnectorsView: View {
    @EnvironmentObject private var chat: LocalChat
    @StateObject private var browser = ConnectorBrowser()
    @State private var connecting: String?
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    /// Connectors are offered to the model only in a plain chat.
    private var locked: Bool { chat.running || chat.repository != nil || chat.activeApp != nil }
    private var remaining: [MCPConnector.CatalogEntry] {
        let added = Set(chat.connectors.map(\.id))
        return MCPConnector.catalog.filter { !added.contains($0.id) }
    }

    var body: some View {
        Form {
            if !chat.connectors.isEmpty {
                Section {
                    ForEach(chat.connectors) { server in
                        Toggle(isOn: Binding(
                            get: { chat.isConnectorEnabled(server.id) },
                            set: { _ = chat.setConnectorEnabled(server.id, enabled: $0) }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                    Text(chat.isConnectorEnabled(server.id) ? "On in this chat" : "Off in this chat")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: MCPConnector.catalog.first(where: { $0.id == server.id })?.symbol ?? "puzzlepiece.extension")
                                    .foregroundStyle(KeelStyle.accent)
                            }
                        }
                        .disabled(locked)
                        .accessibilityIdentifier("toggleMCPConnector-\(server.id)")
                        NavigationLink {
                            ConnectorDetailView(serverID: server.id)
                        } label: {
                            Text("\(server.tools.count) of \((server.available ?? server.tools).count) tools in use")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("connectorDetail-\(server.id)")
                    }
                } header: {
                    Text("Connected")
                } footer: {
                    Text(locked ? "Connectors can be switched on in a plain chat while no reply is running."
                                : "Switch a connector on to let this chat use it. Other chats are not affected.")
                }
            }
            if !remaining.isEmpty {
                Section {
                    ForEach(remaining) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.symbol).foregroundStyle(KeelStyle.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if connecting == entry.id {
                                ProgressView()
                            } else {
                                Button("Connect") { connect(entry) }
                                    .buttonStyle(.bordered)
                                    .disabled(connecting != nil)
                                    .accessibilityIdentifier("connectService-\(entry.id)")
                            }
                        }.padding(.vertical, 2)
                    }
                } header: {
                    Text(chat.connectors.isEmpty ? "Connect a service" : "Add another")
                } footer: {
                    Text("If a service needs your account, Keel opens its own sign-in page. Your password never passes through Keel.")
                }
            }
            if connecting != nil {
                Section { Button("Cancel") { task?.cancel(); browser.cancel() } }
            }
            if let error {
                Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("mcpConnectorError") }
            }
            Section {
                NavigationLink {
                    CustomConnectorView(browser: browser)
                } label: {
                    Label("Custom connector", systemImage: "plus.circle")
                }.accessibilityIdentifier("openCustomConnector")
            } footer: {
                Text("For a service that is not listed, if you have its connector address.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .navigationTitle("Connectors")
    }

    private func connect(_ entry: MCPConnector.CatalogEntry) {
        guard connecting == nil else { return }
        error = nil
        connecting = entry.id
        task = Task {
            do {
                try await chat.connect(id: entry.id, name: entry.name, endpoint: entry.endpoint,
                                       preferred: entry.preferredTools, browser: browser)
            } catch is CancellationError {
            } catch { self.error = connectorMessage(error) }
            connecting = nil
        }
    }
}

/// What the user reads when connecting fails. Never a status code or a token.
func connectorMessage(_ error: Error) -> String {
    if error is MCPConnector.Problem || error is MCPConnectorAuth.Problem { return error.localizedDescription }
    return "Keel could not connect to this service. Check your connection and try again."
}

/// One connected service: which of its tools the model is offered, which may
/// run without asking, and Disconnect.
struct ConnectorDetailView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    let serverID: String
    @State private var error: String?

    var body: some View {
        Form {
            if let server = chat.connectors.first(where: { $0.id == serverID }) {
                let inUse = Set(server.tools.map(\.remoteName))
                Section {
                    ForEach(server.available ?? server.tools, id: \.callName) { tool in
                        let on = inUse.contains(tool.remoteName)
                        Button {
                            var names = server.tools.map(\.remoteName)
                            if on { names.removeAll { $0 == tool.remoteName } } else { names.append(tool.remoteName) }
                            perform { try chat.setConnectorTools(server.id, remoteNames: names) }
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.remoteName).foregroundStyle(.primary)
                                    if !tool.description.isEmpty {
                                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Text(server.needsApproval(tool) ? "Asks you before it runs" : "Runs without asking")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? KeelStyle.accent : .secondary)
                            }
                        }
                        // The last tool stays on, and no more than five at once.
                        .disabled(chat.running || (on && inUse.count == 1) || (!on && inUse.count >= MCPConnector.maxToolsPerConnector))
                        .accessibilityIdentifier("connectorTool-\(tool.remoteName)")
                    }
                } header: {
                    Text("Tools in use")
                } footer: {
                    Text("Up to \(MCPConnector.maxToolsPerConnector) at a time. Fewer tools keep a small on-device model accurate.")
                }
                if let trusted = server.trusted, !trusted.isEmpty {
                    Section("Always allowed") {
                        ForEach(trusted, id: \.self) { name in
                            Button("Ask before \(name) again") {
                                perform { try chat.setConnectorToolTrusted(server.id, remoteName: name, trusted: false) }
                            }
                        }
                    }
                }
                Section {
                    Button("Disconnect \(server.name)", role: .destructive) {
                        perform { try chat.removeConnector(server.id) }
                        dismiss()
                    }
                    .disabled(chat.running)
                    .accessibilityIdentifier("removeMCPConnector-\(server.id)")
                } footer: {
                    Text("Removes the connection and its sign-in from this iPhone.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .navigationTitle(chat.connectors.first(where: { $0.id == serverID })?.name ?? "Connector")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func perform(_ change: () throws -> Void) {
        do { try change(); error = nil }
        catch { self.error = connectorMessage(error) }
    }
}

/// A service that is not in the list: its name and address. An access token
/// is asked for only under Advanced, for services that hand one out.
struct CustomConnectorView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: ConnectorBrowser
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var advanced = false
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private var incomplete: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                    .accessibilityIdentifier("mcpConnectorName")
                TextField("https://example.com/mcp", text: $endpoint)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mcpConnectorEndpoint")
            } footer: {
                Text("The address of the service's MCP connector. If it needs your account, Keel opens its sign-in page.")
            }
            Section {
                DisclosureGroup("Advanced: access token", isExpanded: $advanced) {
                    SecureField("Access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("mcpConnectorToken")
                    Text("Only for a service that gave you a token instead of a sign-in page. It is kept in Keychain on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if busy {
                    HStack { ProgressView(); Text("Connecting…") }
                    Button("Cancel") { task?.cancel(); browser.cancel() }
                } else {
                    Button("Connect", action: connect)
                        .disabled(incomplete)
                        .accessibilityIdentifier("saveMCPConnector")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("mcpConnectorError") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .navigationTitle("Custom connector")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { token = "" }
    }

    private func connect() {
        guard !busy else { return }
        error = nil
        busy = true
        task = Task {
            do {
                try await chat.connect(name: name, endpoint: endpoint, token: token, browser: browser)
                token = ""
                busy = false
                dismiss()
            } catch is CancellationError {
                busy = false
            } catch {
                self.error = connectorMessage(error)
                busy = false
            }
        }
    }
}
