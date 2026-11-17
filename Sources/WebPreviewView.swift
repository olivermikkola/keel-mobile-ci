import SwiftUI
import UIKit
import WebKit
#if canImport(KeelHarness)
import KeelHarness
#endif

@MainActor
final class WebPreviewController: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var pdfURL: URL?
    private var exporting = false

    func exportPDF(title: String) {
        guard let webView, !exporting else { return }
        exporting = true
        defer { exporting = false }
        // Render via UIPrintPageRenderer (pure UIKit) rather than WKWebView.createPDF,
        // whose Swift overlay links libswiftWebKit.dylib (missing in iOS 18 simulator runtimes).
        let pageSize = CGSize(width: 612, height: 792)
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let printableRect = pageRect.insetBy(dx: 24, dy: 24)
        let renderer = UIPrintPageRenderer()
        renderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))

        let pageCount = renderer.numberOfPages
        var data = Data()
        if pageCount > 0 {
            data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
                for index in 0..<pageCount {
                    context.beginPage()
                    renderer.drawPage(at: index, in: context.pdfContextBounds)
                }
            }
        }
        if data.isEmpty {
            let bounds = webView.bounds.width > 0 && webView.bounds.height > 0 ? webView.bounds : pageRect
            data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage()
                webView.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
        guard !data.isEmpty else { return }
        cleanup()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(FileView.pdfFileName(for: title))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            pdfURL = url
        } catch {}
    }

    func cleanup() {
        if let pdfURL {
            try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
            self.pdfURL = nil
        }
    }
}

// Shows a workspace page (WebPreview.document) on the phone. The page runs its
// own scripts, but cannot load anything from the network (its CSP), keep data
// (non-persistent store), open windows, or navigate away.
struct WebPreviewView: View {
    let title: String
    let document: String
    @StateObject private var controller = WebPreviewController()
    @State private var showingShareSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPreviewPage(document: document, controller: controller)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("webPreview")
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if controller.pdfURL != nil {
                                showingShareSheet = true
                            } else {
                                controller.exportPDF(title: title)
                            }
                        } label: {
                            if controller.pdfURL != nil {
                                Label("Share PDF", systemImage: "square.and.arrow.up")
                            } else {
                                Label("Export PDF", systemImage: "arrow.down.doc")
                            }
                        }
                        .accessibilityIdentifier(controller.pdfURL != nil ? "sharePreviewPDF" : "exportPreviewPDF")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { controller.cleanup(); dismiss() }
                    }
                }
                .sheet(isPresented: $showingShareSheet) {
                    if let pdfURL = controller.pdfURL {
                        PDFActivityShareSheet(url: pdfURL)
                    }
                }
                .onDisappear { controller.cleanup() }
        }
    }
}

private struct PDFActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct WebPreviewPage: UIViewRepresentable {
    let document: String
    let controller: WebPreviewController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        controller.webView = view
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        controller.webView = view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // The page itself and links within it (about:blank#section) stay; every
        // other navigation, including links to websites, is cancelled.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
