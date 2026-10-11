import Foundation
import Synchronization
import Testing
import WebKit
@testable import PatronArchiverKit

/// Answers every request from a table of canned responses, so the downloader can be driven
/// through success and refusal without a network.
private final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        let statusCode: Int
        let body: Data
        let chunkCount: Int
    }

    static let stubs = Mutex<[URL: Stub]>([:])

    /// - Parameter chunkCount: How many pieces to deliver the body in, pausing between them so a
    ///   transfer's progress has time to be seen partway.
    static func stub(
        _ url: URL,
        statusCode: Int,
        body: Data = Data("payload".utf8),
        chunkCount: Int = 1
    ) {
        stubs.withLock {
            $0[url] = Stub(statusCode: statusCode, body: body, chunkCount: chunkCount)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stubs.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // A literal status on a URL the stub already holds; the initializer only fails on
        // malformed input.
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(stub.body.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunkSize = stub.body.count / stub.chunkCount
        for index in 0..<stub.chunkCount {
            if index > 0 {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let start = index * chunkSize
            let end = index == stub.chunkCount - 1 ? stub.body.count : start + chunkSize
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: start..<end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct MediaDownloaderTests {
    private let session: URLSession
    private let downloader: MediaDownloader
    private let directory: URL

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        downloader = MediaDownloader(
            websiteDataStore: .nonPersistent(),
            urlSession: session
        )
        directory = FileManager.default.temporaryDirectory
            .appending(component: "MediaDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func item(_ name: String) -> MediaItem {
        // Each test uses its own URL, so the shared stub table never has to be reset.
        MediaItem(
            url: URL(string: "https://example.com/\(UUID().uuidString)/\(name)")!,
            type: .image,
            filename: nil,
            downloadAttribute: nil,
            referrerURL: nil
        )
    }

    private func stagedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path()).sorted()
    }

    @Test func savesAnAcceptedDownload() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = item("picture.png")
        let body = Data("image bytes".utf8)
        StubURLProtocol.stub(item.url, statusCode: 200, body: body)

        let downloaded = try await downloader.download([item], to: directory)

        #expect(downloaded.count == 1)
        #expect(try stagedFiles() == ["01 - picture.png"])
        #expect(try Data(contentsOf: directory.appending(component: "01 - picture.png")) == body)
    }

    @Test func failsOnARefusedDownload() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = item("gone.png")
        StubURLProtocol.stub(item.url, statusCode: 404, body: Data("<html>Not Found</html>".utf8))

        await #expect(throws: HTTPStatusError.self) {
            try await downloader.download([item], to: directory)
        }
        // The refused body is not saved as if it were the image.
        #expect(try stagedFiles().isEmpty)
    }

    @Test func failsOnAServerError() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = item("flaky.png")
        StubURLProtocol.stub(item.url, statusCode: 503)

        let error = await #expect(throws: HTTPStatusError.self) {
            try await downloader.download([item], to: directory)
        }
        #expect(error?.status.kind == .serverError)
        #expect(error?.url == item.url)
    }

    @Test func reportsEachDownloadAsOneUnitOfProgress() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = [item("first.png"), item("second.png"), item("third.png")]
        for item in items {
            StubURLProtocol.stub(item.url, statusCode: 200)
        }
        let progress = Progress.discreteProgress(totalUnitCount: Int64(items.count))

        _ = try await downloader.download(items, to: directory, progress: progress)

        #expect(progress.completedUnitCount == 3)
        #expect(progress.fractionCompleted == 1)
    }

    @Test func reportsATransferPartway() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = item("large.mp4")
        StubURLProtocol.stub(
            item.url,
            statusCode: 200,
            body: Data(repeating: 0xAB, count: 256 * 1024),
            chunkCount: 8
        )
        let progress = Progress.discreteProgress(totalUnitCount: 1)
        let fractions = FractionLog()
        // `@Sendable` so it is not taken as main-actor-isolated like the rest of this suite: KVO
        // calls it on URLSession's thread.
        let observation = progress.observe(\.fractionCompleted) { @Sendable progress, _ in
            fractions.append(progress.fractionCompleted)
        }
        defer { observation.invalidate() }

        _ = try await downloader.download([item], to: directory, progress: progress)

        // Somewhere between nothing and done: the bytes moved it, not only the file finishing.
        #expect(fractions.values.contains { $0 > 0 && $0 < 1 }, "\(fractions.values)")
        #expect(progress.fractionCompleted == 1)
    }

    @Test func oneRefusalFailsTheBatch() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = item("good.png")
        let bad = item("bad.png")
        StubURLProtocol.stub(good.url, statusCode: 200)
        StubURLProtocol.stub(bad.url, statusCode: 403)

        await #expect(throws: HTTPStatusError.self) {
            try await downloader.download([good, bad], to: directory)
        }
    }
}

private final class FractionLog: Sendable {
    private let log = Mutex<[Double]>([])

    var values: [Double] {
        log.withLock { $0 }
    }

    func append(_ fraction: Double) {
        log.withLock { $0.append(fraction) }
    }
}
