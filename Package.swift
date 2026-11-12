// swift-tools-version:5.9
// KeelHarness: Keel's small-model techniques as plain Foundation Swift.
// No UIKit or SwiftUI, so `swift test` runs on Linux as well as macOS.
// The iOS app is built from project.yml; this package is used from there.
import PackageDescription

let package = Package(
    name: "KeelHarness",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "KeelHarness", targets: ["KeelHarness"])],
    targets: [
        .target(name: "KeelHarness", path: "Harness"),
        .testTarget(name: "KeelHarnessTests", dependencies: ["KeelHarness"], path: "HarnessTests"),
    ]
)
