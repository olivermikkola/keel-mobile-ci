#if DEBUG && targetEnvironment(simulator)
import Foundation

enum ModelDownloadUITestFixture {
    static func prepare(in directory: URL) {
        guard ProcessInfo.processInfo.arguments.contains("--partial-model-fixture"),
              let model = LocalModel.catalog.first else { return }
        let file = directory.appendingPathComponent(model.fileName + ".download")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.protectionKey: FileProtectionType.complete]) else { return }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            // Sparse, deliberately unverified data. Never an installed model.
            try handle.truncate(atOffset: 16_777_216)
        } catch { }
    }
}
#endif
