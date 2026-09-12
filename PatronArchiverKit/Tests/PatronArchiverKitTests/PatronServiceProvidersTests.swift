import Foundation
import Testing
@testable import PatronArchiverKit

struct PatronServiceProvidersTests {
    @Test func matchesPatreonURL() throws {
        let url = URL(string: "https://www.patreon.com/posts/12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PatreonProvider.self)
    }

    @Test func matchesPatreonURLWithoutWWW() throws {
        let url = URL(string: "https://patreon.com/posts/some-title-12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PatreonProvider.self)
    }

    @Test func matchesPatreonCreatorPrefixedURL() throws {
        let url = URL(string: "https://www.patreon.com/creator/posts/some-title-12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PatreonProvider.self)
    }

    @Test func matchesPatreonCreatorPrefixedURLWithQuery() throws {
        let url = URL(string: "https://www.patreon.com/creator/posts/some-title-12345?utm_campaign=patron_engagement&post_id=12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PatreonProvider.self)
    }

    @Test func matchesPixivFanboxURL() throws {
        let url = URL(string: "https://creator.fanbox.cc/posts/12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PixivFanboxProvider.self)
    }

    @Test func matchesPixivFanboxWWWURL() throws {
        let url = URL(string: "https://www.fanbox.cc/@creator/posts/12345")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == PixivFanboxProvider.self)
    }

    @Test func matchesSubscribeStarURL() throws {
        let url = URL(string: "https://www.subscribestar.com/posts/2465042")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == SubscribeStarProvider.self)
    }

    @Test func matchesSubscribeStarURLWithoutWWW() throws {
        let url = URL(string: "https://subscribestar.com/posts/2465042")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == SubscribeStarProvider.self)
    }

    @Test func matchesSubscribeStarAdultURL() throws {
        let url = URL(string: "https://subscribestar.adult/posts/2332276")!
        let provider = try #require(PatronServiceProviders.provider(for: url))
        #expect(type(of: provider) == SubscribeStarAdultProvider.self)
    }

    @Test func returnsNilForUnknownSite() {
        let url = URL(string: "https://example.com/page")!
        let provider = PatronServiceProviders.provider(for: url)
        #expect(provider == nil)
    }

    @Test func userVisibleCount() {
        let types = PatronServiceProviders.userVisible
        #expect(types.count == 3)
    }

    @Test func allIncludesAlternates() {
        let types = PatronServiceProviders.all
        #expect(types.count == 4)
    }

    @Test func subscribeStarAlternateProviderType() throws {
        let alternate = try #require(SubscribeStarProvider.alternateProviderType)
        #expect(alternate is SubscribeStarAdultProvider.Type)
    }

    @Test func defaultAlternateProviderTypeIsNil() {
        #expect(PatreonProvider.alternateProviderType == nil)
        #expect(PixivFanboxProvider.alternateProviderType == nil)
        #expect(SubscribeStarAdultProvider.alternateProviderType == nil)
    }

    @Test func subscribeStarIsLoggedInIsolatesByDomain() throws {
        let adultCookie = try #require(HTTPCookie(properties: [
            .name: "_personalization_id",
            .value: "x",
            .domain: ".subscribestar.adult",
            .path: "/",
        ]))
        let comCookie = try #require(HTTPCookie(properties: [
            .name: "_personalization_id",
            .value: "y",
            .domain: ".subscribestar.com",
            .path: "/",
        ]))

        #expect(SubscribeStarProvider.isLoggedIn(cookies: [adultCookie]) == false)
        #expect(SubscribeStarAdultProvider.isLoggedIn(cookies: [comCookie]) == false)
        #expect(SubscribeStarProvider.isLoggedIn(cookies: [comCookie]) == true)
        #expect(SubscribeStarAdultProvider.isLoggedIn(cookies: [adultCookie]) == true)
    }
}
