import SwiftUI

struct PublishView: View {
    @ObservedObject var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkflowID: Int?
    @State private var confirmingPublish = false
    @State private var confirmingPullRequest = false

    private var selectedWorkflow: GitHubRepository.Workflow? {
        chat.publishWorkflows.first { $0.id == selectedWorkflowID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let state = chat.publishState {
                    status(state)
                } else {
                    ready
                }
                if chat.publishIsStale, chat.publishState != nil {
                    Section {
                        Label("Reviewed changes have changed since this publish. Publish again to create a new commit.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                        if chat.publishState?.prURL == nil {
                            Button("Publish current reviewed changes") { confirmingPublish = true }
                                .disabled(chat.publishing || chat.publishEdits.isEmpty)
                        } else {
                            Text("Start a new task for changes after opening a pull request.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = chat.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("publishError")
                    }
                }
                if let logs = chat.publishLogs {
                    Section("Failure logs") {
                        Text(logs).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("publishFailureLogs")
                    }
                }
            }
            .navigationTitle("Publish changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } .disabled(chat.publishing) } }
            .interactiveDismissDisabled(chat.publishing)
            .task {
                if chat.publishState == nil { chat.loadPublishWorkflows() }
                selectFirstWorkflow()
            }
            .onChange(of: chat.publishWorkflows) { _, _ in selectFirstWorkflow() }
            .alert("Publish reviewed changes to GitHub?", isPresented: $confirmingPublish) {
                Button("Publish and run CI") {
                    if let workflow = selectedWorkflow { chat.startPublish(workflow: workflow) }
                    else if chat.publishState != nil { chat.retryPublish() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Keel will create branch \(chat.publishBranch), commit the applied changes and dispatch the selected workflow. Nothing is opened as a pull request until CI passes on that exact commit.")
            }
            .alert("Open the pull request?", isPresented: $confirmingPullRequest) {
                Button("Open pull request") { chat.openPublishPullRequest() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("CI passed on the exact published commit. GitHub will receive the pull request for \(chat.publishBranch).")
            }
        }
    }

    private var ready: some View {
        Group {
            Section("Reviewed changes") {
                if chat.publishEdits.isEmpty {
                    Text("Apply at least one reviewed change before publishing.").foregroundStyle(.secondary)
                } else {
                    ForEach(chat.publishEdits) { edit in
                        HStack {
                            Image(systemName: Self.symbol(for: edit.kind)).foregroundStyle(KeelStyle.accent)
                            Text(edit.kind == .rename ? "\(edit.path) → \(edit.afterPath)" : edit.path)
                                .font(.subheadline).lineLimit(2)
                            Spacer()
                            Text(Self.label(for: edit.kind)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Publish to") {
                LabeledContent("Repository", value: chat.repository?.repository.fullName ?? "No repository")
                LabeledContent("Branch", value: chat.publishBranch)
                if let commit = chat.repository?.commit {
                    LabeledContent("Base commit", value: String(commit.prefix(12)))
                }
            }
            Section("CI workflow") {
                if chat.publishWorkflows.isEmpty {
                    if chat.publishing {
                        HStack { ProgressView(); Text("Loading workflows…") }
                    } else {
                        Text("No active GitHub Actions workflow found. Keel will not publish without CI.")
                            .foregroundStyle(.secondary)
                        Button("Reload workflows") { chat.loadPublishWorkflows() }
                            .disabled(chat.publishing)
                    }
                } else {
                    Picker("Workflow", selection: $selectedWorkflowID) {
                        ForEach(chat.publishWorkflows) { workflow in
                            Text(workflow.name).tag(Optional(workflow.id))
                        }
                    }
                    .accessibilityIdentifier("publishWorkflowPicker")
                }
                if let workflow = selectedWorkflow {
                    Text(workflow.path).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    confirmingPublish = true
                } label: {
                    HStack {
                        if chat.publishing { ProgressView() }
                        Text(chat.publishing ? "Publishing…" : "Publish and run CI")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(KeelStyle.accent)
                .disabled(chat.publishing || selectedWorkflow == nil || chat.publishEdits.isEmpty)
                .accessibilityIdentifier("publishChanges")
            } footer: {
                Text("This writes a branch and dispatches a GitHub Actions workflow. A pull request opens only after CI passes on the exact commit. CI continues on GitHub if you leave the app. The saved GitHub token needs Contents, Pull requests and Actions write access.")
            }
        }
    }

    private func status(_ state: PublishState) -> some View {
        Group {
            Section("Status") {
                Label(state.statusText, systemImage: statusImage(state.stage))
                    .foregroundStyle(state.stage == .ciFailed ? .orange : KeelStyle.accent)
                    .accessibilityIdentifier("publishStatus")
                LabeledContent("Repository", value: chat.repository?.repository.fullName ?? "Unknown")
                LabeledContent("Branch", value: state.branch)
                if let commit = state.commit {
                    LabeledContent("Commit", value: String(commit.prefix(12)))
                }
                LabeledContent("Workflow", value: state.workflowName)
                if let urlString = state.runURL, let url = URL(string: urlString) {
                    Link("Open CI run", destination: url)
                }
                if let urlString = state.prURL, let url = URL(string: urlString) {
                    Link("Open pull request", destination: url)
                }
            }
            Section {
                switch state.stage {
                case .ready, .pushed, .waitingForCI:
                    Button("Check CI status") { chat.checkPublish() }
                        .disabled(chat.publishing)
                case .ciPassed:
                    Button("Open pull request") { confirmingPullRequest = true }
                        .buttonStyle(.borderedProminent).tint(KeelStyle.accent)
                        .disabled(chat.publishing || chat.publishIsStale || !state.canOpenPullRequest)
                case .ciFailed:
                    Button("Read failure logs") { chat.loadPublishLogs() }
                        .disabled(chat.publishing)
                    Button("Retry with current reviewed changes") { chat.retryPublish() }
                        .disabled(chat.publishing || chat.publishEdits.isEmpty)
                case .published:
                    Label("Pull request opened — nothing else to do.", systemImage: "checkmark.seal")
                        .foregroundStyle(KeelStyle.accent)
                }
            }
            if chat.publishing {
                Section { HStack { ProgressView(); Text(chat.phase) } }
            }
        }
    }

    private func selectFirstWorkflow() {
        if selectedWorkflowID == nil { selectedWorkflowID = chat.publishWorkflows.first?.id }
    }

    private func statusImage(_ stage: PublishState.Stage) -> String {
        switch stage {
        case .ready: return "tray.and.arrow.up"
        case .pushed, .waitingForCI: return "clock"
        case .ciPassed: return "checkmark.seal"
        case .ciFailed: return "xmark.octagon"
        case .published: return "arrow.up.right.square"
        }
    }

    private static func symbol(for kind: FileEditKind) -> String {
        switch kind {
        case .replace: return "doc.text"
        case .create: return "doc.badge.plus"
        case .delete: return "trash"
        case .rename: return "arrow.right.doc.on.clipboard"
        }
    }

    private static func label(for kind: FileEditKind) -> String {
        switch kind {
        case .replace: return "edited"
        case .create: return "new file"
        case .delete: return "deleted"
        case .rename: return "renamed"
        }
    }
}
