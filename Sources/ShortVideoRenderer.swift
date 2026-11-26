import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Turns a short-video `RenderPlan` into an H.264 `.mp4` on the phone, with no
/// FFmpeg and no network: each scene's picture with its camera move and
/// overlay text is drawn frame by frame into an `AVAssetWriter`, then the
/// narration clips are laid on at each scene's start and the two are joined.
///
/// Timing comes from the narration: each scene lasts as long as its spoken
/// line plus a short pause (`RenderPlan.retimed`). The maths for timing and
/// camera moves lives in the harness (`Harness/ShortVideoTimeline.swift`).
enum ShortVideoRenderer {
    enum Failure: LocalizedError, Equatable {
        case image(String)
        case writer(String)
        case export(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case .image(let path): return "The picture \(path) could not be opened."
            case .writer(let detail): return "The video could not be written: \(detail)"
            case .export(let detail): return "The narration could not be added to the video: \(detail)"
            case .stopped: return "Making the video was stopped. Nothing was saved."
            }
        }
    }

    /// Longest side a scene picture is decoded at. Chat photos are 768 px;
    /// generated pictures up to 1024. Bigger sources are cut down to this.
    static let maxPictureSide = 2_048
    /// H.264 bit rate. 1080×1920 at 30 fps of mostly still pictures looks clean at 6 Mbit/s.
    static let bitRate = 6_000_000

    /// Renders the plan to `output` (replaced if present) and returns the plan
    /// as rendered, with clip lengths fitted to the narration.
    /// - Parameters:
    ///   - picture: the file for a storyboard image path.
    ///   - narration: one optional audio file per clip, in order (AAC `.m4a`).
    ///   - shouldContinue: polled every few frames; false stops and saves nothing.
    ///   - progress: 0…1 as frames are written.
    static func render(
        plan: ShortVideoRequest.RenderPlan,
        picture: (String) -> URL?,
        narration: [URL?],
        to output: URL,
        shouldContinue: @escaping () -> Bool = { true },
        progress: (Double) -> Void = { _ in }
    ) async throws -> ShortVideoRequest.RenderPlan {
        var spoken: [TimeInterval?] = []
        for url in narration {
            if let url { spoken.append(try await AVURLAsset(url: url).load(.duration).seconds) } else { spoken.append(nil) }
        }
        let timed = plan.retimed(narrationSeconds: spoken)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let silent = work.appendingPathComponent("video.mp4")
        try await writeVideo(timed, picture: picture, to: silent, shouldContinue: shouldContinue, progress: progress)
        guard shouldContinue() else { throw Failure.stopped }

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if narration.contains(where: { $0 != nil }) {
            try await addNarration(timed, narration: narration, video: silent, to: output)
        } else {
            try FileManager.default.moveItem(at: silent, to: output)
        }
        return timed
    }

    // MARK: - Pictures

    private static func writeVideo(
        _ plan: ShortVideoRequest.RenderPlan,
        picture: (String) -> URL?,
        to url: URL,
        shouldContinue: () -> Bool,
        progress: (Double) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("no video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let fps = ShortVideoRequest.RenderPlan.framesPerSecond
        let total = plan.clips.reduce(0) { $0 + ShortVideoRequest.RenderPlan.frameCount(seconds: $1.duration) }
        var frame: Int64 = 0
        do {
            for clip in plan.clips {
                // One picture in memory at a time.
                guard let file = picture(clip.imagePath), let image = loadPicture(file) else { throw Failure.image(clip.imagePath) }
                let overlay = clip.overlay.map { overlayImage($0, width: plan.width, height: plan.height) } ?? nil
                let count = ShortVideoRequest.RenderPlan.frameCount(seconds: clip.duration)
                for index in 0..<count {
                    if index % 15 == 0 {
                        guard shouldContinue() else { throw Failure.stopped }
                        try Task.checkCancellation()
                    }
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                    guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
                    var made: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                    guard let buffer = made else { throw Failure.writer("no pixel buffer") }
                    let crop = clip.motion.cropRect(
                        imageWidth: Double(image.width), imageHeight: Double(image.height),
                        canvasWidth: Double(plan.width), canvasHeight: Double(plan.height),
                        progress: count > 1 ? Double(index) / Double(count - 1) : 0)
                    draw(image, crop: crop, overlay: overlay, into: buffer, width: plan.width, height: plan.height)
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps)) else {
                        throw Failure.writer(writer.error?.localizedDescription ?? "append")
                    }
                    frame += 1
                    if frame % 10 == 0 { progress(Double(frame) / Double(max(total, 1))) }
                }
            }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        // The last frame lasts one frame, so the video is exactly `total` frames long.
        writer.endSession(atSourceTime: CMTime(value: frame, timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "finish") }
        progress(1)
    }

    /// The picture upright and at most `maxPictureSide` on its long side.
    static func loadPicture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPictureSide,
        ] as CFDictionary)
    }

    private static func draw(_ image: CGImage, crop: CGRect, overlay: CGImage?, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.interpolationQuality = .high
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Scale the whole picture so the crop fills the canvas. Core Graphics
        // counts y from the bottom; the crop counts it from the top.
        let scale = Double(width) / crop.width
        let rect = CGRect(x: -crop.minX * scale,
                          y: -(Double(image.height) - crop.maxY) * scale,
                          width: Double(image.width) * scale,
                          height: Double(image.height) * scale)
        context.draw(image, in: rect)
        if let overlay {
            context.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Overlay text

    /// Overlay colour: bold yellow with a dark outline and shadow, readable on
    /// bright snow and dark sea alike.
    static let overlayColour = UIColor(red: 1, green: 0.91, blue: 0.1, alpha: 1)

    /// The overlay as a transparent canvas-sized image: upper-case, heavy and
    /// condensed, centred in the lower third, shrunk to fit at most 3 lines.
    static func overlayImage(_ text: String, width: Int, height: Int) -> CGImage? {
        let canvas = CGSize(width: width, height: height)
        let box = CGSize(width: canvas.width * 0.86, height: canvas.height * 0.24)
        let content = text.uppercased()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        var size = canvas.width * 0.105
        var attributes: [NSAttributedString.Key: Any] = [:]
        var bounds = CGRect.zero
        repeat {
            let font = UIFont.systemFont(ofSize: size, weight: .black, width: .condensed)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = size * 0.18
            shadow.shadowOffset = CGSize(width: 0, height: size * 0.04)
            attributes = [.font: font, .foregroundColor: overlayColour, .paragraphStyle: style, .shadow: shadow]
            bounds = (content as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            size *= 0.92
        } while (bounds.height > box.height) && size > 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let picture = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let origin = CGPoint(x: (canvas.width - box.width) / 2, y: canvas.height * 0.64 - bounds.height / 2)
            let rect = CGRect(origin: origin, size: CGSize(width: box.width, height: bounds.height))
            // Outline first, fill on top: a one-pass fill-and-stroke draws the
            // outline inside the letters where strokes cross (seen in the A and M).
            var outline = attributes
            outline[.foregroundColor] = UIColor.clear
            outline[.strokeColor] = UIColor.black.withAlphaComponent(0.85)
            outline[.strokeWidth] = 9.0
            (content as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: outline, context: nil)
            var fill = attributes
            fill[.shadow] = nil
            (content as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: fill, context: nil)
        }
        return picture.cgImage
    }

    // MARK: - Narration

    private static func addNarration(_ plan: ShortVideoRequest.RenderPlan, narration: [URL?], video: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: video)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.export("no tracks")
        }
        let length = try await source.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceVideo, at: .zero)
        for (clip, url) in zip(plan.clips, narration) {
            guard let url else { continue }
            let line = AVURLAsset(url: url)
            guard let track = try await line.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await line.load(.duration)
            let start = CMTime(seconds: clip.start, preferredTimescale: 600)
            // Never past the end of the video.
            let room = CMTimeSubtract(length, start)
            guard room > .zero else { continue }
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, room)), of: track, at: start)
        }
        // Passthrough keeps the H.264 frames as written; the narration must be AAC.
        // If a phone refuses passthrough, re-encode once instead.
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            try await export(composition, preset: AVAssetExportPresetHighestQuality, to: output)
        }
    }

    private static func export(_ asset: AVAsset, preset: String, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.export("no export session") }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw Failure.export(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
    }
}
