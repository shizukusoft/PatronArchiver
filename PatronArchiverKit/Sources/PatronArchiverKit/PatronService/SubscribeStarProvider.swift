import Foundation

struct SubscribeStarProvider: SubscribeStarProviding {
    static let baseURL = URL(string: "https://www.subscribestar.com")!
    static let siteIdentifier = "SubscribeStar"

    // Computed rather than stored: `Regex` is not `Sendable`, so a `static let` would need
    // `nonisolated(unsafe)`. Building the patterns per access keeps them unshared, and the only
    // caller matches a URL once per archive job.
    static var matchPatterns: [Regex<Substring>] {
        [
            /https:\/\/(?:www\.)?subscribestar\.com\/posts\/.+/,
        ]
    }

    static let alternateProviderType: (any PatronServiceProviding.Type)? = SubscribeStarAdultProvider.self
}
