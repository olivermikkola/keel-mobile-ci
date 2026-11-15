import Foundation
import SwiftUI
import UIKit

/// Coordinates iOS ~30-second background execution grace windows (`beginBackgroundTask`)
/// for in-flight model downloads, custom GGUF imports, and GitHub publish/CI checks,
/// plus live status snapshots for the Dynamic Island / in-app live status pill and
/// iOS 26+ continued background processing tasks.
@MainActor
final class BackgroundAllowance {
    struct Token: Hashable {
        let rawValue: Int
    }

    private let beginHandler: @MainActor (String, @escaping @MainActor () -> Void) -> Token?
    private let endHandler: @MainActor (Token) -> Void
    private(set) var activeToken: Token?
    private(set) var activeName: String?

    var isHoldingBackgroundTime: Bool { activeToken != nil }

    init(
        begin: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Token? = BackgroundAllowance.systemBegin,
        end: @escaping @MainActor (Token) -> Void = BackgroundAllowance.systemEnd
    ) {
        self.beginHandler = begin
        self.endHandler = end
    }

    func acquire(name: String, onExpire: @escaping @MainActor () -> Void) {
        release()
        activeName = name
        let token = beginHandler(name) { [weak self] in
            self?.release()
            onExpire()
        }
        if let token {
            activeToken = token
        } else {
            activeName = nil
            onExpire()
        }
    }

    func release() {
        guard let token = activeToken else {
            activeName = nil
            return
        }
        activeToken = nil
        activeName = nil
        endHandler(token)
    }

    private static func systemBegin(
        name: String,
        onExpire: @escaping @MainActor () -> Void
    ) -> Token? {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in
                onExpire()
            }
        }
        guard identifier != .invalid else { return nil }
        return Token(rawValue: identifier.rawValue)
    }

    private static func systemEnd(_ token: Token) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Live activity / Dynamic Island and iOS 26+ continued-processing task descriptor.
struct KeelLiveActivitySnapshot: Equatable {
    enum Kind: String, Equatable {
        case modelDownload
        case modelImport
        case githubPublish
    }

    static let modelTransferTaskIdentifier = "com.olivermikkola.keelmobile.transfer"
    static let githubPublishTaskIdentifier = "com.olivermikkola.keelmobile.publish"

    let kind: Kind
    let title: String
    let subtitle: String
    let progress: Double?
    let isBackgroundGraceActive: Bool

    var continuedProcessingIdentifier: String {
        switch kind {
        case .modelDownload, .modelImport:
            return Self.modelTransferTaskIdentifier
        case .githubPublish:
            return Self.githubPublishTaskIdentifier
        }
    }

    var compactLeadingSymbol: String {
        switch kind {
        case .modelDownload, .modelImport:
            return "arrow.down.circle.fill"
        case .githubPublish:
            return "arrow.triangle.branch"
        }
    }

    var compactTrailingText: String {
        if let progress {
            return "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        }
        return "Live"
    }

    @MainActor
    static func current(models: ModelLibrary, chat: LocalChat) -> KeelLiveActivitySnapshot? {
        if let downloadingID = models.downloading,
           let model = models.catalog.first(where: { $0.id == downloadingID }) {
            let pct = Int((min(max(models.progress, 0), 1) * 100).rounded())
            let subtitle: String
            if models.verifying {
                subtitle = "Verifying SHA-256 checksum…"
            } else if models.restarting {
                subtitle = "Restarting clean download…"
            } else {
                let sizeText = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
                subtitle = "Downloading \(sizeText) · \(pct)%"
            }
            return KeelLiveActivitySnapshot(
                kind: .modelDownload,
                title: model.name,
                subtitle: subtitle,
                progress: models.verifying ? nil : models.progress,
                isBackgroundGraceActive: models.isHoldingBackgroundGrace
            )
        }
        if let importing = models.importing {
            return KeelLiveActivitySnapshot(
                kind: .modelImport,
                title: "Model import",
                subtitle: importing,
                progress: Self.parsedPercentage(from: importing),
                isBackgroundGraceActive: models.isHoldingBackgroundGrace
            )
        }
        if chat.publishing {
            return KeelLiveActivitySnapshot(
                kind: .githubPublish,
                title: chat.repository?.repository.fullName ?? "GitHub CI",
                subtitle: chat.phase.isEmpty ? "Running GitHub publish workflow…" : chat.phase,
                progress: nil,
                isBackgroundGraceActive: chat.isHoldingBackgroundGrace
            )
        }
        return nil
    }

    static func parsedPercentage(from text: String) -> Double? {
        guard let percentIndex = text.lastIndex(of: "%") else { return nil }
        let prefix = text[..<percentIndex]
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty, let value = Double(String(digits)) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }
}

/// Dynamic-Island-styled live status capsule shown in the chat screen when a model
/// download or import is running while the user browses or chats.
struct LiveStatusBannerView: View {
    let snapshot: KeelLiveActivitySnapshot
    let openAction: () -> Void
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openAction) {
                HStack(spacing: 10) {
                    Image(systemName: snapshot.compactLeadingSymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KeelStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(snapshot.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(snapshot.compactTrailingText)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(KeelStyle.accent)
                        }
                        Text(snapshot.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = snapshot.progress {
                            ProgressView(value: min(max(progress, 0), 1))
                                .tint(KeelStyle.accent)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("liveTransferBanner")

            if let cancelAction {
                Button(action: cancelAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel transfer")
                .accessibilityIdentifier("cancelLiveTransferBanner")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KeelStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(KeelStyle.accent.opacity(0.35)))
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
