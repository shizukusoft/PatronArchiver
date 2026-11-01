import Foundation

/// How far a job's media has transferred, in bytes, across every file it downloads.
public struct MediaTransferProgress: Equatable, Sendable {
    /// Bytes received so far, across every transfer.
    public let countOfBytesReceived: Int64
    /// Bytes expected in all, once every transfer has declared its length. Until then — and for
    /// good if any server declares none — there is no total to show.
    public let countOfBytesExpectedToReceive: Int64?
    /// Bytes received per second, averaged over the last few seconds. Absent until two samples
    /// have been taken, and once the transfers are done.
    public let throughput: Int?

    /// How long the rest should take at the current rate, while both the total and the rate are
    /// known.
    public var estimatedTimeRemaining: Duration? {
        guard let countOfBytesExpectedToReceive, let throughput, throughput > 0 else { return nil }
        let remainingBytes = max(countOfBytesExpectedToReceive - countOfBytesReceived, 0)
        return .seconds(Double(remainingBytes) / Double(throughput))
    }

    /// The bytes, rate, and time left worded by the system, as under a download in Safari:
    /// "285.9 MB of 8.74 GB (51.4 MB/s) — About 2 minutes remaining", in the user's language.
    ///
    /// Each part appears as it becomes known. Without a total the system words only the rate,
    /// so the received bytes are put in front of it here: "285.9 MB (51.4 MB/s)".
    public var localizedDescription: String {
        let progress = Progress()
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.completedUnitCount = countOfBytesReceived
        progress.throughput = throughput
        progress.estimatedTimeRemaining = estimatedTimeRemaining.map { $0 / .seconds(1) }
        if let countOfBytesExpectedToReceive {
            progress.totalUnitCount = countOfBytesExpectedToReceive
            return progress.localizedAdditionalDescription ?? ""
        }
        progress.totalUnitCount = NSURLSessionTransferSizeUnknown
        let received = countOfBytesReceived.formatted(.byteCount(style: .file))
        let rate = progress.localizedAdditionalDescription ?? ""
        return rate.isEmpty ? received : "\(received) (\(rate))"
    }
}
