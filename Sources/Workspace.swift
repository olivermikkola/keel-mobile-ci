import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    @Published var address: String
    @Published var token: String
    @Published var status: GatewayStatus?
    @Published var approvals: [Approval] = []
    @Published var output = "Command output will appear here."
    @Published var diff = "Refresh to inspect the workspace diff."
    @Published var error: String?
    @Published var busy = false
    private var gateway: Gateway?
    private var savedAddress: String

    init() {
        let saved = UserDefaults.standard.string(forKey: "gatewayAddress") ?? ""
        address = saved
        savedAddress = saved
        token = PairingKeychain.load(address: saved)
        #if DEBUG && targetEnvironment(simulator)
        // Rendering/navigation fixture only. No client, credential or host
        // command is created; device builds cannot activate it.
        if ProcessInfo.processInfo.arguments.contains("--connected-host-fixture") {
            status = GatewayStatus(status: "Connected UI fixture", execution_mode: "host",
                                   workspace_path: "/fixture/workspace", workspace_safe: true, approval_policy: "explicit")
        }
        #endif
    }

    func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        gateway = nil
        status = nil
        approvals = []
        output = "Command output will appear here."
        diff = "Refresh to inspect the workspace diff."
        do {
            let client = try Gateway(address: address, token: token)
            let connected = try await client.status()
            let canonical = client.baseURL.absoluteString
            try PairingKeychain.save(token: token.trimmingCharacters(in: .whitespacesAndNewlines), address: canonical)
            if !savedAddress.isEmpty && savedAddress != canonical {
                try PairingKeychain.remove(address: savedAddress)
            }
            address = canonical
            savedAddress = canonical
            UserDefaults.standard.set(canonical, forKey: "gatewayAddress")
            gateway = client
            status = connected
            approvals = try await client.approvals()
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        gateway = nil
        status = nil
        approvals = []
        output = "Command output will appear here."
        diff = "Refresh to inspect the workspace diff."
    }

    func forget() {
        do {
            try PairingKeychain.remove(address: savedAddress)
            disconnect()
            token = ""
            address = ""
            savedAddress = ""
            UserDefaults.standard.removeObject(forKey: "gatewayAddress")
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        await perform { client in
            self.status = try await client.status()
            self.approvals = try await client.approvals()
        }
    }

    func loadDiff() async {
        await perform { self.diff = try await $0.diff() }
    }

    func execute(command: String, pty: Bool) async {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform { client in
            self.show(try await client.execute(command, pty: pty))
            self.approvals = try await client.approvals()
        }
    }

    func decide(_ approval: Approval, approved: Bool) async {
        await perform { client in
            self.show(try await client.decide(approval, approved: approved))
            self.approvals = try await client.approvals()
        }
    }

    private func show(_ reply: ExecutionReply) {
        if let result = reply.result { output = result.display }
        else if reply.status == "pending_approval" { output = "Waiting for your decision in Approvals." }
        else { output = reply.error ?? "Request: \(reply.status)" }
    }

    private func perform(_ operation: (Gateway) async throws -> Void) async {
        guard !busy, let client = gateway else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await operation(client) }
        catch { self.error = error.localizedDescription }
    }
}
