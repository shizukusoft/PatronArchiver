import Foundation

// MARK: - Demo Mode

#if DEBUG
extension PatronArchiver {
    public func loadDemoJobs() {
        isDemoMode = true
        jobs = Self.makeDemoJobs()
    }

    private static func makeDemoJobs() -> [ArchiveJob] {
        let demoEntries: [(url: String, title: String, author: String, siteIdentifier: String, status: JobStatus, completedUnits: Int64)] = [
            // Oldest first, matching enqueue order. The job list displays these newest first, and the
            // statuses follow the FIFO queue: finished jobs, then the one running, then queued ones.
            (
                "https://www.patreon.com/posts/monthly-pack-dec-12345",
                "Monthly Illustration Pack - December",
                "ArtStudio",
                "Patreon",
                .completed,
                100
            ),
            (
                "https://artstudio.fanbox.cc/posts/67890",
                "Character Design Tutorial Part 3",
                "DrawingMaster",
                "pixivFANBOX",
                .completed,
                100
            ),
            (
                "https://soundworks.fanbox.cc/posts/33333",
                "Voice Acting Session Recording",
                "SoundWorks",
                "pixivFANBOX",
                .failed(DemoError.networkTimeout),
                40
            ),
            (
                "https://www.subscribestar.com/posts/animation-process-11111",
                "Behind the Scenes - Animation Process",
                "MotionLab",
                "SubscribeStar",
                .downloading,
                65
            ),
            (
                "https://www.patreon.com/posts/wallpaper-vol12-22222",
                "Exclusive Wallpaper Set Vol.12",
                "PixelCraft",
                "Patreon",
                .queued,
                0
            ),
        ]

        return demoEntries.map { entry in
            let url = URL(string: entry.url)!
            let provider = PatronServiceProviders.provider(for: url)
            let job = ArchiveJob(inputURL: url, provider: provider)
            job.status = entry.status
            job.progress.completedUnitCount = entry.completedUnits
            job.metadata = PostMetadata(
                siteIdentifier: entry.siteIdentifier,
                postID: url.lastPathComponent,
                title: entry.title,
                authorName: entry.author,
                createdAt: Date(timeIntervalSinceNow: -86400 * 3),
                modifiedAt: nil,
                tags: [],
                originalURL: url,
                redirectChain: [url]
            )
            return job
        }
    }

    private enum DemoError: LocalizedError {
        case networkTimeout

        var errorDescription: String? {
            switch self {
            case .networkTimeout:
                "The request timed out."
            }
        }
    }
}
#endif
