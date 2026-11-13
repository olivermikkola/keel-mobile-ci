// swift-tools-version:5.9
// KeelHarness: Keel's small-model techniques as plain Foundation Swift.
// No UIKit or SwiftUI, so `swift test` runs on Linux as well as macOS.
// The iOS app is built from project.yml; this package is used from there.
import PackageDescription

// The task workspace uses SQLite. Apple platforms provide the SQLite3 module;
// Linux needs the system library (`apt install libsqlite3-dev`).
#if os(Linux)
let sqliteTargets: [Target] = [.systemLibrary(name: "CSQLite", path: "Package/CSQLite", providers: [.apt(["libsqlite3-dev"])])]
let sqliteDependencies: [Target.Dependency] = ["CSQLite"]
#else
let sqliteTargets: [Target] = []
let sqliteDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "KeelHarness",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "KeelHarness", targets: ["KeelHarness"])],
    targets: sqliteTargets + [
        .target(name: "KeelHarness", dependencies: sqliteDependencies, path: "Harness"),
        .testTarget(name: "KeelHarnessTests", dependencies: ["KeelHarness"], path: "HarnessTests"),
    ]
)
