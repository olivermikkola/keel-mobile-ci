import SwiftUI

/// App metadata, plain-English privacy summary, bundled open-source and model
/// license notices, and TestFlight feedback guidance.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    static func appVersion(from bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (build \(build))"
    }

    static func bundledText(named resource: String, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    HStack(spacing: 14) {
                        KeelMark().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keel Mobile").font(.title3.weight(.semibold))
                            Text(Self.appVersion())
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("aboutAppVersion")
                        }
                    }
                    .padding(.vertical, 4)
                    Text("A local AI agent that runs directly on this \(KeelDevice.name). No Keel account and no cloud model fallback.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy & safety") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("On-device by default").font(.subheadline.weight(.medium))
                            Text("Models, chats, attached files, memory, image generation and offline dictation run on this \(KeelDevice.name). Your prompts are never sent to a Keel server.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(KeelStyle.accent)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Optional connections").font(.subheadline.weight(.medium))
                            Text("GitHub, MCP connectors, Brave Web Search and paired gateways connect only when you enable or approve them. Access tokens stay in Keychain.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network").foregroundStyle(KeelStyle.accent)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review AI output").font(.subheadline.weight(.medium))
                            Text("On-device models can make mistakes. Always review proposed file edits, SQL/JavaScript outputs and important answers before relying on them.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.seal").foregroundStyle(KeelStyle.accent)
                    }
                }

                Section {
                    NavigationLink {
                        LicenseDocumentView(title: "Third-Party Notices", resource: "ThirdPartyNotices")
                    } label: {
                        Label("Third-Party & Model Notices", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("openThirdPartyNotices")
                    NavigationLink {
                        LicenseDocumentView(title: "LFM Open License v1.0", resource: "LFMOpenLicense")
                    } label: {
                        Label("LFM Open License v1.0", systemImage: "doc.plaintext")
                    }
                    .accessibilityIdentifier("openLFMLicense")
                    NavigationLink {
                        LicenseDocumentView(title: "Apache License 2.0", resource: "BonsaiChatTemplateLicense")
                    } label: {
                        Label("Apache License 2.0", systemImage: "doc.plaintext")
                    }
                    .accessibilityIdentifier("openApacheLicense")
                } header: {
                    Text("Licenses & notices")
                } footer: {
                    Text("Keel Mobile includes open-source software and lets you optionally download third-party models under their own licenses.")
                }

                Section("TestFlight beta feedback") {
                    Text("Found a bug or something confusing? Take a screenshot in Keel or open the TestFlight app and choose Send Beta Feedback. Include your device model and which AI model you were using.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                }.listRowBackground(KeelStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("About Keel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LicenseDocumentView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(AboutView.bundledText(named: resource) ?? "License notice is unavailable in this build.")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("licenseDocumentText")
        }
        .background(KeelStyle.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
