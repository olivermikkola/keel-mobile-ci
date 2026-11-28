import CoreML
import CryptoKit
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

/// The image model's download and BYO Core ML pack store: every built-in file is
/// pinned and hash-checked, and user-imported Core ML Stable Diffusion packs
/// (from folders, `.zip` archives, or public Hugging Face repositories) are
/// layout-checked, memory-checked, fingerprinted, and stored alongside them.
@MainActor
final class ImageModelStore: ObservableObject {
    /// The primary, recommended Core ML image model pack (DreamShaper 8 LCM).
    nonisolated static let pack = ImageModelPack.defaultPack
    /// Legacy Stable Diffusion 2.1 pack kept working until the user upgrades.
    nonisolated static let legacyPack = ImageModelPack.stableDiffusion21
    nonisolated static let selectedPackKey = "selectedImagePackID"

    @Published private(set) var progress: Double? { didSet { reportContinued() } }
    @Published private(set) var importing: String? { didSet { reportContinued() } }
    @Published private(set) var importedPacks: [ImportedImagePack] = []
    @Published private(set) var selectedPackID: String?
    @Published private(set) var activePack: ImageModelPack?
    @Published private(set) var installed = false
    @Published private(set) var builtInInstalled = false
    @Published var error: String?

    private let modelsDirectory: URL
    private let defaults: UserDefaults
    private let transferConfiguration: () -> URLSessionConfiguration
    private let backgroundAllowance: BackgroundAllowance
    private let startContinued: ContinuedWork.Starter
    private var continued: ContinuedWorkSession?
    private var work: Task<Void, Never>?

    var isHoldingBackgroundGrace: Bool { backgroundAllowance.isHoldingBackgroundTime }
    var continuesInBackground: Bool { continued?.isRunning == true }
    /// True when the user still has legacy SD 2.1 installed and hasn't upgraded to DreamShaper 8 LCM.
    var canUpgrade: Bool {
        Self.builtInInstalledPack(in: modelsDirectory)?.pack == Self.legacyPack
    }

    /// All currently installed Core ML packs (built-in + imported) that fit this device's memory.
    var installedPacks: [ImageModelPack] {
        Self.allInstalledPacks(in: modelsDirectory).map(\.pack)
    }

    init(modelsDirectory: URL = ModelLibrary.defaultDirectory,
         defaults: UserDefaults = .standard,
         transferConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         backgroundAllowance: BackgroundAllowance? = nil,
         continuedWork: @escaping ContinuedWork.Starter = ContinuedWork.system) {
        self.modelsDirectory = modelsDirectory
        self.defaults = defaults
        self.transferConfiguration = transferConfiguration
        self.backgroundAllowance = backgroundAllowance ?? BackgroundAllowance()
        self.startContinued = continuedWork
        Self.cleanupOrphanStaging(in: modelsDirectory)
        refreshState()
    }

    nonisolated static func imageRoot(in modelsDirectory: URL = ModelLibrary.defaultDirectory) -> URL {
        modelsDirectory.appendingPathComponent("image", isDirectory: true)
    }

    nonisolated static func importedManifestURL(in modelsDirectory: URL = ModelLibrary.defaultDirectory) -> URL {
        imageRoot(in: modelsDirectory).appendingPathComponent("imported-packs.json")
    }

    nonisolated static func loadImportedPacks(in modelsDirectory: URL = ModelLibrary.defaultDirectory) -> [ImportedImagePack] {
        guard let data = try? Data(contentsOf: importedManifestURL(in: modelsDirectory)) else { return [] }
        return ImportedImagePack.load(data)
    }

    nonisolated static func folder(for pack: ImageModelPack, in modelsDirectory: URL = ModelLibrary.defaultDirectory) -> URL {
        pack.directory(in: modelsDirectory)
    }

    nonisolated static var folder: URL { folder(for: pack) }

    nonisolated private static func cleanupOrphanStaging(in modelsDirectory: URL) {
        let root = imageRoot(in: modelsDirectory)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix("custom-img-") && name.hasSuffix(".import") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    nonisolated private static func builtInInstalledPack(in modelsDirectory: URL) -> (pack: ImageModelPack, folder: URL)? {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        for candidate in ImageModelPack.allPacks {
            let dir = folder(for: candidate, in: modelsDirectory)
            if candidate.missing(in: dir).isEmpty,
               ImageRequest.fits(imageModelBytes: UInt64(candidate.totalBytes), physicalMemoryBytes: physicalMemory) {
                return (candidate, dir)
            }
        }
        return nil
    }

    nonisolated static func allInstalledPacks(in modelsDirectory: URL = ModelLibrary.defaultDirectory) -> [(pack: ImageModelPack, folder: URL)] {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        var results: [(pack: ImageModelPack, folder: URL)] = []
        if let builtIn = builtInInstalledPack(in: modelsDirectory) {
            results.append(builtIn)
        }
        for imported in loadImportedPacks(in: modelsDirectory) {
            let dir = imported.directory(in: modelsDirectory)
            if ImportedImagePack.isPresent(in: dir, chunkedUnet: imported.chunkedUnet),
               ImageRequest.fits(imageModelBytes: UInt64(imported.bytes), physicalMemoryBytes: physicalMemory) {
                results.append((imported.asImageModelPack(), dir))
            }
        }
        return results
    }

    /// The active installed Core ML image pack and folder that fits this device's memory,
    /// honoring the user's selected pack (built-in or BYO imported) when installed.
    nonisolated static func installedPack(
        in modelsDirectory: URL = ModelLibrary.defaultDirectory,
        defaults: UserDefaults = .standard
    ) -> (pack: ImageModelPack, folder: URL)? {
        let available = allInstalledPacks(in: modelsDirectory)
        guard !available.isEmpty else { return nil }
        if let chosen = defaults.string(forKey: selectedPackKey),
           let match = available.first(where: { $0.pack.id == chosen }) {
            return match
        }
        if let preferredDefault = available.first(where: { $0.pack.id == pack.id }) {
            return preferredDefault
        }
        if let imported = available.first(where: { $0.pack.repository == "imported" }) {
            return imported
        }
        return available.first
    }

    /// The active model's folder when every file is there and this device has the memory for it.
    nonisolated static func installedFolder() -> URL? {
        installedPack()?.folder
    }

    nonisolated static func installedFolder(
        in modelsDirectory: URL,
        defaults: UserDefaults = .standard
    ) -> URL? {
        installedPack(in: modelsDirectory, defaults: defaults)?.folder
    }

    /// Nil when this device can make images; otherwise why not.
    static var unsupportedReason: String? {
        ImageRequest.fits(imageModelBytes: UInt64(pack.totalBytes), physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            ? nil : ImageRequest.Problem.memory.localizedDescription
    }

    var downloading: Bool { work != nil }

    func refreshState() {
        importedPacks = Self.loadImportedPacks(in: modelsDirectory)
        builtInInstalled = Self.builtInInstalledPack(in: modelsDirectory) != nil
        let current = Self.installedPack(in: modelsDirectory, defaults: defaults)?.pack
        activePack = current
        selectedPackID = current?.id
        installed = current != nil
    }

    func selectPack(_ id: String) {
        guard Self.allInstalledPacks(in: modelsDirectory).contains(where: { $0.pack.id == id }) else { return }
        defaults.set(id, forKey: Self.selectedPackKey)
        refreshState()
    }

    func setImportedEngine(_ id: String, engine: ImageModelPack.Engine) {
        guard work == nil, let idx = importedPacks.firstIndex(where: { $0.id == id }) else { return }
        let previous = importedPacks[idx]
        importedPacks[idx].engine = engine
        do {
            try saveImportedPacks()
            refreshState()
        } catch {
            importedPacks[idx] = previous
            self.error = "Could not update image pack settings."
        }
    }

    func download() {
        guard work == nil else { return }
        error = nil
        let folder = Self.folder(for: Self.pack, in: modelsDirectory)
        let legacyDir = Self.folder(for: Self.legacyPack, in: modelsDirectory)
        let pack = Self.pack, configuration = transferConfiguration
        beginContinued(title: "Downloading \(pack.name)")
        work = Task {
            defer {
                work = nil
                progress = nil
                importing = nil
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
                    if legacyDir != folder {
                        try? FileManager.default.removeItem(at: legacyDir)
                    }
                    defaults.set(pack.id, forKey: Self.selectedPackKey)
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = error is LocalModelError || error is ModelVerificationFailure
                    ? error.localizedDescription : "Download interrupted. Your progress is kept; check your connection and resume."
            }
        }
    }

    /// Imports a user-supplied Core ML Stable Diffusion pack from a folder or `.zip`
    /// archive chosen in Files. Validates structure, tokenizer, architecture, and
    /// device memory before committing atomically.
    func importPack(from source: URL) {
        guard work == nil else { return }
        guard importedPacks.count < ImportedImagePack.limit else {
            error = "You have \(ImportedImagePack.limit) imported image packs. Remove one before importing another."
            return
        }
        error = nil
        importing = "Checking Core ML pack…"
        progress = 0
        let modelsDir = modelsDirectory
        let memory = ProcessInfo.processInfo.physicalMemory
        beginContinued(title: "Importing Core ML image pack")
        work = Task {
            defer {
                work = nil
                progress = nil
                importing = nil
                backgroundAllowance.release()
                finishContinued()
                refreshState()
            }
            do {
                let job = Task.detached(priority: .userInitiated) {
                    try Self.copyOrExtractPack(
                        from: source,
                        into: modelsDir,
                        physicalMemoryBytes: memory
                    ) { [weak self] fraction, status in
                        Task { @MainActor [weak self] in
                            guard self?.work != nil else { return }
                            self?.progress = fraction
                            self?.importing = status
                        }
                    }
                }
                let imported = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                do { try Task.checkCancellation() } catch {
                    try? FileManager.default.removeItem(at: imported.directory(in: modelsDir))
                    throw error
                }
                importedPacks.append(imported)
                do {
                    try saveImportedPacks()
                } catch {
                    importedPacks.removeLast()
                    try? FileManager.default.removeItem(at: imported.directory(in: modelsDir))
                    throw error
                }
                defaults.set(imported.id, forKey: Self.selectedPackKey)
            } catch is CancellationError {
            } catch ZipArchiveReader.Failure.cancelled {
            } catch {
                self.error = Self.userMessage(for: error, fallback: "The image pack could not be imported. Choose a compiled Core ML Stable Diffusion folder or .zip from Files.")
            }
        }
    }

    /// Downloads and imports a compiled Core ML Stable Diffusion pack from a public
    /// Hugging Face repository or `/tree/<revision>/<folder>` link.
    func importPack(link text: String) {
        guard work == nil else { return }
        guard importedPacks.count < ImportedImagePack.limit else {
            error = "You have \(ImportedImagePack.limit) imported image packs. Remove one before importing another."
            return
        }
        let link: HuggingFaceCoreMLPackLink
        do { link = try HuggingFaceCoreMLPackLink.parse(text) } catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        importing = "Inspecting Hugging Face pack…"
        progress = 0
        let modelsDir = modelsDirectory
        let memory = ProcessInfo.processInfo.physicalMemory
        let configuration = transferConfiguration
        beginContinued(title: "Downloading \(link.displayName)")
        work = Task {
            let id = ImportedImagePack.newID()
            let root = Self.imageRoot(in: modelsDir)
            let staging = root.appendingPathComponent(id + ".import", isDirectory: true)
            defer {
                work = nil
                progress = nil
                importing = nil
                backgroundAllowance.release()
                finishContinued()
                try? FileManager.default.removeItem(at: staging)
                refreshState()
            }
            do {
                try Task.checkCancellation()
                let treeEntries = try await Self.fetchHuggingFaceTree(link: link, configuration: configuration())
                let fileMap = Dictionary(uniqueKeysWithValues: treeEntries.filter { $0.type == "file" }.map { ($0.path, $0) })
                let layoutEntries = treeEntries
                    .filter { $0.type == "file" }
                    .map { (path: $0.path, bytes: $0.effectiveBytes, sha256: $0.lfsSHA256) }
                let plan = try CoreMLImagePackLayout.plan(entries: layoutEntries, physicalMemoryBytes: memory)

                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var rootFolder = root
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                try? rootFolder.setResourceValues(excluded)

                let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? 0
                guard available > plan.totalBytes + 256_000_000 else { throw LocalModelError.storage }

                let total = Double(max(1, plan.totalBytes))
                var completedBytes: Int64 = 0
                var manifestLines: [String] = []

                for file in plan.files {
                    try Task.checkCancellation()
                    guard let fileURL = link.resolveURL(forRepoPath: file.sourcePath) else {
                        throw CustomModelError.invalidPath("Unsafe file path \(file.sourcePath) in repository.")
                    }
                    let destination = staging.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let base = Double(completedBytes)
                    var transfer = LocalModel(
                        id: file.relativePath,
                        name: file.relativePath,
                        bytes: file.bytes,
                        revision: link.revision,
                        sha256: file.sha256 ?? "",
                        detail: "",
                        repository: link.repository,
                        fileName: file.sourcePath
                    )
                    transfer.sourceURL = fileURL
                    importing = "Downloading \(link.displayName) · \(Int(min(1, base / total) * 100))%"
                    progress = min(1, base / total)

                    try await ModelTransfer.fetch(transfer, to: destination, configuration: configuration()) { [weak self] received, _ in
                        Task { @MainActor [weak self] in
                            guard self?.work != nil else { return }
                            let fraction = min(1, (base + Double(received)) / total)
                            self?.progress = fraction
                            self?.importing = "Downloading \(link.displayName) · \(Int(fraction * 100))%"
                        }
                    }
                    try Task.checkCancellation()

                    let treeItem = fileMap[file.sourcePath]
                    let fileHash = try await Task.detached(priority: .utility) {
                        try Self.verifyDownloadedFile(
                            at: destination,
                            expectedBytes: file.bytes,
                            expectedSHA256: file.sha256,
                            expectedGitOID: treeItem?.oid
                        )
                    }.value
                    manifestLines.append("\(file.relativePath):\(file.bytes):\(fileHash)")
                    completedBytes += file.bytes
                }

                importing = "Verifying Core ML pack…"
                let packRecord = try await Task.detached(priority: .utility) {
                    try Self.finalizeStagedPack(
                        id: id,
                        staging: staging,
                        modelsDirectory: modelsDir,
                        name: link.displayName,
                        totalBytes: plan.totalBytes,
                        fileCount: plan.files.count,
                        chunkedUnet: plan.chunkedUnet,
                        manifestLines: manifestLines,
                        engineHint: "\(link.repository)/\(link.subpath)/\(plan.rootPrefix)",
                        sourceLabel: link.repository
                    )
                }.value

                try Task.checkCancellation()
                importedPacks.append(packRecord)
                do {
                    try saveImportedPacks()
                } catch {
                    importedPacks.removeLast()
                    try? FileManager.default.removeItem(at: packRecord.directory(in: modelsDir))
                    throw error
                }
                defaults.set(packRecord.id, forKey: Self.selectedPackKey)
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = Self.userMessage(for: error, fallback: "The Core ML pack could not be downloaded. Check your connection and link, then try again.")
            }
        }
    }

    func pause() {
        backgroundAllowance.release()
        work?.cancel()
    }

    /// Removes built-in Core ML packs (DreamShaper 8 LCM / SD 2.1), leaving imported packs intact.
    func remove() {
        guard work == nil else { return }
        for candidate in ImageModelPack.allPacks {
            try? FileManager.default.removeItem(at: Self.folder(for: candidate, in: modelsDirectory))
        }
        if let chosen = defaults.string(forKey: Self.selectedPackKey),
           ImageModelPack.allPacks.contains(where: { $0.id == chosen }) {
            defaults.removeObject(forKey: Self.selectedPackKey)
        }
        refreshState()
    }

    func removeImported(_ id: String) {
        guard work == nil, let idx = importedPacks.firstIndex(where: { $0.id == id }) else { return }
        let removed = importedPacks.remove(at: idx)
        do {
            try saveImportedPacks()
        } catch {
            importedPacks.insert(removed, at: idx)
            self.error = "Could not remove this image pack. Try again."
            return
        }
        try? FileManager.default.removeItem(at: removed.directory(in: modelsDirectory))
        if defaults.string(forKey: Self.selectedPackKey) == id {
            defaults.removeObject(forKey: Self.selectedPackKey)
        }
        refreshState()
    }

    private func saveImportedPacks() throws {
        let root = Self.imageRoot(in: modelsDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        let data = try JSONEncoder().encode(importedPacks)
        try data.write(to: Self.importedManifestURL(in: modelsDirectory), options: [.atomic, .completeFileProtection])
    }

    // MARK: - Local folder / .zip import (off main actor)

    nonisolated static func copyOrExtractPack(
        from source: URL,
        into modelsDirectory: URL,
        physicalMemoryBytes: UInt64,
        progress: @Sendable (Double, String) -> Void
    ) throws -> ImportedImagePack {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw CoreMLImagePackLayout.Problem.empty
        }

        let id = ImportedImagePack.newID()
        let root = imageRoot(in: modelsDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rootFolder = root
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? rootFolder.setResourceValues(excluded)

        let staging = root.appendingPathComponent(id + ".import", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let plan: CoreMLImagePackLayout.Plan
        var manifestLines: [String] = []

        if isDir.boolValue {
            let walked = try walkLocalFolder(at: source)
            plan = try CoreMLImagePackLayout.plan(entries: walked.map { ($0.path, $0.bytes, nil) }, physicalMemoryBytes: physicalMemoryBytes)
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available > plan.totalBytes + 256_000_000 else { throw LocalModelError.storage }

            let total = Double(max(1, plan.totalBytes))
            var copiedBytes: Int64 = 0
            for file in plan.files {
                try Task.checkCancellation()
                let srcURL = source.appendingPathComponent(file.sourcePath)
                let dstURL = staging.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = copiedBytes
                let fileHash = try copyFileStreaming(from: srcURL, to: dstURL, expectedBytes: file.bytes) { written in
                    let fraction = min(1, Double(base + written) / total)
                    progress(fraction, "Copying pack · \(Int(fraction * 100))%")
                }
                manifestLines.append("\(file.relativePath):\(file.bytes):\(fileHash)")
                copiedBytes += file.bytes
            }
        } else {
            guard source.pathExtension.lowercased() == "zip" else {
                throw ZipArchiveReader.Failure.invalidArchive("choose a folder or a .zip archive containing compiled Core ML models.")
            }
            let entries = try ZipArchiveReader.listEntries(
                at: source,
                maxEntries: 2_000,
                maxTotalBytes: UInt64(ImportedImagePack.maxPackBytes)
            )
            let entryByPath = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.path, $0) })
            let layoutInput = entries
                .filter { !$0.isDirectory }
                .map { (path: $0.path, bytes: Int64(min($0.uncompressedSize, UInt64(Int64.max))), sha256: nil as String?) }
            plan = try CoreMLImagePackLayout.plan(entries: layoutInput, physicalMemoryBytes: physicalMemoryBytes)

            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available > plan.totalBytes + 256_000_000 else { throw LocalModelError.storage }

            let total = Double(max(1, plan.totalBytes))
            var extractedBytes: Int64 = 0
            for file in plan.files {
                try Task.checkCancellation()
                guard let entry = entryByPath[file.sourcePath] else {
                    throw CoreMLImagePackLayout.Problem.missingFiles([file.relativePath])
                }
                let dstURL = staging.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: dstURL.path, contents: nil) else {
                    throw LocalModelError.storage
                }
                let output = try FileHandle(forWritingTo: dstURL)
                var hasher = SHA256()
                var fileWritten: Int64 = 0
                let base = extractedBytes
                do {
                    try ZipArchiveReader.extractEntry(
                        entry,
                        from: source,
                        maxBytes: entry.uncompressedSize,
                        shouldContinue: { !Task.isCancelled }
                    ) { buffer in
                        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), count: buffer.count, deallocator: .none)
                        hasher.update(data: data)
                        try output.write(contentsOf: data)
                        fileWritten += Int64(buffer.count)
                        let fraction = min(1, Double(base + fileWritten) / total)
                        progress(fraction, "Unpacking zip · \(Int(fraction * 100))%")
                    }
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
                let fileHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                manifestLines.append("\(file.relativePath):\(file.bytes):\(fileHash)")
                extractedBytes += file.bytes
            }
        }

        progress(0.99, "Verifying Core ML pack…")
        return try finalizeStagedPack(
            id: id,
            staging: staging,
            modelsDirectory: modelsDirectory,
            name: source.lastPathComponent,
            totalBytes: plan.totalBytes,
            fileCount: plan.files.count,
            chunkedUnet: plan.chunkedUnet,
            manifestLines: manifestLines,
            engineHint: "\(source.lastPathComponent)/\(plan.rootPrefix)",
            sourceLabel: "Files"
        )
    }

    nonisolated private static func walkLocalFolder(at root: URL) throws -> [(path: String, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let deepWalker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw CoreMLImagePackLayout.Problem.empty
        }
        let basePath = root.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        var items: [(path: String, bytes: Int64)] = []
        for case let url as URL in deepWalker {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ZipArchiveReader.Failure.unsafePath("symbolic link in folder")
            }
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let rel = String(full.dropFirst(prefix.count))
            let size = Int64(values.fileSize ?? 0)
            items.append((rel, size))
            if items.count > 4_000 {
                throw CoreMLImagePackLayout.Problem.tooManyFiles(items.count)
            }
        }
        return items
    }

    nonisolated private static func copyFileStreaming(
        from source: URL,
        to destination: URL,
        expectedBytes: Int64,
        onProgress: (Int64) -> Void
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LocalModelError.storage
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 4_194_304), !chunk.isEmpty {
            try Task.checkCancellation()
            guard copied + Int64(chunk.count) <= expectedBytes else {
                throw CoreMLImagePackLayout.Problem.invalidTokenizer("A file changed while it was being copied.")
            }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            onProgress(copied)
        }
        guard copied == expectedBytes else {
            throw CoreMLImagePackLayout.Problem.invalidTokenizer("A file changed while it was being copied.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func verifyDownloadedFile(
        at url: URL,
        expectedBytes: Int64,
        expectedSHA256: String?,
        expectedGitOID: String?
    ) throws -> String {
        let actualSize = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        guard actualSize == expectedBytes else {
            throw ModelVerificationFailure(detail: "Expected \(expectedBytes) bytes; received \(actualSize).")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        let checkGitBlob = expectedSHA256 == nil
            && expectedGitOID?.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
        if checkGitBlob {
            gitSHA1.update(data: Data("blob \(expectedBytes)\0".utf8))
        }
        while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            sha256.update(data: block)
            if checkGitBlob { gitSHA1.update(data: block) }
        }
        let actualSHA256 = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256 {
            guard actualSHA256 == expectedSHA256.lowercased() else {
                throw ModelVerificationFailure(detail: "SHA-256 mismatch for \(url.lastPathComponent).")
            }
        } else if checkGitBlob, let expectedGitOID {
            let actualSHA1 = gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualSHA1 == expectedGitOID.lowercased() else {
                throw ModelVerificationFailure(detail: "File integrity mismatch for \(url.lastPathComponent).")
            }
        }
        return actualSHA256
    }

    nonisolated private static func finalizeStagedPack(
        id: String,
        staging: URL,
        modelsDirectory: URL,
        name: String,
        totalBytes: Int64,
        fileCount: Int,
        chunkedUnet: Bool,
        manifestLines: [String],
        engineHint: String,
        sourceLabel: String
    ) throws -> ImportedImagePack {
        let vocabData = try Data(contentsOf: staging.appendingPathComponent("vocab.json"))
        let mergesData = try Data(contentsOf: staging.appendingPathComponent("merges.txt"))
        try CoreMLImagePackLayout.validateTokenizer(vocabData: vocabData, mergesData: mergesData)

        let textMetadata = try? String(
            contentsOf: staging.appendingPathComponent("TextEncoder.mlmodelc/metadata.json"),
            encoding: .utf8
        )
        let unetMetadataPath = chunkedUnet ? "UnetChunk1.mlmodelc/metadata.json" : "Unet.mlmodelc/metadata.json"
        let unetMetadata = try? String(
            contentsOf: staging.appendingPathComponent(unetMetadataPath),
            encoding: .utf8
        )
        if let reason = ImportedImagePack.unsupportedMetadataReason(unetMetadata: unetMetadata) {
            throw CoreMLImagePackLayout.Problem.unsupportedArchitecture(reason)
        }

        let padToken = ImportedImagePack.detectPadToken(textEncoderMetadata: textMetadata)
        let engine = ImportedImagePack.inferEngine(from: engineHint)
        let manifestFingerprint = SHA256.hash(data: Data(manifestLines.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()

        let record = ImportedImagePack(
            id: id,
            name: name,
            bytes: totalBytes,
            fileCount: fileCount,
            sha256: manifestFingerprint,
            engine: engine,
            padToken: padToken,
            chunkedUnet: chunkedUnet,
            sourceLabel: sourceLabel
        )
        let finalDir = record.directory(in: modelsDirectory)
        try? FileManager.default.removeItem(at: finalDir)
        try FileManager.default.moveItem(at: staging, to: finalDir)
        return record
    }

    nonisolated private static func fetchHuggingFaceTree(
        link: HuggingFaceCoreMLPackLink,
        configuration: URLSessionConfiguration
    ) async throws -> [HuggingFaceTreeEntry] {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var all: [HuggingFaceTreeEntry] = []
        var nextURL: URL? = link.treeAPIURL
        var visited = Set<URL>()
        let allowedPrefix = "https://huggingface.co/api/models/\(link.repository)/"

        while let url = nextURL {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, visited.count <= 10 else { break }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HuggingFaceImport.Failure.unreachable(0)
            }
            guard http.statusCode == 200 else {
                throw HuggingFaceImport.Failure.unreachable(http.statusCode)
            }
            let page = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
            all.append(contentsOf: page)
            if let linkHeader = http.value(forHTTPHeaderField: "Link"),
               let next = parseNextLink(linkHeader),
               next.absoluteString.hasPrefix(allowedPrefix) {
                nextURL = next
            } else {
                nextURL = nil
            }
        }
        return all
    }

    nonisolated private static func parseNextLink(_ header: String) -> URL? {
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.contains("rel=\"next\"") else { continue }
            let raw = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if let url = URL(string: raw), url.scheme == "https", url.host == "huggingface.co" {
                return url
            }
        }
        return nil
    }

    nonisolated private static func userMessage(for error: Error, fallback: String) -> String {
        if error is CoreMLImagePackLayout.Problem || error is ZipArchiveReader.Failure
            || error is CustomModelError || error is HuggingFaceImport.Failure
            || error is LocalModelError || error is ModelVerificationFailure {
            return error.localizedDescription
        }
        return fallback
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
        guard let continued else { return }
        if let importing {
            continued.update(fraction: progress ?? 0, subtitle: importing)
        } else if let progress {
            continued.update(fraction: progress, subtitle: "\(Int(min(max(progress, 0), 1) * 100))% downloaded")
        }
    }

    private func finishContinued() {
        let succeeded = error == nil && !Task.isCancelled && Self.installedPack(in: modelsDirectory, defaults: defaults) != nil
        continued?.finish(success: succeeded)
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
