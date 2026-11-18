import SwiftUI

/// Project IDs pinned to the menu, between the feature rows and the chats.
enum PinnedProjects {
    static let key = "pinnedProjectIDs"
    static func ids(_ raw: String) -> [UUID] { raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
    static func toggled(_ id: UUID, in raw: String) -> String {
        var list = ids(raw)
        if let index = list.firstIndex(of: id) { list.remove(at: index) } else { list.append(id) }
        return list.map(\.uuidString).joined(separator: ",")
    }
}

/// The menu that slides in over the chat: one row per feature, pinned
/// projects, then recent chats by title. Laid out like ChatGPT's menu.
struct SidebarView: View {
    @EnvironmentObject private var chat: LocalChat
    let hostConnected: Bool
    let approvals: Int
    let open: (ShellDestination) -> Void
    let close: () -> Void
    @AppStorage(PinnedProjects.key) private var pinnedRaw = ""
    @State private var action: ChatAction?
    @State private var name = ""
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var showAll = false
    @State private var openProject: ChatProject?
    @FocusState private var searchFocused: Bool

    /// Recent chats shown before "See all".
    static let recentLimit = 8

    private enum ChatAction {
        case rename(SavedTask), delete(SavedTask), reset

        var title: String {
            switch self {
            case .rename: return "Rename chat"
            case .delete(let task): return "Delete \(task.title)?"
            case .reset: return "Reset unreadable saved chats?"
            }
        }

        var message: String {
            switch self {
            case .rename: return "Use up to 80 characters."
            case .delete: return "This removes the conversation and its files from this device."
            case .reset: return "A protected recovery copy is kept on this device before starting an empty chat list."
            }
        }
    }

    private var pinned: [ChatProject] {
        PinnedProjects.ids(pinnedRaw).compactMap { id in chat.projects.first { $0.id == id } }
    }

    var body: some View {
        List {
            header
            if searching {
                searchField
            } else {
                row("Scheduled", "clock", .scheduled)
                row("Library", "books.vertical", .library)
                row("Images", "photo.on.rectangle.angled", .images)
                row("Decide", "checklist", .decide)
                row("Apps", "square.grid.2x2", .apps)
                row("Projects", "folder", .projects)
                row("Customize", "slider.horizontal.3", .customize)
                row("Connections", "network", .connections, badge: hostConnected ? approvals : 0)
                if !pinned.isEmpty {
                    separator
                    ForEach(pinned) { project in
                        Button { openProject = project } label: {
                            Label(project.name, systemImage: "pin").foregroundStyle(.primary)
                        }
                        .contextMenu { Button("Unpin") { pinnedRaw = PinnedProjects.toggled(project.id, in: pinnedRaw) } }
                        .accessibilityIdentifier("pinnedProject-\(project.name)")
                    }
                }
            }
            separator
            if chat.storageUnreadable {
                Text("Your saved chats could not be opened. The original file has been kept unchanged.")
                Button("Reset saved chats", role: .destructive) { action = .reset }
            } else {
                recents
            }
            if let error = chat.error {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 40)
        .scrollContentBackground(.hidden)
        .background(KeelStyle.background)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(item: $openProject) { project in
            ProjectView(projectID: project.id, opened: close)
        }
        .alert(action?.title ?? "Chat", isPresented: Binding(
            get: { action != nil }, set: { if !$0 { action = nil } }
        )) {
            if let action {
                switch action {
                case .rename(let task):
                    TextField("Chat name", text: $name).accessibilityIdentifier("savedTaskName")
                    Button("Save") { chat.renameTask(task.id, title: name); self.action = nil }
                case .delete(let task):
                    Button("Delete chat", role: .destructive) { chat.deleteTask(task.id); self.action = nil }
                case .reset:
                    Button("Keep recovery copy and reset", role: .destructive) {
                        chat.resetUnreadableStorage(); self.action = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { action = nil }
        } message: { Text(action?.message ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Keel").font(.title.weight(.semibold))
            Spacer()
            Button {
                withAnimation { searching.toggle() }
                if searching { searchFocused = true } else { searchQuery = "" }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.body.weight(.medium)).frame(width: 44, height: 44)
                    .background(KeelStyle.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searching ? "Close search" : "Search chats")
            .accessibilityIdentifier("sidebarSearch")
        }
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .padding(.vertical, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $searchQuery)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sidebarSearchField")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(KeelStyle.surface, in: Capsule())
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    @ViewBuilder private var recents: some View {
        let all = SavedTask.filter(chat.tasks, query: searchQuery)
        let shown = searching || showAll ? all : Array(all.prefix(Self.recentLimit))
        if all.isEmpty {
            Text(searching ? "No matching chats" : "No chats yet")
                .font(.subheadline).foregroundStyle(.secondary)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        ForEach(shown) { task in
            Button {
                if chat.selectTask(task.id) { close() }
            } label: {
                Text(task.shownTitle).lineLimit(1).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(chat.running)
            .listRowSeparator(.hidden)
            .listRowBackground(RoundedRectangle(cornerRadius: 12)
                .fill(task.id == chat.activeTaskID ? KeelStyle.surface : Color.clear).padding(.horizontal, 8))
            .accessibilityIdentifier("savedTask-\(task.title)")
            .accessibilityValue(task.id == chat.activeTaskID ? "Current chat" : "")
            .contextMenu {
                Button { name = task.title; action = .rename(task) } label: { Label("Rename", systemImage: "pencil") }
                if task.repository == nil, !chat.projects.isEmpty {
                    Menu("Move to project") {
                        ForEach(chat.projects) { project in
                            Button(project.name) { _ = chat.moveTask(task.id, to: project) }
                        }
                        if task.projectID != nil { Button("No project") { _ = chat.moveTask(task.id, to: nil) } }
                    }
                }
                Button(role: .destructive) { action = .delete(task) } label: { Label("Delete", systemImage: "trash") }
            }
        }
        if !searching, all.count > Self.recentLimit {
            Button(showAll ? "Show fewer" : "See all…") { withAnimation { showAll.toggle() } }
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .accessibilityIdentifier("seeAllChats")
        }
    }

    private var footer: some View {
        HStack {
            Button { if chat.newChat() { close() } } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .foregroundStyle(KeelStyle.background)
                    .background(KeelStyle.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(chat.running || chat.storageUnreadable)
            .accessibilityIdentifier("createSavedTask")
            Spacer()
            Button { open(.models) } label: {
                Image(systemName: "square.stack.3d.up").font(.body.weight(.medium))
                    .frame(width: 48, height: 48)
                    .background(KeelStyle.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Models")
            .accessibilityIdentifier("menu-models")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(KeelStyle.background)
    }

    private var separator: some View {
        Rectangle().fill(KeelStyle.hairline).frame(height: 1)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private func row(_ title: String, _ icon: String, _ target: ShellDestination, badge: Int = 0) -> some View {
        Button { open(target) } label: {
            Label(title, systemImage: icon).font(.body.weight(.medium)).foregroundStyle(.primary)
        }
        .badge(badge)
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .accessibilityIdentifier("menu-\(target.rawValue)")
    }
}

/// The five apps, each starting a chat set up for one kind of work.
struct AppsView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    let opened: () -> Void

    var body: some View {
        NavigationStack {
            List(AppPreset.allCases, id: \.self) { app in
                Button { if chat.newChat(app: app) { dismiss(); opened() } } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.title).foregroundStyle(.primary)
                            Text(app.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: app.symbol).foregroundStyle(KeelStyle.accent) }
                }
                .disabled(chat.running)
                .listRowBackground(KeelStyle.surface)
                .accessibilityIdentifier("app-\(app.rawValue)")
            }
            .scrollContentBackground(.hidden).background(KeelStyle.background)
            .navigationTitle("Apps")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// All projects, a way to make one, and pinning to the menu.
struct ProjectsView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    let opened: () -> Void
    @AppStorage(PinnedProjects.key) private var pinnedRaw = ""
    @State private var openProject: ChatProject?
    @State private var newProject = false
    @State private var projectName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { projectName = ""; newProject = true } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                }
                .disabled(chat.running)
                .listRowBackground(KeelStyle.surface)
                .accessibilityIdentifier("createProject")
                if chat.projects.isEmpty {
                    Text("A project gives its chats shared instructions and files.").foregroundStyle(.secondary)
                }
                ForEach(chat.projects) { project in
                    let isPinned = PinnedProjects.ids(pinnedRaw).contains(project.id)
                    Button { openProject = project } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).foregroundStyle(.primary)
                                let count = chat.chats(in: project).count
                                Text("\(count) chat\(count == 1 ? "" : "s") · \(project.files.count) file\(project.files.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: isPinned ? "pin.fill" : "folder").foregroundStyle(KeelStyle.accent) }
                    }
                    .listRowBackground(KeelStyle.surface)
                    .accessibilityIdentifier("project-\(project.name)")
                    .swipeActions(edge: .leading) {
                        Button(isPinned ? "Unpin" : "Pin") { pinnedRaw = PinnedProjects.toggled(project.id, in: pinnedRaw) }
                            .tint(KeelStyle.accent)
                    }
                    .contextMenu {
                        Button(isPinned ? "Unpin from menu" : "Pin to menu") { pinnedRaw = PinnedProjects.toggled(project.id, in: pinnedRaw) }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(KeelStyle.background)
            .navigationTitle("Projects")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $openProject) { project in
                ProjectView(projectID: project.id) { dismiss(); opened() }
            }
            .alert("New project", isPresented: $newProject) {
                TextField("Project name", text: $projectName).accessibilityIdentifier("newProjectName")
                Button("Create") {
                    if let project = chat.createProject(name: projectName) { openProject = project }
                }.accessibilityIdentifier("confirmCreateProject")
                Button("Cancel", role: .cancel) {}
            } message: { Text("A project gives its chats shared instructions and files.") }
        }
    }
}
