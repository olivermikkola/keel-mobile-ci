import Foundation

/// Groundwork for making images on the phone (`generate_image`).
///
/// A diffusion model (about 0.65–1.6 GB) and the chat model cannot both sit
/// in an 8 GB iPhone's memory budget, so they take turns: the chat model is
/// unloaded, the image model is loaded and run, the image model is unloaded,
/// and the chat model loads again on the next step. `ModelSwap` enforces that
/// order; `ImageRequest` is the tool's call format and limits. The diffusion
/// runtime itself is not part of this file: the tool is only offered once a
/// runtime is installed and passes `ImageRequest.fits`.
public enum ImageRequest {
    public static let tool = #"{"type":"function","function":{"name":"generate_image","description":"Make one picture from a text description and save it as a .png file in this chat. Describe the subject, style and colours in under 300 characters. Size is 256, 384 or 512 (default 512). Takes up to a minute; the chat model pauses meanwhile.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"path":{"type":"string"},"size":{"type":"integer","enum":[256,384,512]}},"required":["prompt","path"]}}}"#

    public static let maxPromptCharacters = 300
    public static let sizes = [256, 384, 512]
    public static let defaultSize = 512
    /// Few-step distilled models; more steps cost time and heat for little gain.
    public static let steps = 8
    /// The longest a run may take before it is stopped.
    public static let timeLimit: TimeInterval = 120

    public struct Arguments: Equatable, Sendable {
        public let prompt: String
        public let path: String
        public let size: Int
        public let seed: UInt32
    }

    public enum Problem: LocalizedError, Equatable {
        case arguments, prompt, path, size, memory, busy
        public var errorDescription: String? {
            switch self {
            case .arguments: return "Expected prompt, path and optional size."
            case .prompt: return "Describe the picture in 1 to \(ImageRequest.maxPromptCharacters) characters."
            case .path: return "path must be a new .png file name, such as cat.png."
            case .size: return "size is 256, 384 or 512."
            case .memory: return "This device does not have the memory to make images on the phone."
            case .busy: return "Another model is still loaded. Try again after this step."
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
