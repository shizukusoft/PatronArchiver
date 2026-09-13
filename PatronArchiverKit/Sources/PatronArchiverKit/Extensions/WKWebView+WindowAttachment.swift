import Foundation
import WebKit

extension WKWebView {
    /// Whether the web view is currently part of a window's view hierarchy.
    ///
    /// `NSView.window` is flagged unsafe under strict memory safety, whereas `UIView.window` is
    /// not as of the iOS 27 SDK; reading either on the main actor is fine.
    @MainActor
    private var isAttachedToWindow: Bool {
        #if os(macOS)
        unsafe window != nil
        #else
        window != nil
        #endif
    }

    /// Waits until the web view is attached to a window, up to a bounded timeout.
    ///
    /// `WKWebView` only renders while it is part of a window's view hierarchy, so page loading,
    /// lazy-content scrolling, and PDF capture must wait for attachment. The view is displayed via
    /// SwiftUI's `ArchiveWebViewRepresentable`, which attaches it once its enclosing window exists.
    ///
    /// - Parameters:
    ///   - timeout: The longest time to wait before returning regardless of attachment.
    ///   - pollInterval: How often to re-check attachment.
    /// - Returns: `true` if the view became attached within the timeout, `false` otherwise.
    @MainActor
    public func waitUntilAttached(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        if isAttachedToWindow { return true }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return isAttachedToWindow
            }
            if isAttachedToWindow { return true }
        }
        return isAttachedToWindow
    }
}
