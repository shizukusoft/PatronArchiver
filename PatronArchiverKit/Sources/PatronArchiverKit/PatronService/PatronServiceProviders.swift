import Foundation

/// The providers this app knows, and which one handles a given URL.
public enum PatronServiceProviders {
    /// Providers shown in the user-facing site list (e.g., Settings).
    public static let userVisible: [any PatronServiceProviding.Type] = [
        PatreonProvider.self,
        PixivFanboxProvider.self,
        SubscribeStarProvider.self,
    ]

    /// All providers, including alternates that are reachable via URL routing
    /// but should not be listed in the user-facing UI.
    public static let all: [any PatronServiceProviding.Type] = userVisible
        + [SubscribeStarAdultProvider.self]

    static func provider(for url: URL) -> (any PatronServiceProviding)? {
        let urlString = url.absoluteString
        for providerType in all {
            for pattern in providerType.matchPatterns {
                if wholeMatch(urlString, pattern: pattern) {
                    return providerType.init()
                }
            }
        }
        return nil
    }

    private static func wholeMatch(_ string: String, pattern: Regex<Substring>) -> Bool {
        string.wholeMatch(of: pattern) != nil
    }
}
