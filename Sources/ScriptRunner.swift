import Foundation
#if canImport(WebKit)
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct ScriptExecution {
    let outcome: ScriptOutcome
    let output: String
    let changedFiles: [String]
    let readPaths: [String]
    let netChanges: [(path: String, after: String?)]
}

private final class ScriptHostBox: @unchecked Sendable {
    let host: ScriptHost
    private let queue = DispatchQueue(label: "keel.script.host", qos: .userInitiated)

    init(_ host: ScriptHost) {
        self.host = host
    }

    func handle(name: String, argumentsJSON: String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.host.handle(name: name, argumentsJSON: argumentsJSON))
            }
        }
    }

    func snapshot(after workspace: TaskWorkspace) async -> (
        output: String,
        changedFiles: [String],
        readPaths: [String],
        netChanges: [(path: String, after: String?)]
    ) {
        await withCheckedContinuation { continuation in
            queue.async {
                let changed = self.host.changedFiles
                let net = changed.map { ($0, try? workspace.read($0).text) }
                continuation.resume(returning: (self.host.output, changed, self.host.readPaths, net))
            }
        }
    }
}

/// Runs model JavaScript inside an isolated non-persistent `WKWebView` with
/// CSP `default-src 'none'`, explicit host bridge (`ScriptHost`), and a hard
/// wall-clock timeout that tears down `WebContent` cleanly.
@MainActor
final class ScriptRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static let emptyHTML = """
    <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'none'; img-src 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'; object-src 'none'; media-src 'none'; form-action 'none';"></head><body></body></html>
    """

    private static var preludeScriptSource: String {
        """
        (function () {
          const bridge = window.webkit.messageHandlers.keel;
          globalThis.__keelHost = (name, argsJSON) => bridge.postMessage({ name: name, argsJSON: argsJSON });
        })();
        \(ScriptPrelude.asyncSource())
        """
    }

    private let hostBox: ScriptHostBox
    private var webView: WKWebView?
    private var pendingCode = ""
    private var didLoad = false
    private var finished = false
    private var continuation: CheckedContinuation<ScriptOutcome, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var scriptTimeout: TimeInterval = 5
    private static let startupTimeout: TimeInterval = 20

    private init(hostBox: ScriptHostBox) {
        self.hostBox = hostBox
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "keel")
        controller.addUserScript(WKUserScript(
            source: Self.preludeScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        self.webView = view
    }

    static func run(
        code: String,
        workspace: TaskWorkspace,
        allowWrites: Bool,
        approvedKey: String,
        approvedOperations: [TaskWorkspace.Operation],
        budget: ScriptBudget = ScriptBudget(),
        timeout: TimeInterval = 5
    ) async throws -> ScriptExecution {
        let host = ScriptHost(workspace: workspace, budget: budget, allowWrites: allowWrites)
        let hostBox = ScriptHostBox(host)
        let runner = ScriptRunner(hostBox: hostBox)
        do {
            let outcome = try await runner.run(code: code, timeout: timeout)
            let snap = await hostBox.snapshot(after: workspace)
            try? workspace.setOverlay(key: approvedKey, operations: approvedOperations)
            return ScriptExecution(
                outcome: outcome,
                output: snap.output,
                changedFiles: snap.changedFiles,
                readPaths: snap.readPaths,
                netChanges: snap.netChanges
            )
        } catch {
            _ = await hostBox.snapshot(after: workspace)
            try? workspace.setOverlay(key: approvedKey, operations: approvedOperations)
            throw error
        }
    }

    private func run(code: String, timeout: TimeInterval) async throws -> ScriptOutcome {
        pendingCode = code
        scriptTimeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // Starting WebKit's content process can take seconds on a cold launch.
                // It gets its own limit so the script's time limit covers only the script.
                self.timeoutTask = Task { @MainActor [weak self] in
                    // Cancelled when the script starts; a cancelled sleep returns at once.
                    guard (try? await Task.sleep(for: .seconds(Self.startupTimeout))) != nil else { return }
                    self?.finish(.success(.failed(message: "The JavaScript sandbox did not start in time. Try again.")))
                }
                self.attachToWindow()
                self.webView?.loadHTMLString(Self.emptyHTML, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func executePendingCode() {
        guard !finished, let webView else { return }
        let timeout = scriptTimeout
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            self?.finish(.success(.timedOut(seconds: max(1, Int(timeout.rounded(.up))))))
        }
        // Call the Objective-C method directly. WebKit's Swift wrapper for it lives in
        // libswiftWebKit, which the iOS 18 simulator does not ship: the app crashed at launch.
        webView.__callAsyncJavaScript(pendingCode, arguments: [:], inFrame: nil, in: .defaultClient) { [weak self] value, error in
            guard let self, !self.finished, let webView = self.webView else { return }
            let outcome: ScriptOutcome
            if let error {
                outcome = .failed(message: Self.errorMessage(error))
            } else {
                outcome = .finished(value: Self.formatValue(value ?? ()))
            }
            webView.__callAsyncJavaScript("return await globalThis.__keelDrain();", arguments: [:], inFrame: nil, in: .defaultClient) { [weak self] _, _ in
                self?.finish(.success(outcome))
            }
        }
    }

    private func finish(_ result: Result<ScriptOutcome, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let webView {
            webView.stopLoading()
            webView.removeFromSuperview()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.configuration.userContentController.removeAllUserScripts()
            self.webView = nil
        }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    /// iOS can suspend the content process of a web view that is in no window, and the
    /// script then never starts. Keep it in the app's window, invisible, while it runs.
    private func attachToWindow() {
        #if canImport(UIKit)
        guard let webView else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) ?? ($0 as? UIWindowScene)?.windows.first }
            .first
        guard let window else { return }
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        window.insertSubview(webView, at: 0)
        #endif
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url?.absoluteString
        let allowedInitial = !didLoad
            && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.navigationType == .other
            && (url == nil || url == "about:blank")
        decisionHandler(allowedInitial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didLoad, !finished else { return }
        didLoad = true
        executePendingCode()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.success(.failed(message: error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.success(.failed(message: error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.success(.failed(message: "JavaScript stopped unexpectedly (memory or runtime limit).")))
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard !finished,
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let argsJSON = body["argsJSON"] as? String else {
            replyHandler(ScriptHost.reply(error: "Invalid host bridge arguments."), nil)
            return
        }
        let hostBox = self.hostBox
        Task { @MainActor in
            let reply = await hostBox.handle(name: name, argumentsJSON: argsJSON)
            replyHandler(reply, nil)
        }
    }

    // MARK: - Formatting

    private static func formatValue(_ value: Any) -> String? {
        if value is Void { return nil }
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    private static func errorMessage(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        if let detail = info["WKJavaScriptExceptionMessage"] as? String, !detail.isEmpty {
            return detail
        }
        return error.localizedDescription
    }
}
#endif
