import Foundation
import Synchronization

/// The progress of one run of a job, weighted across its stages and mirrored onto the job.
///
/// `Progress` rolls each media transfer's bytes up through its tree, but SwiftUI never sees it:
/// changing a `Progress` does not touch the `@Observable` job that would hold it. This owns the
/// tree for a single run and republishes it onto the job, coarsely enough that a transfer's
/// per-chunk updates do not each redraw the row.
///
/// Only the job's ``ArchiveJob/currentProgress`` publishes. A run claims the job when it starts
/// and gives it up at ``stop()``, and a cancel takes it away at once: a cancelled run can take a
/// while to unwind, and a retry may already be reporting on the same job by then, so nothing the
/// old run observes after that point is allowed to land. Checking at publish time, rather than
/// only stopping the observers, also turns away updates that were already on their way to the main
/// actor.
@MainActor
final class JobProgress {
    /// The stages after preparation, sized once the run knows how much of each there is.
    struct Stages {
        /// One unit per page format written.
        let pageFormats: Progress
        /// One unit per media file, each advancing with its transfer's bytes.
        let media: Progress
        /// One unit for attributing the staged files and resolving where they go.
        let saving: Progress
    }

    private enum Weight {
        /// Loading the page and its lazy content through to extracting what it links, before
        /// there is anything to count.
        static let preparation: Int64 = 20
        /// Everything after preparation, divided among the stages below by ``pendingUnits``.
        static let remainder: Int64 = 80
        static let pageFormat: Int64 = 10
        static let mediaFile: Int64 = 5
        /// The most media may claim, however many files a post has, so a post with a great many
        /// of them does not squeeze loading and the page formats into a sliver at the start. Past
        /// this, the file count in the row is what shows the downloads moving.
        static let mediaLimit: Int64 = 60
        static let saving: Int64 = 5
    }

    /// One unit per preparation step.
    let preparation = Progress.discreteProgress(totalUnitCount: 5)

    private let job: ArchiveJob
    private let root = Progress.discreteProgress(totalUnitCount: Weight.preparation + Weight.remainder)
    private let gate = PublishingGate()
    private var media: Progress?
    private var observations: [NSKeyValueObservation] = []

    init(for job: ArchiveJob) {
        self.job = job
        job.currentProgress = self
        root.addChild(preparation, withPendingUnitCount: Weight.preparation)
        // Explicitly `@Sendable`, so the handler is not inferred as main-actor-isolated: KVO calls
        // it on whichever thread changed the value, which for a transfer is URLSession's.
        observations.append(root.observe(\.fractionCompleted) { @Sendable [weak self, gate] root, _ in
            guard gate.admits(root.fractionCompleted), let self else { return }
            Task { @MainActor in self.publishFraction() }
        })
    }

    /// Divides what is left after preparation among the later stages, in proportion to how much
    /// of each there is.
    nonisolated static func pendingUnits(
        pageFormatCount: Int,
        mediaCount: Int
    ) -> (pageFormats: Int64, media: Int64, saving: Int64) {
        let pageFormats = Int64(pageFormatCount) * Weight.pageFormat
        let media = min(Int64(mediaCount) * Weight.mediaFile, Weight.mediaLimit)
        let total = pageFormats + media + Weight.saving
        let pageFormatUnits = Weight.remainder * pageFormats / total
        let mediaUnits = Weight.remainder * media / total
        return (pageFormatUnits, mediaUnits, Weight.remainder - pageFormatUnits - mediaUnits)
    }

    /// Ends preparation and sizes the stages that follow it.
    func allocate(pageFormatCount: Int, mediaCount: Int) -> Stages {
        // Preparation is over by the time anything can be counted, whichever of its steps got as
        // far as reporting.
        preparation.completedUnitCount = preparation.totalUnitCount

        let units = Self.pendingUnits(pageFormatCount: pageFormatCount, mediaCount: mediaCount)
        let stages = Stages(
            pageFormats: .discreteProgress(totalUnitCount: Int64(pageFormatCount)),
            media: .discreteProgress(totalUnitCount: Int64(mediaCount)),
            saving: .discreteProgress(totalUnitCount: 1)
        )
        // A stage with nothing in it is left out rather than attached with no units: an empty
        // `Progress` is indeterminate, never finished, and has no share of the total to give.
        for (stage, pendingUnits) in [
            (stages.pageFormats, units.pageFormats),
            (stages.media, units.media),
            (stages.saving, units.saving),
        ] where pendingUnits > 0 {
            root.addChild(stage, withPendingUnitCount: pendingUnits)
        }

        if mediaCount > 0 {
            media = stages.media
            // A parent's completed count moves only when a child finishes, so this fires once per
            // file rather than once per chunk, and needs no gate.
            observations.append(stages.media.observe(\.completedUnitCount) { @Sendable [weak self] _, _ in
                guard let self else { return }
                Task { @MainActor in self.publishMediaCount() }
            })
        }
        return stages
    }

    /// Stops publishing onto the job.
    func stop() {
        for observation in observations {
            observation.invalidate()
        }
        observations.removeAll()
        if job.currentProgress === self {
            job.currentProgress = nil
        }
    }

    // Both read the tree afresh rather than taking the value that triggered them, so hops that
    // land out of order still leave the job showing the latest state.

    private func publishFraction() {
        guard job.currentProgress === self else { return }
        job.fractionCompleted = root.fractionCompleted
    }

    private func publishMediaCount() {
        guard job.currentProgress === self, let media else { return }
        job.downloadedMediaCount = Int(media.completedUnitCount)
    }
}

/// Lets a fraction through only once it has moved far enough to be worth redrawing for, or the
/// work is done.
private final class PublishingGate: Sendable {
    /// Half a percent: finer than a row's progress bar can show.
    private static let threshold = 0.005

    private let lastAdmitted = Mutex(0.0)

    func admits(_ fraction: Double) -> Bool {
        lastAdmitted.withLock { last in
            guard fraction >= 1 || abs(fraction - last) >= Self.threshold else { return false }
            last = fraction
            return true
        }
    }
}
