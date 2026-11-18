import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

struct CustomizeView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form { Group {
                Section("Standing instructions") {
                    Text("Write standing instructions for Keel to follow in every chat, such as your preferred tone, language, or coding conventions. Stored on this iPhone only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("For example: Reply in concise bullet points and use metric units.", text: $draft, axis: .vertical)
                        .lineLimit(4...10)
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
                    if !chat.memory.facts.isEmpty {
                        Button("Forget everything", role: .destructive) { _ = chat.forgetAll() }
                            .disabled(chat.running)
                    }
                } header: { Text("Memory") } footer: {
                    Text("Facts Keel saved with your approval and uses in every plain chat. Stored on this iPhone only. Swipe to forget one. Turning memory off keeps them but stops using them.")
                }
                }.listRowBackground(KeelStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("Customize")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                draft = chat.customInstructions
            }
        }
    }
}
