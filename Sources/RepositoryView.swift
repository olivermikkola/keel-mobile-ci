import SwiftUI

struct RepositoryView: View {
    var onSelect: ((RepositorySnapshot) -> Void)? = nil
    @State private var address = UserDefaults.standard.string(forKey: "githubRepository") ?? ""
    @State private var branch = UserDefaults.standard.string(forKey: "githubBranch") ?? ""
    @State private var token = ""
    @StateObject private var connection = GitHubConnection()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var manual = false
    @State private var advanced = false
    @State private var snapshot: RepositorySnapshot?
    @State private var client: GitHubRepository?
    @State private var operation: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        Form {
            if snapshot == nil {
                Section {
                    if let user = connection.user {
                        Label("Connected as \(user.login)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.mint).accessibilityElement(children: .ignore)
                            .accessibilityLabel("Connected as \(user.login)").accessibilityIdentifier("githubConnectedAccount")
                        Button("Refresh repositories") { connection.reload() }.disabled(connection.working)
                        if let url = connection.installURL {
                            Button("Choose repositories on GitHub") { openURL(url) }
                        }
                        Button("Disconnect GitHub", role: .destructive) { connection.disconnect() }
                            .disabled(connection.working)
                    } else {
                        Text("Choose a repository from your GitHub account.").foregroundStyle(.secondary)
                        Button { connection.signIn() } label: {
                            Label("Connect GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        }.accessibilityIdentifier("githubSignIn")
                            .disabled(connection.working)
                        Text("Sign in on GitHub, choose which repositories Keel can access, then return here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if connection.working {
                        HStack { ProgressView(); Text(connection.user == nil ? "Connecting to GitHub…" : "Loading repositories…") }
                        Button("Cancel") { connection.cancel() }
                    }
                    if let error = connection.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        Button("Try again") { connection.hasCredential ? connection.reload() : connection.signIn() }
                    }
                } header: { Text("GitHub account") }
                if connection.user != nil {
                    Section("Your repositories") {
                        TextField("Find a repository", text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("githubRepositorySearch")
                        ForEach(connection.repositories.filter { search.isEmpty || $0.full_name.localizedCaseInsensitiveContains(search) }) { repo in
                            Button {
                                address = repo.full_name; branch = repo.default_branch; token = ""; open()
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: repo.private ? "lock.fill" : "folder")
                                    Text(repo.full_name).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }.accessibilityIdentifier("githubRepositoryChoice-\(repo.id)")
                        }.disabled(operation != nil || connection.working)
                        if connection.repositories.isEmpty && !connection.working {
                            Text("No repositories are available yet. Choose repository access on GitHub, then refresh.")
                                .foregroundStyle(.secondary)
                            if let url = connection.installURL { Button("Choose repositories on GitHub") { openURL(url) } }
                        }
                        if connection.canLoadMore { Button("Load more repositories") { connection.loadMore() }.disabled(connection.working) }
                    }
                }
                Section {
                    // An explicit toggle keeps the section identifier from
                    // overwriting the two child text-field identifiers.
                    Button {
                        manual.toggle()
                    } label: {
                        HStack {
                            Text("Open a repository by URL")
                            Spacer()
                            Image(systemName: manual ? "chevron.up" : "chevron.down").font(.caption)
                        }
                    }.foregroundStyle(.primary).accessibilityIdentifier("githubManualRepository")
                    if manual {
                        TextField("https://github.com/owner/repository", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(open).accessibilityIdentifier("githubRepository")
                        TextField("Default branch", text: $branch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(open).accessibilityIdentifier("githubBranch")
                        Button("Open repository", action: open).accessibilityIdentifier("connectGitHubRepository")
                    }
                }.disabled(operation != nil)
                Section {
                    DisclosureGroup("Advanced: personal access token", isExpanded: $advanced) {
                        SecureField("GitHub token", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("githubToken")
                        Text("Optional fallback. Use Contents: read for browsing. Reviewed publishing also needs Contents, Pull requests and Actions: write. Tokens stay in Keychain.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.disabled(operation != nil)
                if operation != nil {
                    Section {
                        HStack { ProgressView(); Text("Opening repository…") }
                        Button("Cancel") { operation?.cancel() }
                    }
                }
            }
            if let snapshot, let client {
                Section("Selected version") {
                    LabeledContent("Repository", value: snapshot.repository.fullName)
                    LabeledContent("Branch", value: snapshot.branch)
                    LabeledContent("Commit", value: String(snapshot.commit.prefix(12)))
                    if let onSelect {
                        Button("Use in this chat") { onSelect(snapshot) }
                            .accessibilityIdentifier("useChatRepository")
                    }
                    NavigationLink {
                        RepositoryFolderView(client: client, snapshot: snapshot, tree: snapshot.tree, path: "")
                    } label: { Label("Browse files", systemImage: "folder") }
                        .accessibilityIdentifier("browseRepositoryFiles")
                    Text("Read-only snapshot. Changes to the branch won’t change these files. Open the repository again to get a newer version.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Choose another repository") { self.snapshot = nil; self.client = nil }
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    .accessibilityIdentifier("repositoryError")
            }
        }.scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("GitHub").navigationBarTitleDisplayMode(.inline)
            .task { if connection.hasCredential { connection.reload() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, connection.user != nil { connection.reload() }
            }
            .onDisappear { operation?.cancel(); connection.cancel(); token = "" }
    }

    private func open() {
        guard operation == nil else { return }
        error = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                let repository = try RepositoryID(address)
                let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
                let credential: String
                if entered.isEmpty { credential = try GitHubCredential.load() }
                else { credential = entered }
                let api = try GitHubRepository(repository: repository, token: credential)
                let version = try await api.snapshot(branch: branch)
                try Task.checkCancellation()
                if !entered.isEmpty { try GitHubCredential.save(entered) }
                token = ""
                if !entered.isEmpty { connection.reload() }
                UserDefaults.standard.set(repository.fullName, forKey: "githubRepository")
                UserDefaults.standard.set(version.branch, forKey: "githubBranch")
                address = repository.fullName; branch = version.branch
                client = api; snapshot = version
            } catch {
                if !Task.isCancelled { self.error = repositoryMessage(error) }
            }
        }
    }
}

private struct RepositoryFolderView: View {
    let client: GitHubRepository
    let snapshot: RepositorySnapshot
    let tree: String
    let path: String
    @State private var entries: [RepositoryEntry]?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        List {
            Section {
                Label("\(snapshot.branch) · \(snapshot.commit.prefix(7))", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let entries {
                if entries.isEmpty { Text("This directory is empty.").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    let fullPath = path.isEmpty ? entry.path : path + "/" + entry.path
                    if entry.isDirectory {
                        NavigationLink {
                            RepositoryFolderView(client: client, snapshot: snapshot, tree: entry.sha, path: fullPath)
                        } label: { Label(entry.path, systemImage: "folder") }
                    } else if entry.isTextCandidate {
                        NavigationLink {
                            RepositoryFileView(client: client, snapshot: snapshot, entry: entry, path: fullPath)
                        } label: { Label(entry.path, systemImage: "doc.text") }
                    } else {
                        Label(entry.path + (entry.type == "commit" ? " · submodule" : " · symlink"), systemImage: "link")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.orange)
                Button("Try again") { self.error = nil; attempt += 1 }
            } else { ProgressView("Loading files…") }
        }.scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle(path.isEmpty ? snapshot.repository.name : String(path.split(separator: "/").last ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                do {
                    let loaded = try await client.entries(snapshot: snapshot, tree: tree)
                    try Task.checkCancellation()
                    entries = loaded
                } catch { if !Task.isCancelled { self.error = repositoryMessage(error) } }
            }
    }
}

private struct RepositoryFileView: View {
    let client: GitHubRepository
    let snapshot: RepositorySnapshot
    let entry: RepositoryEntry
    let path: String
    @State private var text: String?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(path).font(.caption).textSelection(.enabled).padding(.horizontal)
            Text("\(snapshot.branch) · \(snapshot.commit.prefix(7)) · Read only")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            Divider()
            if let text {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Text(text.isEmpty ? "Empty file" : text).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("repositoryFileContent")
                            .textSelection(.enabled)
                            .frame(minWidth: max(0, geometry.size.width - 32),
                                   minHeight: max(0, geometry.size.height - 32), alignment: .topLeading)
                            .padding(16)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.orange).padding()
                Button("Try again") { self.error = nil; attempt += 1 }.padding(.horizontal)
                Spacer()
            } else { ProgressView("Opening file…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(KeelStyle.background)
            .navigationTitle(entry.path).navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                do {
                    let loaded = try await client.read(snapshot: snapshot, entry: entry)
                    try Task.checkCancellation()
                    text = loaded
                } catch { if !Task.isCancelled { self.error = repositoryMessage(error) } }
            }
    }
}

private func repositoryMessage(_ error: Error) -> String {
    connectionMessage(error)
}
