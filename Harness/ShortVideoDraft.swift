import Foundation

// Pure helpers for the short-video draft screen (`Sources/ShortVideoDraftView.swift`):
// which scene is playing, where the scene buttons jump, and the narration
// waveform's bars. Linux-tested; the view only draws.

extension ShortVideoRequest.RenderPlan {
    /// The scene playing at `time` (seconds); the last scene after the end.
    public func clipIndex(at time: TimeInterval) -> Int {
        guard !clips.isEmpty else { return 0 }
        return clips.lastIndex(where: { $0.start <= time + 1e-6 }) ?? 0
    }

    /// Where "previous" goes: the start of this scene, or of the one before if
    /// playback is within `restartWindow` seconds of this scene's start (as a
    /// music player does).
    public func previousStart(from time: TimeInterval, restartWindow: TimeInterval = 1) -> TimeInterval {
        guard !clips.isEmpty else { return 0 }
        let index = clipIndex(at: time)
        if time - clips[index].start > restartWindow || index == 0 { return clips[index].start }
        return clips[index - 1].start
    }

    /// Where "next" goes: the next scene's start, or nil on the last scene.
    public func nextStart(from time: TimeInterval) -> TimeInterval? {
        let index = clipIndex(at: time)
        return index + 1 < clips.count ? clips[index + 1].start : nil
    }

    /// Each scene's share of the timeline (0…1), for the clip strip's widths.
    public var clipFractions: [Double] {
        guard totalSeconds > 0 else { return clips.map { _ in 0 } }
        return clips.map { $0.duration / totalSeconds }
    }
}

public enum ShortVideoWaveform {
    /// Peak level per bar from audio samples (-1…1), scaled so the loudest bar
    /// is 1. Silence stays at 0. `bars` is clamped to 1…2000.
    public static func bars(_ samples: [Float], count bars: Int) -> [Float] {
        let bars = min(2_000, max(1, bars))
        guard !samples.isEmpty else { return Array(repeating: 0, count: bars) }
        var peaks = [Float](repeating: 0, count: bars)
        for (index, sample) in samples.enumerated() {
            let bar = min(bars - 1, index * bars / samples.count)
            peaks[bar] = max(peaks[bar], abs(sample))
        }
        let loudest = peaks.max() ?? 0
        guard loudest > 0.001 else { return Array(repeating: 0, count: bars) }
        return peaks.map { $0 / loudest }
    }
}
