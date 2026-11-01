import Foundation
import Testing
@testable import PatronArchiverKit

/// Stands in for a `URLSessionTask`, reporting whatever bytes a test gives it.
private struct StubTransfer: ByteCounting {
    let countOfBytesReceived: Int64
    let countOfBytesExpectedToReceive: Int64
}

struct MediaTransfersTests {
    private func transfer(received: Int64, expected: Int64) -> StubTransfer {
        StubTransfer(countOfBytesReceived: received, countOfBytesExpectedToReceive: expected)
    }

    @Test func countsNothingBeforeAnyTransferStarts() {
        let transfers = MediaTransfers(count: 2)
        #expect(transfers.countOfBytesReceived == 0)
        #expect(transfers.countOfBytesExpectedToReceive == nil)
    }

    @Test func countsEveryTransfersBytes() {
        let transfers = MediaTransfers(count: 2)
        transfers.add(transfer(received: 10, expected: 100))
        transfers.add(transfer(received: 25, expected: 50))
        #expect(transfers.countOfBytesReceived == 35)
        #expect(transfers.countOfBytesExpectedToReceive == 150)
    }

    @Test func expectedWaitsForEveryTransferToStart() {
        let transfers = MediaTransfers(count: 2)
        transfers.add(transfer(received: 10, expected: 100))
        #expect(transfers.countOfBytesReceived == 10)
        #expect(transfers.countOfBytesExpectedToReceive == nil)
    }

    @Test(arguments: [Int64(0), NSURLSessionTransferSizeUnknown])
    func expectedWaitsForEveryTransferToDeclareALength(undeclared: Int64) {
        let transfers = MediaTransfers(count: 2)
        transfers.add(transfer(received: 10, expected: 100))
        transfers.add(transfer(received: 5, expected: undeclared))
        #expect(transfers.countOfBytesReceived == 15)
        #expect(transfers.countOfBytesExpectedToReceive == nil)
    }
}

struct MediaTransferProgressTests {
    private func progress(
        received: Int64,
        expected: Int64?,
        throughput: Int?
    ) -> MediaTransferProgress {
        MediaTransferProgress(
            countOfBytesReceived: received,
            countOfBytesExpectedToReceive: expected,
            throughput: throughput
        )
    }

    @Test func estimatesTimeRemainingFromTheRate() {
        let progress = progress(received: 40, expected: 100, throughput: 20)
        #expect(progress.estimatedTimeRemaining == .seconds(3))
    }

    @Test func estimatesNothingWithoutATotalOrARate() {
        let noTotal = progress(received: 40, expected: nil, throughput: 20)
        let noRate = progress(received: 40, expected: 100, throughput: nil)
        let stalled = progress(received: 40, expected: 100, throughput: 0)
        #expect(noTotal.estimatedTimeRemaining == nil)
        #expect(noRate.estimatedTimeRemaining == nil)
        #expect(stalled.estimatedTimeRemaining == nil)
    }

    @Test func estimatesNoTimeOnceEverythingIsIn() {
        let progress = progress(received: 120, expected: 100, throughput: 20)
        #expect(progress.estimatedTimeRemaining == .zero)
    }

    // The wording is the system's, so only what this adds to it is checked: the received bytes,
    // which the system leaves out when there is no total to set them against.

    @Test func describesTheReceivedBytesWithoutATotal() {
        let received: Int64 = 285_900_000
        let progress = progress(received: received, expected: nil, throughput: nil)
        #expect(progress.localizedDescription == received.formatted(.byteCount(style: .file)))
    }

    @Test func describesTheRateAfterTheReceivedBytesWithoutATotal() {
        let received: Int64 = 285_900_000
        let progress = progress(received: received, expected: nil, throughput: 51_400_000)
        let description = progress.localizedDescription
        let receivedText = received.formatted(.byteCount(style: .file))
        #expect(description.hasPrefix(receivedText))
        #expect(description.count > receivedText.count)
    }
}
