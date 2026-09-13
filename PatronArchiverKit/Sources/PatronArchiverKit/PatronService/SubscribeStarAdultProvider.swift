import Foundation

struct SubscribeStarAdultProvider: SubscribeStarProviding {
    static let baseURL = URL(string: "https://subscribestar.adult")!
    static let siteIdentifier = "SubscribeStar.adult"

    // Computed rather than stored: `Regex` is not `Sendable`, so a `static let` would need
    // `nonisolated(unsafe)`. Building the patterns per access keeps them unshared, and the only
    // caller matches a URL once per archive job.
    static var matchPatterns: [Regex<Substring>] {
        [
            /https:\/\/subscribestar\.adult\/posts\/.+/,
        ]
    }
}
