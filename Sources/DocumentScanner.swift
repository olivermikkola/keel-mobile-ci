import SwiftUI
#if canImport(VisionKit)
import VisionKit
#endif

/// Apple's document camera: finds the page edges, flattens and crops each
/// page. Keel reads the pages as text on the phone, like "Photo as text".
struct DocumentScanner: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        #if canImport(VisionKit) && !targetEnvironment(simulator)
        return VNDocumentCameraViewController.isSupported
        #else
        return false
        #endif
    }

    /// Each scanned page as JPEG data, in order.
    let onPages: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss

    #if canImport(VisionKit)
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPages: onPages, dismiss: { dismiss() }) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onPages: ([Data]) -> Void
        private let dismiss: () -> Void
        init(onPages: @escaping ([Data]) -> Void, dismiss: @escaping () -> Void) {
            self.onPages = onPages; self.dismiss = dismiss
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // A long scan is capped so its text stays readable for a small model.
            let pages = (0..<min(scan.pageCount, DocumentScanText.maxPages)).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.85)
            }
            dismiss()
            if !pages.isEmpty { onPages(pages) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { dismiss() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { dismiss() }
    }
    #else
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    #endif
}
