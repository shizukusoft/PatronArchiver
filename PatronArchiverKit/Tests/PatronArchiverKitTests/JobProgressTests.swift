import Foundation
import Testing
@testable import PatronArchiverKit

struct JobProgressTests {
    @Test(arguments: [(0, 0), (0, 3), (1, 0), (3, 1), (2, 12), (3, 60), (3, 500)])
    func stagesShareTheWholeRemainder(pageFormatCount: Int, mediaCount: Int) {
        let units = JobProgress.pendingUnits(pageFormatCount: pageFormatCount, mediaCount: mediaCount)
        #expect(units.pageFormats + units.media + units.saving == 80)
    }

    @Test func stagesWithNothingInThemGetNoUnits() {
        let units = JobProgress.pendingUnits(pageFormatCount: 0, mediaCount: 0)
        #expect(units.pageFormats == 0)
        #expect(units.media == 0)
    }

    @Test func mediaShareStopsGrowingWithManyFiles() {
        let dozen = JobProgress.pendingUnits(pageFormatCount: 2, mediaCount: 12)
        let sixty = JobProgress.pendingUnits(pageFormatCount: 2, mediaCount: 60)
        let hundreds = JobProgress.pendingUnits(pageFormatCount: 2, mediaCount: 500)
        // So the page formats keep the share they had at a dozen, however many files follow.
        #expect(sixty == dozen)
        #expect(hundreds == dozen)
    }

    @Test func fewFilesTakeLessThanMany() {
        let few = JobProgress.pendingUnits(pageFormatCount: 2, mediaCount: 2)
        let many = JobProgress.pendingUnits(pageFormatCount: 2, mediaCount: 12)
        #expect(few.media < many.media)
    }

    // Publishing hops to the main actor, so these give it a chance to land before looking. Each
    // keeps its runs alive to the end: one released early would take its observers with it, and
    // pass for the wrong reason.

    @MainActor
    @Test func currentRunPublishes() async {
        let job = ArchiveJob(inputURL: URL(string: "https://example.com/post")!)
        let progress = JobProgress(for: job)
        let stages = progress.allocate(pageFormatCount: 1, mediaCount: 2)

        stages.media.completedUnitCount = 1

        #expect(await eventually { job.downloadedMediaCount == 1 })
        #expect(await eventually { job.fractionCompleted > 0 })
        withExtendedLifetime(progress) {}
    }

    @MainActor
    @Test func supersededRunNoLongerPublishes() async throws {
        let job = ArchiveJob(inputURL: URL(string: "https://example.com/post")!)
        let old = JobProgress(for: job)
        let oldStages = old.allocate(pageFormatCount: 1, mediaCount: 2)
        let current = JobProgress(for: job)
        current.preparation.completedUnitCount = 1
        #expect(await eventually { job.fractionCompleted > 0 })
        let currentFraction = job.fractionCompleted

        oldStages.pageFormats.completedUnitCount = 1
        oldStages.media.completedUnitCount = 1
        try await Task.sleep(for: .milliseconds(100))

        #expect(job.fractionCompleted == currentFraction)
        #expect(job.downloadedMediaCount == 0)
        withExtendedLifetime((old, current)) {}
    }

    @MainActor
    @Test func cancelledRunNoLongerPublishes() async throws {
        let job = ArchiveJob(inputURL: URL(string: "https://example.com/post")!)
        let progress = JobProgress(for: job)
        let stages = progress.allocate(pageFormatCount: 1, mediaCount: 2)
        // What `cancelJob` does to the run it cancels.
        job.currentProgress = nil

        stages.pageFormats.completedUnitCount = 1
        stages.media.completedUnitCount = 1
        try await Task.sleep(for: .milliseconds(100))

        #expect(job.fractionCompleted == 0)
        #expect(job.downloadedMediaCount == 0)
        withExtendedLifetime(progress) {}
    }
}

/// Polls `condition` on the main actor until it holds or about two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
