import CoreGraphics
import CoreML
import Foundation

/// One image from one text prompt, with a Stable Diffusion 1.x or 2.x Core ML
/// model folder (TextEncoder, Unet or its two chunks, VAEDecoder, vocab.json,
/// merges.txt). Built from Apple's parts in this module and following the
/// order of their `StableDiffusionPipeline.generateImages`: encode the prompt
/// and an empty prompt, start from seeded noise, let the U-Net predict the
/// noise step by step with classifier-free guidance, then decode to pixels.
///
/// Each model is loaded when it is first needed and unloaded as soon as its
/// part is done, so only one is in memory at a time.
@available(iOS 17.0, macOS 14.0, *)
public struct TextToImage {
    public enum Problem: Error, Equatable {
        /// The folder lacks one of the model's files.
        case missing(String)
    }

    let textEncoder: TextEncoder
    let unet: Unet
    let decoder: Decoder

    /// The files a model folder must hold, for a clear error before loading.
    public static let requiredNames = ["TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    public init(resourcesAt base: URL, computeUnits: MLComputeUnits) throws {
        let files = FileManager.default
        for name in Self.requiredNames where !files.fileExists(atPath: base.appending(path: name).path) {
            throw Problem.missing(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let tokenizer = try BPETokenizer(mergesAt: base.appending(path: "merges.txt"), vocabularyAt: base.appending(path: "vocab.json"))
        textEncoder = TextEncoder(tokenizer: tokenizer, modelAt: base.appending(path: "TextEncoder.mlmodelc"), configuration: configuration)
        let chunks = [base.appending(path: "UnetChunk1.mlmodelc"), base.appending(path: "UnetChunk2.mlmodelc")]
        if chunks.allSatisfy({ files.fileExists(atPath: $0.path) }) {
            unet = Unet(chunksAt: chunks, configuration: configuration)
        } else {
            guard files.fileExists(atPath: base.appending(path: "Unet.mlmodelc").path) else { throw Problem.missing("Unet.mlmodelc") }
            unet = Unet(modelAt: base.appending(path: "Unet.mlmodelc"), configuration: configuration)
        }
        decoder = Decoder(modelAt: base.appending(path: "VAEDecoder.mlmodelc"), configuration: configuration)
    }

    /// Frees every model. Safe to call at any time.
    public func unload() {
        textEncoder.unloadResources()
        unet.unloadResources()
        decoder.unloadResources()
    }

    /// Makes the image. `progress(step, of)` is called before each step and
    /// stops the run by returning false; the result is then nil.
    public func generate(prompt: String, negativePrompt: String = "", steps: Int = 20, guidance: Float = 7.5,
                         seed: UInt32, progress: (Int, Int) -> Bool = { _, _ in true }) throws -> CGImage? {
        defer { unload() }
        // The prompt and the empty prompt, side by side, in the layout the U-Net reads.
        let wanted = try textEncoder.encode(prompt)
        let unwanted = try textEncoder.encode(negativePrompt)
        textEncoder.unloadResources()
        let hiddenStates = Self.hiddenStates(MLShapedArray<Float32>(concatenating: [unwanted, wanted], alongAxis: 0))

        let scheduler = DPMSolverMultistepScheduler(stepCount: steps)
        var shape = unet.latentSampleShape
        let batched = shape[0] >= 2
        shape[0] = 1
        var random = NumPyRandomSource(seed: seed)
        var latent = MLShapedArray<Float32>(converting: random.normalShapedArray(shape, mean: 0, stdev: Double(scheduler.initNoiseSigma)))
        var denoised = latent

        let timeSteps = scheduler.calculateTimesteps(strength: nil)
        for (index, timeStep) in timeSteps.enumerated() {
            guard progress(index, timeSteps.count) else { return nil }
            let both: MLShapedArray<Float32>
            if batched {
                // The model takes the empty-prompt and prompt cases in one call.
                both = try unet.predictNoise(latents: [MLShapedArray<Float32>(concatenating: [latent, latent], alongAxis: 0)],
                                             timeStep: timeStep, hiddenStates: hiddenStates)[0]
            } else {
                let without = try unet.predictNoise(latents: [latent], timeStep: timeStep, hiddenStates: Self.row(0, of: hiddenStates))[0]
                let with = try unet.predictNoise(latents: [latent], timeStep: timeStep, hiddenStates: Self.row(1, of: hiddenStates))[0]
                both = MLShapedArray<Float32>(concatenating: [without, with], alongAxis: 0)
            }
            latent = scheduler.step(output: Self.guided(both, scale: guidance), timeStep: timeStep, sample: latent)
            denoised = scheduler.modelOutputs.last ?? latent
        }
        unet.unloadResources()
        guard progress(timeSteps.count, timeSteps.count) else { return nil }
        return try decoder.decode([denoised], scaleFactor: 0.18215).first
    }

    /// From [2, 77, width] to [2, width, 1, 77].
    static func hiddenStates(_ embedding: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        let from = embedding.shape
        var states = MLShapedArray<Float32>(repeating: 0, shape: [from[0], from[2], 1, from[1]])
        for batch in 0..<from[0] {
            for token in 0..<from[1] {
                for value in 0..<from[2] {
                    states[scalarAt: batch, value, 0, token] = embedding[scalarAt: batch, token, value]
                }
            }
        }
        return states
    }

    /// One of the two rows of the hidden states, still with a batch dimension.
    static func row(_ index: Int, of states: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        let one = MLShapedArray<Float32>(converting: states[index])
        return MLShapedArray<Float32>(scalars: one.scalars, shape: [1] + one.shape)
    }

    /// Classifier-free guidance: empty + scale × (prompt − empty).
    static func guided(_ noise: MLShapedArray<Float32>, scale: Float) -> MLShapedArray<Float32> {
        var shape = noise.shape
        shape[0] = 1
        let values = noise.scalars
        let half = values.count / 2
        var result = [Float32](repeating: 0, count: half)
        for index in 0..<half {
            result[index] = values[index] + scale * (values[half + index] - values[index])
        }
        return MLShapedArray<Float32>(scalars: result, shape: shape)
    }
}
