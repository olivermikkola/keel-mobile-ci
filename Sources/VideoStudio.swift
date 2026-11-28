import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os
#if canImport(KeelHarness)
import KeelHarness
#endif

/// A video made on the Videos screen: its photos, what the user asked for, and
/// the lines the model wrote, so a change can start from them.
struct StudioVideo: Codable, Identifiable, Equatable {
    var id = UUID()
    /// `ShortVideoStore` file name of the `.mp4`.
    let video: String
    /// Photo file names in `VideoGallery.directory`, in scene order.
    let photos: [String]
    let description: String
    let lines: [VideoScript.Line]
    let voice: String
    let createdAt: Date
    /// What the phone found in each photo (`VideoPhotoNotes`); nil for videos made before notes.
    var notes: [String]? = nil
    /// Seconds each step took, shown under the video so slow steps are visible.
    var timings: Timings? = nil
    /// The user's own music under the narration (a file in the gallery), if any.
    var music: String? = nil
    /// "motion" for motion graphics (`MotionTemplate`); nil for the photo zoom.
    var style: String? = nil

    struct Timings: Codable, Equatable {
        let photos: TimeInterval
        let lines: TimeInterval
        let voice: TimeInterval
        let video: TimeInterval
        var summary: String {
            [("Photos", photos), ("Lines", lines), ("Voice", voice), ("Video", video)]
                .map { "\($0.0) \(Int($0.1.rounded())) s" }.joined(separator: " · ")
        }
    }
}

/// The Videos screen's own list and photos, kept apart from chats (whose
/// clean-up would otherwise delete them) and out of backups.
@MainActor
final class VideoGallery: ObservableObject {
    @Published private(set) var items: [StudioVideo] = []
    let directory: URL
    private var listURL: URL { directory.appendingPathComponent("videos.json") }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoStudio", isDirectory: true)
    }

    init(directory: URL = VideoGallery.defaultDirectory) {
        self.directory = directory
        items = Self.load(listURL).filter { FileManager.default.fileExists(atPath: ShortVideoStore.url($0.video).path) }
    }

    /// Videos this screen still shows, for `ShortVideoStore.prune`.
    nonisolated static func savedVideoNames(directory: URL = VideoGallery.defaultDirectory) -> Set<String> {
        Set(load(directory.appendingPathComponent("videos.json")).map(\.video))
    }

    nonisolated private static func load(_ url: URL) -> [StudioVideo] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StudioVideo].self, from: data)) ?? []
    }

    func photoURL(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A photo as a data URL for a sealed motion-graphics page, which loads nothing else.
    func dataURL(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: photoURL(name)) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Saves picked photos at up to 1920 px on the long side (the video's
    /// size), as JPEG. Returns their file names in the same order.
    func addPhotos(_ photos: [Data]) throws -> [String] {
        try prepare()
        return try photos.map { data in
            guard let image = UIImage(data: data), let jpeg = Self.resized(image, longSide: 1920).jpegData(compressionQuality: 0.88) else {
                throw ImageStudioError.message("One of the photos could not be read.")
            }
            let name = UUID().uuidString + ".jpg"
            try jpeg.write(to: photoURL(name), options: [.atomic, .completeFileProtection])
            return name
        }
    }

    /// Copies a song the user picked into the gallery and returns its file name.
    func addMusic(from source: URL) throws -> String {
        try prepare()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = "music-" + UUID().uuidString + "." + (source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: photoURL(name))
        return name
    }

    /// Deletes a picked photo or music file that was taken off the screen, unless a saved video uses it.
    func discardUnused(_ file: String) {
        guard !items.contains(where: { $0.photos.contains(file) || $0.music == file }) else { return }
        try? FileManager.default.removeItem(at: photoURL(file))
    }

    func add(_ item: StudioVideo) {
        items.insert(item, at: 0)
        save()
    }

    /// Removes the video and any photo no other video uses.
    func delete(_ item: StudioVideo) {
        items.removeAll { $0.id == item.id }
        save()
        try? FileManager.default.removeItem(at: ShortVideoStore.url(item.video))
        try? FileManager.default.removeItem(at: ShortVideoStore.manifestURL(item.video))
        let used = Set(items.flatMap(\.photos) + items.compactMap(\.music))
        for file in item.photos + [item.music].compactMap({ $0 }) where !used.contains(file) {
            try? FileManager.default.removeItem(at: photoURL(file))
        }
    }

    func draft(_ item: StudioVideo) -> ShortVideoDraft? {
        guard let manifest = ShortVideoStore.manifest(for: item.video) else { return nil }
        let plan = manifest.plan
        let label = NarrationVoiceChoice.draftLabel(
            id: item.voice,
            appleVoices: AppleVoices.offered(),
            customVoices: NarrationVoiceStore.loadCustomVoices()
        )
        return ShortVideoDraft(video: ShortVideoStore.url(item.video), plan: plan, voiceLabel: label,
                               pictures: plan.clips.map { clip in
                                   let url = photoURL(clip.imagePath)
                                   return FileManager.default.fileExists(atPath: url.path) ? url : nil
                               })
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

/// Runs one video: the chat model writes the lines, then the narration voice
/// speaks them and the renderer makes the `.mp4`.
@MainActor
final class VideoMaker: ObservableObject {
    @Published private(set) var phase: String? {
        didSet { if let phase { continued?.update(fraction: Self.fraction(of: phase), subtitle: phase) } }
    }
    @Published var error: String?

    /// A rough share of the job done, from the step it is on, for the Lock Screen.
    nonisolated static func fraction(of phase: String) -> Double {
        if phase.hasPrefix("Writing") { return 0.15 }
        if phase.hasPrefix("Speaking") { return 0.35 }
        if phase.hasPrefix("Making the video"), let percent = phase.split(separator: " ").last
            .flatMap({ Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%…"))) }) {
            return 0.6 + 0.4 * percent / 100
        }
        if phase.hasPrefix("Making the video") { return 0.6 }
        return 0.05
    }
    private var work: Task<Void, Never>?
    private var cancellation: InferenceCancellation?
    /// iOS 26's continued task for this video: progress on the Lock Screen
    /// and in the Dynamic Island, and permission to keep going in the background.
    private var continued: ContinuedWorkSession?
    private let startContinued: ContinuedWork.Starter
    /// Whether the current video may carry on in the background: photo-zoom
    /// videos only (motion graphics are drawn by WebKit, which stops there).
    private var canContinue = false
    /// Read by the renderer for every frame; false once the app is left.
    private let foreground = GraphicsPermission()
    /// The voice for a voice id (`NarrationVoiceChoice`): Kokoro once
    /// downloaded, Apple's voices always; a stand-in in tests.
    private let narration: (String) -> (any NarrationSpeaking)?
    /// What the phone finds in the photos; a stand-in in tests.
    private let look: ([URL]) async -> [String]

    init(narration: @escaping (String) -> (any NarrationSpeaking)? = VideoMaker.engine(for:),
         look: @escaping ([URL]) async -> [String] = { await VideoPhotoNotes.notes(for: $0) },
         startContinued: @escaping ContinuedWork.Starter = ContinuedWork.system) {
        self.narration = narration
        self.look = look
        self.startContinued = startContinued
    }

    var busy: Bool { work != nil }

    nonisolated static func engine(for voice: String) -> (any NarrationSpeaking)? {
        switch NarrationVoiceChoice(id: voice) {
        case .kokoro: return NarrationVoiceStore.isInstalled ? NarrationEngine() : nil
        case .apple(let identifier): return AppleNarration(identifier: identifier)
        }
    }

    /// Makes a video from `photos` (file names in the gallery). With `from`
    /// and `change`, rewrites that video's lines with the change.
    func make(description: String, photos: [String], voice: String, music: String? = nil, motionGraphics: Bool = false,
              from previous: StudioVideo? = nil, change: String? = nil,
              chat: LocalChat, model: LocalModel, modelPath: URL, gallery: VideoGallery, done: @escaping (StudioVideo) -> Void = { _ in }) {
        guard work == nil else { return }
        guard !chat.running else { error = "Wait for the chat's reply to finish, then try again."; return }
        guard let engine = narration(voice) else { error = "Download the Kokoro voice first, or pick an Apple voice."; return }
        if case .stop = ThermalPolicy.currentDecision() { error = LocalModelError.thermal.localizedDescription; return }
        error = nil
        let flag = InferenceCancellation()
        cancellation = flag
        phase = "Looking at the photos…"
        UIApplication.shared.isIdleTimerDisabled = true
        canContinue = !motionGraphics
        foreground.set(true)
        // Asked for with the tap that starts the video, as iOS requires.
        continued = startContinued(.media, "Keel is making a video", "Looking at the photos…") { [weak self] in
            // iOS or the user ended it from the Lock Screen or Dynamic Island.
            self?.cancel()
            self?.error = "The video stopped when iOS ended its background time. Try again while Keel is open."
        }
        chat.studioWork = continued
        work = Task {
            defer {
                continued?.finish(success: error == nil && !flag.isCancelled)
                continued = nil; chat.studioWork = nil
                work = nil; phase = nil; cancellation = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                let started = Date()
                // The same photos keep their notes; reading them again would only cost time.
                let notes = previous?.photos == photos ? (previous?.notes ?? []) : []
                let found = notes.isEmpty ? await look(photos.map(gallery.photoURL)) : notes
                try Task.checkCancellation()
                let looked = Date()
                phase = "Writing the lines…"
                let lines = try await chat.writeVideoScript(description: description, photoCount: photos.count, photoNotes: found,
                                                            previous: previous?.lines ?? [], change: change,
                                                            model: model, path: modelPath, cancellation: flag)
                let wrote = Date()
                try Task.checkCancellation()
                let arguments = VideoScript.arguments(lines: lines, photoNames: photos, voice: voice)
                let folder = gallery.directory
                // Motion graphics: one HTML timeline, each scene as long as its spoken line.
                var motion: ((ShortVideoRequest.RenderPlan) -> String)?
                if motionGraphics {
                    let pictures = photos.map { gallery.dataURL($0) }
                    let styles = photos.indices.map { MotionTemplate.style(forPhotoNote: $0 < found.count ? found[$0] : "") }
                    motion = { plan in
                        MotionTemplate.timeline(plan.clips.enumerated().map { index, clip in
                            (scene: MotionTemplate.Scene(style: index < styles.count ? styles[index] : .headline,
                                                         headline: clip.overlay ?? "", caption: clip.narration, seconds: clip.duration),
                             photo: index < pictures.count ? pictures[index] : nil)
                        })
                    }
                }
                let made = try await ShortVideoMaker.make(arguments, picture: { folder.appendingPathComponent($0) }, engine: engine,
                                                          music: music.map { folder.appendingPathComponent($0) }, motion: motion,
                                                          stopped: { flag.isCancelled },
                                                          graphicsAllowed: { [foreground] in foreground.allowed },
                                                          phase: { self.phase = $0 })
                let item = StudioVideo(video: made.name, photos: photos, description: description, lines: lines,
                                       voice: voice, createdAt: Date(), notes: found,
                                       timings: .init(photos: looked.timeIntervalSince(started), lines: wrote.timeIntervalSince(looked),
                                                      voice: made.speakSeconds, video: made.renderSeconds),
                                       music: music, style: motionGraphics ? "motion" : nil)
                gallery.add(item)
                if let timings = item.timings {
                    PhoneMeasurements.record(.video, "\(motionGraphics ? "Motion graphics" : "Photo zoom") · \(photos.count) photo\(photos.count == 1 ? "" : "s") · voice \(voice) · \(model.name) · \(timings.summary)")
                }
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

    /// The app left the screen or came back. A photo-zoom video that iOS
    /// agreed to keep going carries on, drawing on the CPU (iOS refuses the
    /// graphics processor in the background); anything else stops, as before.
    func sceneDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            foreground.set(true)
        case .background:
            foreground.set(false)
            guard busy else { return }
            if !(canContinue && continued?.isRunning == true) {
                cancel()
                error = canContinue
                    ? "iOS did not let this video keep going in the background. Try again while Keel is open."
                    : "Motion graphics stop when you leave Keel. Try again while Keel is open, or pick Photo zoom."
            }
        default:
            break
        }
    }

    /// iOS warns about memory often while the voice runs near the limit on
    /// older phones (the XR). A warning alone is no reason to throw the video
    /// away; stop only when little memory is really left, as Images does.
    func handleMemoryWarning(available: () -> Int = { Int(os_proc_available_memory()) }) {
        guard busy else { return }
        #if !targetEnvironment(simulator)
        let left = available()
        if left > 0 && left < 250_000_000 {
            cancel()
            error = "Your \(KeelDevice.name) is low on memory. The video stopped; close other apps and try again."
        }
        #endif
    }

    /// Waits for the current video, for tests.
    func finish() async { await work?.value }
}

/// The Videos screen: pick photos, say what the video is about, and Keel
/// writes the lines, the narration voice reads them, and the video is made.
struct VideosView: View {
    @EnvironmentObject private var chat: LocalChat
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var images: ImageModelStore
    @EnvironmentObject private var narration: NarrationVoiceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gallery = VideoGallery()
    @StateObject private var maker = VideoMaker()
    @AppStorage("videoVoice") private var voice = NarrationVoicePack.defaultVoice
    @AppStorage("videoMotionGraphics") private var motionGraphics = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var photos: [String] = []
    @State private var loadingPhotos = false
    @State private var about = ""
    @State private var opened: StudioVideo?
    @State private var musicFile: String?
    @State private var musicTitle: String?
    @State private var pickingMusic = false
    @State private var appleVoices: [NarrationVoiceChoice.AppleVoice] = []
    @State private var canAskForPersonalVoice = false
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
            && voiceReady && hasModel && !maker.busy && !chat.running && !loadingPhotos
    }
    /// Kokoro voices need the download; Apple's voices are always there.
    private var voiceReady: Bool { !NarrationVoiceChoice(id: voice).needsKokoro || narration.installed }

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
            .navigationTitle("Videos")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled(maker.busy)
            .onDisappear { maker.cancel() }
            .onChange(of: scenePhase) { _, phase in maker.sceneDidChange(phase) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                maker.handleMemoryWarning()
            }
            .onChange(of: picked) { _, items in load(items) }
            .onAppear {
                refreshVoices()
                if !shared.isEmpty, photos.isEmpty {
                    photos = Array(((try? gallery.addPhotos(shared)) ?? []).prefix(VideoScript.maxPhotos))
                    if about.isEmpty { about = sharedAbout }
                }
            }
            .fullScreenCover(item: $opened) { item in
                if let draft = gallery.draft(item) {
                    ShortVideoDraftView(draft: draft) { change in remake(item, change: change) }
                } else {
                    NavigationStack {
                        Text("This video's files are gone.")
                            .foregroundStyle(.secondary)
                            .padding()
                            .navigationTitle("Video")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { opened = nil }
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick up to \(VideoScript.maxPhotos) photos and say what the video is about. Keel writes a line for each photo and reads it aloud, all on this \(KeelDevice.name).")
                .font(.subheadline).foregroundStyle(.secondary)
            photoStrip
            TextField("What is it about? Say what it is and who it is for: the more you say, the better the lines.", text: $about, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .padding(12)
                .background(KeelStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("videoAbout")
            musicRow
            Picker("Style", selection: $motionGraphics) {
                Text("Photo zoom").tag(false)
                Text("Motion graphics").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(maker.busy)
            .accessibilityIdentifier("videoStyle")
            HStack {
                Picker("Voice", selection: $voice) {
                    Section("Kokoro · on-device AI voice") {
                        ForEach(NarrationVoicePack.voices, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    if !narration.customVoices.isEmpty {
                        Section("Custom Kokoro voices") {
                            ForEach(narration.customVoices) { Text($0.pickerLabel).tag($0.id) }
                        }
                    }
                    if !appleVoices.isEmpty {
                        Section("Apple · instant, no download") {
                            ForEach(appleVoices, id: \.identifier) { Text($0.label).tag(NarrationVoiceChoice.apple(identifier: $0.identifier).id) }
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(maker.busy)
                .onChange(of: narration.customVoices) { _, _ in
                    if case .kokoro(let id) = NarrationVoiceChoice(id: voice),
                       !NarrationVoicePack.voiceIDs.contains(id),
                       !narration.customVoices.contains(where: { $0.id == id }) {
                        voice = NarrationVoicePack.defaultVoice
                    }
                }
                Spacer()
                if maker.busy {
                    Button(role: .destructive) { maker.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                } else {
                    Button { make() } label: { Label("Make video", systemImage: "film") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canMake)
                        .accessibilityIdentifier("makeVideo")
                }
            }
            if let phase = maker.phase {
                HStack(spacing: 8) { ProgressView(); Text(phase).font(.footnote).foregroundStyle(.secondary) }
            }
            setupNotes
            if let error = maker.error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .padding(18)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photos.enumerated()), id: \.element) { index, name in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(gallery.photoURL(name))
                            .frame(width: 84, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button { gallery.discardUnused(photos.remove(at: index)) } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(4)
                        .disabled(maker.busy)
                        .accessibilityLabel("Remove photo \(index + 1)")
                    }
                }
                if photos.count < VideoScript.maxPhotos {
                    PhotosPicker(selection: $picked, maxSelectionCount: VideoScript.maxPhotos - photos.count,
                                 selectionBehavior: .ordered, matching: .images) {
                        VStack(spacing: 6) {
                            if loadingPhotos { ProgressView() } else { Image(systemName: "plus").font(.title2) }
                            Text(photos.isEmpty ? "Add photos" : "Add").font(.caption)
                        }
                        .frame(width: 84, height: 112)
                        .background(KeelStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(maker.busy || loadingPhotos)
                    .accessibilityIdentifier("videoAddPhotos")
                }
            }
        }
    }

    /// The user's own song under the voice: quiet, dipped while a line is spoken.
    @ViewBuilder private var musicRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note").foregroundStyle(KeelStyle.accent)
            if let musicTitle {
                Text(musicTitle).font(.subheadline).lineLimit(1)
                Spacer()
                Button {
                    if let old = musicFile { gallery.discardUnused(old) }
                    musicFile = nil; self.musicTitle = nil
                } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .disabled(maker.busy)
                    .accessibilityLabel("Remove music")
            } else {
                Button("Add music") { pickingMusic = true }
                    .disabled(maker.busy)
                    .accessibilityIdentifier("videoAddMusic")
                Spacer()
                Text("Optional · plays quietly under the voice").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $pickingMusic, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            do {
                let next = try gallery.addMusic(from: url)
                if let old = musicFile { gallery.discardUnused(old) }
                musicFile = next
                musicTitle = url.deletingPathExtension().lastPathComponent
            } catch {
                maker.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var setupNotes: some View {
        if let reason = NarrationVoiceStore.unsupportedReason {
            Text(reason).font(.footnote).foregroundStyle(.orange)
        } else if !narration.installed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kokoro voices need a download (about \(ByteCountFormatter.string(fromByteCount: NarrationVoicePack.approximateBytes, countStyle: .file))). Apple voices work right away.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let progress = narration.progress {
                    ProgressView(value: progress)
                    Button("Stop") { narration.cancel() }.font(.footnote)
                } else {
                    Button("Download narration voice") { narration.download { await chat.unloadModelsNow() } }
                        .buttonStyle(.bordered)
                        .disabled(chat.running || maker.busy || models.isTransferring || images.downloading)
                        .accessibilityIdentifier("videoDownloadVoice")
                }
                if let error = narration.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        if canAskForPersonalVoice {
            VStack(alignment: .leading, spacing: 6) {
                Text("Read your videos in your own voice: make a Personal Voice in Settings → Accessibility → Personal Voice, then let Keel use it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Use my Personal Voice") {
                    Task { await AppleVoices.askForPersonalVoice(); refreshVoices() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("videoPersonalVoice")
            }
        }
        if !hasModel { StudioChatModelSetup(writes: "the lines") }
    }

    private var madeHere: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Made here").font(.headline)
            ForEach(gallery.items) { item in
                Button { opened = item } label: {
                    HStack(spacing: 12) {
                        thumbnail(item.photos.first.map(gallery.photoURL))
                            .frame(width: 54, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.description).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                            Text("\(item.photos.count) photos · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let timings = item.timings {
                                Text(timings.summary).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(KeelStyle.accent)
                    }
                    .padding(10)
                    .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Use these photos again") {
                        photos = item.photos; about = item.description
                        musicFile = item.music; musicTitle = item.music == nil ? nil : "Music from this video"
                    }
                    Button("Delete", role: .destructive) { gallery.delete(item) }
                }
            }
        }
    }

    private func thumbnail(_ url: URL?) -> some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 240)) {
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
                photos = Array((photos + names).prefix(VideoScript.maxPhotos))
            } catch {
                maker.error = error.localizedDescription
            }
        }
    }

    private func refreshVoices() {
        narration.refreshCustomVoices()
        appleVoices = AppleVoices.offered()
        canAskForPersonalVoice = AppleVoices.canAskForPersonalVoice
        if case .kokoro(let id) = NarrationVoiceChoice(id: voice),
           !NarrationVoicePack.voiceIDs.contains(id),
           !narration.customVoices.contains(where: { $0.id == id }) {
            voice = NarrationVoicePack.defaultVoice
        }
    }

    private func make() {
        typing = false
        maker.make(description: about, photos: photos, voice: voice, music: musicFile, motionGraphics: motionGraphics,
                   chat: chat, model: models.current,
                   modelPath: models.path(models.current), gallery: gallery) { item in opened = item }
    }

    private func remake(_ item: StudioVideo, change: String) {
        opened = nil
        maker.make(description: item.description, photos: item.photos, voice: item.voice, music: item.music,
                   motionGraphics: item.style == "motion", from: item, change: change,
                   chat: chat, model: models.current, modelPath: models.path(models.current), gallery: gallery) { made in opened = made }
    }
}

/// Whether the renderer may use the graphics processor; read from the
/// rendering task, set on the main actor as the app comes and goes.
final class GraphicsPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var allowed: Bool { lock.withLock { value } }
    func set(_ allowed: Bool) { lock.withLock { value = allowed } }
}

/// A studio needs the chat model to write its lines or slides. Instead of
/// sending the user to Models, offer the one this phone should use: switch to
/// one already downloaded, or download the recommended one here.
struct StudioChatModelSetup: View {
    /// What the model writes, e.g. "the lines".
    let writes: String
    @EnvironmentObject private var models: ModelLibrary
    @EnvironmentObject private var hardware: HardwareRecommendationStore
    @EnvironmentObject private var chat: LocalChat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let id = models.downloading {
                let name = models.catalog.first { $0.id == id }?.name ?? "the model"
                Text("Downloading \(name)…").font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: models.progress)
            } else if let ready = models.catalog.first(where: { models.installed.contains($0.id) }) {
                Text("A chat model writes \(writes).").font(.footnote).foregroundStyle(.secondary)
                Button("Use \(ready.name)") {
                    models.selected = ready.id
                    Task { await chat.unloadModelsNow() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("studioUseModel")
            } else if let model = hardware.setupModel(for: models) {
                let size = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
                Text("A chat model writes \(writes). Download \(model.name) once (\(size)).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(models.partialBytes[model.id] == nil ? "Download \(model.name)" : "Resume download") {
                    models.install(model)
                }
                .buttonStyle(.bordered)
                .disabled(models.isTransferring || chat.running)
                .accessibilityIdentifier("studioDownloadModel")
            } else {
                Text("Download a chat model in Models; it writes \(writes).").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
