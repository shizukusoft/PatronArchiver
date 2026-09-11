import Foundation
import Synchronization
import UniformTypeIdentifiers
import WebKit

enum MediaDownloader {
    struct DownloadedMedia: Sendable {
        let item: MediaItem
        let localURL: URL
        let downloadRedirects: [URL]
    }

    static func download(
        items: [MediaItem],
        to directory: URL,
        websiteDataStore: WKWebsiteDataStore,
        urlSession: URLSession,
        onFileDownloaded: (@Sendable () -> Void)? = nil
    ) async throws -> [DownloadedMedia] {
        // Batch urlRequest creation to minimize main actor hops
        var requests: [URL: URLRequest] = [:]
        for item in items {
            var urlRequest = URLRequest(url: item.url)
            await websiteDataStore.addCookies(to: &urlRequest)
            requests[item.url] = urlRequest
        }

        return try await withThrowingTaskGroup(of: DownloadedMedia?.self) { group in
            for (index, item) in items.enumerated() {
                let request = requests[item.url]!
                group.addTask {
                    let redirectCollector = RedirectCollector()
                    let (tempURL, response) = try await urlSession.download(
                        for: request,
                        delegate: redirectCollector
                    )

                    let destinationURL = try resolveDestinationURL(
                        for: item,
                        in: directory,
                        response: response as? HTTPURLResponse,
                        index: index
                    )

                    // Left to fail if something is already there. The staging directory is new for
                    // every job, so nothing in it is stale enough to be worth clearing — a name
                    // that is taken means this download collided with the page dump or with
                    // another item, and losing a file quietly is worse than failing the job.
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                    return DownloadedMedia(
                        item: item,
                        localURL: destinationURL,
                        downloadRedirects: redirectCollector.redirectedURLs
                    )
                }
            }

            var results: [DownloadedMedia] = []
            for try await media in group {
                if let media { results.append(media) }
                onFileDownloaded?()
            }
            return results
        }
    }

    private static func resolveDestinationURL(
        for item: MediaItem,
        in directory: URL,
        response: HTTPURLResponse?,
        index: Int
    ) throws -> URL {
        // `String(format:)` goes through untyped `CVarArg` varargs, hence `unsafe`.
        let prefix = unsafe String(format: "%02d", index + 1)
        let baseURL = resolveBaseURL(for: item, in: directory, response: response, index: index)
        let lastComponent = baseURL.deletingPathExtension().lastPathComponent
        guard let stem = FileNameSanitizer.sanitize(lastComponent) else {
            throw FileNameSanitizer.FileNameSanitizerError.emptyFileName
        }
        var destinationURL = directory.appending(component: "\(prefix) - \(stem)")
        let pathExtension = baseURL.pathExtension
        if !pathExtension.isEmpty {
            destinationURL.appendPathExtension(pathExtension)
        }
        return destinationURL
    }

    private static func resolveBaseURL(
        for item: MediaItem,
        in directory: URL,
        response: HTTPURLResponse?,
        index: Int
    ) -> URL {
        // 1. Use explicit filename if provided
        if let filename = item.filename, !filename.isEmpty {
            return directory.appending(component: filename)
        }

        // 2. Try Content-Disposition header (filename* takes precedence per RFC 6266)
        if let disposition = response?.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = ContentDisposition(headerValue: disposition),
           let filename = parsed.filename,
           !filename.isEmpty {
            return directory.appending(component: filename)
        }

        // 3. Try HTML download attribute
        if let downloadAttr = item.downloadAttribute, !downloadAttr.isEmpty {
            return directory.appending(component: downloadAttr)
        }

        // 4. Fall back to URL last path component
        let lastComponent = item.url.lastPathComponent
        if !lastComponent.isEmpty && lastComponent != "/" {
            return directory.appending(component: lastComponent)
        }

        // 5. Generate indexed filename, using UTType for extension when possible
        // `String(format:)` goes through untyped `CVarArg` varargs, hence `unsafe`.
        let sequence = unsafe String(format: "%03d", index + 1)
        var fileURL = directory.appending(component: "\(item.type)_\(sequence)")
        if let mimeType = response?.mimeType,
           let utType = UTType(mimeType: mimeType),
           let ext = utType.preferredFilenameExtension {
            fileURL.appendPathExtension(ext)
        }
        return fileURL
    }
}

private final class RedirectCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let urls = Mutex<[URL]>([])

    var redirectedURLs: [URL] {
        urls.withLock { $0 }
    }

    // Workaround for a SILGen crash while emitting the ObjC thunk for an `@objc`-exposed
    // `nonisolated(nonsending)` async method (swiftlang/swift#88789). `@concurrent` restores the
    // pre-SE-0461 isolation, which this method wants anyway: it only touches lock-guarded state,
    // so there is nothing to gain from inheriting the caller's executor. Revisit once fixed.
    @concurrent
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let url = request.url {
            urls.withLock { $0.append(url) }
        }
        return request
    }
}
