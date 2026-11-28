import AVFoundation
import SwiftUI

/// A finished short video in the chat: a poster frame and a button that opens
/// the draft screen.
struct ShortVideoCard: View {
    let name: String
    let caption: String
    let open: () -> Void
    @State private var poster: UIImage?

    private var exists: Bool { FileManager.default.fileExists(atPath: ShortVideoStore.url(name).path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exists {
                Button(action: open) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(KeelStyle.surface)
                        if let poster { Image(uiImage: poster).resizable().scaledToFill() }
                        Image(systemName: "play.circle.fill").font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.92)).shadow(radius: 6)
                    }
                    .frame(width: 180, height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open short video draft")
                .accessibilityIdentifier("openShortVideo")
                .task(id: name) { poster = await Self.frame(of: ShortVideoStore.url(name)) }
            } else {
                Label("This video is no longer on this \(KeelDevice.name).", systemImage: "film").font(.caption).foregroundStyle(.secondary)
            }
            // The first line of the result; the storyboard below it is for the model.
            Text(caption.components(separatedBy: "\n").first ?? caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A frame half a second in, past any fade-in, small.
    static func frame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 640)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }
}
