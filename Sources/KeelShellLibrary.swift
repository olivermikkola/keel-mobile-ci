import Foundation

/// `Resources/KeelShell.js`, built by `tools/keel-shell` (just-bash over the
/// task workspace). Read once; about 1.3 MB.
enum KeelShellLibrary {
    static let source: String? = {
        guard let url = Bundle.main.url(forResource: "KeelShell", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()
}
