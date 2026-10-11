import Foundation

@MainActor
@Observable
public final class ArchiveJob: Identifiable {
    public let id: UUID
    public let inputURL: URL
    public let provider: (any PatronServiceProviding)?
    public internal(set) var status: JobStatus
    public internal(set) var metadata: PostMetadata?
    var mediaItems: [MediaItem]
    /// How far the current run has got, from 0 to 1.
    public internal(set) var fractionCompleted: Double
    /// How many of ``mediaCount`` files have finished downloading.
    public internal(set) var downloadedMediaCount: Int
    /// The run whose progress the job shows. Anything else still reporting onto it — a cancelled run
    /// that has not finished unwinding — is ignored.
    @ObservationIgnored weak var currentProgress: JobProgress?
    var pendingSave: PatronArchiver.PreparedSave?

    init(id: UUID = UUID(), inputURL: URL, provider: (any PatronServiceProviding)? = nil) {
        self.id = id
        self.inputURL = inputURL
        self.provider = provider
        self.status = .queued
        self.metadata = nil
        self.mediaItems = []
        self.fractionCompleted = 0
        self.downloadedMediaCount = 0
        self.pendingSave = nil
    }

    /// How many media files the post links.
    public var mediaCount: Int {
        mediaItems.count
    }
}
