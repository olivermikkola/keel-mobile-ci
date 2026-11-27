import Foundation

/// Making images on the phone (`generate_image`).
///
/// A diffusion model (about 1.0 GB) and the chat model cannot both sit in an
/// 8 GB iPhone's memory budget, so they take turns: the chat model is
/// unloaded, the image model is loaded and run, the image model is unloaded,
/// and the chat model loads again on the next step. `ModelSwap` enforces that
/// order; `ImageRequest` is the tool's call format and limits; `ImageModelPack`
/// pins the model's files.
public enum ImageRequest {
    public static let tool = #"{"type":"function","function":{"name":"generate_image","description":"Make one picture from a text description and save it as a .png file in this chat. Describe the subject, lighting, style and colours in under 300 characters. Optional style: photo, illustration, animation or sketch. Size is 256, 384 or 512 (default 512).","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"path":{"type":"string"},"size":{"type":"integer","enum":[256,384,512]},"style":{"type":"string","enum":["photo","illustration","animation","sketch"]}},"required":["prompt","path"]}}}"#

    public static let maxPromptCharacters = 300
    public static let sizes = [256, 384, 512]
    public static let defaultSize = 512
    /// Default denoising steps for the primary on-device Core ML model
    /// (`ImageModelPack.defaultPack`, DreamShaper 8 LCM: 8 steps).
    public static let steps = ImageModelPack.defaultPack.defaultSteps
    /// The longest a run may take before it is stopped. The first run after
    /// a download is the slow one: Core ML prepares the model for the phone's chip.
    public static let timeLimit: TimeInterval = 300

    public enum Style: String, Codable, Equatable, Sendable, CaseIterable {
        case photo, animation, illustration, sketch
    }

    public struct Arguments: Equatable, Sendable {
        public let prompt: String
        public let path: String
        public let size: Int
        public let seed: UInt32
        public let style: Style?

        public init(prompt: String, path: String, size: Int, seed: UInt32, style: Style? = nil) {
            self.prompt = prompt
            self.path = path
            self.size = size
            self.seed = seed
            self.style = style
        }
    }

    public enum Problem: LocalizedError, Equatable {
        case arguments, prompt, path, size, style, memory, busy, slow
        public var errorDescription: String? {
            switch self {
            case .arguments: return "Expected prompt, path, optional size and optional style."
            case .prompt: return "Describe the picture in 1 to \(ImageRequest.maxPromptCharacters) characters."
            case .path: return "path must be a new .png file name, such as cat.png."
            case .size: return "size is 256, 384 or 512."
            case .style: return "style is photo, illustration, animation or sketch."
            case .memory: return "This device does not have the memory to make images on the phone."
            case .busy: return "Another model is still loaded. Try again after this step."
            case .slow: return "Making the picture took longer than \(Int(ImageRequest.timeLimit)) seconds and was stopped. Nothing was saved."
            }
        }
    }

    /// Checks a call. `seed` is drawn by the caller so a run can be repeated.
    public static func arguments(_ raw: [String: String], seed: UInt32) throws -> Arguments {
        guard Set(raw.keys).isSubset(of: ["prompt", "path", "size", "style"]),
              raw["prompt"] != nil, raw["path"] != nil else { throw Problem.arguments }
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
        var style: Style?
        if let rawStyle = raw["style"] {
            let normalized = rawStyle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                guard let parsed = Style(rawValue: normalized) else { throw Problem.style }
                style = parsed
            }
        }
        return Arguments(prompt: prompt, path: path, size: size, seed: seed, style: style)
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
    public static func result(_ arguments: Arguments, seconds: Double, steps: Int = ImageRequest.steps, engine: String? = nil) -> String {
        if let engine {
            return "Saved \(arguments.path) (\(arguments.size)×\(arguments.size), \(engine)) in \(Int(seconds.rounded())) s. The user can open it in the chat."
        }
        return "Saved \(arguments.path) (\(arguments.size)×\(arguments.size), \(steps) steps, seed \(arguments.seed)) in \(Int(seconds.rounded())) s. The user can open it in the chat."
    }
}

/// An image model is a folder of Core ML files. Each is pinned to a revision,
/// a size and a SHA-256, like the chat models.
public struct ImageModelPack: Equatable, Sendable {
    public enum Engine: String, Equatable, Sendable {
        /// Latent Consistency Model (4–10 steps, low CFG ~2.0, LCMScheduler).
        case lcm
        /// Standard Stable Diffusion (20 steps, CFG ~7.5, DPM-Solver++ Karras).
        case standard
    }

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
    /// Where the files sit inside the repository (empty string for repo root).
    public let remoteFolder: String
    public let engine: Engine
    public let defaultSteps: Int
    public let defaultGuidance: Float
    public let defaultNegativePrompt: String
    public let padToken: String
    public let files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public func url(for file: File) -> URL {
        let prefix = remoteFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = prefix.isEmpty ? file.path : "\(prefix)/\(file.path)"
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(relative)")!
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

    /// The default on-device Core ML image model pack for new downloads.
    public static let defaultPack = dreamShaper8LCM

    /// All known packs in preference order (newest/best first).
    public static let allPacks = [dreamShaper8LCM, stableDiffusion21]

    /// DreamShaper 8 LCM (512×512), 6-bit palettized `split_einsum_v2` UNet with
    /// FP16 CLIP text encoder and FP16 VAE decoder. Generates sharp images in 8
    /// LCM steps (~2.5× faster and substantially higher quality than SD 2.1 base).
    public static let dreamShaper8LCM = ImageModelPack(
        id: "dreamshaper-8-lcm-6bit", name: "DreamShaper 8 LCM",
        repository: "LocalMuseAI/coreml-dreamshaper-8-lcm-6bit-v2", revision: "145761e40713fa2cb0348a90fc721109f2a98083",
        remoteFolder: "",
        engine: .lcm,
        defaultSteps: 8,
        defaultGuidance: 2.0,
        defaultNegativePrompt: "blurry, deformed, bad anatomy, low quality, watermark, text",
        padToken: "<|endoftext|>",
        files: [
            File(path: "TextEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "79f08f9d4bd1826dc2d7dad85909842ac3c6f3ead3962185bb4cea3e729eb428"),
            File(path: "TextEncoder.mlmodelc/coremldata.bin", bytes: 1_061, sha256: "55ab12055a74a5385bb43042cb9ed3018caef28012c87c02a1b39cbae46b33a9"),
            File(path: "TextEncoder.mlmodelc/metadata.json", bytes: 3_094, sha256: "b9079015cf1ade6f98184ac93f90a2b2720c8255d306c88a2834aaa3d3cc9799"),
            File(path: "TextEncoder.mlmodelc/model.mil", bytes: 170_454, sha256: "6c46f72e8208ae72fc1eca66623e30171dc17c746ced77bdd117a1644889d180"),
            File(path: "TextEncoder.mlmodelc/weights/weight.bin", bytes: 246_145_536, sha256: "4f2738a64525cbfd0a103d7a6fe4b95c8bcd6edcb7e73d8d2f7bf9929634df5e"),
            File(path: "Unet.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "fb238d2ddf84aebfa33dc056275ae4f9fa7723040911ce39bbb21dc17f0f8a60"),
            File(path: "Unet.mlmodelc/coremldata.bin", bytes: 1_494, sha256: "3e31fe74607b65401fbce527847b95773fc31adb70340fdede7b9a1fc999f1da"),
            File(path: "Unet.mlmodelc/metadata.json", bytes: 4_113, sha256: "0b51cca698f01954e9c4f14d60b5cf1795f8056b07b807b278708ddab76b051c"),
            File(path: "Unet.mlmodelc/model.mil", bytes: 3_136_990, sha256: "c1fb9b4c4e2a9a33f002e77c166cf685f16a7e570611dabdb60c74e9854cfe13"),
            File(path: "Unet.mlmodelc/weights/weight.bin", bytes: 645_325_440, sha256: "4683ed5311eac6bff02a85e999e07241b6db64a86c0f12291444b51c04870c57"),
            File(path: "VAEDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "5cdb3da22cf34f744e0a6591225df4f75891cb9f229a51557536c96bf710c92d"),
            File(path: "VAEDecoder.mlmodelc/coremldata.bin", bytes: 988, sha256: "2241fead3ade729dff21c1b3caa9160437360b38559d71c146bab8cdf9973309"),
            File(path: "VAEDecoder.mlmodelc/metadata.json", bytes: 2_800, sha256: "a58400ccac0a8a5af6f876a81bfa6d43624755885c02e79c53762fe0775c962a"),
            File(path: "VAEDecoder.mlmodelc/model.mil", bytes: 194_895, sha256: "cb04b781e565b37c62c518a2f1bb02b2c5667db86c80ca44ab84637fb74c233d"),
            File(path: "VAEDecoder.mlmodelc/weights/weight.bin", bytes: 98_993_280, sha256: "26e320b84ccd02aa065db9b9a56b342a3380fd9ea8b2fde954559b9446358199"),
            File(path: "merges.txt", bytes: 524_619, sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a"),
            File(path: "vocab.json", bytes: 1_059_962, sha256: "e089ad92ba36837a0d31433e555c8f45fe601ab5c221d4f607ded32d9f7a4349"),
        ])

    /// Apple's own Core ML build of Stable Diffusion 2.1 base (512×512),
    /// weights palettized to 6 bits, in the layout made for the Neural Engine.
    /// Kept for users who already downloaded it; OpenCLIP pads with `"!"` (ID 0).
    public static let stableDiffusion21 = ImageModelPack(
        id: "sd21-base-palettized", name: "Stable Diffusion 2.1",
        repository: "apple/coreml-stable-diffusion-2-1-base-palettized", revision: "dca5f2fda9c5143c71aded72bbb4ce39f3c2cc9c",
        remoteFolder: "split_einsum_v2/compiled",
        engine: .standard,
        defaultSteps: 20,
        defaultGuidance: 7.5,
        defaultNegativePrompt: "blurry, deformed, bad anatomy, ugly, low quality, watermark, text",
        padToken: "!",
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
