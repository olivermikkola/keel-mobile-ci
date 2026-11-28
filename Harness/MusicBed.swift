import Foundation

/// Background music under a short video's narration: quiet throughout, dipped
/// further ("ducked") while a line is spoken, faded in at the start and out at
/// the end. Pure timing maths, so Linux tests can check the curve; the iOS
/// renderer turns the ramps into an `AVAudioMix`.
public enum MusicBed {
    /// Music level between lines and while speaking, as linear gain.
    public static let baseVolume: Float = 0.30   // about -10 dB
    public static let duckedVolume: Float = 0.08 // about -22 dB
    /// Seconds to dip before a line starts and to come back after it ends.
    public static let duckRamp: TimeInterval = 0.25
    public static let fadeIn: TimeInterval = 0.6
    public static let fadeOut: TimeInterval = 1.2

    /// One linear volume change from `start` to `end`.
    public struct Ramp: Equatable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let from: Float
        public let to: Float
    }

    /// Spoken stretches, merged where the music would only come back up for
    /// a moment between two lines.
    public static func speech(_ lines: [(start: TimeInterval, seconds: TimeInterval)]) -> [ClosedRange<TimeInterval>] {
        let sorted = lines.filter { $0.seconds > 0 }.map { $0.start...($0.start + $0.seconds) }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound - last.upperBound < 2 * duckRamp {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The music's volume at `t`.
    public static func volume(at t: TimeInterval, speech: [ClosedRange<TimeInterval>], total: TimeInterval) -> Float {
        guard total > 0, t >= 0, t <= total else { return 0 }
        var level = baseVolume
        for range in speech {
            if range.contains(t) { level = duckedVolume; break }
            let before = range.lowerBound - t, after = t - range.upperBound
            if before > 0, before < duckRamp { level = min(level, mix(duckedVolume, baseVolume, before / duckRamp)) }
            if after > 0, after < duckRamp { level = min(level, mix(duckedVolume, baseVolume, after / duckRamp)) }
        }
        let fadeInLevel = t < fadeIn ? Float(t / fadeIn) : 1
        let fadeOutLevel = total - t < fadeOut ? Float((total - t) / fadeOut) : 1
        return level * min(fadeInLevel, fadeOutLevel)
    }

    /// Back-to-back ramps covering the whole video, broken at every point
    /// where the curve changes direction.
    public static func ramps(lines: [(start: TimeInterval, seconds: TimeInterval)], total: TimeInterval) -> [Ramp] {
        guard total > 0 else { return [] }
        let spoken = speech(lines)
        var points: Set<TimeInterval> = [0, total, min(fadeIn, total), max(0, total - fadeOut)]
        for range in spoken {
            for t in [range.lowerBound - duckRamp, range.lowerBound, range.upperBound, range.upperBound + duckRamp] where t > 0 && t < total {
                points.insert(t)
            }
        }
        let times = points.sorted()
        return zip(times, times.dropFirst()).compactMap { start, end in
            guard end - start > 0.001 else { return nil }
            return Ramp(start: start, end: end, from: volume(at: start, speech: spoken, total: total),
                        to: volume(at: end, speech: spoken, total: total))
        }
    }

    private static func mix(_ a: Float, _ b: Float, _ fraction: Double) -> Float {
        a + (b - a) * Float(max(0, min(1, fraction)))
    }
}
