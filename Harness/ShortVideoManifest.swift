import Foundation

/// What Keel keeps next to a finished short video (`<id>.json` beside
/// `<id>.mp4`), so the draft screen can show its scenes after a relaunch and the
/// model can be shown the storyboard to change. Plain data, versioned.
public struct ShortVideoManifest: Codable, Equatable, Sendable {
    public struct Scene: Codable, Equatable, Sendable {
        public let imagePath: String
        public let narration: String
        public let overlay: String?
        public let motion: String
        public let start: TimeInterval
        public let duration: TimeInterval
    }

    public var version = 1
    public let path: String
    public let title: String?
    public let voice: String
    public let aspectRatio: String
    public let scenes: [Scene]

    public init(plan: ShortVideoRequest.RenderPlan) {
        path = plan.path
        title = plan.title
        voice = plan.voice.id
        aspectRatio = plan.aspectRatio.rawValue
        scenes = plan.clips.map {
            Scene(imagePath: $0.imagePath, narration: $0.narration, overlay: $0.overlay,
                  motion: $0.motion.rawValue, start: $0.start, duration: $0.duration)
        }
    }

    /// The plan back, with the lengths it was rendered at.
    public var plan: ShortVideoRequest.RenderPlan {
        let aspect = ShortVideoRequest.AspectRatio(rawValue: aspectRatio) ?? .vertical
        let clips = scenes.map {
            ShortVideoRequest.RenderPlan.Clip(imagePath: $0.imagePath, narration: $0.narration, overlay: $0.overlay,
                                              motion: ShortVideoRequest.Motion(rawValue: $0.motion) ?? .none,
                                              duration: $0.duration, start: $0.start)
        }
        return ShortVideoRequest.RenderPlan(path: path, title: title, voice: .init(id: voice), aspectRatio: aspect, clips: clips)
    }

    /// The storyboard as the model writes it, for a follow-up change.
    public var storyboard: String {
        scenes.map { scene in
            var lines = ["image: \(scene.imagePath)", "say: \(scene.narration)"]
            if let overlay = scene.overlay { lines.append("overlay: \(overlay)") }
            if scene.motion != ShortVideoRequest.Motion.none.rawValue { lines.append("motion: \(scene.motion)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
