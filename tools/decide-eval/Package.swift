// swift-tools-version: 5.9
// Runs the app's decision runtime (Sources/DecisionRuntime.swift) on Linux
// against a llama.cpp build, so its answers can be compared with llama.cpp's
// own /v1/systemone server on the same model. See README.md.
import PackageDescription

let package = Package(
    name: "decide-eval",
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        // llama.cpp's C API; include and library paths come from run.sh.
        .systemLibrary(name: "llama", path: "Sources/llama"),
        // The app's harness sources (a symlink to /Harness).
        .target(name: "KeelHarness", dependencies: ["CSQLite"], path: "Sources/KeelHarness"),
        .executableTarget(name: "decide-eval", dependencies: ["KeelHarness", "llama"]),
    ]
)
