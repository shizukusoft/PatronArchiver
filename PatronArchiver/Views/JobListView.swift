import PatronArchiverKit
import SwiftUI

struct JobListView: View {
    var archiver: PatronArchiver

    var body: some View {
        List {
            // Newest first for display only: `jobs` stays in FIFO order because the queue
            // picks the next job from the front of the array.
            ForEach(archiver.jobs.reversed()) { job in
                JobRowView(job: job, archiver: archiver)
            }
        }
        .accessibilityIdentifier("jobList")
        .overlay {
            if archiver.jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs",
                    systemImage: "tray",
                    description: Text("Enter a URL to start archiving.")
                )
                .accessibilityIdentifier("emptyState")
            }
        }
    }
}
