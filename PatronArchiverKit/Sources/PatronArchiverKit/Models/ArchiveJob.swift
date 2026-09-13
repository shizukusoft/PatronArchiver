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
    public internal(set) var progress: Progress
    var pendingSave: PatronArchiver.PreparedSave?

    init(id: UUID = UUID(), inputURL: URL, provider: (any PatronServiceProviding)? = nil) {
        self.id = id
        self.inputURL = inputURL
        self.provider = provider
        self.status = .queued
        self.metadata = nil
        self.mediaItems = []
        self.progress = Progress(totalUnitCount: 100)
        self.pendingSave = nil
    }
}
