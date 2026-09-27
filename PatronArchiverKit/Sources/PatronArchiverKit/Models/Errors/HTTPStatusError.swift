import Foundation
import HTTPTypes

/// An HTTP response whose status says the request did not succeed.
///
/// Neither `URLSession` nor WebKit treats a 4xx or 5xx as a failure: the response comes back like
/// any other, body and all. Anything that needs the request to have actually worked — a page load,
/// a media download — has to look at the status itself. This is that check, and the error to
/// throw when it fails.
struct HTTPStatusError: LocalizedError, Sendable {
    let status: HTTPResponse.Status
    let url: URL?

    /// Fails with `nil` when `response` is not HTTP or reports success, so a caller only has to
    /// deal with the case that is a problem.
    init?(rejecting response: URLResponse) {
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        let status = HTTPResponse.Status(code: httpResponse.statusCode)
        guard status.kind != .successful else { return nil }
        self.status = status
        self.url = httpResponse.url
    }

    var errorDescription: String? {
        // Explains what went wrong rather than reciting the status line; the code rides along in
        // parentheses for anyone who needs to look it up.
        let code = status.code
        return switch status {
        case .unauthorized, .forbidden:
            String(
                localized: "Access was denied. Check that you are logged in and can view this content. (\(code))",
                bundle: Bundle.module
            )
        case .notFound, .gone:
            String(
                localized: "This content could not be found. It may have been removed. (\(code))",
                bundle: Bundle.module
            )
        case .tooManyRequests:
            String(
                localized: "The site is limiting requests. Try again in a few minutes. (\(code))",
                bundle: Bundle.module
            )
        default:
            switch status.kind {
            case .clientError:
                String(localized: "The site rejected the request. (\(code))", bundle: Bundle.module)
            case .serverError:
                String(
                    localized: "The site is having a problem. Try again later. (\(code))",
                    bundle: Bundle.module
                )
            default:
                String(
                    localized: "The site returned an unexpected response. (\(code))",
                    bundle: Bundle.module
                )
            }
        }
    }
}
