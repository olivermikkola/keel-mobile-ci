// swift-tools-version: 6.2
// Runs the app's MLX runtime (Sources/MLXRunner.swift) on a Mac with the
// runtime benchmark's cases, so the MLX path is exercised before a phone.
// macOS only: mlx-swift-lm does not build on Linux.
import PackageDescription

let package = Package(
    name: "mlx-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to the commit that added LFM3 (ml-explore/mlx-swift-lm#750); keep in sync with project.yml.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "6352907543270ae9c61fcaf59cb3e07b0b989ea1"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        // The app's harness sources (a symlink to /Harness), built in here so the probe's folder name does not matter.
        .target(name: "KeelHarness", path: "Sources/KeelHarness", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "mlx-probe", dependencies: [
            "KeelHarness",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
