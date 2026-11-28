import Foundation
import Security
import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Keychain storage for the QR-paired computer's bearer token and pinned TLS fingerprint.
enum ComputerHostKeychain {
    private static let tokenService = "com.olivermikkola.keelmobile.computerhost.token"
    private static let fpService = "com.olivermikkola.keelmobile.computerhost.fingerprint"
    private static let account = "primary"

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(service: String) -> String? {
        var req = query(service: service)
        req[kSecReturnData as String] = true
        req[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(req as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, service: String) throws {
        let attrs: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let lookup = query(service: service)
        let status = SecItemUpdate(lookup as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw NSError(domain: "ComputerHostKeychain", code: Int(status))
        }
        let addStatus = SecItemAdd(lookup.merging(attrs) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: "ComputerHostKeychain", code: Int(addStatus))
        }
    }

    private static func remove(service: String) {
        _ = SecItemDelete(query(service: service) as CFDictionary)
    }

    static func loadSecret() -> (token: String, fingerprint: String)? {
        guard let token = load(service: tokenService), !token.isEmpty,
              let fp = load(service: fpService), fp.count == 64 else { return nil }
        return (token, fp)
    }

    static func saveSecret(token: String, fingerprint: String) throws {
        try save(token, service: tokenService)
        try save(fingerprint.lowercased(), service: fpService)
    }

    static func clear() {
        remove(service: tokenService)
        remove(service: fpService)
    }
}

/// Manages a QR-paired Keel Desktop host completely independently of on-device `LocalChat`,
/// so heavy computer threads run in parallel while the iPhone stays free for local tiny-model work.
@MainActor
final class ComputerHostStore: ObservableObject {
    private static let profileKey = "keel.computerHostProfile.v1"

    @Published private(set) var profile: SavedComputerProfile?
    @Published private(set) var info: ComputerHostInfo?
    @Published private(set) var threads: [ComputerThreadSummary] = []
    @Published private(set) var activeThread: ComputerThreadDetail?
    @Published private(set) var schedules: [ComputerSchedule] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingThinking = ""
    @Published private(set) var activeToolLabel: String?
    @Published private(set) var busy = false
    @Published private(set) var online = false
    @Published var error: String?

    private var client: ComputerHostClient?
    private var streamTask: Task<Void, Never>?
    private var lastSeq: UInt64 = 0

    var isPaired: Bool { profile != nil }

    var pendingApprovalCount: Int {
        threads.reduce(0) { $0 + $1.pending_approvals }
    }

    var activeTurnCount: Int {
        threads.filter { $0.status == "running" || $0.status == "waiting_approval" }.count
    }

    var displayName: String {
        info?.host_name ?? profile?.hostName ?? "My Computer"
    }

    var modelLabel: String {
        if let name = info?.model_name, !name.isEmpty { return name }
        return online ? "Connected" : "Offline"
    }

    init() {
        restoreSavedPairing()
    }

    private func restoreSavedPairing() {
        guard let data = UserDefaults.standard.data(forKey: Self.profileKey),
              let saved = try? JSONDecoder().decode(SavedComputerProfile.self, from: data),
              let secret = ComputerHostKeychain.loadSecret() else {
            return
        }
        profile = saved
        client = try? ComputerHostClient(
            urls: saved.orderedURLs,
            fingerprint: secret.fingerprint,
            token: secret.token
        )
        Task { await refresh(silent: true) }
    }

    func pair(rawURI: String) async -> Bool {
        error = nil
        busy = true
        defer { busy = false }
        do {
            let bundle = try ComputerPairingBundle.parse(rawURI)
            let candidate = try ComputerHostClient(
                urls: bundle.urls,
                fingerprint: bundle.fingerprint,
                token: bundle.token
            )
            let fetchedInfo = try await candidate.info()
            try ComputerHostKeychain.saveSecret(token: bundle.token, fingerprint: bundle.fingerprint)
            let saved = SavedComputerProfile(
                hostName: fetchedInfo.host_name.isEmpty ? bundle.hostName : fetchedInfo.host_name,
                urls: bundle.urls,
                preferredURL: candidate.currentBaseURL
            )
            if let encoded = try? JSONEncoder().encode(saved) {
                UserDefaults.standard.set(encoded, forKey: Self.profileKey)
            }
            profile = saved
            client = candidate
            info = fetchedInfo
            online = true
            await refreshCollections()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func forget() {
        streamTask?.cancel()
        streamTask = nil
        ComputerHostKeychain.clear()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        profile = nil
        client = nil
        info = nil
        threads = []
        activeThread = nil
        schedules = []
        streamingText = ""
        streamingThinking = ""
        activeToolLabel = nil
        online = false
        error = nil
    }

    func refresh(silent: Bool = false) async {
        guard let client else {
            online = false
            return
        }
        if !silent { error = nil }
        do {
            let fetched = try await client.info()
            info = fetched
            online = true
            if var saved = profile, saved.preferredURL != client.currentBaseURL {
                saved.preferredURL = client.currentBaseURL
                profile = saved
                if let encoded = try? JSONEncoder().encode(saved) {
                    UserDefaults.standard.set(encoded, forKey: Self.profileKey)
                }
            }
            await refreshCollections()
        } catch {
            online = false
            if !silent { self.error = error.localizedDescription }
        }
    }

    private func refreshCollections() async {
        guard let client else { return }
        if let list = try? await client.listThreads() {
            threads = list
        }
        if let scheds = try? await client.listSchedules() {
            schedules = scheds
        }
    }

    func createThread(preset: String = "chat", title: String? = nil) async -> ComputerThreadDetail? {
        guard let client else {
            error = ComputerHostError.notPaired.localizedDescription
            return nil
        }
        error = nil
        do {
            let created = try await client.createThread(title: title, appPreset: preset)
            activeThread = created
            streamingText = ""
            streamingThinking = ""
            activeToolLabel = nil
            lastSeq = created.latest_seq
            await refreshCollections()
            return created
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func openThread(id: String) async {
        guard let client else { return }
        streamTask?.cancel()
        streamTask = nil
        error = nil
        streamingText = ""
        streamingThinking = ""
        activeToolLabel = nil
        do {
            let detail = try await client.threadDetail(id: id)
            activeThread = detail
            lastSeq = detail.latest_seq
            if detail.status == "running" || detail.status == "waiting_approval" {
                attachEventStream(threadID: detail.id, afterSeq: 0)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(prompt: String, preset: String = "chat", enableThinking: Bool = false) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client else {
            error = ComputerHostError.notPaired.localizedDescription
            return
        }
        error = nil
        var thread = activeThread
        if thread == nil {
            thread = await createThread(preset: preset)
        }
        guard let target = thread else { return }
        streamingText = ""
        streamingThinking = ""
        activeToolLabel = nil
        do {
            let reply = try await client.sendMessage(threadID: target.id, prompt: trimmed, enableThinking: enableThinking)
            if let refreshed = try? await client.threadDetail(id: target.id) {
                activeThread = refreshed
            }
            attachEventStream(threadID: target.id, afterSeq: reply.after_seq)
            await refreshCollections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stopActiveTurn() async {
        guard let client, let id = activeThread?.id else { return }
        streamTask?.cancel()
        streamTask = nil
        do {
            try await client.cancelThread(id: id)
            if let detail = try? await client.threadDetail(id: id) {
                activeThread = detail
            }
            streamingText = ""
            streamingThinking = ""
            activeToolLabel = nil
            await refreshCollections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func respondApproval(_ approval: ComputerApproval, decision: String) async {
        guard let client, let id = activeThread?.id else { return }
        do {
            try await client.respondApproval(threadID: id, approvalID: approval.id, decision: decision)
            if let detail = try? await client.threadDetail(id: id) {
                activeThread = detail
            }
            await refreshCollections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resolveEdit(_ edit: ComputerStagedEdit, action: String) async {
        guard let client, let id = activeThread?.id else { return }
        do {
            try await client.resolveEdit(threadID: id, editID: edit.id, action: action)
            if let detail = try? await client.threadDetail(id: id) {
                activeThread = detail
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createSchedule(
        name: String,
        prompt: String,
        preset: String = "chat",
        intervalMinutes: UInt64 = 60,
        repeatEnabled: Bool = true,
        watchPath: String? = nil
    ) async -> Bool {
        guard let client else {
            error = ComputerHostError.notPaired.localizedDescription
            return false
        }
        error = nil
        do {
            _ = try await client.createSchedule(
                name: name,
                prompt: prompt,
                appPreset: preset,
                intervalMinutes: intervalMinutes,
                repeatEnabled: repeatEnabled,
                watchPath: watchPath
            )
            await refreshCollections()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteSchedule(id: String) async {
        guard let client else { return }
        do {
            try await client.deleteSchedule(id: id)
            await refreshCollections()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runScheduleNow(id: String) async -> String? {
        guard let client else { return nil }
        do {
            let tid = try await client.runScheduleNow(id: id)
            await openThread(id: tid)
            await refreshCollections()
            return tid
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func attachEventStream(threadID: String, afterSeq: UInt64) {
        #if !os(Linux)
        guard let client else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in client.streamEvents(threadID: threadID, afterSeq: afterSeq) {
                    if Task.isCancelled { break }
                    self.lastSeq = max(self.lastSeq, frame.seq)
                    self.handleFrame(frame, threadID: threadID)
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
            if !Task.isCancelled, self.activeThread?.id == threadID {
                if let detail = try? await client.threadDetail(id: threadID) {
                    self.activeThread = detail
                }
                self.streamingText = ""
                self.streamingThinking = ""
                self.activeToolLabel = nil
                await self.refreshCollections()
            }
        }
        #endif
    }

    private func handleFrame(_ frame: ComputerSSEFrame, threadID: String) {
        guard activeThread?.id == threadID,
              let data = frame.data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        switch frame.event {
        case "text":
            if let chunk = obj["text"] as? String {
                streamingText += chunk
            }
        case "thinking":
            if let chunk = obj["text"] as? String {
                streamingThinking += chunk
            }
        case "tool_start":
            if let name = obj["name"] as? String {
                activeToolLabel = "Running \(name)…"
            }
        case "tool_result":
            activeToolLabel = nil
        case "approval_request", "approval_resolved", "staged_edit":
            Task {
                if let detail = try? await client?.threadDetail(id: threadID) {
                    self.activeThread = detail
                }
                await self.refreshCollections()
            }
        case "status":
            if let status = obj["status"] as? String {
                if status == "error", let msg = obj["error"] as? String, !msg.isEmpty {
                    error = msg
                }
                if status == "done" || status == "error" || status == "idle" {
                    activeToolLabel = nil
                }
            }
        default:
            break
        }
    }
}
