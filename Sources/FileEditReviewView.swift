import SwiftUI

// Callbacks belong to the task controller. Merely opening this screen has no
// side effects; Done keeps the pending proposal available for a later review.
struct FileEditReviewView: View {
    let proposal: ProposedFileEdit
    let decision: TaskFileEdit.Decision
    let applying: Bool
    let error: String?
    let apply: () -> Void
    let discard: () -> Void
    /// Builds the page this proposal creates, for proposals of HTML files.
    var preview: (() -> String)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var showingWhitespace = false
    @State private var previewDocument: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        Text(kindLabel)
                            .font(.caption2.weight(.bold)).tracking(1)
                            .foregroundStyle(KeelStyle.accent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(KeelStyle.accent.opacity(0.12), in: Capsule())
                        Text(proposal.path).font(.headline).textSelection(.enabled)
                    }
                    if let destination = proposal.destinationPath {
                        Text("→ \(destination)").font(.subheadline).textSelection(.enabled)
                    }
                    if proposal.snapshot.isLocalFiles {
                        Text("This chat's files").font(.subheadline).foregroundStyle(.secondary)
                        Text("Review the proposed change before applying it to this chat's files. They stay on this iPhone.")
                            .font(.subheadline)
                    } else {
                        Text("\(proposal.snapshot.repository.fullName)\n\(proposal.snapshot.branch) · \(proposal.snapshot.commit.prefix(7))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Review the proposed change before applying it to this task. Publishing to GitHub is a separate decision.")
                            .font(.subheadline)
                    }
                    if let preview {
                        Button { previewDocument = preview() } label: {
                            Label("Preview page", systemImage: "safari")
                        }.buttonStyle(.bordered).accessibilityIdentifier("previewPage")
                    }
                    if proposal.kind == .rename {
                        Label("Content is unchanged. Only the path moves when applied.", systemImage: "arrow.right.doc.on.clipboard")
                            .font(.subheadline)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Toggle("Show whitespace", isOn: $showingWhitespace).font(.caption)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(proposal.diff.hunk).foregroundStyle(.secondary).padding(.vertical, 10)
                                ForEach(proposal.diff.lines) { line in
                                    HStack(alignment: .top, spacing: 8) {
                                        gutter(line.oldLine)
                                        gutter(line.newLine)
                                        Text(prefix(line.kind) + display(line.text))
                                            .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                                    }
                                    .padding(.vertical, 2)
                                    .foregroundStyle(foreground(line.kind))
                                    .background(background(line.kind))
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(accessibilityText(line))
                                    .accessibilityIdentifier("editDiffLine-\(line.id)")
                                }
                            }.font(.system(.caption, design: .monospaced)).padding(12)
                        }.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("fileEditDiff")
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                }.padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if decision == .pending {
                        Button(applying ? "Checking current content…" : "Apply to task") { confirming = true }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                            .accessibilityIdentifier("reviewApplyEdit")
                        Button("Discard proposal", role: .destructive, action: discard)
                            .accessibilityIdentifier("reviewDiscardEdit")
                    } else {
                        Label(decision == .applied ? "Applied to task" : "Proposal discarded",
                              systemImage: decision == .applied ? "checkmark.circle" : "xmark.circle")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(decision == .applied ? "Applied to task" : "Proposal discarded")
                            .accessibilityIdentifier("reviewEditDecision")
                    }
                }.padding().background(.regularMaterial).disabled(applying)
            }
            .navigationTitle("Review change").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(applying) } }
            .interactiveDismissDisabled(applying)
            .sheet(isPresented: Binding(get: { previewDocument != nil }, set: { if !$0 { previewDocument = nil } })) {
                WebPreviewView(title: proposal.afterPath, document: previewDocument ?? "")
            }
            .alert(actionTitle, isPresented: $confirming) {
                Button("Apply reviewed change", action: apply)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Keel will check the current content before applying this proposal. The change stays in this saved task until you separately choose to publish.")
            }
        }
    }

    private var kindLabel: String {
        switch proposal.kind {
        case .replace: return "EDIT"
        case .create: return "CREATE"
        case .delete: return "DELETE"
        case .rename: return "RENAME"
        }
    }

    private var actionTitle: String {
        switch proposal.kind {
        case .replace: return "Apply this change to the task?"
        case .create: return "Create this file in the task?"
        case .delete: return "Delete this file from the task?"
        case .rename: return "Rename this file in the task?"
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text("00000").hidden().overlay(alignment: .trailing) {
            Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
        }
    }
    private func display(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\r", with: "␍")
        return showingWhitespace ? text.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "⇥") : text
    }
    private func prefix(_ kind: FileEditDiff.Kind) -> String {
        switch kind {
        case .removal: return "− "
        case .addition: return "+ "
        case .context: return "  "
        case .noNewline: return "\\ "
        }
    }
    private func foreground(_ kind: FileEditDiff.Kind) -> Color {
        switch kind {
        case .removal: return .red
        case .addition: return .green
        case .context: return .primary
        case .noNewline: return .secondary
        }
    }
    private func background(_ kind: FileEditDiff.Kind) -> Color {
        switch kind {
        case .removal: return .red.opacity(0.1)
        case .addition: return .green.opacity(0.1)
        default: return .clear
        }
    }
    private func accessibilityText(_ line: FileEditDiff.Line) -> String {
        switch line.kind {
        case .removal: return "Remove line \(line.oldLine ?? 0): \(line.text)"
        case .addition: return "Add line \(line.newLine ?? 0): \(line.text)"
        case .context: return "Unchanged line \(line.oldLine ?? 0): \(line.text)"
        case .noNewline: return "No newline at end of file"
        }
    }
}
