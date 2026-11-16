import Foundation

/// An MLX model is a folder of files, not one file: weights, config and
/// tokenizer. Each file is pinned to a revision, a size and a SHA-256, like
/// the GGUF catalog, so the benchmark compares exactly the same weights on
/// every phone.
public struct MLXModelPack: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }

    public let id: String
    public let name: String
    public let repository: String
    public let revision: String
    public let files: [File]
    /// The GGUF catalog model with the same weights, run by llama.cpp for comparison.
    public let ggufModelID: String
    let family: ModelFamily

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
    }

    /// The folder the pack lives in, inside the app's model directory.
    public func directory(in models: URL) -> URL { models.appendingPathComponent("mlx", isDirectory: true).appendingPathComponent(id, isDirectory: true) }

    /// Files not yet present at their pinned size. A present file of the right
    /// size was hash-checked when it was saved.
    public func missing(in directory: URL, fileManager: FileManager = .default) -> [File] {
        files.filter { file in
            let size = (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(file.name).path)[.size] as? NSNumber)?.int64Value
            return size != file.bytes
        }
    }

    /// LFM3 1.7B in MLX 4-bit: the same model as the catalog's `LFM3 · 1.7B` GGUF.
    public static let lfm3 = MLXModelPack(
        id: "lfm3-1.7b-mlx-4bit", name: "LFM3 · 1.7B (MLX 4-bit)",
        repository: "LiquidAI/LFM3-1.7B-MLX-4bit", revision: "91f34088d6946482cbcae11b85d4657093618c34",
        files: [
            File(name: "config.json", bytes: 2_423, sha256: "7df2ea819f9a31b770192a0a9dc1b7953a7dd8c41b816cc3905bbec99ef332bd"),
            File(name: "model.safetensors", bytes: 973_083_386, sha256: "1be5bf672013cd91aa62148f77c5eea8d2784a95845d5fe826e08c7b84823815"),
            File(name: "model.safetensors.index.json", bytes: 50_700, sha256: "2c8b88e25f6a1055164dd051436b170872200047bce4b3ec5f2a58f6ef929a75"),
            File(name: "tokenizer.json", bytes: 17_908_634, sha256: "41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44"),
            File(name: "tokenizer_config.json", bytes: 1_859, sha256: "b77214b9f12be74b9e5e1dab35d7dace077a31be969314bf38866fd6c8163853"),
            File(name: "special_tokens_map.json", bytes: 92, sha256: "7946f864cbfb62a1b041bda937244210a1a87f4a6cab3a48b791131b2cd57f88"),
            File(name: "generation_config.json", bytes: 328, sha256: "0095ba7158e938b1e2d3082d412f00d8be85e42cbbd7608b63866f7a081cf270"),
            File(name: "chat_template.jinja", bytes: 12_143, sha256: "306497f109439afcfa248f4ef5800601de24942e2981d632ae63fc5c070ceb12"),
        ],
        ggufModelID: "lfm3", family: .lfm3)
}
