import Foundation
import OSLog

enum StorageManager {
    private static let logger = Logger(
        subsystem: Logger.moduleSubsystem,
        category: "StorageManager"
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    struct PreparedSave {
        let stagingDirectory: URL
        let finalDirectory: URL
    }

    // MARK: - Phase 1: Prepare all files in staging directory

    static func prepareSave(
        metadata: PostMetadata,
        pageTitle: String,
        pdfData: Data?,
        mhtmlData: Data?,
        downloadedMedia: [MediaDownloader.DownloadedMedia],
        stagingDirectory: URL,
        baseDirectory: URL,
        includesWhereFroms: Bool = true,
        includesFinderTags: Bool = true,
        includesContentDates: Bool = true
    ) throws -> PreparedSave {
        let finalDirectory = try makePostFolderURL(metadata: metadata, baseDirectory: baseDirectory)
        guard let sanitizedPageTitle = FileNameSanitizer.sanitize(pageTitle) else {
            throw FileNameSanitizer.FileNameSanitizerError.emptyFileName
        }
        let whereFroms = metadata.redirectChain.isEmpty ? [metadata.originalURL] : metadata.redirectChain

        logger.info("Preparing save in staging: \(stagingDirectory.path(), privacy: .private)")
        logger.info("Final directory: \(finalDirectory.path(), privacy: .private)")

        // Write PDF to staging
        if let pdfData {
            let pdfURL = stagingDirectory.appendingPathComponent("\(sanitizedPageTitle).pdf")
            try pdfData.write(to: pdfURL, options: .atomic)
            if includesWhereFroms {
                try? XattrHelper.setWhereFroms(whereFroms, on: pdfURL.path)
            }
        }

        // Write MHTML to staging
        if let mhtmlData {
            let mhtmlURL = stagingDirectory.appendingPathComponent("\(sanitizedPageTitle).mhtml")
            try mhtmlData.write(to: mhtmlURL, options: .atomic)
            if includesWhereFroms {
                try? XattrHelper.setWhereFroms(whereFroms, on: mhtmlURL.path)
            }
        }

        // Set xattr on media files (already in staging from MediaDownloader)
        if includesWhereFroms {
            let landingURL = metadata.redirectChain.last ?? metadata.originalURL
            for media in downloadedMedia {
                var mediaWhereFroms = [landingURL, media.item.url]
                mediaWhereFroms.append(contentsOf: media.downloadRedirects)
                try? XattrHelper.setWhereFroms(mediaWhereFroms, on: media.localURL.path)
            }
        }

        // Set xattr on staging folder
        if includesWhereFroms {
            try? XattrHelper.setWhereFroms(whereFroms, on: stagingDirectory.path)
        }
        if includesFinderTags, !metadata.tags.isEmpty {
            try? XattrHelper.setUserTags(metadata.tags, on: stagingDirectory.path)
        }
        if includesContentDates {
            try? XattrHelper.setContentDates(
                createdAt: metadata.createdAt,
                modifiedAt: metadata.modifiedAt,
                on: stagingDirectory.path
            )
        }

        return PreparedSave(stagingDirectory: stagingDirectory, finalDirectory: finalDirectory)
    }

    // MARK: - Phase 2: Move staging to final location

    static func commitSave(_ preparedSave: PreparedSave, overwrite: Bool) throws {
        let fm = FileManager.default
        let finalDirectory = preparedSave.finalDirectory

        logger.info(
            "Committing save to: \(finalDirectory.path(), privacy: .private), overwrite: \(overwrite)"
        )

        if overwrite, fm.fileExists(atPath: finalDirectory.path(percentEncoded: false)) {
            try fm.removeItem(at: finalDirectory)
            logger.debug("Removed existing folder")
        }

        // Ensure parent (author) directory exists
        let parentDirectory = finalDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        try fm.moveItem(at: preparedSave.stagingDirectory, to: finalDirectory)
        logger.info("Save committed successfully")
    }

    // MARK: - Check if post folder already exists

    static func postFolderExists(metadata: PostMetadata, baseDirectory: URL) throws -> Bool {
        let postFolder = try makePostFolderURL(metadata: metadata, baseDirectory: baseDirectory)
        return FileManager.default.fileExists(atPath: postFolder.path(percentEncoded: false))
    }

    // MARK: - Discard staging on cancel

    static func discardPreparedSave(_ preparedSave: PreparedSave) {
        discardStagingDirectory(preparedSave.stagingDirectory)
    }

    /// Removes a staging directory that no longer has anywhere to go.
    ///
    /// Takes the URL rather than a ``PreparedSave`` so a job that failed before preparing one — a
    /// download error, say — can still clean up what it had already written.
    static func discardStagingDirectory(_ stagingDirectory: URL) {
        do {
            try FileManager.default.removeItem(at: stagingDirectory)
            logger.debug("Discarded staging: \(stagingDirectory.path(), privacy: .private)")
        } catch {
            logger.warning("Failed to discard staging directory: \(error.localizedDescription)")
        }
    }

    static func makePostFolderURL(metadata: PostMetadata, baseDirectory: URL) throws -> URL {
        guard let authorFolder = FileNameSanitizer.sanitize(metadata.authorName) else {
            throw FileNameSanitizer.FileNameSanitizerError.emptyFileName
        }
        let dateString = dateFormatter.string(from: metadata.modifiedAt ?? metadata.createdAt)
        guard let postFolder = FileNameSanitizer.sanitize(
            "\(metadata.postID) - \(metadata.title) (\(dateString))"
        ) else {
            throw FileNameSanitizer.FileNameSanitizerError.emptyFileName
        }
        return baseDirectory
            .appendingPathComponent(metadata.siteIdentifier)
            .appendingPathComponent(authorFolder)
            .appendingPathComponent(postFolder)
    }

    static func temporaryDownloadDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatronArchiver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
}
