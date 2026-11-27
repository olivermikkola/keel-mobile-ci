import Foundation

/// Evens out one spoken narration line before it goes into a video: the
/// voice leaves about half a second of silence at each end, which with the
/// scene pause made 1.5 s of dead air between lines, and it speaks quietly
/// (about -28 dB on average in a real video). Pure arithmetic on samples so
/// Linux tests can check it.
public enum NarrationLevels {
    /// Quieter than this counts as silence at the ends (-40 dBFS).
    public static let silenceThreshold: Float = 0.01
    /// Kept before the first and after the last sound, so words are not clipped.
    public static let leadSeconds = 0.05
    public static let tailSeconds = 0.12
    /// Loudness the speech is brought to (about -18 dBFS RMS), never letting
    /// a peak pass -1 dBFS.
    public static let targetRMS: Float = 0.125
    public static let peakLimit: Float = 0.89
    public static let maxGain: Float = 6

    public struct Plan: Equatable, Sendable {
        /// First and one-past-last sample to keep.
        public let start: Int
        public let end: Int
        public let gain: Float
    }

    /// Where to cut and how much to raise one line. All-silent input keeps
    /// everything at gain 1.
    public static func plan(samples: [Float], sampleRate: Double) -> Plan {
        guard let first = samples.firstIndex(where: { abs($0) > silenceThreshold }),
              let last = samples.lastIndex(where: { abs($0) > silenceThreshold }) else {
            return Plan(start: 0, end: samples.count, gain: 1)
        }
        let start = max(0, first - Int(leadSeconds * sampleRate))
        let end = min(samples.count, last + 1 + Int(tailSeconds * sampleRate))
        var sum: Float = 0
        var peak: Float = 0
        for sample in samples[start..<end] {
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = (sum / Float(max(1, end - start))).squareRoot()
        var gain = rms > 0 ? targetRMS / rms : 1
        if peak > 0 { gain = min(gain, peakLimit / peak) }
        return Plan(start: start, end: end, gain: min(maxGain, max(0.25, gain)))
    }
}
