// swift-tools-version: 5.9
import PackageDescription

// Apple's Core ML Stable Diffusion building blocks, copied from
// github.com/apple/ml-stable-diffusion (MIT, see LICENSE.md), plus a slim
// text-to-image pipeline (TextToImage.swift). See README.md for why it is
// copied rather than added as a package.
let package = Package(
    name: "StableDiffusionCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StableDiffusionCore", targets: ["StableDiffusionCore"])],
    targets: [.target(name: "StableDiffusionCore")]
)
