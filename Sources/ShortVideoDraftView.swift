import AVFoundation
import ImageIO
import Photos
import SwiftUI
#if canImport(KeelHarness)
import KeelHarness
#endif

/// A finished short video, ready to review: the file, the plan it was rendered
/// from (with real scene lengths) and each scene's picture.
struct ShortVideoDraft: Identifiable, Equatable {
    let id: UUID
    let video: URL
    let plan: ShortVideoRequest.RenderPlan
    let voiceLabel: String
    /// One picture per scene, for the clip strip; nil when it is gone.
    let pictures: [URL?]

    init(id: UUID = UUID(), video: URL, plan: ShortVideoRequest.RenderPlan, voiceLabel: String, pictures: [URL?]) {
        self.id = id
        self.video = video
        self.plan = plan
        self.voiceLabel = voiceLabel
        self.pictures = pictures
    }
}

/// The draft screen: watch the video, see its narration and scenes on one
/// timeline, and ask for a change in words. It is a viewer, not an editor
/// (AGENTS.md): every change goes back to the agent, which edits the
/// storyboard and renders again.
struct ShortVideoDraftView: View {
    let draft: ShortVideoDraft
    /// Sends the user's change to the chat; the screen closes.
    var describeChange: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: DraftPlayback
    @State private var change = ""
    @State private var bars: [Float] = []
    @State private var saveNote: String?
    @FocusState private var typing: Bool

    init(draft: ShortVideoDraft, describeChange: @escaping (String) -> Void) {
        self.draft = draft
        self.describeChange = describeChange
        _playback = StateObject(wrappedValue: DraftPlayback(url: draft.video))
    }

    private var plan: ShortVideoRequest.RenderPlan { draft.plan }
    private var fraction: Double { plan.totalSeconds > 0 ? min(1, playback.time / plan.totalSeconds) : 0 }

    var body: some View {
        VStack(spacing: 14) {
            header
            DraftPlayerView(player: playback.player)
                .aspectRatio(CGFloat(plan.width) / CGFloat(plan.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 3))
                .frame(maxHeight: .infinity)
                .onTapGesture { playback.toggle() }
                .accessibilityIdentifier("draftVideo")
            transport
            timeline
            if let saveNote { Text(saveNote).font(.caption).foregroundStyle(.secondary) }
            changeBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(KeelStyle.background.ignoresSafeArea())
        .task { bars = await DraftPlayback.waveform(of: draft.video, bars: 140) }
        .onDisappear { playback.pause() }
    }

    // MARK: - Parts

    private var header: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                        .font(.title3).foregroundStyle(KeelStyle.accent)
                }
                .accessibilityIdentifier("draftBack")
                Spacer()
            }
            VStack(spacing: 8) {
                Text(plan.title ?? "Draft").font(.title3.weight(.semibold)).lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(KeelStyle.accent).frame(width: proxy.size.width * fraction)
                        }
                }
                .frame(width: 170, height: 6)
                .accessibilityLabel("Played \(Int(fraction * 100)) percent")
            }
        }
        .padding(.top, 6)
    }

    private var transport: some View {
        HStack(spacing: 56) {
            Button { playback.seek(to: plan.previousStart(from: playback.time)) } label: {
                Image(systemName: "backward.end.fill")
            }.accessibilityLabel("Previous scene")
            Button { playback.toggle() } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 34))
            }
            .accessibilityLabel(playback.playing ? "Pause" : "Play")
            .accessibilityIdentifier("draftPlay")
            Button { if let next = plan.nextStart(from: playback.time) { playback.seek(to: next) } } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next scene")
            .disabled(plan.nextStart(from: playback.time) == nil)
        }
        .font(.title2)
        .foregroundStyle(.primary)
    }

    private var timeline: some View {
        VStack(spacing: 10) {
            lane(icon: "waveform") {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14).fill(KeelStyle.accent.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14).stroke(KeelStyle.accent, lineWidth: 2)
                    Text("Kokoro TTS (\(draft.voiceLabel))").font(.caption).padding(.leading, 10).padding(.top, 6)
                    WaveformBars(bars: bars).padding(.horizontal, 8).padding(.top, 24).padding(.bottom, 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Narration, voice \(draft.voiceLabel)")
            }
            .frame(height: 74)
            lane(icon: "photo.on.rectangle") {
                GeometryReader { proxy in
                    HStack(spacing: 4) {
                        ForEach(Array(plan.clips.enumerated()), id: \.offset) { index, clip in
                            let width = max(28, (proxy.size.width - 4 * CGFloat(plan.clips.count - 1)) * plan.clipFractions[index])
                            ClipThumbnail(url: index < draft.pictures.count ? draft.pictures[index] : nil,
                                          current: plan.clipIndex(at: playback.time) == index)
                                .frame(width: width, height: proxy.size.height)
                                .onTapGesture { playback.seek(to: clip.start) }
                                .accessibilityLabel("Scene \(index + 1): \(clip.narration)")
                        }
                    }
                }
            }
            .frame(height: 64)
        }
        // One playhead across both lanes, at the playing time.
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                let start = 64 + 10.0
                Rectangle().fill(Color.white).frame(width: 2)
                    .offset(x: start + (proxy.size.width - start) * fraction - 1)
            }
            .allowsHitTesting(false)
        }
    }

    private func lane<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(KeelStyle.surface)
                .frame(width: 64)
                .overlay(Image(systemName: icon).font(.title2).foregroundStyle(KeelStyle.accent))
            content()
        }
    }

    private var changeBar: some View {
        HStack(spacing: 10) {
            TextField("Describe a change…", text: $change, axis: .vertical)
                .lineLimit(1...3)
                .focused($typing)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Capsule().fill(KeelStyle.surface))
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityIdentifier("draftChange")
            if change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                circle("square.and.arrow.down", label: "Save to Photos") { save() }
                ShareLink(item: draft.video) {
                    circleLabel("square.and.arrow.up")
                }.accessibilityLabel("Share")
            } else {
                circle("arrow.up", label: "Send change", filled: true) { send() }
                    .accessibilityIdentifier("draftSendChange")
            }
        }
    }

    private func circle(_ symbol: String, label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(symbol, filled: filled) }.accessibilityLabel(label)
    }

    private func circleLabel(_ symbol: String, filled: Bool = false) -> some View {
        Image(systemName: symbol).font(.title3.weight(.semibold))
            .foregroundStyle(filled ? KeelStyle.background : KeelStyle.accent)
            .frame(width: 52, height: 52)
            .background(Circle().fill(filled ? KeelStyle.accent : KeelStyle.surface))
    }

    private func send() {
        let text = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        playback.pause()
        describeChange(text)
        dismiss()
    }

    private func save() {
        let video = draft.video
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveNote = "Keel may not add to Photos. Allow it in Settings → Keel Mobile → Photos."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                }
                saveNote = "Saved to Photos."
            } catch {
                saveNote = "Could not save to Photos: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Playback

@MainActor
final class DraftPlayback: ObservableObject {
    let player: AVPlayer
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var playing = false
    private var observer: Any?
    private var ended: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated { self?.time = now.seconds.isFinite ? now.seconds : 0 }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playing = false }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let ended { NotificationCenter.default.removeObserver(ended) }
    }

    func toggle() {
        if playing { pause(); return }
        if let item = player.currentItem, item.duration.isNumeric, time >= item.duration.seconds - 0.05 { seek(to: 0) }
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        time = max(0, seconds)
    }

    /// The narration track's loudness as `bars` peaks (0…1); empty when the
    /// video has no sound. Read at 8 kHz mono, which is plenty for a picture.
    nonisolated static func waveform(of url: URL, bars: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        return ShortVideoWaveform.bars(samples, count: bars)
    }
}

/// The video with no system controls; the screen draws its own.
private struct DraftPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct WaveformBars: View {
    let bars: [Float]

    var body: some View {
        GeometryReader { proxy in
            let count = max(bars.count, 1)
            let step = proxy.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: step * 0.35) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(KeelStyle.accent)
                        .frame(width: step * 0.65, height: max(2, proxy.size.height * CGFloat(level)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct ClipThumbnail: View {
    let url: URL?
    let current: Bool
    /// Decoded once, small: playback redraws this 30 times a second.
    @State private var image: UIImage?

    var body: some View {
        // The picture fills the given frame and is cropped to it; on its own a
        // scaled-to-fill image grows past the frame (it spilled over the lanes).
        RoundedRectangle(cornerRadius: 12).fill(KeelStyle.surface)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: thumb)
            }.value
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? KeelStyle.accent : .clear, lineWidth: 3))
    }
}
