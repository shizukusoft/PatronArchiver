import Foundation
import WebKit

extension WKWebView {
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
        // `window` is flagged unsafe under strict memory safety; reading it on the main actor is fine.
        if unsafe window != nil { return true }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return unsafe window != nil
            }
            if unsafe window != nil { return true }
        }
        return unsafe window != nil
    }
}
