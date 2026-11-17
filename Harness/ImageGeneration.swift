import Foundation

/// Making images on the phone (`generate_image`).
///
/// A diffusion model (about 1.1 GB) and the chat model cannot both sit in an
/// 8 GB iPhone's memory budget, so they take turns: the chat model is
/// unloaded, the image model is loaded and run, the image model is unloaded,
/// and the chat model loads again on the next step. `ModelSwap` enforces that
/// order; `ImageRequest` is the tool's call format and limits; `ImageModelPack`
/// pins the model's files. The diffusion runtime is in the app
/// (`ImageRuntime`, Core ML): the tool is only offered once the model is
/// downloaded and passes `ImageRequest.fits`.
public enum ImageRequest {
    public static let tool = #"{"type":"function","function":{"name":"generate_image","description":"Make one picture from a text description and save it as a .png file in this chat. Describe the subject, style and colours in under 300 characters. Size is 256, 384 or 512 (default 512). Takes about a minute; the chat model pauses meanwhile.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"path":{"type":"string"},"size":{"type":"integer","enum":[256,384,512]}},"required":["prompt","path"]}}}"#

    public static let maxPromptCharacters = 300
    public static let sizes = [256, 384, 512]
    public static let defaultSize = 512
    /// Stable Diffusion 2.1 with the DPM-Solver++ scheduler: fewer steps look
    /// unfinished, more cost time and heat for little gain.
    public static let steps = 20
    /// The longest a run may take before it is stopped. The first run after
    /// a download is the slow one: Core ML prepares the model for the phone's chip.
    public static let timeLimit: TimeInterval = 300

    public struct Arguments: Equatable, Sendable {
        public let prompt: String
        public let path: String
        public let size: Int
        public let seed: UInt32
    }

    public enum Problem: LocalizedError, Equatable {
        case arguments, prompt, path, size, memory, busy, slow
        public var errorDescription: String? {
            switch self {
            case .arguments: return "Expected prompt, path and optional size."
            case .prompt: return "Describe the picture in 1 to \(ImageRequest.maxPromptCharacters) characters."
            case .path: return "path must be a new .png file name, such as cat.png."
            case .size: return "size is 256, 384 or 512."
            case .memory: return "This device does not have the memory to make images on the phone."
            case .busy: return "Another model is still loaded. Try again after this step."
            case .slow: return "Making the picture took longer than \(Int(ImageRequest.timeLimit)) seconds and was stopped. Nothing was saved."
            }
        }
    }

    /// Checks a call. `seed` is drawn by the caller so a run can be repeated.
    public static func arguments(_ raw: [String: String], seed: UInt32) throws -> Arguments {
        guard Set(raw.keys).isSubset(of: ["prompt", "path", "size"]), raw["prompt"] != nil, raw["path"] != nil else { throw Problem.arguments }
        let prompt = raw["prompt"]!.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !prompt.isEmpty, prompt.count <= maxPromptCharacters else { throw Problem.prompt }
        let path = raw["path"]!.trimmingCharacters(in: .whitespaces)
        guard path.lowercased().hasSuffix(".png"), path.count > 4, path.count <= 120, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !path.contains("\\") else { throw Problem.path }
        var size = defaultSize
        if let text = raw["size"] {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), sizes.contains(value) else { throw Problem.size }
            size = value
        }
        return Arguments(prompt: prompt, path: path, size: size, seed: seed)
    }

    /// Whether the image model fits the device's budget on its own. The chat
    /// model is unloaded first, so its size does not count.
    public static func fits(imageModelBytes: UInt64, workingBytes: UInt64 = 600_000_000, physicalMemoryBytes: UInt64) -> Bool {
        imageModelBytes + workingBytes <= DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Whether both models could stay loaded together. On an 8 GB phone they
    /// cannot, which is why `ModelSwap` exists.
    public static func bothFit(chatModelBytes: UInt64, imageModelBytes: UInt64, workingBytes: UInt64 = 600_000_000, physicalMemoryBytes: UInt64) -> Bool {
        chatModelBytes + imageModelBytes + workingBytes <= DeviceMemoryGate.estimatedAppBudgetBytes(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// What the model reads after a run.
    public static func result(_ arguments: Arguments, seconds: Double) -> String {
        "Saved \(arguments.path) (\(arguments.size)×\(arguments.size), \(steps) steps, seed \(arguments.seed)) in \(Int(seconds.rounded())) s. The user can open it in the chat."
    }
}

/// An image model is a folder of Core ML files. Each is pinned to a revision,
/// a size and a SHA-256, like the chat models.
public struct ImageModelPack: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// Path inside the model folder, such as `Unet.mlmodelc/weights/weight.bin`.
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }

    public let id: String
    public let name: String
    public let repository: String
    public let revision: String
    /// Where the files sit inside the repository.
    public let remoteFolder: String
    public let files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remoteFolder)/\(file.path)")!
    }

    /// The folder the pack lives in, inside the app's model directory.
    public func directory(in models: URL) -> URL {
        models.appendingPathComponent("image", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    /// Files not yet present at their pinned size. A present file of the right
    /// size was hash-checked when it was saved.
    public func missing(in directory: URL, fileManager: FileManager = .default) -> [File] {
        files.filter { file in
            let size = (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path)[.size] as? NSNumber)?.int64Value
            return size != file.bytes
        }
    }

    /// Apple's own Core ML build of Stable Diffusion 2.1 base (512×512),
    /// weights palettized to 6 bits, in the layout made for the Neural Engine.
    public static let stableDiffusion21 = ImageModelPack(
        id: "sd21-base-palettized", name: "Stable Diffusion 2.1",
        repository: "apple/coreml-stable-diffusion-2-1-base-palettized", revision: "dca5f2fda9c5143c71aded72bbb4ce39f3c2cc9c",
        remoteFolder: "split_einsum_v2/compiled",
        files: [
            File(path: "TextEncoder.mlmodelc/analytics/coremldata.bin", bytes: 207, sha256: "a26bdd792e919ca3412c0685e74ea507a6de835532f0ec58d780c99b0a7a0193"),
            File(path: "TextEncoder.mlmodelc/coremldata.bin", bytes: 839, sha256: "2f0484a1a04e023da06787de4140cf215f9ccd67f93d916dc388b846d8607899"),
            File(path: "TextEncoder.mlmodelc/metadata.json", bytes: 2_792, sha256: "72df3fb2e265896ba2b34e8b5e245777f0803345f724c386ac4556d54935ebaf"),
            File(path: "TextEncoder.mlmodelc/model.mil", bytes: 391_100, sha256: "819d8e7b680b25c8601d44861545d013c02b9c94b9d9ad42290de3de489a6e52"),
            File(path: "TextEncoder.mlmodelc/weights/weight.bin", bytes: 318_860_352, sha256: "3be3ff19e2ed53774d8c4c22f58bb4f9d37a44c2d6d34955e72decef86aa8615"),
            File(path: "Unet.mlmodelc/analytics/coremldata.bin", bytes: 207, sha256: "7432befba40c728344d55ededaedcbeebf04eca023437afb4418e655515c066c"),
            File(path: "Unet.mlmodelc/coremldata.bin", bytes: 1_221, sha256: "5bc742d03b80b46feaa6f9e2159a5c89acda3ed2c1562f2b4f781bb7bfbce110"),
            File(path: "Unet.mlmodelc/metadata.json", bytes: 3_728, sha256: "cc395449fa607b675a3a3aac5b81946abd6cce1beb9a4397a0cd2fe5be2ac0c3"),
            File(path: "Unet.mlmodelc/model.mil", bytes: 3_101_782, sha256: "c03ece04683b45e1838b6fbe899e38f9ed18c12589b22772088fd58ce960d0bb"),
            File(path: "Unet.mlmodelc/weights/weight.bin", bytes: 649_959_936, sha256: "a4bfeb078744274ac2000593ae80522c8e3363bec8a4cf5e35ef93e3f7b14056"),
            File(path: "VAEDecoder.mlmodelc/analytics/coremldata.bin", bytes: 207, sha256: "682f30dbd27b8c96fae9dd5d7cec36e85812e370cc2a920d9a6cef7a908e29d3"),
            File(path: "VAEDecoder.mlmodelc/coremldata.bin", bytes: 769, sha256: "57555bee9ff5d60c5b6fd48564eac43523d954a2d34101273b8e3fa8f1aee3d0"),
            File(path: "VAEDecoder.mlmodelc/metadata.json", bytes: 2_493, sha256: "19dcc0cdee77617dd0ec273ca9ffe8fc55165985f0490004d9f1bf5a3017c61f"),
            File(path: "VAEDecoder.mlmodelc/model.mil", bytes: 181_387, sha256: "4769720187b4f34c1335e8ba79424bdfc41b5b55e5bfccf4cbc41a78116d6bb7"),
            File(path: "VAEDecoder.mlmodelc/weights/weight.bin", bytes: 98_993_280, sha256: "2caef4ff7a13ebe71592e39aff32a93ad62f54fb9fd8ea68ce9239550c5ed63b"),
            File(path: "merges.txt", bytes: 524_657, sha256: "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"),
            File(path: "vocab.json", bytes: 862_328, sha256: "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
        ])
}

/// A model that can be put in and taken out of memory.
public protocol ResidentModel: AnyObject, Sendable {
    func load() async throws
    func unload() async
}

/// Lets two heavy models take turns. At most one is loaded at any moment:
/// the other is unloaded before the next one loads, also when a run fails or
/// is cancelled.
public actor ModelSwap {
    public enum Resident: Equatable, Sendable { case none, chat, image }
    public private(set) var resident: Resident = .none
    private var running = false
    private let chat: any ResidentModel
    private let image: any ResidentModel

    public init(chat: any ResidentModel, image: any ResidentModel) {
        self.chat = chat; self.image = image
    }

    /// Call before each chat step: unloads the image model if needed.
    public func useChat() async throws {
        guard !running else { throw ImageRequest.Problem.busy }
        if resident == .chat { return }
        if resident == .image { await image.unload(); resident = .none }
        try await chat.load()
        resident = .chat
    }

    /// Runs `body` with only the image model loaded, and unloads it after,
    /// however the run ends. The chat model is left unloaded: the next chat
    /// step loads it with `useChat`.
    public func withImage<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard !running else { throw ImageRequest.Problem.busy }
        running = true
        defer { running = false }
        if resident == .chat { await chat.unload(); resident = .none }
        do {
            try await image.load()
            resident = .image
            let value = try await body()
            await image.unload(); resident = .none
            return value
        } catch {
            if resident == .image { await image.unload(); resident = .none }
            throw error
        }
    }
}
