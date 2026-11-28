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
    @State private var openedVideo: ShortVideoDraft?
    @State private var openedCarousel: StudioCarousel?
    @StateObject private var gallery = ImageGallery()
    @StateObject private var videos = VideoGallery()
    @StateObject private var carousels = CarouselGallery()

    var body: some View {
        let all = chat.libraryItems
        let shown = Library.filter(all, filter, query: query)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            List { Group {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Library.Filter.allCases, id: \.self) { option in
                                let selected = filter == option
                                Button { filter = option } label: {
                                    Text(option.title)
                                        .font(.subheadline.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? KeelStyle.background : .primary)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(selected ? KeelStyle.accent : KeelStyle.surface, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("libraryFilter-\(option.rawValue)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("libraryFilter")
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if filter == .images {
                    if gallery.items.isEmpty && !chat.tasks.contains(where: { $0.messages.contains { $0.image != nil } }) {
                        Text("No pictures yet. Make one in Images, or ask for one in a Work chat.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("libraryImagesEmpty")
                    } else {
                        ImageGrid(gallery: gallery, query: query).listRowBackground(Color.clear)
                    }
                } else if filter == .videos {
                    videosSection(needle: needle)
                } else if filter == .carousels {
                    carouselsSection(needle: needle)
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
            .searchable(text: $query, prompt: "Search files, media and chats")
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
            .fullScreenCover(item: $openedVideo) { draft in
                ShortVideoDraftView(draft: draft)
            }
            .sheet(item: $openedCarousel) { item in
                CarouselViewer(item: item, gallery: carousels)
            }
        }
    }

    @ViewBuilder private func videosSection(needle: String) -> some View {
        let studioVideos = needle.isEmpty ? videos.items
            : videos.items.filter { $0.description.localizedCaseInsensitiveContains(needle) }
        let chatVideos = chat.tasks.flatMap { task in
            task.messages.compactMap(\.video).map { (task.title, task.updatedAt, $0) }
        }.filter { FileManager.default.fileExists(atPath: ShortVideoStore.url($0.2).path) }
            .filter { needle.isEmpty || $0.0.localizedCaseInsensitiveContains(needle) }
        if studioVideos.isEmpty && chatVideos.isEmpty {
            Text(needle.isEmpty ? "No videos yet. Make one in Apps → Videos, or ask for one in a Work chat." : "No videos match.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("libraryVideosEmpty")
        }
        ForEach(studioVideos) { item in
            Button { openedVideo = videos.draft(item) } label: {
                HStack(spacing: 12) {
                    thumbnail(item.photos.first.map(videos.photoURL))
                        .frame(width: 44, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description).foregroundStyle(.primary).lineLimit(2)
                        Text("\(item.photos.count) photo\(item.photos.count == 1 ? "" : "s") · Videos")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(KeelStyle.accent)
                }
            }
            .accessibilityIdentifier("libraryVideo-\(item.id.uuidString)")
        }
        ForEach(chatVideos, id: \.2) { title, date, name in
            Button { openedVideo = chatVideoDraft(name) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "film").foregroundStyle(KeelStyle.accent).frame(width: 44, height: 58)
                        .background(KeelStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary).lineLimit(1)
                        Text("Chat video · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(KeelStyle.accent)
                }
            }
        }
    }

    @ViewBuilder private func carouselsSection(needle: String) -> some View {
        let shown = needle.isEmpty ? carousels.items : carousels.items.filter { item in
            item.description.localizedCaseInsensitiveContains(needle)
                || (item.slides.first?.headline.localizedCaseInsensitiveContains(needle) ?? false)
        }
        if shown.isEmpty {
            Text(needle.isEmpty ? "No carousels yet. Make one in Apps → Carousels." : "No carousels match.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("libraryCarouselsEmpty")
        }
        ForEach(shown) { item in
            Button { openedCarousel = item } label: {
                HStack(spacing: 12) {
                    thumbnail(item.images.first.map(carousels.url))
                        .frame(width: 46, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.slides.first?.headline ?? item.description).foregroundStyle(.primary).lineLimit(2)
                        Text("\(item.images.count) slides · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("libraryCarousel-\(item.id.uuidString)")
        }
    }

    private func chatVideoDraft(_ name: String) -> ShortVideoDraft? {
        if let active = chat.shortVideoDraft(for: name) { return active }
        guard FileManager.default.fileExists(atPath: ShortVideoStore.url(name).path),
              let manifest = ShortVideoStore.manifest(for: name) else { return nil }
        return ShortVideoDraft(video: ShortVideoStore.url(name), plan: manifest.plan,
                               voiceLabel: NarrationVoiceChoice.draftLabel(id: manifest.voice, appleVoices: AppleVoices.offered()),
                               pictures: manifest.plan.clips.map { _ in nil })
    }

    private func thumbnail(_ url: URL?) -> some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
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
