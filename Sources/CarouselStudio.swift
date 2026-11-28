import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import os
#if canImport(KeelHarness)
import KeelHarness
#endif

/// A carousel made on the Carousels screen: its slides' words and the
/// rendered slide images, in order.
struct StudioCarousel: Codable, Identifiable, Equatable {
    var id = UUID()
    let description: String
    let photos: [String]
    let slides: [CarouselScript.Slide]
    /// PNG file names in `CarouselGallery.directory`, one per slide.
    let images: [String]
    let createdAt: Date
    /// What the phone found in each photo (`VideoPhotoNotes`); nil for carousels made before notes were kept.
    var notes: [String]? = nil
}

/// The Carousels screen's photos, slide images and list, kept apart from
/// chats and videos and out of backups.
@MainActor
final class CarouselGallery: ObservableObject {
    @Published private(set) var items: [StudioCarousel] = []
    let directory: URL
    private var listURL: URL { directory.appendingPathComponent("carousels.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CarouselStudio", isDirectory: true)) {
        self.directory = directory
        if let data = try? Data(contentsOf: listURL), let saved = try? JSONDecoder().decode([StudioCarousel].self, from: data) {
            items = saved.filter { $0.images.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } }
        }
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Saves picked photos at up to 1600 px on the long side, as JPEG, and
    /// returns their file names in the same order.
    func addPhotos(_ photos: [Data]) throws -> [String] {
        try prepare()
        return try photos.map { data in
            guard let image = UIImage(data: data),
                  let jpeg = Self.resized(image, longSide: 1600).jpegData(compressionQuality: 0.86) else {
                throw ImageStudioError.message("One of the photos could not be read.")
            }
            let name = UUID().uuidString + ".jpg"
            try jpeg.write(to: url(name), options: [.atomic, .completeFileProtection])
            return name
        }
    }

    func addSlide(png: Data) throws -> String {
        try prepare()
        let name = "slide-" + UUID().uuidString + ".png"
        try png.write(to: url(name), options: [.atomic, .completeFileProtection])
        return name
    }

    /// Deletes a picked photo that was taken off the screen, unless a saved carousel uses it.
    func discardUnused(_ photo: String) {
        guard !items.contains(where: { $0.photos.contains(photo) }) else { return }
        try? FileManager.default.removeItem(at: url(photo))
    }

    func add(_ item: StudioCarousel) {
        items.insert(item, at: 0)
        save()
    }

    /// Removes the carousel's slides and any photo no other carousel uses.
    func delete(_ item: StudioCarousel) {
        items.removeAll { $0.id == item.id }
        save()
        let used = Set(items.flatMap(\.photos))
        for file in item.images + item.photos.filter({ !used.contains($0) }) {
            try? FileManager.default.removeItem(at: url(file))
        }
    }

    /// A photo as a data URL for the sealed slide page, which loads nothing else.
    func dataURL(_ photo: String) -> String? {
        guard let data = try? Data(contentsOf: url(photo)) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
    }

    private func save() {
        try? prepare()
        try? JSONEncoder().encode(items).write(to: listURL, options: [.atomic, .completeFileProtection])
    }

    private static func resized(_ image: UIImage, longSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, longSide / max(size.width, size.height, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// Makes one carousel: the phone reads the photos, the chat model writes the
/// slides, and each slide is drawn from HTML into a 1080×1350 image.
@MainActor
final class CarouselMaker: ObservableObject {
    @Published private(set) var phase: String?
    @Published var error: String?
    private var work: Task<Void, Never>?
    private var cancellation: InferenceCancellation?
    /// What the phone finds in the photos; a stand-in in tests.
    private let look: ([URL]) async -> [String]

    static let width = 1080, height = 1350

    init(look: @escaping ([URL]) async -> [String] = { await VideoPhotoNotes.notes(for: $0) }) {
        self.look = look
    }

    var busy: Bool { work != nil }

    func make(description: String, photos: [String], from previous: StudioCarousel? = nil, change: String? = nil,
              chat: LocalChat, model: LocalModel, modelPath: URL,
              gallery: CarouselGallery, done: @escaping (StudioCarousel) -> Void = { _ in }) {
        guard work == nil else { return }
        guard !chat.running else { error = "Wait for the chat's reply to finish, then try again."; return }
        if case .stop = ThermalPolicy.currentDecision() { error = LocalModelError.thermal.localizedDescription; return }
        error = nil
        let flag = InferenceCancellation()
        cancellation = flag
        phase = "Looking at the photos…"
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            defer {
                work = nil; phase = nil; cancellation = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                // The same photos keep their notes; reading them again would only cost time.
                let cached = previous?.photos == photos ? (previous?.notes ?? []) : []
                let notes = cached.isEmpty ? await look(photos.map(gallery.url)) : cached
                try Task.checkCancellation()
                let prompt = try CarouselScript.prompt(description: description, photoCount: photos.count, photoNotes: notes,
                                                       previous: previous?.slides ?? [], change: change)
                phase = "Writing the slides…"
                var slides: [CarouselScript.Slide]?
                var problem: Error = CarouselScript.Problem.script
                for _ in 0..<2 where slides == nil {
                    let reply = try await chat.writePlainReply(system: prompt.system, user: prompt.user,
                                                               limit: CarouselScript.replyTokens(photoCount: photos.count),
                                                               model: model, path: modelPath, cancellation: flag)
                    do { slides = try CarouselScript.parse(reply, photoCount: photos.count) } catch { problem = error }
                }
                guard let slides else { throw problem }
                let styles = photos.indices.map { CarouselPage.style(forPhotoNote: $0 < notes.count ? notes[$0] : "") }
                var images: [String] = []
                let capture = HTMLMotionCapture()
                for (index, slide) in slides.enumerated() {
                    try Task.checkCancellation()
                    if case .stop = ThermalPolicy.currentDecision() { throw LocalModelError.thermal }
                    phase = "Drawing slide \(index + 1) of \(slides.count)…"
                    // The cover and the closing slide reuse the first and last photo.
                    let photoIndex = slide.kind == .cover ? 0 : slide.kind == .closing ? photos.count - 1 : index - 1
                    let photo = photos.indices.contains(photoIndex) ? photos[photoIndex] : nil
                    let style = styles.indices.contains(photoIndex) ? styles[photoIndex] : .photo
                    let html = CarouselPage.html(slide, photo: photo.flatMap(gallery.dataURL), index: index, count: slides.count, style: style)
                    let image = try await capture.still(html: html, width: Self.width, height: Self.height)
                    guard let png = UIImage(cgImage: image).pngData() else { throw HTMLMotionCapture.Failure.snapshot }
                    images.append(try gallery.addSlide(png: png))
                }
                let item = StudioCarousel(description: description, photos: photos, slides: slides, images: images,
                                          createdAt: Date(), notes: notes)
                gallery.add(item)
                done(item)
            } catch is CancellationError {
            } catch {
                if !flag.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        work?.cancel()
    }

    /// Stop only when memory headroom is genuinely low, as Videos and Images do.
    func handleMemoryWarning(available: () -> Int = { Int(os_proc_available_memory()) }) {
        guard busy else { return }
        #if !targetEnvironment(simulator)
        let left = available()
        if left > 0 && left < 250_000_000 {
            cancel()
            error = "Your \(KeelDevice.name) is low on memory. The carousel stopped; close other apps and try again."
        }
        #endif
    }

    /// Waits for the current carousel, for tests.
    func finish() async { await work?.value }
}

/// The Carousels screen: pick photos, say what it is about, and get a
/// swipeable set of slides to save or share.
struct CarouselsView: View {
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var models: ModelLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gallery = CarouselGallery()
    @StateObject private var maker = CarouselMaker()
    @State private var picked: [PhotosPickerItem] = []
    @State private var photos: [String] = []
    @State private var loadingPhotos = false
    @State private var about = ""
    @State private var opened: StudioCarousel?
    @FocusState private var typing: Bool
    /// Photos and a sentence shared from another app ("Send to Keel").
    private let shared: [Data]
    private let sharedAbout: String

    init(shared: [Data] = [], sharedAbout: String = "") {
        self.shared = shared
        self.sharedAbout = sharedAbout
    }

    private var hasModel: Bool { models.installed.contains(models.selected) }
    private var canMake: Bool {
        !photos.isEmpty && !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasModel && !maker.busy && !chat.running && !loadingPhotos
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    composer
                    if !gallery.items.isEmpty { madeHere }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KeelStyle.background)
            .navigationTitle("Carousels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled(maker.busy)
            .onDisappear { maker.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { maker.cancel() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                maker.handleMemoryWarning()
            }
            .onChange(of: picked) { _, items in load(items) }
            .onAppear {
                if !shared.isEmpty, photos.isEmpty {
                    photos = Array(((try? gallery.addPhotos(shared)) ?? []).prefix(CarouselScript.maxPhotos))
                    if about.isEmpty { about = sharedAbout }
                }
            }
            .sheet(item: $opened) { item in
                CarouselViewer(item: item, gallery: gallery) { change in remake(item, change: change) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick up to \(CarouselScript.maxPhotos) photos and say what the carousel is about. Keel writes a cover, a slide for each photo and a closing slide, all on this \(KeelDevice.name).")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(photos.enumerated()), id: \.element) { index, name in
                        ZStack(alignment: .topTrailing) {
                            thumbnail(gallery.url(name)).frame(width: 84, height: 105)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Button { gallery.discardUnused(photos.remove(at: index)) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4).disabled(maker.busy)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                    }
                    if photos.count < CarouselScript.maxPhotos {
                        PhotosPicker(selection: $picked, maxSelectionCount: CarouselScript.maxPhotos - photos.count,
                                     selectionBehavior: .ordered, matching: .images) {
                            VStack(spacing: 6) {
                                if loadingPhotos { ProgressView() } else { Image(systemName: "plus").font(.title2) }
                                Text(photos.isEmpty ? "Add photos" : "Add").font(.caption)
                            }
                            .frame(width: 84, height: 105)
                            .background(KeelStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(maker.busy || loadingPhotos)
                        .accessibilityIdentifier("carouselAddPhotos")
                    }
                }
            }
            TextField("What is it about? Say what it is and who it is for.", text: $about, axis: .vertical)
                .lineLimit(1...4).focused($typing).padding(12)
                .background(KeelStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("carouselAbout")
            HStack {
                Spacer()
                if maker.busy {
                    Button(role: .destructive) { maker.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.bordered)
                } else {
                    Button { make() } label: { Label("Make carousel", systemImage: "square.stack") }
                        .buttonStyle(.borderedProminent).disabled(!canMake)
                        .accessibilityIdentifier("makeCarousel")
                }
            }
            if let phase = maker.phase {
                HStack(spacing: 8) { ProgressView(); Text(phase).font(.footnote).foregroundStyle(.secondary) }
            }
            if !hasModel { Text("Download a chat model in Models; it writes the slides.").font(.footnote).foregroundStyle(.secondary) }
            if let error = maker.error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .padding(18)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var madeHere: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Made here").font(.headline)
            ForEach(gallery.items) { item in
                Button { opened = item } label: {
                    HStack(spacing: 12) {
                        thumbnail(item.images.first.map(gallery.url)).frame(width: 58, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.slides.first?.headline ?? item.description).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                            Text("\(item.images.count) slides · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Use these photos again") { photos = item.photos; about = item.description }
                    Button("Delete", role: .destructive) { gallery.delete(item) }
                }
            }
        }
    }

    private func thumbnail(_ url: URL?) -> some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loadingPhotos = true
        Task {
            defer { loadingPhotos = false; picked = [] }
            var data: [Data] = []
            for item in items {
                if let loaded = try? await item.loadTransferable(type: Data.self) { data.append(loaded) }
            }
            do {
                let names = try gallery.addPhotos(data)
                photos = Array((photos + names).prefix(CarouselScript.maxPhotos))
            } catch {
                maker.error = error.localizedDescription
            }
        }
    }

    private func make() {
        typing = false
        maker.make(description: about, photos: photos, chat: chat, model: models.current,
                   modelPath: models.path(models.current), gallery: gallery) { item in opened = item }
    }

    private func remake(_ item: StudioCarousel, change: String) {
        opened = nil
        maker.make(description: item.description, photos: item.photos, from: item, change: change,
                   chat: chat, model: models.current, modelPath: models.path(models.current), gallery: gallery) { made in opened = made }
    }
}

/// Swipe through a carousel's slides; save them all to Photos, share them, or ask for a change.
struct CarouselViewer: View {
    let item: StudioCarousel
    @ObservedObject var gallery: CarouselGallery
    var describeChange: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?
    @State private var change = ""
    @FocusState private var typing: Bool

    private var urls: [URL] { item.images.map(gallery.url) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                TabView {
                    ForEach(urls, id: \.self) { url in
                        Group {
                            if let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                Color.secondary.opacity(0.15)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .accessibilityIdentifier("carouselSlides")
                HStack(spacing: 14) {
                    Button { Task { await saveAll() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                    ShareLink(items: urls) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                if describeChange != nil { changeBar }
            }
            .padding(.vertical, 12)
            .background(KeelStyle.background)
            .navigationTitle("Carousel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var changeBar: some View {
        HStack(spacing: 10) {
            TextField("Describe a change…", text: $change, axis: .vertical)
                .lineLimit(1...3)
                .focused($typing)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Capsule().fill(KeelStyle.surface))
                .submitLabel(.send)
                .onSubmit(sendChange)
                .accessibilityIdentifier("carouselChange")
            if !change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendChange) {
                    Image(systemName: "arrow.up").font(.title3.weight(.semibold))
                        .foregroundStyle(KeelStyle.background)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(KeelStyle.accent))
                }
                .accessibilityLabel("Send change")
                .accessibilityIdentifier("carouselSendChange")
            }
        }
        .padding(.horizontal, 16)
    }

    private func sendChange() {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let describeChange else { return }
        typing = false
        describeChange(text)
        dismiss()
    }

    private func saveAll() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            note = "Keel can't add to Photos. Allow it in Settings → Keel → Photos."
            return
        }
        do {
            let files = urls
            try await PHPhotoLibrary.shared().performChanges {
                for file in files { _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file) }
            }
            note = "Saved \(files.count) slides to Photos."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }
}
