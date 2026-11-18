import SwiftUI

struct WebSearchSettingsView: View {
    @State private var key = ""
    @State private var saved = WebSearchCredential.contains()
    @State private var error: String?
    var body: some View {
        Form { Group {
            Section {
                Text("Search the web from a local chat. Your model stays on this iPhone; approved search queries go to Brave Search.")
                Text("Keel shows the exact query for your approval before sending it. Website text cannot approve a search.")
            }
            Section("Brave Search API key") {
                if saved { Label("Key saved on this device", systemImage: "key.fill") }
                SecureField(saved ? "Replacement API key" : "API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("webSearchKey")
                Button("Save key") {
                    do {
                        try WebSearchCredential.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        key = ""; saved = true; error = nil
                    } catch { self.error = "The search key could not be saved. Check the key and unlock your device." }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveWebSearchKey")
                if saved {
                    Button("Remove search key", role: .destructive) {
                        do { try WebSearchCredential.remove(); saved = false; key = ""; error = nil }
                        catch { self.error = "The search key could not be removed. Unlock your device and try again." }
                    }
                }
                Link("Get a Brave Search API key", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
                Text("Use your own API key. Usage, credits and charges follow your Brave Search plan. The key stays in Keychain and is never included in chat.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            }.listRowBackground(KeelStyle.surface)
        }.scrollContentBackground(.hidden).background(KeelStyle.background).navigationTitle("Web search")
    }
}
