import SwiftUI
import WebKit

// Shows a workspace page (WebPreview.document) on the phone. The page runs its
// own scripts, but cannot load anything from the network (its CSP), keep data
// (non-persistent store), open windows, or navigate away.
struct WebPreviewView: View {
    let title: String
    let document: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPreviewPage(document: document)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("webPreview")
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct WebPreviewPage: UIViewRepresentable {
    let document: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        // The page itself and links within it (about:blank#section) stay; every
        // other navigation, including links to websites, is cancelled.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
