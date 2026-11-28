import ObjectiveC
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Send to Keel" in other apps' share sheets. Saves what was shared in the
/// App Group (`SharedInbox`) and opens Keel; nothing runs here but copying.
/// Photos can go to Videos or Carousels; links, text and a file start a new chat.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] opened in self?.complete(opened: opened) }
        let host = UIHostingController(rootView: ShareSheet(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }

    private func complete(opened: URL?) {
        if let opened { open(opened) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Asks iOS to bring Keel forward. Extensions have no public way to do
    /// this; if iOS ignores it, Keel finds the share next time it opens.
    private func open(_ url: URL) {
        // `UIApplication.open` is marked unavailable in extensions, so it is
        // called through the Objective-C runtime on the app object found in
        // the responder chain.
        guard let appClass = NSClassFromString("UIApplication") else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: appClass), let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(method_getImplementation(method), to: Open.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable { case loading, ready, failed(String) }

    @Published var state = State.loading
    @Published private(set) var photos: [Data] = []
    @Published private(set) var text: String?
    @Published private(set) var url: String?
    @Published private(set) var file: (name: String, data: Data)?
    var finish: (URL?) -> Void = { _ in }

    var summary: String {
        var parts: [String] = []
        if !photos.isEmpty { parts.append("\(photos.count) photo\(photos.count == 1 ? "" : "s")") }
        if let url { parts.append(URL(string: url)?.host ?? url) }
        if let file { parts.append(file.name) }
        if let text, url == nil || !text.contains(url ?? "") { parts.append("“\(text.prefix(80))”") }
        return parts.joined(separator: " · ")
    }

    func load(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if photos.count < SharedInbox.maxPhotos, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await Self.data(provider, UTType.image) {
                photos.append(data)
            } else if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let link = await Self.url(provider), !link.isFileURL {
                if let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" { url = link.absoluteString }
            } else if file == nil, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                      !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let loaded = await Self.file(provider) {
                file = loaded
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let words = await Self.text(provider) {
                text = String(words.prefix(16_000))
            }
        }
        state = photos.isEmpty && url == nil && text == nil && file == nil
            ? .failed("Keel can take links, text, up to \(SharedInbox.maxPhotos) photos or one file up to 32 MB.")
            : .ready
    }

    /// Saves the share and finishes; `action` picks where Keel opens it.
    func send(_ action: SharedItem.Action) {
        guard let root = SharedInbox.root() else {
            state = .failed("Keel's shared folder is missing. Reinstall Keel and try again.")
            return
        }
        var item = SharedItem(action: action, text: text, url: url)
        do {
            let folder = try SharedInbox.prepare(item.id, in: root)
            for (index, data) in photos.enumerated() {
                let name = "photo-\(index + 1).jpg"
                try data.write(to: folder.appendingPathComponent(name), options: .completeFileProtectionUntilFirstUserAuthentication)
                item.photos.append(name)
            }
            if let file {
                let name = (file.name as NSString).lastPathComponent
                try file.data.write(to: folder.appendingPathComponent(name), options: .completeFileProtectionUntilFirstUserAuthentication)
                item.files.append(name)
            }
            try SharedInbox.save(item, in: root)
            finish(SharedInbox.link(item.id))
        } catch {
            SharedInbox.remove(item.id, in: root)
            state = .failed("Keel could not save this: \(error.localizedDescription)")
        }
    }

    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { $0.count <= SharedInbox.maxFileBytes ? $0 : nil })
            }
        }
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func text(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    private static func file(_ provider: NSItemProvider) async -> (name: String, data: Data)? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                // The file is only there until this returns: read it now.
                guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= SharedInbox.maxFileBytes, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (provider.suggestedName.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix(url.pathExtension) ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent, data))
            }
        }
    }
}

private struct ShareSheet: View {
    @ObservedObject var model: ShareModel
    private let jade = Color(red: 0.21, green: 0.70, blue: 0.58)
    private let ink = Color(red: 0.04, green: 0.07, blue: 0.07)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .loading:
                    ProgressView("Reading…").frame(maxWidth: .infinity)
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                case .ready:
                    Text(model.summary).font(.headline).lineLimit(3)
                    Text("Keel opens it on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"). Nothing is sent anywhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !model.photos.isEmpty {
                        button("Make a video", "film") { model.send(.video) }
                            .accessibilityIdentifier("shareMakeVideo")
                        button("Make a carousel", "square.stack") { model.send(.carousel) }
                            .accessibilityIdentifier("shareMakeCarousel")
                    }
                    button(model.photos.count > 1 ? "Ask in a new chat (first photo)" : "Ask in a new chat", "bubble.left") { model.send(.chat) }
                        .accessibilityIdentifier("shareNewChat")
                }
                Spacer()
            }
            .padding(20)
            .background(ink)
            .navigationTitle("Send to Keel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.finish(nil) } } }
        }
        .tint(jade)
        .preferredColorScheme(.dark)
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(ink)
    }
}
