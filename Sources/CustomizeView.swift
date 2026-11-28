import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

struct CustomizeView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var memoryDraft = ""
    @State private var memoryError: String?
    @State private var shortcutName = ""
    @State private var shortcutError: String?
    @FocusState private var editingInstructions: Bool
    /// Opens About in place of Customize (About used to be its own menu row).
    let openAbout: () -> Void

    init(openAbout: @escaping () -> Void = {}) { self.openAbout = openAbout }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section("Standing instructions") {
                    Text("Write standing instructions for Keel to follow in every chat, such as your preferred tone, language, or coding conventions. Stored on this \(KeelDevice.name) only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("For example: Reply in concise bullet points and use metric units.", text: $draft, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($editingInstructions)
                        .accessibilityIdentifier("customInstructionsField")
                    Text("\(min(draft.count, CustomInstructions.maxCharacters)) / \(CustomInstructions.maxCharacters) characters")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Save instructions") {
                        if chat.saveCustomInstructions(draft) { dismiss() }
                    }
                    .disabled(chat.running || chat.storageUnreadable)
                    .accessibilityIdentifier("saveCustomInstructions")
                    if !chat.customInstructions.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear instructions", role: .destructive) {
                            draft = ""
                            _ = chat.saveCustomInstructions("")
                        }
                        .disabled(chat.running || chat.storageUnreadable)
                        .accessibilityIdentifier("clearCustomInstructions")
                    }
                }
                Section {
                    Toggle("Let Keel remember", isOn: Binding(get: { chat.memory.enabled }, set: { _ = chat.setMemoryEnabled($0) }))
                        .disabled(chat.running)
                        .accessibilityIdentifier("memoryToggle")
                    if chat.memory.facts.isEmpty {
                        Text("Nothing remembered yet. Say \"remember that I'm vegetarian\" in a chat, and Keel asks before saving it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(chat.memory.facts.sorted { $0.savedAt > $1.savedAt }) { fact in
                        Text(fact.text)
                            .swipeActions { Button("Forget", role: .destructive) { _ = chat.forget(fact.id) } }
                            .accessibilityIdentifier("memoryFact")
                    }
                    HStack {
                        TextField("Add a fact to remember", text: $memoryDraft)
                            .onSubmit(addMemoryFact)
                            .accessibilityIdentifier("memoryFactField")
                        Button("Add", action: addMemoryFact)
                            .disabled(memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.running || chat.storageUnreadable)
                            .accessibilityIdentifier("addMemoryFact")
                    }
                    if let memoryError {
                        Text(memoryError).font(.footnote).foregroundStyle(.orange)
                    }
                    if !chat.memory.facts.isEmpty {
                        Button("Forget everything", role: .destructive) { _ = chat.forgetAll() }
                            .disabled(chat.running)
                    }
                } header: { Text("Memory") } footer: {
                    Text("Facts Keel saved with your approval and uses in every plain chat. Stored on this \(KeelDevice.name) only. Swipe to forget one. Turning memory off keeps them but stops using them.")
                }
                Section {
                    ForEach(chat.allowedShortcuts, id: \.self) { name in
                        Label(name, systemImage: "square.2.layers.3d")
                            .swipeActions { Button("Remove", role: .destructive) { _ = chat.removeShortcut(name) } }
                            .accessibilityIdentifier("allowedShortcut")
                    }
                    HStack {
                        TextField("Shortcut name, exactly as in Shortcuts", text: $shortcutName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(addShortcut)
                            .accessibilityIdentifier("shortcutNameField")
                        Button("Add", action: addShortcut)
                            .disabled(shortcutName.trimmingCharacters(in: .whitespaces).isEmpty || chat.running)
                            .accessibilityIdentifier("addShortcut")
                    }
                    if let shortcutError {
                        Text(shortcutError).font(.footnote).foregroundStyle(.orange)
                    }
                } header: { Text("Shortcuts") } footer: {
                    Text("Keel can run these shortcuts from the Shortcuts app when a chat needs them, such as turning off the lights or getting your next meeting. You approve every run. Keel cannot see or run any other shortcut. Say \"Ask Keel Mobile\" to Siri to start a chat.")
                }
                Section {
                    Toggle("Calendar & Reminders tools", isOn: $chat.calendarToolsEnabled)
                        .disabled(chat.running)
                        .accessibilityIdentifier("calendarToolsToggle")
                } header: { Text("Calendar & Reminders") } footer: {
                    Text("Lets Keel read your upcoming events or incomplete reminders and propose new ones in plain chats. Every new event or reminder asks for your approval first. Data stays on this \(KeelDevice.name).")
                }
                Section {
                    Toggle("Contacts search", isOn: $chat.contactsToolEnabled)
                        .disabled(chat.running)
                        .accessibilityIdentifier("contactsToolToggle")
                } header: { Text("Contacts") } footer: {
                    Text("Lets Keel look up a person's phone number or email in your Contacts when a plain chat asks, such as \"what's Aino's number?\". It only reads, at most 10 people at a time, and nothing leaves this \(KeelDevice.name). When you ask about something you copied, Keel can read the clipboard; iOS asks you first.")
                }
                Section {
                    Button { openAbout() } label: { Label("About Keel", systemImage: "info.circle") }
                        .accessibilityIdentifier("openAbout")
                }
                }.listRowBackground(KeelStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("Customize")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Done keeps what was typed: the Save button below the
                    // field sits under the keyboard while typing.
                    Button("Done") {
                        if instructionsChanged, !chat.running, !chat.storageUnreadable,
                           !chat.saveCustomInstructions(draft) { return }
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if editingInstructions {
                        Spacer()
                        Button("Save") { if chat.saveCustomInstructions(draft) { dismiss() } }
                            .disabled(chat.running || chat.storageUnreadable)
                            .accessibilityIdentifier("keyboardSaveCustomInstructions")
                    }
                }
            }
            .onAppear {
                draft = chat.customInstructions
            }
        }
    }

    private var instructionsChanged: Bool {
        CustomInstructions.sanitize(draft) != chat.customInstructions
    }

    private func addMemoryFact() {
        memoryError = chat.rememberFact(memoryDraft)
        if memoryError == nil { memoryDraft = "" }
    }

    private func addShortcut() {
        shortcutError = chat.allowShortcut(shortcutName)
        if shortcutError == nil { shortcutName = "" }
    }
}
