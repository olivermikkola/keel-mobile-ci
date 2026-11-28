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
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var computer: ComputerHostStore
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
                // Six rows, like ChatGPT's menu. Images, Videos, Carousels and
                // Decide live in Apps; About lives at the end of Customize.
                row("Library", "books.vertical", .library)
                row("Apps", "square.grid.2x2", .apps)
                row("Projects", "folder", .projects)
                row("Scheduled", "clock", .scheduled)
                row("Customize", "slider.horizontal.3", .customize)
                row("Connections", "network", .connections, badge: (hostConnected ? approvals : 0) + computer.pendingApprovalCount)
                if computer.isPaired {
                    separator
                    Button { open(.computerChat) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(computer.online ? KeelStyle.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(computer.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(computer.modelLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if computer.pendingApprovalCount > 0 {
                                Text("\(computer.pendingApprovalCount) approve")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            } else if computer.activeTurnCount > 0 {
                                Text("\(computer.activeTurnCount) running")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(KeelStyle.accent.opacity(0.2), in: Capsule())
                                    .foregroundStyle(KeelStyle.accent)
                            }
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .accessibilityIdentifier("sidebarComputerHost")
                    ForEach(computer.threads.prefix(3)) { item in
                        Button {
                            Task { await computer.openThread(id: item.id) }
                            open(.computerChat)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.pending_approvals > 0 ? Color.orange : item.status == "running" ? KeelStyle.accent : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(item.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
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
            KeelMark().frame(width: 26, height: 26)
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
        // Empty chats stay out of the list (except the one on screen); New chat reuses them.
        let kept = chat.tasks.filter { !$0.messages.isEmpty || $0.repository != nil || $0.id == chat.activeTaskID }
        let all = SavedTask.filter(kept, query: searchQuery)
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
            .layoutPriority(1)
            Spacer(minLength: 8)
            modelChip
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(KeelStyle.background)
    }

    /// The model chats run on, named rather than hidden behind an icon:
    /// running on this phone is the point of Keel. Tap to change it.
    private var modelChip: some View {
        let model = models.current
        let ready = model.isSystem || models.installed.contains(model.id)
        return Button { open(.models) } label: {
            HStack(spacing: 7) {
                Circle().fill(ready ? KeelStyle.accent : Color.secondary).frame(width: 7, height: 7)
                Text(ready ? model.name : "Choose a model")
                    .font(.footnote.monospaced()).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(KeelStyle.surface, in: Capsule())
            .overlay(Capsule().stroke(KeelStyle.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ready ? "Model, \(model.name)" : "Choose a model")
        .accessibilityHint("Opens Models")
        .accessibilityIdentifier("menu-models")
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

/// Apps: studios that make something from your photos or a question
/// (Images, Videos, Carousels, Decide), then the chat apps, each starting a
/// chat set up for one kind of work. A grid, not a settings list: the icon is
/// the choice.
struct AppsView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    let opened: () -> Void
    /// Opens a studio screen (Images, Videos, Carousels, Decide) in place of Apps.
    var openStudio: (ShellDestination) -> Void = { _ in }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Everything runs on this \(KeelDevice.name).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Make").font(.headline)
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(Studio.allCases, id: \.self) { studio in
                            Button { openStudio(studio.destination) } label: {
                                tile(studio.title, studio.symbol, studio.tint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(studio.title)
                            .accessibilityHint(studio.summary)
                            .accessibilityIdentifier("app-\(studio.destination.rawValue)")
                        }
                    }
                    Text("Chat apps").font(.headline)
                    Text("Each one is a chat with the tools for that job.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(AppPreset.allCases, id: \.self) { app in
                            Button {
                                if chat.newChat(app: app) { dismiss(); opened() }
                            } label: {
                                tile(app.title, tileSymbol(app), tileTint(app))
                            }
                            .buttonStyle(.plain)
                            .disabled(chat.running)
                            .accessibilityLabel(app.title)
                            .accessibilityHint(app.summary)
                            .accessibilityIdentifier("app-\(app.rawValue)")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("Apps")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    /// The screens that used to be menu rows. Each opens its own studio.
    enum Studio: CaseIterable {
        case images, videos, carousels, decide

        var destination: ShellDestination {
            switch self {
            case .images: return .images
            case .videos: return .videos
            case .carousels: return .carousels
            case .decide: return .decide
            }
        }

        var title: String {
            switch self {
            case .images: return "Images"
            case .videos: return "Videos"
            case .carousels: return "Carousels"
            case .decide: return "Decide"
            }
        }

        var summary: String {
            switch self {
            case .images: return "Make a picture from a sentence"
            case .videos: return "Turn photos and a sentence into a narrated video"
            case .carousels: return "Turn photos and a sentence into swipeable slides"
            case .decide: return "Answer the same questions across many documents"
            }
        }

        var symbol: String {
            switch self {
            case .images: return "photo.on.rectangle.angled"
            case .videos: return "film"
            case .carousels: return "square.stack"
            case .decide: return "checklist"
            }
        }

        var tint: Color {
            switch self {
            case .images: return Color(red: 0.88, green: 0.40, blue: 0.55)
            case .videos: return Color(red: 0.93, green: 0.36, blue: 0.30)
            case .carousels: return Color(red: 0.20, green: 0.66, blue: 0.80)
            case .decide: return Color(red: 0.80, green: 0.70, blue: 0.25)
            }
        }
    }

    /// Distinct colours so the grid reads as choices, not one repeated jade icon.
    private func tileTint(_ app: AppPreset) -> Color {
        switch app {
        case .websites: return Color(red: 0.30, green: 0.69, blue: 0.45)
        case .docs: return Color(red: 0.29, green: 0.52, blue: 0.93)
        case .slides: return Color(red: 0.92, green: 0.62, blue: 0.22)
        case .sheets: return Color(red: 0.22, green: 0.62, blue: 0.46)
        case .study: return Color(red: 0.55, green: 0.40, blue: 0.86)
        }
    }

    private func tileSymbol(_ app: AppPreset) -> String {
        switch app {
        case .websites: return "macwindow"
        case .docs: return "doc.fill"
        case .slides: return "rectangle.on.rectangle.angled"
        case .sheets: return "tablecells.fill"
        case .study: return "book.fill"
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
