import SwiftUI
import UIKit
import PhotosUI
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Which engine draws a picture. `photo` is Keel's own Stable Diffusion
/// (Core ML, on this phone). The other three are Apple's Image Playground
/// styles, on-device, on iPhones with Apple Intelligence.
enum ImageStyle: String, Codable, CaseIterable, Identifiable {
    case photo, animation, illustration, sketch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: return "Photo"
        case .animation: return "Animation"
        case .illustration: return "Illustration"
        case .sketch: return "Sketch"
        }
    }
    var engine: String { self == .photo ? "Keel · Stable Diffusion" : "Apple Image Playground" }
    var symbol: String {
        switch self {
        case .photo: return "camera.aperture"
        case .animation: return "sparkles"
        case .illustration: return "paintpalette"
        case .sketch: return "pencil.and.scribble"
        }
    }
}

/// One picture made in Images.
struct StudioImage: Codable, Identifiable, Equatable {
    var id = UUID()
    let file: String
    let prompt: String
    let style: ImageStyle
    let createdAt: Date
}

/// The pictures made in Images, kept apart from chat pictures (which a chat's
/// deletion prunes). Files and the list sit in Application Support, protected.
@MainActor
final class ImageGallery: ObservableObject {
    @Published private(set) var items: [StudioImage] = []
    let directory: URL
    private var listURL: URL { directory.appendingPathComponent("gallery.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageStudio", isDirectory: true)) {
        self.directory = directory
        if let data = try? Data(contentsOf: listURL), let saved = try? JSONDecoder().decode([StudioImage].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: url($0).path) }
        }
    }

    func url(_ item: StudioImage) -> URL { directory.appendingPathComponent(item.file) }

    func add(png: Data, prompt: String, style: ImageStyle) throws -> StudioImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let item = StudioImage(file: UUID().uuidString + ".png", prompt: prompt, style: style, createdAt: Date())
        try png.write(to: url(item), options: [.atomic, .completeFileProtection])
        items.insert(item, at: 0)
        save()
        return item
    }

    func delete(_ item: StudioImage) {
        try? FileManager.default.removeItem(at: url(item))
        items.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: listURL, options: [.atomic, .completeFileProtection])
    }
}

/// Draws one picture with the chosen engine.
@MainActor
final class ImageStudio: ObservableObject {
    @Published var phase: String?
    @Published var error: String?
    @Published private(set) var appleStyles: Set<ImageStyle> = []
    private let runtime = ImageRuntime()
    private var work: Task<Void, Never>?

    var busy: Bool { phase != nil }

    /// Whether this iPhone offers Apple's styles (Apple Intelligence on).
    /// Asks the system's cheap flag only: creating Apple's `ImageCreator`
    /// starts its engine and holds memory, which left no room for Keel's
    /// own model. The engine is created only to make an Apple-style picture.
    func checkApple() {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *), ImagePlaygroundViewController.isAvailable {
            appleStyles = [.animation, .illustration, .sketch]
            return
        }
        #endif
        appleStyles = []
    }

    func available(_ style: ImageStyle) -> Bool {
        style == .photo ? ImageModelStore.installedFolder() != nil : appleStyles.contains(style)
    }

    /// Why a style cannot be used here, or nil.
    func unavailableReason(_ style: ImageStyle) -> String? {
        if style == .photo {
            if let reason = ImageModelStore.unsupportedReason { return reason }
            let size = ByteCountFormatter.string(fromByteCount: ImageModelStore.pack.totalBytes, countStyle: .file)
            return ImageModelStore.installedFolder() == nil ? "Download the image model (\(size)) to make photos on this \(KeelDevice.name)." : nil
        }
        return appleStyles.contains(style) ? nil : "Apple's styles need a device with Apple Intelligence turned on."
    }

    /// Makes a picture. `source` is a starting picture (Apple styles only).
    func make(prompt: String, style: ImageStyle, source: CGImage?, chat: LocalChat, gallery: ImageGallery,
              done: @escaping (StudioImage) -> Void) {
        guard work == nil else { return }
        let text = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, text.count <= ImageRequest.maxPromptCharacters else {
            error = ImageRequest.Problem.prompt.localizedDescription; return
        }
        guard !chat.running else { error = "Wait for the chat's reply to finish, then try again."; return }
        if case .stop = ThermalPolicy.currentDecision() {
            error = LocalModelError.thermal.localizedDescription; return
        }
        error = nil
        phase = "Getting ready…"
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task {
            defer { work = nil; phase = nil; UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let png = style == .photo ? try await photo(text, chat: chat) : try await apple(text, style: style, source: source)
                try Task.checkCancellation()
                done(try gallery.add(png: png, prompt: text, style: style))
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel(reason: String? = nil) {
        guard let work else { return }
        work.cancel()
        if let reason { error = reason }
    }

    private func photo(_ prompt: String, chat: LocalChat) async throws -> Data {
        guard let folder = ImageModelStore.installedFolder() else { throw ImageStudioError.message(unavailableReason(.photo) ?? "") }
        // The chat model and the image model do not fit in memory together.
        phase = "Making room for the image model…"
        await chat.unloadModelsNow()
        let began = Date()
        let thermalStop = ThermalFlag()
        let request = try ImageRequest.arguments(["prompt": prompt, "path": "image.png"], seed: UInt32.random(in: 0...UInt32.max))
        let picture = try await runtime.png(for: request, modelFolder: folder) { step, count in
            switch ThermalPolicy.currentDecision(step: step) {
            case .stop:
                thermalStop.trip()
                return false
            case .throttle(let pause):
                Thread.sleep(forTimeInterval: Double(pause) / 1_000_000_000)
            case .proceed:
                break
            }
            Task { @MainActor [weak self] in
                self?.phase = step < count ? "Drawing · step \(step + 1) of \(count)…" : "Finishing the picture…"
            }
            return !Task.isCancelled && Date().timeIntervalSince(began) < ImageRequest.timeLimit
        }
        guard let picture else {
            if thermalStop.tripped { throw LocalModelError.thermal }
            if Task.isCancelled { throw CancellationError() }
            throw ImageRequest.Problem.slow
        }
        return picture
    }

    private final class ThermalFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func trip() { lock.lock(); flag = true; lock.unlock() }
        var tripped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func apple(_ prompt: String, style: ImageStyle, source: CGImage?) async throws -> Data {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) {
            phase = "Drawing with Image Playground…"
            let creator = try await ImageCreator()
            let playgroundStyle: ImagePlaygroundStyle
            switch style {
            case .animation: playgroundStyle = .animation
            case .illustration: playgroundStyle = .illustration
            default: playgroundStyle = .sketch
            }
            var concepts: [ImagePlaygroundConcept] = [.text(prompt)]
            if let source { concepts.append(.image(source)) }
            for try await image in creator.images(for: concepts, style: playgroundStyle, limit: 1) {
                guard let data = UIImage(cgImage: image.cgImage).pngData() else { break }
                return data
            }
            throw ImageStudioError.message("Image Playground did not return a picture. Try a different description.")
        }
        #endif
        throw ImageStudioError.message("Apple's styles need iOS 18.4 or later with Apple Intelligence.")
    }
}

enum ImageStudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// The Images tab: describe a picture, pick a style, and see everything made,
/// here and in chats. Laid out like Apple's Image Playground.
struct ImagesView: View {
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var model: ImageModelStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gallery = ImageGallery()
    @StateObject private var studio = ImageStudio()
    @AppStorage("imageStyle") private var style = ImageStyle.photo
    @State private var prompt = ""
    @State private var source: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var opened: StudioImage?
    @FocusState private var typing: Bool

    private let ideas = ["A lighthouse at dusk in winter", "A red fox in a snowy forest",
                         "A cosy café with rain on the window", "A yellow car on a city street"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    card
                    if let reason = studio.unavailableReason(style) { setup(reason) }
                    if let error = studio.error {
                        Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("imageError")
                    }
                    if prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ideas").font(.headline)
                            ForEach(ideas, id: \.self) { idea in
                                Button(idea) { prompt = idea }.font(.subheadline)
                            }
                        }
                    }
                    gallerySection
                }.padding()
            }
            .scrollContentBackground(.hidden).background(KeelStyle.background)
            .navigationTitle("Images").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { studio.checkApple() }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) { source = UIImage(data: data) }
                    photoItem = nil
                }
            }
            .sheet(item: $opened) { item in
                StudioImageView(item: item, gallery: gallery, studio: studio) { opened = $0 }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    studio.cancel(reason: "Image generation stops when you leave Keel. Try again while Keel is open.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                studio.cancel(reason: "Your \(KeelDevice.name) is low on memory. Image generation stopped; close other apps and try again.")
            }
        }
        .interactiveDismissDisabled(studio.busy)
    }

    private var card: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Menu {
                    ForEach(ImageStyle.allCases) { option in
                        Button { style = option } label: {
                            Label { Text(option.title); Text(option.engine) } icon: { Image(systemName: style == option ? "checkmark" : option.symbol) }
                        }.accessibilityIdentifier("imageStyle-\(option.rawValue)")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(style.title).font(.headline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(KeelStyle.background.opacity(0.6), in: Capsule())
                }
                .disabled(studio.busy)
                .accessibilityIdentifier("imageStylePicker")
            }
            if let source {
                Image(uiImage: source).resizable().scaledToFill().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .topTrailing) {
                        Button { self.source = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Remove starting photo")
                    }
            }
            TextField("Describe an image", text: $prompt, axis: .vertical)
                .font(.title2).multilineTextAlignment(.center).lineLimit(1...5)
                .focused($typing)
                .accessibilityIdentifier("imagePrompt")
            if let phase = studio.phase {
                HStack(spacing: 8) { ProgressView(); Text(phase).font(.footnote).foregroundStyle(.secondary) }
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3).frame(width: 48, height: 48)
                        .background(KeelStyle.background.opacity(0.6), in: Circle())
                }
                .disabled(style == .photo || studio.busy)
                .accessibilityLabel("Start from a photo")
                Spacer()
                if studio.busy {
                    Button { studio.cancel() } label: {
                        Image(systemName: "stop.fill").frame(width: 48, height: 48)
                            .background(KeelStyle.background.opacity(0.6), in: Circle())
                    }.accessibilityLabel("Stop")
                } else {
                    Button(action: make) {
                        Image(systemName: "arrow.up").font(.title3.weight(.bold)).frame(width: 48, height: 48)
                            .foregroundStyle(canMake ? KeelStyle.background : Color.secondary)
                            .background(canMake ? KeelStyle.accent : Color.secondary.opacity(0.15), in: Circle())
                    }
                    .disabled(!canMake)
                    .accessibilityLabel("Make image")
                    .accessibilityIdentifier("makeImage")
                }
            }
            if style == .photo, source != nil {
                Text("Starting from a photo works with Apple's styles. Photo ignores it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
    }

    @ViewBuilder private func setup(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason).font(.footnote).foregroundStyle(.secondary)
            if style == .photo, ImageModelStore.unsupportedReason == nil {
                if let progress = model.progress {
                    ProgressView(value: progress)
                    Button("Pause") { model.pause() }
                } else if !model.installed {
                    Button("Download image model") { model.download() }.buttonStyle(.bordered)
                        .accessibilityIdentifier("imagesDownloadModel")
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    @ViewBuilder private var gallerySection: some View {
        if !gallery.items.isEmpty || chat.tasks.contains(where: { $0.messages.contains { $0.image != nil } }) {
            Text("Your images").font(.headline)
            ImageGrid(gallery: gallery) { opened = $0 }
        }
    }

    private var canMake: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && studio.available(style) && !studio.busy && !chat.running
    }

    private func make() {
        typing = false
        studio.make(prompt: prompt, style: style, source: style == .photo ? nil : source?.cgImage,
                    chat: chat, gallery: gallery) { opened = $0 }
    }
}

/// One picture large, with its prompt, "Describe a change", share and delete.
struct StudioImageView: View {
    let item: StudioImage
    @ObservedObject var gallery: ImageGallery
    @ObservedObject var studio: ImageStudio
    let show: (StudioImage) -> Void
    @EnvironmentObject private var chat: LocalChat
    @Environment(\.dismiss) private var dismiss
    @State private var change = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(item.prompt).font(.title3).multilineTextAlignment(.center).lineLimit(3)
                let picture = UIImage(contentsOfFile: gallery.url(item).path)
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .accessibilityIdentifier("studioImageLarge")
                }
                Text(item.style.title + " · " + item.style.engine).font(.caption).foregroundStyle(.secondary)
                if let phase = studio.phase {
                    HStack(spacing: 8) { ProgressView(); Text(phase).font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = studio.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                HStack {
                    TextField("Describe a change", text: $change)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(KeelStyle.surface, in: Capsule())
                        .submitLabel(.go)
                        .onSubmit { remake(picture) }
                        .disabled(studio.busy)
                        .accessibilityIdentifier("describeChange")
                }
                Spacer(minLength: 0)
                HStack {
                    ShareLink(item: gallery.url(item)) {
                        Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48).background(KeelStyle.surface, in: Circle())
                    }.accessibilityLabel("Share or save")
                    Spacer()
                    Button(role: .destructive) { gallery.delete(item); dismiss() } label: {
                        Image(systemName: "trash").frame(width: 48, height: 48).background(KeelStyle.surface, in: Circle())
                    }.accessibilityLabel("Delete image").disabled(studio.busy)
                }
            }
            .padding()
            .background(KeelStyle.background)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() }.disabled(studio.busy) } }
        }
    }

    /// A new version: Apple's styles start from this picture; Photo redraws
    /// from the prompt with the change added.
    private func remake(_ picture: UIImage?) {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let prompt = String((item.prompt + ", " + text).prefix(ImageRequest.maxPromptCharacters))
        studio.make(prompt: prompt, style: item.style, source: item.style == .photo ? nil : picture?.cgImage,
                    chat: chat, gallery: gallery) { made in change = ""; show(made) }
    }
}

/// Pictures from Images and from chats, newest Images first. Tapping an
/// Images picture opens it; a chat picture opens Share (save to Photos is there).
struct ImageGrid: View {
    @EnvironmentObject private var chat: LocalChat
    @ObservedObject var gallery: ImageGallery
    var open: ((StudioImage) -> Void)?

    var body: some View {
        let chatImages = chat.tasks.flatMap { task in task.messages.compactMap(\.image).map { (task.title, $0) } }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(gallery.items) { item in
                if let open {
                    Button { open(item) } label: { thumbnail(gallery.url(item)) }
                        .accessibilityLabel(item.prompt).accessibilityIdentifier("studioImage")
                } else {
                    ShareLink(item: gallery.url(item)) { thumbnail(gallery.url(item)) }
                        .accessibilityLabel(item.prompt).accessibilityIdentifier("studioImage")
                }
            }
            ForEach(chatImages, id: \.1) { title, name in
                ShareLink(item: ImageRuntime.url(name)) { thumbnail(ImageRuntime.url(name)) }
                    .accessibilityLabel("Picture from \(title)")
            }
        }
    }

    private func thumbnail(_ url: URL) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 240)) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
