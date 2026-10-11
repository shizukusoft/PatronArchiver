import WebKit

@MainActor
final class RedirectTracker: NSObject, WKNavigationDelegate {
    private(set) var redirectChain: [URL] = []
    private var continuation: CheckedContinuation<[URL], any Error>?
    private weak var webView: WKWebView?

    /// Set when the task is cancelled, so a cancellation arriving before the continuation is
    /// installed still resolves the load rather than leaving it suspended for good.
    private var isCancelled = false

    /// The main frame's status, when the server answered with something other than success.
    ///
    /// WebKit renders a 404 or 500 page like any other and reports the navigation as finished, so
    /// the load only fails on it once `didFinish` arrives. The page is left to render rather than
    /// cancelled: what the server sent back — a login wall, a bot challenge — is the best
    /// explanation of the failure the user is going to get.
    private var httpError: HTTPStatusError?

    func load(_ url: URL, in webView: WKWebView) async throws -> [URL] {
        redirectChain = [url]
        httpError = nil
        self.webView = webView
        webView.navigationDelegate = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !isCancelled else {
                    resignNavigationDelegate()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            // Cancellation handlers run outside the actor; hop back so the continuation is only
            // ever touched on the main actor.
            Task { @MainActor in
                self.cancelLoad()
            }
        }
    }

    /// Aborts the navigation and fails the load, so a cancelled task finishes instead of waiting
    /// for a delegate callback that may never come.
    private func cancelLoad() {
        isCancelled = true
        // Read ownership before `finish` gives it up. A cancelled job unwinds asynchronously, so
        // the next job may already drive this web view — stopping its navigation would strand it.
        let ownsWebView = webView?.navigationDelegate === self
        // Resume first: `stopLoading()` can call back into the delegate, and the load should fail
        // as cancelled rather than as whatever WebKit reports for the abort.
        finish(throwing: CancellationError())
        if ownsWebView {
            webView?.stopLoading()
        }
    }

    /// Steps down as the web view's navigation delegate, but only while this tracker is the one
    /// installed — clearing a successor's delegate would leave its load with nothing to resume it.
    private func resignNavigationDelegate() {
        guard let webView, webView.navigationDelegate === self else { return }
        webView.navigationDelegate = nil
    }

    private func finish(returning chain: [URL]) {
        guard let continuation else { return }
        self.continuation = nil
        resignNavigationDelegate()
        continuation.resume(returning: chain)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        resignNavigationDelegate()
        continuation.resume(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true {
            if redirectChain.last != url {
                redirectChain.append(url)
            }
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            httpError = HTTPStatusError(rejecting: navigationResponse.response)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let httpError {
            finish(throwing: httpError)
            return
        }
        if let finalURL = webView.url, redirectChain.last != finalURL {
            redirectChain.append(finalURL)
        }
        finish(returning: redirectChain)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(throwing: error)
    }
}
