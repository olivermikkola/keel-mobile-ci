import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

struct MCPConnectorsView: View {
    @EnvironmentObject private var chat: LocalChat
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Add Model Context Protocol (MCP) servers for external services. A connector's tools are loaded only in chats where you switch it on, keeping small-model prompts short.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved connectors") {
                if chat.connectors.isEmpty {
                    Text("No MCP connectors added yet.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("emptyMCPConnectors")
                }
                ForEach(chat.connectors) { server in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { chat.isConnectorEnabled(server.id) },
                            set: { _ = chat.setConnectorEnabled(server.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.headline)
                                Text(server.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s") · \(server.tools.map(\.remoteName).joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(chat.running || chat.repository != nil || chat.activeApp != nil)
                        .accessibilityIdentifier("toggleMCPConnector-\(server.id)")

                        HStack {
                            if MCPConnectorCredential.contains(serverID: server.id) {
                                Label("Token saved in Keychain", systemImage: "key.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                do {
                                    try chat.removeConnector(server.id)
                                    error = nil
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                            .font(.caption)
                            .disabled(chat.running || busy)
                            .accessibilityIdentifier("removeMCPConnector-\(server.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Add MCP connector") {
                TextField("Service name (e.g. Notion, Linear)", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcpConnectorName")
                TextField("https://mcp.example.com/rpc", text: $endpoint)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcpConnectorEndpoint")
                SecureField("Bearer token (optional, saved in Keychain)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mcpConnectorToken")
                Button(busy ? "Saving…" : "Save connector") {
                    saveConnector()
                }
                .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveMCPConnector")
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.orange).accessibilityIdentifier("mcpConnectorError")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .navigationTitle("MCP connectors")
    }

    private func saveConnector() {
        do {
            let slug = try MCPConnector.slug(for: name)
            let url = try MCPConnector.validateEndpoint(endpoint)
            let defaultTool = MCPConnector.Tool(
                remoteName: "query",
                callName: MCPConnector.callName(serverID: slug, remoteToolName: "query") ?? "mcp_\(slug)_query",
                description: "Query \(name.trimmingCharacters(in: .whitespacesAndNewlines)) via MCP.",
                parameters: [MCPConnector.Parameter(name: "query", type: "string", description: "Request query", required: true)]
            )
            let existingTools = chat.connectors.first(where: { $0.id == slug })?.tools
            let server = MCPConnector.Server(
                id: slug,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: url.absoluteString,
                tools: (existingTools?.isEmpty == false) ? existingTools! : [defaultTool]
            )
            let saved = try chat.saveConnector(server, token: token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token)
            _ = chat.setConnectorEnabled(saved.id, enabled: true)
            name = ""
            endpoint = ""
            token = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
