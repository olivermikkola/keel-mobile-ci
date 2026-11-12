import SwiftUI

struct SavedTasksView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
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
            if chat.storageUnreadable {
                Section {
                    Text("Your saved tasks could not be opened. The original file has been kept unchanged.")
                    Button("Reset saved tasks", role: .destructive) { action = .reset }
                    Text("Reset keeps a protected recovery copy on this device before starting an empty task list.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button { if chat.newChat() { dismiss() } } label: {
                        Label("New task", systemImage: "square.and.pencil")
                    }.accessibilityIdentifier("createSavedTask")
                    Text("Conversations and pinned repository versions stay on this device. Opening a task never restarts a reply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("On this device") {
                    ForEach(chat.tasks.sorted { $0.updatedAt > $1.updatedAt }) { task in
                        HStack(alignment: .top) {
                            Button {
                                if chat.selectTask(task.id) { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(task.title).font(.headline).foregroundStyle(.primary)
                                        if task.id == chat.activeTaskID {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(KeelStyle.accent)
                                                .accessibilityLabel("Current task")
                                        }
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
                }
            }
            if let error = chat.error {
                Section { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .disabled(chat.running)
        .navigationTitle("Saved tasks")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
}
