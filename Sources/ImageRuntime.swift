import CoreML
import StableDiffusionCore
import SwiftUI
import UIKit
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Makes pictures with the downloaded Core ML diffusion model.
/// On a phone it asks for the Neural Engine, which is where `split_einsum_v2`
/// is fastest and coolest; the simulator only has the CPU.
actor ImageRuntime {
    /// Where finished pictures are kept, next to the chat's other private files.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeneratedImages", isDirectory: true)
    }

    static var preferredUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .cpuAndNeuralEngine
        #endif
    }

    /// Runs the model and returns the picture as PNG data, or nil when
    /// `shouldContinue` or `progress` stopped it. `progress(step, of)` is
    /// called before each denoising step and once before decoding.
    func png(
        for request: ImageRequest.Arguments,
        modelFolder: URL,
        pack: ImageModelPack = ImageModelStore.pack,
        computeUnits: MLComputeUnits = ImageRuntime.preferredUnits,
        steps: Int? = nil,
        shouldContinue: @Sendable () -> Bool = { true },
        onStage: @Sendable (TextToImage.Stage) -> Void = { _ in },
        progress: @Sendable (Int, Int) -> Bool
    ) throws -> Data? {
        let pipeline = try TextToImage(resourcesAt: modelFolder, computeUnits: computeUnits, padToken: pack.padToken)
        let mode: TextToImage.Mode = pack.engine == .lcm ? .lcm : .standard
        let effectiveSteps = steps ?? pack.defaultSteps
        guard let image = try pipeline.generate(
            prompt: request.prompt,
            negativePrompt: pack.defaultNegativePrompt,
            mode: mode,
            steps: effectiveSteps,
            guidance: pack.defaultGuidance,
            seed: request.seed,
            shouldContinue: shouldContinue,
            onStage: onStage,
            progress: progress
        ) else {
            return nil
        }
        return try Self.png(image, side: request.size)
    }

    /// The picture as PNG, scaled down when a smaller size was asked for.
    static func png(_ image: CGImage, side: Int) throws -> Data {
        var picture = UIImage(cgImage: image)
        if image.width != side || image.height != side {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            picture = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                picture.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        guard let data = picture.pngData() else { throw AttachmentError.extractionFailed("The picture could not be saved.") }
        return data
    }

    /// Saves a picture and returns its file name.
    static func save(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let name = UUID().uuidString + ".png"
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return name
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Removes pictures no saved chat shows any more.
    static func prune(keeping names: Set<String>) {
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

/// Shared wrapper around Apple's on-device Image Playground (`ImageCreator`),
/// used by both the Images tab and chat's `generate_image` tool.
enum AppleImageGenerator {
    enum Failure: LocalizedError, Equatable {
        /// Programmatic `ImageCreator` is unsupported or unavailable on this OS/state;
        /// callers with UI can fall back to `.imagePlaygroundSheet`.
        case needsInteractiveSheet(String)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .needsInteractiveSheet(let text), .message(let text): return text
            }
        }
    }

    /// Cheap availability flag — does NOT instantiate `ImageCreator` or claim memory.
    @MainActor
    static var isProgrammaticAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *), ImagePlaygroundViewController.isAvailable {
            return true
        }
        #endif
        return false
    }

    /// Generates one PNG with Apple's on-device `ImageCreator` (iOS 18.4+).
    /// Callers MUST unload heavy local LLMs before calling this so iOS has RAM headroom.
    @MainActor
    static func generate(prompt: String, style: ImageRequest.Style, source: CGImage? = nil, side: Int? = nil) async throws -> Data {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) {
            do {
                let creator = try await ImageCreator()
                let desired: ImagePlaygroundStyle
                switch style {
                case .animation: desired = .animation
                case .illustration: desired = .illustration
                case .sketch: desired = .sketch
                case .photo: desired = .illustration
                }
                let available = creator.availableStyles
                guard !available.isEmpty else {
                    throw Failure.needsInteractiveSheet("Apple Image Playground styles are not ready on this \(KeelDevice.name) yet.")
                }
                let chosen = available.contains(desired) ? desired : available[0]
                var concepts: [ImagePlaygroundConcept] = [.text(prompt)]
                if let source { concepts.append(.image(source)) }
                for try await image in creator.images(for: concepts, style: chosen, limit: 1) {
                    if let side {
                        return try ImageRuntime.png(image.cgImage, side: side)
                    }
                    guard let data = UIImage(cgImage: image.cgImage).pngData() else { break }
                    return data
                }
                throw Failure.message("Image Playground did not return a picture. Try a different description.")
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as Failure {
                throw failure
            } catch let error as ImageCreator.Error {
                switch error {
                case .creationCancelled:
                    throw CancellationError()
                case .notSupported:
                    throw Failure.needsInteractiveSheet("Direct Image Playground generation isn't available on this iOS version. Use Apple's Image Playground sheet instead.")
                case .unavailable:
                    throw Failure.needsInteractiveSheet("Apple Image Playground is temporarily unavailable. Check that Apple Intelligence is enabled and downloaded in Settings.")
                case .unsupportedLanguage:
                    throw Failure.message("Apple Image Playground doesn't support the language in that description. Try writing it in English.")
                case .unsupportedInputImage:
                    throw Failure.message("Image Playground couldn't use that starting photo. Try a different photo or remove it.")
                case .faceInImageTooSmall:
                    throw Failure.message("The face in the starting photo is too small for Image Playground. Try a closer photo.")
                case .conceptsRequirePersonIdentity:
                    throw Failure.message("That description needs a starting photo of a person.")
                case .backgroundCreationForbidden:
                    throw Failure.message("Keep Keel open while Image Playground draws your picture.")
                case .creationFailed:
                    throw Failure.message("Image Playground couldn't draw that description. Try rephrasing it (it avoids realistic people, brands and restricted topics).")
                @unknown default:
                    throw Failure.message(error.localizedDescription)
                }
            }
        }
        #endif
        throw Failure.needsInteractiveSheet("Apple's styles need iOS 18.4 or later with Apple Intelligence.")
    }
}

/// The image model's download: every file pinned and checked, like the chat models.
@MainActor
final class ImageModelStore: ObservableObject {
    /// The primary, recommended Core ML image model pack (DreamShaper 8 LCM).
    nonisolated static let pack = ImageModelPack.defaultPack
    /// Legacy Stable Diffusion 2.1 pack kept working until the user upgrades.
    nonisolated static let legacyPack = ImageModelPack.stableDiffusion21

    @Published private(set) var progress: Double? { didSet { reportContinued() } }
    @Published private(set) var activePack: ImageModelPack? = ImageModelStore.installedPack()?.pack
    @Published private(set) var installed = ImageModelStore.installedPack() != nil
    @Published var error: String?
    private let transferConfiguration: () -> URLSessionConfiguration
    private let backgroundAllowance: BackgroundAllowance
    private let startContinued: ContinuedWork.Starter
    private var continued: ContinuedWorkSession?
    private var work: Task<Void, Never>?

    var isHoldingBackgroundGrace: Bool { backgroundAllowance.isHoldingBackgroundTime }
    var continuesInBackground: Bool { continued?.isRunning == true }
    /// True when the user still has legacy SD 2.1 installed and hasn't upgraded to DreamShaper 8 LCM.
    var canUpgrade: Bool { activePack == Self.legacyPack }

    init(transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         backgroundAllowance: BackgroundAllowance? = nil,
         continuedWork: @escaping ContinuedWork.Starter = ContinuedWork.system) {
        self.transferConfiguration = transferConfiguration
        self.backgroundAllowance = backgroundAllowance ?? BackgroundAllowance()
        self.startContinued = continuedWork
    }

    nonisolated static func folder(for pack: ImageModelPack) -> URL {
        pack.directory(in: ModelLibrary.defaultDirectory)
    }

    nonisolated static var folder: URL { folder(for: pack) }

    /// The best installed Core ML image pack and folder that fits this device's memory,
    /// preferring DreamShaper 8 LCM over legacy SD 2.1.
    nonisolated static func installedPack() -> (pack: ImageModelPack, folder: URL)? {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        for candidate in ImageModelPack.allPacks {
            let dir = folder(for: candidate)
            if candidate.missing(in: dir).isEmpty,
               ImageRequest.fits(imageModelBytes: UInt64(candidate.totalBytes), physicalMemoryBytes: physicalMemory) {
                return (candidate, dir)
            }
        }
        return nil
    }

    /// The active model's folder when every file is there and this device has the memory for it.
    nonisolated static func installedFolder() -> URL? {
        installedPack()?.folder
    }

    /// Nil when this device can make images; otherwise why not.
    static var unsupportedReason: String? {
        ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            ? nil : ImageRequest.Problem.memory.localizedDescription
    }

    var downloading: Bool { work != nil }

    func refreshState() {
        let current = Self.installedPack()?.pack
        activePack = current
        installed = current != nil
    }

    func download() {
        guard work == nil else { return }
        error = nil
        let folder = Self.folder, pack = Self.pack, configuration = transferConfiguration
        beginContinued(title: "Downloading \(pack.name)")
        work = Task {
            defer {
                work = nil
                progress = nil
                backgroundAllowance.release()
                finishContinued()
                refreshState()
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var root = folder; try? root.setResourceValues(excluded)
                let total = Double(pack.totalBytes)
                let missing = pack.missing(in: folder)
                let missingBytes = missing.reduce(Int64(0)) { $0 + $1.bytes }
                let savedPartial = missing.reduce(Int64(0)) { sum, file in
                    let staging = folder.appendingPathComponent(file.path).appendingPathExtension("download")
                    let bytes = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    return sum + min(bytes, file.bytes)
                }
                let remaining = max(Int64(0), missingBytes - savedPartial)
                let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
                guard remaining == 0 || available > remaining + 256_000_000 else { throw LocalModelError.storage }
                var done = total - Double(missingBytes)
                for file in missing {
                    let base = done
                    let destination = folder.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let staging = destination.appendingPathExtension("download")
                    if let existing = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                       existing > file.bytes {
                        try? FileManager.default.removeItem(at: staging)
                    }
                    var transfer = LocalModel(id: file.path, name: file.path, bytes: file.bytes, revision: pack.revision,
                                              sha256: file.sha256, detail: "", repository: pack.repository, fileName: file.path)
                    transfer.sourceURL = pack.url(for: file)
                    let partial = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    progress = min(1, (base + Double(partial)) / total)
                    do {
                        try await ModelTransfer.fetch(transfer, to: staging, configuration: configuration()) { [weak self] received, _ in
                            Task { @MainActor [weak self] in
                                guard self?.work != nil else { return }
                                self?.progress = min(1, (base + Double(received)) / total)
                            }
                        }
                        try Task.checkCancellation()
                        let verification = Task.detached(priority: .utility) { try ModelLibrary.verify(staging, model: transfer) }
                        try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
                        try Task.checkCancellation()
                    } catch {
                        if error is ModelVerificationFailure { try? FileManager.default.removeItem(at: staging) }
                        else if case LocalModelError.integrity = error { try? FileManager.default.removeItem(at: staging) }
                        throw error
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: staging, to: destination)
                    done += Double(file.bytes)
                }
                // Once the new pack is complete, reclaim storage from any legacy pack.
                if pack.missing(in: folder).isEmpty {
                    let legacyDir = Self.folder(for: Self.legacyPack)
                    if legacyDir != folder {
                        try? FileManager.default.removeItem(at: legacyDir)
                    }
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = error is LocalModelError || error is ModelVerificationFailure
                    ? error.localizedDescription : "Download interrupted. Your progress is kept; check your connection and resume."
            }
        }
    }

    func pause() {
        backgroundAllowance.release()
        work?.cancel()
    }

    func remove() {
        guard work == nil else { return }
        for candidate in ImageModelPack.allPacks {
            try? FileManager.default.removeItem(at: Self.folder(for: candidate))
        }
        refreshState()
    }

    func sceneDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            backgroundAllowance.release()
        case .background:
            guard downloading else { return }
            if continued?.isRunning == true { return }
            backgroundAllowance.acquire(name: "KeelImageModelTransfer") { [weak self] in
                guard self?.continued?.isRunning != true else { return }
                self?.pause()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func beginContinued(title: String) {
        continued?.finish(success: false)
        continued = startContinued(.transfer, title, "Starting…") { [weak self] in
            self?.pause()
        }
        reportContinued()
    }

    private func reportContinued() {
        guard let continued, let progress else { return }
        continued.update(fraction: progress, subtitle: "\(Int(min(max(progress, 0), 1) * 100))% downloaded")
    }

    private func finishContinued() {
        continued?.finish(success: error == nil && !Task.isCancelled && Self.pack.missing(in: Self.folder).isEmpty)
        continued = nil
    }
}

/// A picture the agent made, in the chat: the image, what it was asked for, and Share.
struct GeneratedImageView: View {
    let name: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let picture = UIImage(contentsOfFile: ImageRuntime.url(name).path) {
                Image(uiImage: picture).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Generated image")
                    .accessibilityIdentifier("generatedImage")
                ShareLink(item: ImageRuntime.url(name)) {
                    Label("Share or save", systemImage: "square.and.arrow.up").font(.caption.weight(.medium))
                }
            } else {
                Label("This picture is no longer on this \(KeelDevice.name).", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
