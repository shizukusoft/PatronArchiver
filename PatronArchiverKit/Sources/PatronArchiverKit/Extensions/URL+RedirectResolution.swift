import Foundation
import OSLog

extension URL {
    private static let logger = Logger(subsystem: Logger.moduleSubsystem, category: "RedirectResolution")

    /// Follows redirects with a HEAD request and returns the final URL.
    ///
    /// - Returns: The URL the request ended at, or `self` if the request fails.
    public func resolvingRedirects(
        using urlSession: URLSession,
        timeout: TimeInterval = 10
    ) async -> URL {
        var request = URLRequest(url: self)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let resolvedURL = httpResponse.url {
                Self.logger.debug("Resolved \(self.absoluteString, privacy: .private) → \(resolvedURL.absoluteString, privacy: .private)")
                return resolvedURL
            }
        } catch {
            Self.logger.warning("Failed to resolve \(self.absoluteString, privacy: .private): \(error.localizedDescription)")
        }

        return self
    }
}
