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
            Form {
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
