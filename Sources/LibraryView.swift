import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Everything the agent made, from every chat, in one place: open it in its
/// viewer, share it, or go back to the chat that made it.
struct LibraryView: View {
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @State private var filter = Library.Filter.all
    @State private var query = ""
    @State private var opened: Library.Item?
    @StateObject private var gallery = ImageGallery()

    var body: some View {
        let all = chat.libraryItems
        let shown = Library.filter(all, filter, query: query)
        NavigationStack {
            List { Group {
                Section {
                    Picker("Kind", selection: $filter) {
                        ForEach(Library.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("libraryFilter")
                }.listRowBackground(Color.clear)
                if filter == .images {
                    if gallery.items.isEmpty && !chat.tasks.contains(where: { $0.messages.contains { $0.image != nil } }) {
                        Text("No pictures yet. Make one in Images, or ask for one in a Work chat.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("libraryImagesEmpty")
                    } else {
                        ImageGrid(gallery: gallery).listRowBackground(Color.clear)
                    }
                } else if shown.isEmpty {
                    Text(all.isEmpty ? "Nothing here yet. Pages, documents, tables and cards the agent makes in your chats appear here once you apply them."
                                     : "No files match.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("libraryEmpty")
                }
                ForEach(shown) { item in
                    Button { opened = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(item.kind)).foregroundStyle(KeelStyle.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).foregroundStyle(.primary)
                                Text(item.chatTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(item.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("libraryItem-\(item.name)")
                }
                }.listRowBackground(KeelStyle.surface)
            }
            .searchable(text: $query, prompt: "Search files and chats")
            .scrollContentBackground(.hidden)
            .background(KeelStyle.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $opened) { item in
                LibraryItemView(item: item, document: Library.document(for: item, in: all)) {
                    opened = nil
                    if chat.selectTask(item.taskID) { dismiss() }
                }
            }
        }
    }

    private func symbol(_ kind: FileView.Kind?) -> String {
        switch kind {
        case .page: return "safari"
        case .document: return "doc.richtext"
        case .table: return "tablecells"
        case .cards: return "rectangle.on.rectangle.angled"
        case nil: return "doc.text"
        }
    }
}

/// One Library file: its viewer (or its text), share as a file, open its chat.
struct LibraryItemView: View {
    let item: Library.Item
    let document: String?
    let openChat: () -> Void
    @StateObject private var controller = WebPreviewController()
    @State private var shareURL: URL?
    @State private var showingPDFShare = false
    @Environment(\.dismiss) private var dismiss

    private func prepareShareURL() -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(item.name)
        return (try? Data(item.text.utf8).write(to: url, options: .atomic)) == nil ? nil : url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    WebPreviewPage(document: document, controller: controller)
                        .accessibilityIdentifier("webPreview")
                } else {
                    ScrollView {
                        Text(item.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { controller.cleanup(); dismiss() } }
                if document != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if controller.pdfURL != nil {
                                showingPDFShare = true
                            } else {
                                controller.exportPDF(title: item.name)
                            }
                        } label: {
                            Label(controller.pdfURL != nil ? "Share PDF" : "Export PDF",
                                  systemImage: controller.pdfURL != nil ? "square.and.arrow.up" : "arrow.down.doc")
                        }
                        .accessibilityIdentifier(controller.pdfURL != nil ? "shareLibraryPDF" : "exportLibraryPDF")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Open chat", action: openChat).accessibilityIdentifier("libraryOpenChat")
                    Spacer()
                    if let shareURL {
                        ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("libraryShare")
                    }
                }
            }
            .task(id: item.id) { shareURL = prepareShareURL() }
            .sheet(isPresented: $showingPDFShare) {
                if let pdfURL = controller.pdfURL {
                    PDFActivityShareSheet(url: pdfURL)
                }
            }
            .onDisappear { controller.cleanup() }
        }
    }
}
