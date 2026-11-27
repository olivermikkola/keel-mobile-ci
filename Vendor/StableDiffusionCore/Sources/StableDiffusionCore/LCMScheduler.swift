import Accelerate
import CoreML
import Foundation

/// Latent Consistency Model (LCM) scheduler for fast 4–10 step inference.
///
/// Matches Hugging Face Diffusers `LCMScheduler` (`scheduling_lcm.py`) with
/// epsilon prediction, discrete boundary condition scaling (`sigma_data = 0.5`),
/// and seeded Gaussian noise re-injection on intermediate steps.
@available(iOS 16.2, macOS 13.1, *)
public final class LCMScheduler: Scheduler {
    public let trainStepCount: Int
    public let inferenceStepCount: Int
    public let betas: [Float]
    public let alphas: [Float]
    public let alphasCumProd: [Float]
    public let timeSteps: [Int]
    public let timestepScaling: Float
    public let finalAlphaCumProd: Float
    public private(set) var modelOutputs: [MLShapedArray<Float32>] = []

    private var randomSource: NumPyRandomSource

    public init(
        stepCount: Int = 8,
        trainStepCount: Int = 1000,
        originalInferenceSteps: Int = 50,
        betaSchedule: BetaSchedule = .scaledLinear,
        betaStart: Float = 0.00085,
        betaEnd: Float = 0.012,
        timestepScaling: Float = 10.0,
        setAlphaToOne: Bool = true,
        seed: UInt32 = 0
    ) {
        self.trainStepCount = trainStepCount
        self.timestepScaling = timestepScaling
        self.randomSource = NumPyRandomSource(seed: seed &+ 1)

        switch betaSchedule {
        case .linear:
            self.betas = linspace(betaStart, betaEnd, trainStepCount)
        case .scaledLinear:
            self.betas = linspace(pow(betaStart, 0.5), pow(betaEnd, 0.5), trainStepCount).map { $0 * $0 }
        }

        self.alphas = betas.map { 1.0 - $0 }
        var cumProd = self.alphas
        for i in 1..<cumProd.count {
            cumProd[i] *= cumProd[i - 1]
        }
        self.alphasCumProd = cumProd
        self.finalAlphaCumProd = setAlphaToOne ? 1.0 : (cumProd.first ?? 1.0)

        let origSteps = max(1, min(originalInferenceSteps, trainStepCount))
        let k = max(1, trainStepCount / origSteps)
        let originAscending = (1...origSteps).map { min(trainStepCount - 1, $0 * k - 1) }
        let originDescending = Array(originAscending.reversed())

        let clampedSteps = max(1, min(stepCount, originDescending.count))
        self.inferenceStepCount = clampedSteps

        let skippingStep = max(1, originDescending.count / clampedSteps)
        var selected: [Int] = []
        selected.reserveCapacity(clampedSteps)
        var idx = 0
        while selected.count < clampedSteps && idx < originDescending.count {
            selected.append(originDescending[idx])
            idx += skippingStep
        }
        self.timeSteps = selected
    }

    public func step(
        output: MLShapedArray<Float32>,
        timeStep t: Int,
        sample: MLShapedArray<Float32>
    ) -> MLShapedArray<Float32> {
        let stepIndex = timeSteps.firstIndex(of: t) ?? (timeSteps.count - 1)
        let clampedT = min(max(t, 0), alphasCumProd.count - 1)
        let alphaProdT = Double(alphasCumProd[clampedT])
        let betaProdT = max(0.0, 1.0 - alphaProdT)
        let sqrtAlphaProdT = sqrt(alphaProdT)
        let sqrtBetaProdT = sqrt(betaProdT)

        // Predict x_0 from epsilon prediction: (sample - sqrt(1 - alpha_bar_t) * eps) / sqrt(alpha_bar_t)
        let predictedOriginal = weightedSum(
            [1.0 / sqrtAlphaProdT, -sqrtBetaProdT / sqrtAlphaProdT],
            [sample, output]
        )

        // Discrete boundary condition scaling (sigma_data = 0.5)
        let sigmaData = 0.5
        let scaledTimestep = Double(t) * Double(timestepScaling)
        let denom = scaledTimestep * scaledTimestep + sigmaData * sigmaData
        let cSkip = (sigmaData * sigmaData) / denom
        let cOut = scaledTimestep / sqrt(denom)

        let denoised = weightedSum([cOut, cSkip], [predictedOriginal, sample])
        modelOutputs = [denoised]

        // Final step returns the clean denoised sample directly without adding noise.
        guard stepIndex < timeSteps.count - 1 else {
            return denoised
        }

        let prevTimestep = timeSteps[stepIndex + 1]
        let alphaProdPrev = prevTimestep >= 0
            ? Double(alphasCumProd[min(prevTimestep, alphasCumProd.count - 1)])
            : Double(finalAlphaCumProd)
        let betaProdPrev = max(0.0, 1.0 - alphaProdPrev)

        let noise = MLShapedArray<Float32>(converting: randomSource.normalShapedArray(sample.shape, mean: 0, stdev: 1.0))
        return weightedSum([sqrt(alphaProdPrev), sqrt(betaProdPrev)], [denoised, noise])
    }
}
