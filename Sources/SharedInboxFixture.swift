#if DEBUG && targetEnvironment(simulator)
import UIKit

/// UI tests: writes what the share extension would save for two photos sent
/// with "Make a video" or "Make a carousel", in the real App Group, before
/// the app opens it.
enum SharedInboxFixture {
    static func write(action: SharedItem.Action = .video, text: String = "Ruben at the beach") {
        guard let root = SharedInbox.root() else { return }
        var item = SharedItem(action: action, text: text)
        guard let folder = try? SharedInbox.prepare(item.id, in: root) else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (index, color) in [UIColor.systemTeal, UIColor.systemOrange].enumerated() {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1600), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1600))
            }.jpegData(compressionQuality: 0.9)
            let name = "photo-\(index + 1).jpg"
            guard (try? data?.write(to: folder.appendingPathComponent(name))) != nil else { return }
            item.photos.append(name)
        }
        try? SharedInbox.save(item, in: root)
    }
}
#endif
