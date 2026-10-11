import Foundation
import HTTPTypes
import Testing
@testable import PatronArchiverKit

struct HTTPStatusErrorTests {
    private static let url = URL(string: "https://example.com/post/1")!

    private static func httpResponse(_ statusCode: Int) -> HTTPURLResponse {
        // A literal URL and status; the initializer only fails on malformed input.
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test func acceptsSuccess() {
        #expect(HTTPStatusError(rejecting: Self.httpResponse(200)) == nil)
        #expect(HTTPStatusError(rejecting: Self.httpResponse(204)) == nil)
    }

    @Test func acceptsNonHTTPResponse() {
        let response = URLResponse(
            url: Self.url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
        )
        #expect(HTTPStatusError(rejecting: response) == nil)
    }

    @Test func rejectsClientError() throws {
        let error = try #require(HTTPStatusError(rejecting: Self.httpResponse(404)))
        #expect(error.status == .notFound)
        #expect(error.status.kind == .clientError)
        #expect(error.url == Self.url)
    }

    @Test func rejectsServerError() throws {
        let error = try #require(HTTPStatusError(rejecting: Self.httpResponse(503)))
        #expect(error.status == .serviceUnavailable)
        #expect(error.status.kind == .serverError)
    }

    @Test func describesEveryStatusWithItsCode() throws {
        for code in [401, 403, 404, 410, 418, 429, 500, 503, 999] {
            let error = try #require(HTTPStatusError(rejecting: Self.httpResponse(code)))
            let description = try #require(error.errorDescription)
            #expect(description.hasSuffix("(\(code))"), "\(code): \(description)")
        }
    }
}
