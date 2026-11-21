import CoreML
import StableDiffusionCore
import SwiftUI
import UIKit
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Makes pictures with the downloaded Stable Diffusion model, through Core ML.
/// On a phone it asks for the Neural Engine, which is where this model's
/// layout is fastest and coolest; the simulator only has the CPU.
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
    /// `progress` stopped it. `progress(step, of)` is called before each step.
    func png(for request: ImageRequest.Arguments, modelFolder: URL, computeUnits: MLComputeUnits = ImageRuntime.preferredUnits,
             steps: Int = ImageRequest.steps, progress: @Sendable (Int, Int) -> Bool) throws -> Data? {
        let pipeline = try TextToImage(resourcesAt: modelFolder, computeUnits: computeUnits)
        guard let image = try pipeline.generate(prompt: request.prompt, steps: steps, seed: request.seed, progress: progress) else {
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

/// The image model's download: every file pinned and checked, like the chat models.
@MainActor
final class ImageModelStore: ObservableObject {
    nonisolated static let pack = ImageModelPack.stableDiffusion21
    @Published private(set) var progress: Double? { didSet { reportContinued() } }
    @Published private(set) var installed = ImageModelStore.installedFolder() != nil
    @Published var error: String?
    private let transferConfiguration: () -> URLSessionConfiguration
    private let backgroundAllowance: BackgroundAllowance
    private let startContinued: ContinuedWork.Starter
    private var continued: ContinuedWorkSession?
    private var work: Task<Void, Never>?

    var isHoldingBackgroundGrace: Bool { backgroundAllowance.isHoldingBackgroundTime }
    var continuesInBackground: Bool { continued?.isRunning == true }

    init(transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         backgroundAllowance: BackgroundAllowance? = nil,
         continuedWork: @escaping ContinuedWork.Starter = ContinuedWork.system) {
        self.transferConfiguration = transferConfiguration
        self.backgroundAllowance = backgroundAllowance ?? BackgroundAllowance()
        self.startContinued = continuedWork
    }

    nonisolated static var folder: URL { pack.directory(in: ModelLibrary.defaultDirectory) }

    /// The model's folder when every file is there and this device has the memory for it.
    nonisolated static func installedFolder() -> URL? {
        guard pack.missing(in: folder).isEmpty,
              ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory) else { return nil }
        return folder
    }

    /// Nil when this device can make images; otherwise why not.
    static var unsupportedReason: String? {
        ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            ? nil : ImageRequest.Problem.memory.localizedDescription
    }

    var downloading: Bool { work != nil }

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
                installed = Self.installedFolder() != nil
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
        try? FileManager.default.removeItem(at: Self.folder)
        installed = false
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
        continued?.finish(success: error == nil && !Task.isCancelled && Self.installedFolder() != nil)
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
