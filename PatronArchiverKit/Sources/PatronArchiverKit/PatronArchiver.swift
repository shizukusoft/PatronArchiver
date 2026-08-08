import Foundation
import OSLog
import WebKit

@MainActor
@Observable
public final class PatronArchiver {
    private static let logger = Logger(subsystem: Logger.moduleSubsystem, category: "PatronArchiver")

    /// The shared cookie/storage domain, shared across every window so a login made in one is
    /// visible to all. `.default()` is already a process-wide singleton.
    public static let websiteDataStore = WKWebsiteDataStore.default()

    /// A session that fetches media and MHTML sub-resources with the same User-Agent as the web
    /// view. The User-Agent is read from a throwaway `WKWebView` once, on first access.
    public static let urlSession: URLSession = {
        let userAgent = WKWebView().value(forKey: "userAgent") as? String
        let configuration = URLSessionConfiguration.default
        if let userAgent {
            configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        }
        return URLSession(configuration: configuration)
    }()

    public internal(set) var jobs: [ArchiveJob] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Set once the owning window has closed. Enqueues after that point are dropped: the web view
    /// is detached, so the job could neither render nor be seen or cancelled by anyone.
    private var isClosed = false

    /// The web view this archiver drives, created lazily and owned for the archiver's lifetime.
    ///
    /// Owned here — rather than injected by a view — so that a window-scoped archiver has a
    /// window-scoped web view. It is excluded from observation: the instance never changes, and
    /// views read it to display, not to react to.
    @ObservationIgnored
    private var _webView: WKWebView?

    public var webView: WKWebView {
        if let _webView {
            return _webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.websiteDataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: AppSettings.renderSize),
            configuration: configuration
        )
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        _webView = webView
        return webView
    }

    #if DEBUG
    var isDemoMode = false
    #endif

    public init() {}
}

// MARK: - Login Check

extension PatronArchiver {
    /// Checks login status by examining cookies only — fast, no network request.
    public static func isLoggedIn(for providerType: any PatronServiceProviding.Type) async -> Bool {
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        return providerType.isLoggedIn(cookies: cookies)
    }

    /// Fetches account info by loading the provider's accountCheckURL in the given webView
    /// and delegating extraction to the provider.
    ///
    /// - Returns: The account info if successfully fetched, nil otherwise.
    public static func fetchAccountInfo(
        for providerType: any PatronServiceProviding.Type,
        in webView: WKWebView
    ) async -> AccountInfo? {
        let identifier = providerType.siteIdentifier
        do {
            let info = try await providerType.extractAccountInfo(in: webView)
            logger.info(
                "fetchAccountInfo \(identifier, privacy: .public) parsed=\(info != nil, privacy: .public)"
            )
            return info
        } catch is CancellationError {
            return nil
        } catch {
            logger.error(
                "fetchAccountInfo error for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Job Queue

extension PatronArchiver {
    public func enqueue(url: URL) {
        guard !isClosed else {
            Self.logger.info("Ignoring enqueue after the owning window closed")
            return
        }
        let provider = PatronServiceManager.shared.provider(for: url)
        let job = ArchiveJob(inputURL: url, provider: provider)
        jobs.append(job)
        startJobIfPossible(job)
    }

    public func cancelJob(_ job: ArchiveJob) {
        activeTasks[job.id]?.cancel()
        activeTasks[job.id] = nil
        discardPendingSaveIfNeeded(job)
        if !job.status.isTerminal {
            job.status = .failed(CancellationError())
        }
        processNextQueuedJob()
    }

    public func removeJob(_ job: ArchiveJob) {
        cancelJob(job)
        jobs.removeAll { $0.id == job.id }
    }

    public func retryJob(_ job: ArchiveJob) {
        discardPendingSaveIfNeeded(job)
        job.status = .queued
        job.progress = Progress(totalUnitCount: 100)
        job.metadata = nil
        job.mediaItems = []
        startJobIfPossible(job)
    }

    /// Cancels every job and its in-flight work. Call when the owning window is closing so the
    /// tasks release their strong reference to the archiver and it can deinitialize.
    ///
    /// Also closes the archiver to further work: a URL the user submitted before the window closed
    /// may still be resolving, and enqueuing its job here would start work nobody can see or cancel.
    public func cancelAllJobs() {
        isClosed = true
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        for job in jobs {
            discardPendingSaveIfNeeded(job)
            if !job.status.isTerminal {
                job.status = .failed(CancellationError())
            }
        }
    }

    private func discardPendingSaveIfNeeded(_ job: ArchiveJob) {
        if let preparedSave = job.pendingSave {
            StorageManager.discardPreparedSave(preparedSave)
            job.pendingSave = nil
        }
    }

    private func startJobIfPossible(_ job: ArchiveJob) {
        #if DEBUG
        guard !isDemoMode else { return }
        #endif
        guard activeTasks.isEmpty else { return }

        let task = Task {
            await processJob(job)
        }
        activeTasks[job.id] = task
    }

    private func processJob(_ job: ArchiveJob) async {
        let webView = self.webView

        // Tracked outside `do` so a failure can remove it. On the paths that succeed it is no
        // longer this job's to delete: `commitSave` moves it to its final home, and an overwrite
        // prompt hands it to `job.pendingSave` until the user answers.
        var stagingDirectory: URL?

        do {
            // WKWebView only renders while attached to a window; wait for the SwiftUI representable
            // to attach it before any rendering-dependent step. If it never attaches — the window
            // closed, or layout took too long — every step below would capture a blank page.
            guard await webView.waitUntilAttached() else {
                throw JobError.webViewNotAttached
            }

            // 1. Identify service provider
            Self.logger.info("Starting job for URL: \(job.inputURL, privacy: .private)")
            guard let provider = job.provider else {
                throw JobError.unsupportedSite
            }
            Self.logger.info("Matched provider: \(type(of: provider).siteIdentifier, privacy: .public)")

            // 2. Load page
            job.status = .loading
            job.progress.completedUnitCount = 10
            try Task.checkCancellation()
            let tracker = RedirectTracker()
            Self.logger.debug("Loading page...")
            let redirectChain = try await tracker.load(job.inputURL, in: webView)
            let chain = redirectChain.map(\.absoluteString)
            Self.logger.debug("Page loaded, redirect chain: \(chain, privacy: .private)")

            // 3. Check login
            let isLoggedIn = await Self.isLoggedIn(for: type(of: provider))
            Self.logger.info("Login status for \(type(of: provider).siteIdentifier, privacy: .public): \(isLoggedIn)")

            // 4. Load lazy content
            try Task.checkCancellation()
            job.progress.completedUnitCount = 15
            Self.logger.debug("Loading lazy content...")
            try await webView.loadLazyContent(scrollDelay: AppSettings.scrollDelay.wrappedValue)
            job.progress.completedUnitCount = 20
            try await provider.preloadContent(in: webView)
            job.progress.completedUnitCount = 25
            try await webView.loadLazyContent(scrollDelay: AppSettings.scrollDelay.wrappedValue)
            Self.logger.debug("Lazy content loaded")
            job.progress.completedUnitCount = 30

            // 5. Extract metadata
            try Task.checkCancellation()
            Self.logger.debug("Resolving time zone...")
            let timeZone = try await provider.resolveTimeZone(in: webView)
            Self.logger.debug("Extracting metadata...")
            var metadata = try await provider.extractMetadata(in: webView, timeZone: timeZone)
            metadata = PostMetadata(
                siteIdentifier: metadata.siteIdentifier,
                postID: metadata.postID,
                title: metadata.title,
                authorName: metadata.authorName,
                createdAt: metadata.createdAt,
                modifiedAt: metadata.modifiedAt,
                tags: metadata.tags,
                originalURL: metadata.originalURL,
                redirectChain: redirectChain
            )
            job.metadata = metadata
            let pageTitle = webView.title ?? metadata.title
            Self.logger.info("Metadata extracted — \(metadata.title, privacy: .private)")
            Self.logger.info("  author: \(metadata.authorName, privacy: .private)")

            // 6. Extract media URLs
            let mediaItems = try await provider.extractMediaURLs(in: webView)
            job.mediaItems = mediaItems
            job.progress.completedUnitCount = 40
            Self.logger.info("Found \(mediaItems.count) media items")

            // 7. Page dump + media download (concurrent)
            try Task.checkCancellation()
            job.status = .dumping

            let tempDir = try StorageManager.temporaryDownloadDirectory()
            stagingDirectory = tempDir

            // Start media download in background (no WebView dependency)
            Self.logger.debug("Starting media download concurrently...")
            let totalMedia = mediaItems.count
            let completedMediaCount = OSAllocatedUnfairLock(initialState: 0)
            async let mediaResult = MediaDownloader.download(
                items: mediaItems,
                to: tempDir,
                websiteDataStore: Self.websiteDataStore,
                urlSession: Self.urlSession,
                onFileDownloaded: { @Sendable in
                    let count = completedMediaCount.withLock { value in
                        value += 1
                        return value
                    }
                    Task { @MainActor in
                        guard job.progress.completedUnitCount >= 60 else { return }
                        job.progress.completedUnitCount = 60 + Int64(count * 20 / max(totalMedia, 1))
                    }
                }
            )

            // MHTML + PDF on WebView (sequential, needs WebView)
            Self.logger.debug("Generating MHTML...")
            let mhtmlData = try await MHTMLArchiver(webView, urlSession: Self.urlSession).archive()
            let mhtmlSize = mhtmlData.count.formatted(
                .byteCount(style: .binary, spellsOutZero: false, includesActualByteCount: true)
            )
            Self.logger.debug("MHTML generated (\(mhtmlSize))")
            job.progress.completedUnitCount = 50

            Self.logger.debug("Generating PDF...")
            let pdfData = try await webView.fullPagePDF()
            let pdfSize = pdfData.count.formatted(
                .byteCount(style: .binary, spellsOutZero: false, includesActualByteCount: true)
            )
            Self.logger.debug("PDF generated (\(pdfSize))")
            let alreadyCompleted = completedMediaCount.withLock { $0 }
            job.progress.completedUnitCount = 60 + Int64(alreadyCompleted * 20 / max(totalMedia, 1))

            // Await media download completion
            let downloadedMedia = try await mediaResult
            Self.logger.info("Downloaded \(downloadedMedia.count) media files")
            job.progress.completedUnitCount = 80

            // 9. Prepare save (write PDF/MHTML to staging + xattr)
            try Task.checkCancellation()
            job.status = .saving
            let baseDir = AppSettings.resolveBaseDirectory()
            Self.logger.debug("Preparing save to: \(baseDir.path(), privacy: .private)")
            let preparedSave = try StorageManager.prepareSave(
                metadata: metadata,
                pageTitle: pageTitle,
                pdfData: pdfData,
                mhtmlData: mhtmlData,
                downloadedMedia: downloadedMedia,
                stagingDirectory: tempDir,
                baseDirectory: baseDir,
                includesWhereFroms: AppSettings.includesWhereFroms.wrappedValue,
                includesFinderTags: AppSettings.includesFinderTags.wrappedValue,
                includesContentDates: AppSettings.includesContentDates.wrappedValue
            )
            job.progress.completedUnitCount = 90

            // 10. Check if post folder already exists
            let folderExists = try baseDir.withSecurityScopedAccess {
                try StorageManager.postFolderExists(metadata: metadata, baseDirectory: baseDir)
            }

            if folderExists {
                // Await user confirmation. This job is parked on the user rather than still
                // working, so it falls through to release the queue slot below: everything it
                // still needs is already staged on disk, and committing later touches no web view.
                Self.logger.info("Post folder already exists, awaiting overwrite confirmation")
                job.pendingSave = preparedSave
                job.status = .awaitingOverwriteConfirmation
            } else {
                // 11. Commit save
                try baseDir.withSecurityScopedAccess {
                    try StorageManager.commitSave(preparedSave, overwrite: false)
                }
                job.progress.completedUnitCount = 100
                job.status = .completed
                Self.logger.info("Job completed successfully")
            }
        } catch {
            Self.logger.error("Job failed: \(error.localizedDescription, privacy: .public)")
            job.status = .failed(error)
            if let stagingDirectory {
                StorageManager.discardStagingDirectory(stagingDirectory)
            }
        }

        activeTasks[job.id] = nil
        // A cancelled job unwinds after `cancelJob` has already started the next one, so the web
        // view may no longer be this job's to reset — blanking it here would abort the navigation
        // the successor just started.
        if activeTasks.isEmpty {
            await loadBlankPage(in: webView)
        }
        processNextQueuedJob()
    }

    private func loadBlankPage(in webView: WKWebView) async {
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        guard webView.isLoading else { return }
        for await isLoading in webView.publisher(for: \.isLoading)
            .buffer(size: .max, prefetch: .byRequest, whenFull: .dropOldest)
            .values
        {
            if !isLoading {
                break
            }
        }
    }

    public func confirmOverwrite(_ job: ArchiveJob) {
        guard let preparedSave = job.pendingSave else { return }
        job.status = .saving

        do {
            let baseDir = AppSettings.resolveBaseDirectory()
            try baseDir.withSecurityScopedAccess {
                try StorageManager.commitSave(preparedSave, overwrite: true)
            }
            job.pendingSave = nil
            job.progress.completedUnitCount = 100
            job.status = .completed
            Self.logger.info("Overwrite confirmed and save committed")
        } catch {
            job.pendingSave = nil
            Self.logger.error("Overwrite commit failed: \(error.localizedDescription, privacy: .public)")
            job.status = .failed(error)
        }
    }

    public func skipOverwrite(_ job: ArchiveJob) {
        if let preparedSave = job.pendingSave {
            StorageManager.discardPreparedSave(preparedSave)
        }
        job.pendingSave = nil
        job.status = .failed(JobError.overwriteDeclined)
        Self.logger.info("Overwrite declined, staging discarded")
    }

    private func processNextQueuedJob() {
        guard let nextJob = jobs.first(where: {
            if case .queued = $0.status { return true }
            return false
        }) else { return }
        startJobIfPossible(nextJob)
    }
}
