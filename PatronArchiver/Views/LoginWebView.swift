import PatronArchiverKit
import SwiftUI
import WebKit

struct LoginWebView: View {
    let initialURL: URL
    let initialProviderType: any PatronServiceProviding.Type
    let websiteDataStore: WKWebsiteDataStore
    var onLoginDetected: (() -> Void)?

    @State private var currentURL: URL
    @State private var currentProviderType: any PatronServiceProviding.Type
    @State private var pendingAlternateProviderType: (any PatronServiceProviding.Type)?
    @State private var isShowingAlternateLoginAlert = false

    init(
        url: URL,
        providerType: any PatronServiceProviding.Type,
        websiteDataStore: WKWebsiteDataStore,
        onLoginDetected: (() -> Void)? = nil
    ) {
        self.initialURL = url
        self.initialProviderType = providerType
        self.websiteDataStore = websiteDataStore
        self.onLoginDetected = onLoginDetected
        _currentURL = State(initialValue: url)
        _currentProviderType = State(initialValue: providerType)
    }

    var body: some View {
        LoginWebViewRepresentable(
            url: currentURL,
            providerType: currentProviderType,
            websiteDataStore: websiteDataStore,
            onLoginDetected: handleLoginDetected
        )
        .alert(
            "Additional Sign-In",
            isPresented: $isShowingAlternateLoginAlert
        ) {
            Button("Skip", role: .cancel) {
                pendingAlternateProviderType = nil
                onLoginDetected?()
            }
            Button("Continue") {
                guard let alternate = pendingAlternateProviderType else { return }
                pendingAlternateProviderType = nil
                currentProviderType = alternate
                currentURL = alternate.loginURL
            }
        } message: {
            Text("Some \(currentProviderType.siteIdentifier) content is hosted on a separate domain. Sign in there as well to access it.")
        }
    }

    private func handleLoginDetected() {
        if let alternate = currentProviderType.alternateProviderType {
            pendingAlternateProviderType = alternate
            isShowingAlternateLoginAlert = true
        } else {
            onLoginDetected?()
        }
    }
}

private struct LoginWebViewRepresentable {
    let url: URL
    let providerType: any PatronServiceProviding.Type
    let websiteDataStore: WKWebsiteDataStore
    var onLoginDetected: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            providerType: providerType,
            websiteDataStore: websiteDataStore,
            onLoginDetected: onLoginDetected
        )
    }

    fileprivate func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator.load(url, in: webView)
        return webView
    }
}

#if canImport(AppKit)
extension LoginWebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(providerType: providerType, url: url, in: nsView)
    }
}
#elseif canImport(UIKit)
extension LoginWebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.update(providerType: providerType, url: url, in: uiView)
    }
}
#endif

extension LoginWebViewRepresentable {
    final class Coordinator {
        private var providerType: any PatronServiceProviding.Type
        private let websiteDataStore: WKWebsiteDataStore
        private let onLoginDetected: (() -> Void)?
        private var detectionTask: Task<Void, Never>?
        private var lastRequestedURL: URL?

        /// How often the cookie store is checked for the provider's sign-in.
        private static let detectionInterval = Duration.milliseconds(500)

        init(
            providerType: any PatronServiceProviding.Type,
            websiteDataStore: WKWebsiteDataStore,
            onLoginDetected: (() -> Void)?
        ) {
            self.providerType = providerType
            self.websiteDataStore = websiteDataStore
            self.onLoginDetected = onLoginDetected
            startDetectingLogin()
        }

        isolated deinit {
            detectionTask?.cancel()
        }

        func load(_ url: URL, in webView: WKWebView) {
            lastRequestedURL = url
            webView.load(URLRequest(url: url))
        }

        func update(
            providerType newProviderType: any PatronServiceProviding.Type,
            url: URL,
            in webView: WKWebView
        ) {
            if ObjectIdentifier(newProviderType) != ObjectIdentifier(providerType) {
                providerType = newProviderType
                startDetectingLogin()
            }
            if lastRequestedURL != url {
                load(url, in: webView)
            }
        }

        /// Watches the cookie store until the provider reports a completed sign-in.
        ///
        /// Polling rather than an event: `WKHTTPCookieStoreObserver` never fires for cookies the
        /// network process sets while loading a page, and the navigation callbacks all complete
        /// before the sign-in cookie has propagated to `WKHTTPCookieStore` — a single check driven
        /// by either one misses the sign-in and nothing comes along afterwards to re-check.
        private func startDetectingLogin() {
            detectionTask?.cancel()
            detectionTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let cookies = await websiteDataStore.httpCookieStore.allCookies()
                    guard !Task.isCancelled else { return }
                    if providerType.isLoggedIn(cookies: cookies) {
                        onLoginDetected?()
                        return
                    }
                    try? await Task.sleep(for: Self.detectionInterval)
                }
            }
        }
    }
}
