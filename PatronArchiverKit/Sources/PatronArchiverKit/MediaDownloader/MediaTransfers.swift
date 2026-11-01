import Foundation
import Synchronization

/// What a transfer reports about its bytes: a `URLSessionTask`, or a stand-in for one in tests.
///
/// Not the task's `progress`: that is a composite of a hundred units weighted between sending
/// and receiving, so its counts say nothing about bytes.
protocol ByteCounting: Sendable {
    /// Bytes received so far.
    var countOfBytesReceived: Int64 { get }
    /// The length the server declared, or zero or `NSURLSessionTransferSizeUnknown` while it has
    /// yet to answer or never declares one.
    var countOfBytesExpectedToReceive: Int64 { get }
}

extension URLSessionTask: ByteCounting {}

/// The transfers a media download has started, held so their bytes can be totalled.
///
/// Reads like one transfer, with the counts summed across all of them.
final class MediaTransfers: Sendable {
    /// How many transfers there will be, so the total counts as known only once every one of them
    /// has a length.
    private let count: Int
    private let transfers = Mutex<[any ByteCounting]>([])

    /// - Parameter count: How many transfers will be added in all.
    init(count: Int) {
        self.count = count
    }

    /// Registers a transfer that has started.
    func add(_ transfer: any ByteCounting) {
        transfers.withLock { $0.append(transfer) }
    }

    /// Bytes received across every transfer. Reads every transfer, so O(n) in their number.
    var countOfBytesReceived: Int64 {
        transfers.withLock { transfers in
            transfers.reduce(0) { $0 + max($1.countOfBytesReceived, 0) }
        }
    }

    /// Bytes expected across every transfer, only once each of them has declared a length. Reads
    /// every transfer, so O(n) in their number.
    var countOfBytesExpectedToReceive: Int64? {
        transfers.withLock { transfers in
            guard transfers.count == count else { return nil }
            var expected: Int64 = 0
            for transfer in transfers {
                let declared = transfer.countOfBytesExpectedToReceive
                guard declared > 0 else { return nil }
                expected += declared
            }
            return expected
        }
    }
}
