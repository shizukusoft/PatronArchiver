import Foundation
import OSLog

public struct URLResolver: Sendable {
    private static let logger = Logger(subsystem: Logger.moduleSubsystem, category: "URLResolver")

    /// Resolves a URL by following redirects with a HEAD request.
    ///
    /// - Returns: The final resolved URL, or the original URL if resolution fails.
    public static func resolve(
        _ url: URL,
        using urlSession: URLSession,
        timeout: TimeInterval = 10
    ) async -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let resolvedURL = httpResponse.url {
                logger.debug("Resolved \(url.absoluteString, privacy: .private) → \(resolvedURL.absoluteString, privacy: .private)")
                return resolvedURL
            }
        } catch {
            logger.warning("Failed to resolve \(url.absoluteString, privacy: .private): \(error.localizedDescription)")
        }

        return url
    }
}
