import SwiftUI

/// The menu that slides in over the chat: where to go, and recent chats.
struct SidebarView: View {
    @EnvironmentObject private var chat: LocalChat
    let hostConnected: Bool
    let approvals: Int
    let open: (ShellDestination) -> Void
    let close: () -> Void
    @State private var action: TaskAction?
    @State private var name = ""

    private enum TaskAction {
        case rename(SavedTask), delete(SavedTask), reset

        var title: String {
            switch self {
            case .rename: return "Rename task"
            case .delete(let task): return "Delete \(task.title)?"
            case .reset: return "Reset unreadable saved tasks?"
            }
        }

        var message: String {
            switch self {
            case .rename: return "Use up to 80 characters."
            case .delete: return "This removes the saved conversation and its repository context from this device."
            case .reset: return "A protected recovery copy is kept on this device before starting an empty task list."
            }
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    KeelMark().frame(width: 28, height: 28)
                    Text("Keel").font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").padding(6) }
                        .buttonStyle(.plain).accessibilityLabel("Close menu")
                }
                row("Models", "square.stack.3d.up", .models)
                row("Connections", "network", .connections)
                if hostConnected {
                    row("Host workspace", "terminal", .hostWorkspace)
                    row("Host approvals", "checkmark.shield", .hostApprovals).badge(approvals)
                }
            }.listRowBackground(KeelStyle.surface)
            if chat.storageUnreadable {
                Section {
                    Text("Your saved tasks could not be opened. The original file has been kept unchanged.")
                    Button("Reset saved tasks", role: .destructive) { action = .reset }
                    Text("Reset keeps a protected recovery copy on this device before starting an empty task list.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button { if chat.newChat() { close() } } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }.accessibilityIdentifier("createSavedTask")
                }.disabled(chat.running)
                Section("Apps") {
                    ForEach(AppPreset.allCases, id: \.self) { app in
                        Button { if chat.newChat(app: app) { close() } } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.title).foregroundStyle(.primary)
                                    Text(app.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: app.symbol).foregroundStyle(KeelStyle.accent) }
                        }.accessibilityIdentifier("app-\(app.rawValue)")
                    }
                }.disabled(chat.running)
                Section("Recents") {
                    ForEach(chat.tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
                        HStack(alignment: .top) {
                            Button {
                                if chat.selectTask(task.id) { close() }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(task.title).font(.headline).foregroundStyle(.primary)
                                        if task.id == chat.activeTaskID {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(KeelStyle.accent)
                                                .accessibilityLabel("Current task")
                                        }
                                    }
                                    if let app = task.app, task.repository == nil {
                                        Label(app.title, systemImage: app.symbol).font(.caption).foregroundStyle(KeelStyle.accent)
                                    }
                                    if let repository = task.repository {
                                        Text("\(repository.repository.fullName) · \(repository.commit.prefix(7))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(task.status).font(.caption).foregroundStyle(.secondary)
                                    Text(task.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("savedTask-\(task.title)")
                            Menu {
                                Button("Rename") { name = task.title; action = .rename(task) }
                                Button("Delete", role: .destructive) { action = .delete(task) }
                            } label: { Image(systemName: "ellipsis").padding(8) }
                                .accessibilityLabel("Task options: \(task.title)")
                        }.padding(.vertical, 4)
                    }
                    Text("Chats stay on this device. Opening one never restarts a reply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(chat.running)
            }
            if let error = chat.error {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .alert(action?.title ?? "Saved task", isPresented: Binding(
            get: { action != nil }, set: { if !$0 { action = nil } }
        )) {
            if let action {
                switch action {
                case .rename(let task):
                    TextField("Task name", text: $name).accessibilityIdentifier("savedTaskName")
                    Button("Save") { chat.renameTask(task.id, title: name); self.action = nil }
                case .delete(let task):
                    Button("Delete task", role: .destructive) { chat.deleteTask(task.id); self.action = nil }
                case .reset:
                    Button("Keep recovery copy and reset", role: .destructive) {
                        chat.resetUnreadableStorage(); self.action = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { action = nil }
        } message: { Text(action?.message ?? "") }
    }

    private func row(_ title: String, _ icon: String, _ target: ShellDestination) -> some View {
        Button { open(target) } label: {
            Label(title, systemImage: icon).foregroundStyle(.primary)
        }.accessibilityIdentifier("menu-\(target.rawValue)")
    }
}
