import Foundation
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Where finished short videos are kept: `<id>.mp4` and its `<id>.json`
/// manifest, next to the chat's other private files, out of backups.
enum ShortVideoStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeneratedVideos", isDirectory: true)
    }

    static func newName() -> String { UUID().uuidString + ".mp4" }
    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func manifestURL(_ name: String) -> URL { url(name).deletingPathExtension().appendingPathExtension("json") }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
    }

    static func save(_ manifest: ShortVideoManifest, for name: String) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(name), options: [.atomic, .completeFileProtection])
    }

    static func manifest(for name: String) -> ShortVideoManifest? {
        guard let data = try? Data(contentsOf: manifestURL(name)) else { return nil }
        return try? JSONDecoder().decode(ShortVideoManifest.self, from: data)
    }

    /// Removes videos (and manifests) no saved chat shows any more.
    static func prune(keeping names: Set<String>) {
        let keep = names.union(names.map { ($0 as NSString).deletingPathExtension + ".json" })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

/// What the short-video tool needs from a voice: speak one line to an AAC file
/// and free the memory afterwards. `NarrationEngine` (Kokoro) in the app; a
/// stand-in in tests.
protocol NarrationSpeaking: Sendable {
    func speak(_ text: String, voice: String, to url: URL) async throws -> TimeInterval
    func unload() async
}

extension NarrationEngine: NarrationSpeaking {}
