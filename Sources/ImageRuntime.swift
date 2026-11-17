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
    static let pack = ImageModelPack.stableDiffusion21
    @Published private(set) var progress: Double?
    @Published private(set) var installed = ImageModelStore.installedFolder() != nil
    @Published var error: String?
    private var work: Task<Void, Never>?

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
        let folder = Self.folder, pack = Self.pack
        work = Task {
            defer { work = nil; progress = nil; installed = Self.installedFolder() != nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var root = folder; try? root.setResourceValues(excluded)
                let total = Double(pack.totalBytes)
                let missing = pack.missing(in: folder)
                var done = total - Double(missing.reduce(0) { $0 + $1.bytes })
                for file in missing {
                    let base = done
                    progress = done / total
                    let fetched = try await MLXPackDownload.fetch(pack.url(for: file)) { fraction in
                        Task { @MainActor in self.progress = (base + fraction * Double(file.bytes)) / total }
                    }
                    let hash = try await Task.detached { try MLXPackDownload.sha256(of: fetched) }.value
                    let size = (try FileManager.default.attributesOfItem(atPath: fetched.path)[.size] as? NSNumber)?.int64Value
                    guard hash == file.sha256, size == file.bytes else {
                        try? FileManager.default.removeItem(at: fetched)
                        throw ModelVerificationFailure(detail: "\(file.path): SHA-256 or size mismatch")
                    }
                    let destination = folder.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: fetched, to: destination)
                    done += Double(file.bytes)
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func pause() { work?.cancel() }

    func remove() {
        guard work == nil else { return }
        try? FileManager.default.removeItem(at: Self.folder)
        installed = false
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
                Label("This picture is no longer on this iPhone.", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
