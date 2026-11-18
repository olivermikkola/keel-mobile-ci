# StableDiffusionCore

The parts of Apple's [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion)
Swift code needed to make an image from text with a Stable Diffusion 1.x or 2.x
Core ML model: the tokenizer, text encoder, U-Net, VAE decoder, DPM-Solver++
scheduler and the NumPy-compatible random source. Copied unchanged from commit
`ea2805dc1945be20561c77e5f6d1d9a5a637cda2` (2026-09-11). MIT licensed, see
`LICENSE.md`.

`TextToImage.swift` is ours: one image from one prompt, built from those parts,
following the order of Apple's `StableDiffusionPipeline.generateImages`.

Why a copy and not the package: Apple's package requires `swift-transformers`
at exactly 0.1.8, and the app's MLX runtime needs 1.4.0. The two cannot be
resolved together. The copied files do not use `swift-transformers` at all
(only Apple's SD3, SDXL and T5 code does, which is left out), and living in
their own module keeps names such as `Decoder` and `Encoder` away from the app's.

To update: copy the same files again from a newer commit and note it here.
