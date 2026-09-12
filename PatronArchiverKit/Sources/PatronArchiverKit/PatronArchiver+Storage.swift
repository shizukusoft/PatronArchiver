import Foundation
import OSLog

// MARK: - Storage

private let logger = Logger(subsystem: Logger.moduleSubsystem, category: "PatronArchiver")

extension PatronArchiver {
    /// A save whose files are staged and attributed, waiting to be moved into place.
    struct PreparedSave: Sendable {
        let stagingDirectory: URL
        let finalDirectory: URL
        /// The security-scoped directory the other two sit under.
        ///
        /// Carried along because staging lives on the destination's volume, so discarding it needs
        /// the same access the save was made under, and this is the only URL that can be asked for
        /// it — `finalDirectory` is a path beneath the bookmark, not the bookmark.
        let baseDirectory: URL

        /// What committing a staged save turned out to do.
        enum CommitResult {
            case committed
            /// Something was already at the destination. The staged files are untouched, and
            /// committing again with `overwrite: true` is what replaces it.
            case destinationExists
        }

        // MARK: Phase 2: Move staging to final location

        /// Moves the staged save into place.
        ///
        /// Nothing is asked about the destination beforehand. `moveItem` already refuses to
        /// overwrite, so the move *is* the check — and one that cannot be raced, unlike looking
        /// first and moving after. Replacement is reached only when that move reports a collision,
        /// which also means a destination that disappeared while the user was deciding is simply
        /// moved into, rather than failing an overwrite that no longer has anything to overwrite.
        @concurrent
        func commit(overwrite: Bool) async throws -> CommitResult {
            let fileManager = FileManager.default

            logger.info(
                "Committing save to: \(finalDirectory.path(), privacy: .private), overwrite: \(overwrite)"
            )

            // Ensure parent (author) directory exists
            try fileManager.createDirectory(
                at: finalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            do {
                try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                guard overwrite else {
                    logger.info("Destination is taken, leaving staging for the user to decide on")
                    return .destinationExists
                }
                // `usingNewMetadataOnly` because the staging directory carries the tags and content
                // dates this save just set; the default would restore the replaced folder's
                // instead. The replacement is atomic, so a failure here leaves the existing folder
                // standing.
                _ = try fileManager.replaceItemAt(
                    finalDirectory,
                    withItemAt: stagingDirectory,
                    options: .usingNewMetadataOnly
                )
                logger.info("Save committed over what was already there")
                return .committed
            }
            logger.info("Save committed successfully")
            return .committed
        }

        // MARK: Discard staging on cancel

        /// Throws the staged files away, reopening the access they were written under.
        ///
        /// Callers reach this from UI actions that are nowhere near the save's security scope, so
        /// the scope is taken here rather than expected of them.
        func discard() async {
            await baseDirectory.withSecurityScopedAccess {
                await PatronArchiver.discardStagingDirectory(stagingDirectory)
            }
        }
    }

    private nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: Phase 0: The directory a job assembles itself in

    /// Makes the directory a job writes its files into before they are committed.
    ///
    /// Placed on the destination's own volume rather than in the app's temporary directory, so the
    /// commit at the end is a rename within one volume: atomic, immediate, and without copying the
    /// downloaded media a second time. `.itemReplacementDirectory` hands back a fresh directory per
    /// call — which is why no UUID is appended — in the same temporary area the system already
    /// prunes, so a staging directory orphaned by a crash is not ours alone to worry about.
    ///
    /// - Parameter baseDirectory: Where the save is ultimately headed. Only its volume is used, but
    ///   it has to exist and be security-scoped for the duration of this call.
    @concurrent
    static func makeStagingDirectory(for baseDirectory: URL) async throws -> URL {
        // The volume can only be resolved from a directory that is actually there, and this is
        // where the save is going regardless.
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: baseDirectory,
            create: true
        )
    }

    /// The name every page-level file in a save shares, minus the extension.
    nonisolated static func pageFileStem(for pageTitle: String) throws -> String {
        guard let stem = pageTitle.sanitizedFileName() else {
            throw FileNameError.empty
        }
        return stem
    }

    // MARK: Phase 1: Attribute the staged files and work out where they belong

    /// Marks up a staging directory whose contents are already written, and resolves its
    /// destination.
    ///
    /// The files arrive here already on disk — each one was written as it was produced — so this
    /// only attaches the metadata that has to survive the move.
    @concurrent
    static func prepareSave(
        of metadata: PostMetadata,
        pageFiles: [URL],
        downloadedMedia: [MediaDownloader.DownloadedMedia],
        in stagingDirectory: URL,
        to baseDirectory: URL,
        includesWhereFroms: Bool = true,
        includesFinderTags: Bool = true,
        includesContentDates: Bool = true
    ) async throws -> PreparedSave {
        let finalDirectory = try postFolderURL(for: metadata, in: baseDirectory)
        let whereFroms = metadata.redirectChain.isEmpty ? [metadata.originalURL] : metadata.redirectChain

        logger.info("Preparing save in staging: \(stagingDirectory.path(), privacy: .private)")
        logger.info("Final directory: \(finalDirectory.path(), privacy: .private)")

        if includesWhereFroms {
            for fileURL in pageFiles {
                try? fileURL.setWhereFroms(whereFroms)
            }

            let landingURL = metadata.redirectChain.last ?? metadata.originalURL
            for media in downloadedMedia {
                var mediaWhereFroms = [landingURL, media.item.url]
                mediaWhereFroms.append(contentsOf: media.downloadRedirects)
                try? media.localURL.setWhereFroms(mediaWhereFroms)
            }

            try? stagingDirectory.setWhereFroms(whereFroms)
        }
        if includesFinderTags, !metadata.tags.isEmpty {
            try? stagingDirectory.setUserTags(metadata.tags)
        }
        if includesContentDates {
            try? stagingDirectory.setContentDates(
                createdAt: metadata.createdAt,
                modifiedAt: metadata.modifiedAt
            )
        }

        return PreparedSave(
            stagingDirectory: stagingDirectory,
            finalDirectory: finalDirectory,
            baseDirectory: baseDirectory
        )
    }

    /// Removes a staging directory that no longer has anywhere to go.
    ///
    /// Takes the URL rather than a ``PreparedSave`` so a job that failed before preparing one — a
    /// download error, say — can still clean up what it had already written.
    ///
    /// `@concurrent` because the tree being removed holds every media file the job downloaded, so
    /// the cost scales with the post rather than being the constant one directory it looks like.
    @concurrent
    static func discardStagingDirectory(_ stagingDirectory: URL) async {
        do {
            try FileManager.default.removeItem(at: stagingDirectory)
            logger.debug("Discarded staging: \(stagingDirectory.path(), privacy: .private)")
        } catch {
            logger.warning("Failed to discard staging directory: \(error.localizedDescription)")
        }
    }

    /// Where a post's save belongs under `baseDirectory`: site, then author, then the post itself.
    nonisolated static func postFolderURL(for metadata: PostMetadata, in baseDirectory: URL) throws -> URL {
        guard let authorFolder = metadata.authorName.sanitizedFileName() else {
            throw FileNameError.empty
        }
        let dateString = dateFormatter.string(from: metadata.modifiedAt ?? metadata.createdAt)
        guard let postFolder = "\(metadata.postID) - \(metadata.title) (\(dateString))".sanitizedFileName() else {
            throw FileNameError.empty
        }
        return baseDirectory
            .appendingPathComponent(metadata.siteIdentifier)
            .appendingPathComponent(authorFolder)
            .appendingPathComponent(postFolder)
    }
}
