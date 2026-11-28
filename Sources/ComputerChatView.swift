import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Dedicated chat view for a thread running on the user's QR-paired computer (e.g. Inkling 2 Mini).
/// Runs completely in parallel with Keel Mobile's on-device local chat so the phone stays free.
struct ComputerChatView: View {
    @EnvironmentObject private var computer: ComputerHostStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var preset = "chat"
    @State private var thinking = false
    @State private var showingThreads = false

    private var isRunning: Bool {
        guard let status = computer.activeThread?.status else { return false }
        return status == "running" || status == "waiting_approval"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBanner
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if let thread = computer.activeThread {
                                ForEach(thread.messages) { msg in
                                    messageBubble(msg)
                                }
                                if !computer.streamingThinking.isEmpty {
                                    Text(computer.streamingThinking)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                                }
                                if let toolLabel = computer.activeToolLabel {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text(toolLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !computer.streamingText.isEmpty {
                                    Text(computer.streamingText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                                }
                                ForEach(thread.pending_approvals) { approval in
                                    approvalCard(approval)
                                }
                                ForEach(thread.staged_edits.filter { $0.status.lowercased() == "pending" }) { edit in
                                    editCard(edit)
                                }
                            } else {
                                emptyState
                            }
                            Color.clear.frame(height: 1).id("computer-bottom")
                        }
                        .padding()
                    }
                    .onChange(of: computer.streamingText) { _, _ in
                        withAnimation { proxy.scrollTo("computer-bottom", anchor: .bottom) }
                    }
                    .onChange(of: computer.activeThread?.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("computer-bottom", anchor: .bottom) }
                    }
                }
                if let error = computer.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).font(.footnote)
                        Spacer()
                        Button { computer.error = nil } label: { Image(systemName: "xmark") }
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                composerBar
            }
            .background(KeelStyle.background)
            .navigationTitle(computer.activeThread?.title ?? computer.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingThreads = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Computer threads")
                    Button {
                        Task { _ = await computer.createThread(preset: preset) }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New computer chat")
                }
            }
            .sheet(isPresented: $showingThreads) {
                NavigationStack {
                    List {
                        ForEach(computer.threads) { item in
                            Button {
                                showingThreads = false
                                Task { await computer.openThread(id: item.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).foregroundStyle(.primary).lineLimit(1)
                                        Text("\(item.app_preset.capitalized) · \(item.message_count) msgs")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    statusPill(item.status, approvals: item.pending_approvals)
                                }
                            }
                            .listRowBackground(KeelStyle.surface)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(KeelStyle.background)
                    .navigationTitle(computer.displayName)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingThreads = false }
                        }
                    }
                }
            }
            .task {
                await computer.refresh(silent: true)
            }
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(computer.online ? KeelStyle.accent : .orange)
                .frame(width: 8, height: 8)
            Text("\(computer.displayName) · \(computer.modelLabel)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer()
            if computer.activeThread == nil || computer.activeThread?.messages.isEmpty == true {
                Menu {
                    Button("Chat") { preset = "chat" }
                    Button("Work") { preset = "general" }
                    Button("Code") { preset = "code" }
                } label: {
                    Text(preset == "general" ? "Work" : preset.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(KeelStyle.surface, in: Capsule())
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(KeelStyle.surface.opacity(0.6))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Running on \(computer.displayName)", systemImage: "desktopcomputer")
                .font(.headline)
            Text("Send a heavy coding, research, or everyday task to \(computer.modelLabel). You can close this screen and keep using your \(KeelDevice.name)’s local model while your computer works in the background.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func messageBubble(_ msg: ComputerMessage) -> some View {
        let isUser = msg.role == "user"
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if let thinkingText = msg.thinking, !thinkingText.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(thinkingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Text(msg.content)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    isUser ? KeelStyle.accent.opacity(0.22) : KeelStyle.surface,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private func approvalCard(_ approval: ComputerApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval needed: \(approval.tool)", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(approval.summary)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Allow once") {
                    Task { await computer.respondApproval(approval, decision: "allow_once") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Always") {
                    Task { await computer.respondApproval(approval, decision: "allow_always") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Deny", role: .destructive) {
                    Task { await computer.respondApproval(approval, decision: "deny") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.5)))
    }

    private func editCard(_ edit: ComputerStagedEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(edit.path, systemImage: "doc.badge.gearshape")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("+\(edit.added_lines) -\(edit.removed_lines)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(edit.diff)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(8)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Apply") {
                    Task { await computer.resolveEdit(edit, action: "apply") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Discard", role: .destructive) {
                    Task { await computer.resolveEdit(edit, action: "discard") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var composerBar: some View {
        HStack(spacing: 8) {
            Button {
                thinking.toggle()
            } label: {
                Image(systemName: thinking ? "brain.head.profile.fill" : "brain.head.profile")
                    .foregroundStyle(thinking ? KeelStyle.accent : .secondary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(thinking ? "Thinking on" : "Thinking off")
            TextField("Ask \(computer.displayName)…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            if isRunning {
                Button {
                    Task { await computer.stopActiveTurn() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel("Stop computer task")
            } else {
                Button {
                    let text = draft
                    draft = ""
                    Task { await computer.send(prompt: text, preset: preset, enableThinking: thinking) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : KeelStyle.accent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send to computer")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(KeelStyle.background)
    }

    @ViewBuilder
    private func statusPill(_ status: String, approvals: Int) -> some View {
        if approvals > 0 || status == "waiting_approval" {
            Text("Needs approval")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        } else if status == "running" {
            Text("Running")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(KeelStyle.accent.opacity(0.2), in: Capsule())
                .foregroundStyle(KeelStyle.accent)
        } else if status == "error" {
            Text("Error")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.2), in: Capsule())
                .foregroundStyle(.red)
        }
    }
}
