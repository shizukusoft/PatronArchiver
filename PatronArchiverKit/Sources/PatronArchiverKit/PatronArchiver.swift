import Foundation
import OSLog
import Synchronization
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

    /// The job currently driving the web view, if any. Its single slot is what keeps two jobs from
    /// rendering into the same view at once.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Overwrite commits still running.
    ///
    /// Kept apart from ``activeTasks`` because a commit only moves files — it never touches the web
    /// view — so it has no business holding the queue's one slot and making unrelated jobs wait.
    /// It is tracked at all so that Cancel can still reach it.
    private var commitTasks: [UUID: Task<Void, Never>] = [:]

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
        // A starting size only: the SwiftUI representable sizes the view once it lays out, which is
        // also how a Render Width change reaches a web view that already exists.
        let renderSize = AppSettings.renderSize(forWidth: AppSettings.renderWidth.wrappedValue)
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: renderSize),
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
        commitTasks[job.id]?.cancel()
        commitTasks[job.id] = nil
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
        for task in commitTasks.values {
            task.cancel()
        }
        commitTasks.removeAll()
        for job in jobs {
            discardPendingSaveIfNeeded(job)
            if !job.status.isTerminal {
                job.status = .failed(CancellationError())
            }
        }
    }

    /// Throws away a job's staged files, if it has any.
    ///
    /// The removal is left to finish on its own. Every caller is a synchronous UI action, and the
    /// staging directory is uniquely named, so nothing that follows waits on it being gone — only
    /// the bookkeeping that stops anyone else from reaching it has to happen here and now.
    private func discardPendingSaveIfNeeded(_ job: ArchiveJob) {
        guard let preparedSave = job.pendingSave else { return }
        job.pendingSave = nil
        Task { await StorageManager.discardPreparedSave(preparedSave) }
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
        //
        // The base directory rides along because staging sits on its volume, so removing it needs
        // the access it was created under — and the `catch` below is outside that access.
        var staging: (directory: URL, baseDirectory: URL)?

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
            let extracted = try await provider.extractMetadata(in: webView, timeZone: timeZone)
            // Rebuilt with the redirect chain the tracker collected, which the provider has no way
            // of knowing about.
            let metadata = PostMetadata(
                siteIdentifier: extracted.siteIdentifier,
                postID: extracted.postID,
                title: extracted.title,
                authorName: extracted.authorName,
                createdAt: extracted.createdAt,
                modifiedAt: extracted.modifiedAt,
                tags: extracted.tags,
                originalURL: extracted.originalURL,
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

            // Everything from here writes to the destination's volume — the staging directory is
            // put there so the commit can be a rename rather than a second copy of every file
            // downloaded below — so the access is held open across the whole stretch. Opening it
            // only long enough to create the directory would leave the writes that follow, on a
            // volume the app has no standing permission for, to fail.
            let baseDir = AppSettings.resolveBaseDirectory()
            try await baseDir.withSecurityScopedAccess {
                let tempDir = try await StorageManager.stagingDirectory(for: baseDir)
                staging = (tempDir, baseDir)
                let fileStem = try StorageManager.pageFileStem(for: pageTitle)

                // Start media download in background (no WebView dependency)
                Self.logger.debug("Starting media download concurrently...")
                let totalMedia = mediaItems.count
                let completedMediaCount = Atomic(0)
                async let mediaResult = MediaDownloader.download(
                    items: mediaItems,
                    to: tempDir,
                    websiteDataStore: Self.websiteDataStore,
                    urlSession: Self.urlSession,
                    onFileDownloaded: { @Sendable in
                        let count = completedMediaCount.add(1, ordering: .relaxed).newValue
                        Task { @MainActor in
                            guard job.progress.completedUnitCount >= 60 else { return }
                            job.progress.completedUnitCount = 60 + Int64(count * 20 / max(totalMedia, 1))
                        }
                    }
                )

                // MHTML + PDF on WebView (sequential, needs WebView). Both are written straight
                // into staging as they are produced rather than carried around as `Data`: an
                // archive of an image-heavy post is the largest thing this job would otherwise hold.
                let mhtmlURL = tempDir.appending(component: "\(fileStem).mhtml")
                let pdfURL = tempDir.appending(component: "\(fileStem).pdf")

                Self.logger.debug("Generating MHTML...")
                try await MHTMLArchiver(webView, urlSession: Self.urlSession).write(to: mhtmlURL)
                Self.logger.debug("MHTML written")
                job.progress.completedUnitCount = 50

                Self.logger.debug("Generating PDF...")
                try await webView.writeFullPagePDF(to: pdfURL)
                Self.logger.debug("PDF written")
                let alreadyCompleted = completedMediaCount.load(ordering: .relaxed)
                job.progress.completedUnitCount = 60 + Int64(alreadyCompleted * 20 / max(totalMedia, 1))

                // Await media download completion
                let downloadedMedia = try await mediaResult
                Self.logger.info("Downloaded \(downloadedMedia.count) media files")
                job.progress.completedUnitCount = 80

                // 9. Attribute the staged files and resolve where they belong
                try Task.checkCancellation()
                job.status = .saving
                Self.logger.debug("Preparing save to: \(baseDir.path(), privacy: .private)")
                let preparedSave = try await StorageManager.prepareSave(
                    metadata: metadata,
                    pageFiles: [mhtmlURL, pdfURL],
                    downloadedMedia: downloadedMedia,
                    stagingDirectory: tempDir,
                    baseDirectory: baseDir,
                    includesWhereFroms: AppSettings.includesWhereFroms.wrappedValue,
                    includesFinderTags: AppSettings.includesFinderTags.wrappedValue,
                    includesContentDates: AppSettings.includesContentDates.wrappedValue
                )
                job.progress.completedUnitCount = 90

                // 10. Commit — the move is also the check for whether the destination is free
                try Task.checkCancellation()
                let result = try await StorageManager.commitSave(preparedSave, overwrite: false)

                switch result {
                case .destinationExists:
                    // `commitSave` cannot be interrupted partway, so a cancel that landed during it
                    // is only answerable here — and nothing was written, so answering it costs
                    // nothing. Skipping this check would revive a job the user called off as a
                    // prompt, and one nobody is left to answer if the window is what closed.
                    try Task.checkCancellation()

                    // Await user confirmation. This job is parked on the user rather than still
                    // working, so it falls through to release the queue slot below: everything it
                    // still needs is already staged on disk, and committing later touches no web
                    // view.
                    Self.logger.info("Post folder already exists, awaiting overwrite confirmation")
                    job.pendingSave = preparedSave
                    job.status = .awaitingOverwriteConfirmation
                case .committed:
                    // The files are in place whatever happened while the commit ran, but the job
                    // is not necessarily still this task's to describe: a cancel may have failed
                    // it and a retry may have queued it up again, and calling that `completed`
                    // would drop the retry on the floor.
                    guard !Task.isCancelled else {
                        Self.logger.info("Job committed after being cancelled; leaving its state alone")
                        return
                    }
                    job.progress.completedUnitCount = 100
                    job.status = .completed
                    Self.logger.info("Job completed successfully")
                }
            }
        } catch {
            Self.logger.error("Job failed: \(error.localizedDescription, privacy: .public)")
            if let staging {
                await staging.baseDirectory.withSecurityScopedAccess {
                    await StorageManager.discardStagingDirectory(staging.directory)
                }
            }
            // Staging is cleaned up either way, but the status is not this task's to set once it has
            // been cancelled: `cancelJob` already marked the job, and a retry may have restarted it
            // since — writing here would relabel work that is running again.
            if !Task.isCancelled {
                job.status = .failed(error)
            }
        }

        // Likewise for the bookkeeping. A cancelled task has already had its slot cleared and the
        // queue passed on by `cancelJob`, and the entry under this job's id may belong to a retry
        // by now, so it takes nothing back.
        if !Task.isCancelled {
            activeTasks[job.id] = nil
        }
        // The web view is only this job's to reset when nothing else has picked it up — blanking it
        // otherwise would abort the navigation the successor just started.
        if activeTasks.isEmpty {
            await loadBlankPage(in: webView)
        }
        if !Task.isCancelled {
            processNextQueuedJob()
        }
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
        // Taken before the commit starts, so a second tap arriving while it runs finds nothing left
        // to commit rather than replacing the destination twice.
        job.pendingSave = nil
        job.status = .saving

        // Tracked so Cancel can reach it, but outside the queue: this moves files and leaves the
        // web view alone, so making the next job wait on it would be a delay with nothing behind it.
        commitTasks[job.id] = Task {
            do {
                // The last point a cancel can stop the replacement. Past it the commit runs to
                // completion regardless — it is a synchronous, atomic file operation that does not
                // observe cancellation — though staging sits on the destination's volume, so that
                // window is a rename's worth of time.
                try Task.checkCancellation()
                let baseDir = AppSettings.resolveBaseDirectory()
                _ = try await baseDir.withSecurityScopedAccess {
                    try await StorageManager.commitSave(preparedSave, overwrite: true)
                }
                // The replacement did land, but a cancel that arrived during it has already failed
                // the job, and a retry may have queued it behind that. Reporting `completed` here
                // would bury a retry that is waiting its turn, so the state is left to whoever
                // holds it and the outcome only goes to the log.
                guard !Task.isCancelled else {
                    Self.logger.info("Overwrite committed after being cancelled; leaving its state alone")
                    return
                }
                job.progress.completedUnitCount = 100
                job.status = .completed
                Self.logger.info("Overwrite confirmed and save committed")
            } catch {
                // Nothing else knows about this staging directory any more — `pendingSave` was
                // cleared above — so failing without removing it would strand the files.
                await StorageManager.discardPreparedSave(preparedSave)
                Self.logger.error("Overwrite commit failed: \(error.localizedDescription, privacy: .public)")
                if !Task.isCancelled {
                    job.status = .failed(error)
                }
            }
            // Same as `processJob`: a cancelled task leaves the entry to whoever holds it now.
            // Nothing is handed on to the queue — this never took a slot from it.
            if !Task.isCancelled {
                commitTasks[job.id] = nil
            }
        }
    }

    public func skipOverwrite(_ job: ArchiveJob) {
        discardPendingSaveIfNeeded(job)
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
