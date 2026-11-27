import Foundation

// Pure timeline maths for the short-video renderer (`Sources/ShortVideoRenderer.swift`):
// fitting clips to real narration, the camera move for each frame, and unique
// storyboard names for chat photos. No AVFoundation, so Linux tests cover it.

extension ShortVideoRequest.RenderPlan {
    /// Silence after each spoken line before the next scene, in seconds.
    public static let narrationPad: TimeInterval = 0.35
    /// The shortest a scene may be, spoken or not.
    public static let minimumClipSeconds: TimeInterval = 1.5
    /// Frames per second of the finished video.
    public static let framesPerSecond: Int32 = 30

    /// The plan with each clip as long as its real narration plus a pause.
    /// `narrationSeconds[i]` is nil when clip i has no audio (it keeps the
    /// estimate from the character count). Starts are recomputed in order.
    public func retimed(narrationSeconds: [TimeInterval?]) -> Self {
        var cursor: TimeInterval = 0
        var built: [Clip] = []
        for (index, clip) in clips.enumerated() {
            let spoken = index < narrationSeconds.count ? narrationSeconds[index] : nil
            let duration = spoken.map { max(Self.minimumClipSeconds, $0 + Self.narrationPad) } ?? clip.duration
            built.append(Clip(imagePath: clip.imagePath, narration: clip.narration, overlay: clip.overlay,
                              motion: clip.motion, duration: duration, start: cursor))
            cursor += duration
        }
        return Self(path: path, title: title, voice: voice, aspectRatio: aspectRatio, clips: built)
    }

    /// Whole frames in a clip, at least one.
    public static func frameCount(seconds: TimeInterval) -> Int {
        max(1, Int((seconds * Double(framesPerSecond)).rounded()))
    }
}

extension ShortVideoRequest.Motion {
    /// How far `slow_zoom` closes in by the end of a clip (1.12 = 12 %).
    public static let zoomEnd: Double = 1.12
    /// Zoom held during a pan, so there is picture to move across.
    public static let panZoom: Double = 1.10

    /// The part of the picture to show at `progress` (0…1 through the clip), in
    /// the picture's own pixels. It always has the canvas's shape (aspect fill),
    /// stays inside the picture, and moves smoothly (eased at both ends).
    public func cropRect(imageWidth: Double, imageHeight: Double,
                         canvasWidth: Double, canvasHeight: Double, progress: Double) -> CGRect {
        let t = Self.ease(min(1, max(0, progress)))
        let canvasAspect = canvasWidth / canvasHeight
        // The largest canvas-shaped rect that fits in the picture.
        var baseWidth = imageWidth
        var baseHeight = imageWidth / canvasAspect
        if baseHeight > imageHeight {
            baseHeight = imageHeight
            baseWidth = imageHeight * canvasAspect
        }
        let zoom: Double
        switch self {
        case .none: zoom = 1
        case .slowZoom: zoom = 1 + (Self.zoomEnd - 1) * t
        case .panLeft, .panRight: zoom = Self.panZoom
        }
        let width = baseWidth / zoom
        let height = baseHeight / zoom
        var x = (imageWidth - width) / 2
        let y = (imageHeight - height) / 2
        if self == .panLeft || self == .panRight {
            // Move across the room the zoom (and a wide picture) leaves, centred,
            // at most 10 % of the crop either side so it reads as a gentle drift.
            let room = imageWidth - width
            let reach = min(room / 2, width * 0.10)
            // pan_left: the camera turns left, so the view starts right and ends left.
            let from = self == .panLeft ? x + reach : x - reach
            let to = self == .panLeft ? x - reach : x + reach
            x = from + (to - from) * t
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

extension ShortVideoMediaIndex {
    /// Unique storyboard names for chat photos, in the order they were attached:
    /// `IMG_1.HEIC`, `Photo.jpg`, `Photo.jpg` → `img_1.heic`, `photo.jpg`, `photo-2.jpg`.
    /// `taken` holds names already used (generated pictures), so none clash.
    public static func photoNames(_ filenames: [String], taken: Set<String> = []) -> [String] {
        var used = Set(taken.map { $0.lowercased() })
        return filenames.enumerated().map { index, filename in
            let base = storyboardPath(fromAttachmentFilename: filename, fallbackStem: "photo")
                ?? "photo-\(index + 1).jpg"
            var name = base
            var counter = 2
            while used.contains(name.lowercased()) {
                let dot = base.lastIndex(of: ".") ?? base.endIndex
                name = "\(base[..<dot])-\(counter)\(base[dot...])"
                counter += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }
}
