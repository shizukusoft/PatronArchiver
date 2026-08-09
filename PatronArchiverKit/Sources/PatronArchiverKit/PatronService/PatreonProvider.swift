import Foundation
import WebKit

struct PatreonProvider: PatronServiceProviding {
    // Computed rather than stored: `Regex` is not `Sendable`, so a `static let` would need
    // `nonisolated(unsafe)`. Building the patterns per access keeps them unshared, and the only
    // caller matches a URL once per archive job.
    static var matchPatterns: [Regex<Substring>] {
        [
            /https:\/\/(?:www\.)?patreon\.com\/posts\/.+/,
            /https:\/\/(?:www\.)?patreon\.com\/[^\/]+\/posts\/.+/,
        ]
    }
    static let loginURL = URL(string: "https://www.patreon.com/login")!
    static let accountCheckURL = URL(string: "https://www.patreon.com/settings/basics")!
    static let siteIdentifier = "Patreon"

    static func isLoggedIn(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "session_id" }
    }

    @MainActor static func extractAccountInfo(in webView: WKWebView) async throws -> AccountInfo? {
        let tracker = RedirectTracker()
        _ = try await tracker.load(accountCheckURL, in: webView)

        // /settings/basics is client-rendered: poll until the email input is populated.
        let script = """
        (() => {
            const emailInput = document.querySelector('[data-tag="settings-profile-email-box"] input')
                ?? document.querySelector('input#email');
            const nameInput = document.querySelector('[data-tag="settings-profile-name-box"] input');
            return {
                email: emailInput?.value ?? '',
                name: nameInput?.value ?? '',
            };
        })()
        """
        for _ in 0..<40 {
            try Task.checkCancellation()
            let result = try await webView.evaluateJavaScript(script) as? [String: String]
            let email = result?["email"] ?? ""
            let name = result?["name"] ?? ""
            if !email.isEmpty {
                let displayName = name.isEmpty ? email : name
                return AccountInfo(displayName: displayName)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    func preloadContent(in webView: WKWebView) async throws {
        // Load all comments and replies
        for _ in 0..<UInt16.max {
            let result = try await evaluateJavaScript("""
                (() => {
                    const before = document.querySelectorAll('[data-tag="comment-row"]').length;
                    let clicked = 0;
                    document.querySelectorAll('button[data-tag="loadMoreCommentsCta"]').forEach(btn => {
                        btn.click();
                        clicked++;
                    });
                    document.querySelectorAll('button[class*="TextLink"]').forEach(btn => {
                        if (!btn.hasAttribute('data-tag') && btn.textContent.trim() === 'Load replies') {
                            btn.click();
                            clicked++;
                        }
                    });
                    return { clicked, before };
                })()
            """, in: webView) as? [String: Int]

            guard let result,
                  let clicked = result["clicked"], clicked > 0,
                  let before = result["before"]
            else { break }

            // Wait until new comment-rows appear or timeout
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                let current = try await evaluateJavaScript(
                    "document.querySelectorAll('[data-tag=\"comment-row\"]').length",
                    in: webView
                ) as? Int ?? 0
                if current > before { break }
            }
        }
    }

    func extractMediaURLs(in webView: WKWebView) async throws -> [MediaItem] {
        let script = """
        (() => {
            const media = [];

            const nextData = document.getElementById('__NEXT_DATA__');
            if (nextData) {
                try {
                    const data = JSON.parse(nextData.textContent);
                    const post = data?.props?.pageProps?.bootstrapEnvelope?.pageBootstrap?.post;
                    if (post?.data && post?.included) {
                        const mediaById = {};
                        for (const item of post.included) {
                            if (item.type === 'media' && item.attributes) mediaById[item.id] = item;
                        }
                        const urlOf = (item) => item.attributes.download_url || item.attributes.image_urls?.original || item.attributes.image_urls?.url;

                        // 1. Gallery/header images in image_order
                        const imageOrder = post.data.attributes?.post_metadata?.image_order || [];
                        const imageIds = imageOrder.length > 0
                            ? imageOrder
                            : (post.data.relationships?.images?.data || []).map(d => d.id);
                        for (const id of imageIds) {
                            const item = mediaById[id];
                            if (item) {
                                media.push({ url: urlOf(item), type: 'image', filename: item.attributes.file_name || null, downloadAttribute: null });
                            }
                        }

                        // 2. Inline images from content_json_string (in document order)
                        const contentJson = post.data.attributes?.content_json_string;
                        if (contentJson) {
                            const content = JSON.parse(contentJson);
                            const walk = (nodes) => {
                                for (const node of (nodes || [])) {
                                    if (node.type === 'image' && node.attrs?.src) {
                                        if (!media.some(m => m.url === node.attrs.src)) {
                                            media.push({ url: node.attrs.src, type: 'image', filename: null, downloadAttribute: null });
                                        }
                                    }
                                    if (node.content) walk(node.content);
                                }
                            };
                            walk(content.content);
                        }

                        // 3. Attachments in attachments_media order
                        const attachmentIds = (post.data.relationships?.attachments_media?.data || []).map(d => d.id);
                        for (const id of attachmentIds) {
                            const item = mediaById[id];
                            if (item) {
                                media.push({ url: urlOf(item), type: 'archive', filename: item.attributes.file_name || null, downloadAttribute: null });
                            }
                        }
                    }
                } catch {}
            }

            return media;
        })()
        """
        guard let array = try await evaluateJavaScript(script, in: webView) as? [[String: Any]] else {
            return []
        }
        let referrerURL = webView.url
        return array.compactMap { MediaItem(from: $0, referrerURL: referrerURL) }
    }

    func extractMetadata(in webView: WKWebView, timeZone: TimeZone?) async throws -> PostMetadata {
        let script = """
        (() => {
            const meta = {};

            const nextData = document.getElementById('__NEXT_DATA__');
            if (nextData) {
                try {
                    const data = JSON.parse(nextData.textContent);
                    const post = data?.props?.pageProps?.bootstrapEnvelope?.pageBootstrap?.post;
                    if (post?.data?.attributes) {
                        const attrs = post.data.attributes;
                        meta.postID = post.data.id || '';
                        meta.title = attrs.title || '';
                        meta.createdAt = attrs.published_at || attrs.created_at || '';
                        meta.modifiedAt = attrs.edited_at || null;

                        const tagData = post.data.relationships?.user_defined_tags?.data || [];
                        meta.tags = tagData
                            .map(t => (t.id || '').replace('user_defined;', ''))
                            .filter(t => t);
                    }
                    if (post?.included) {
                        for (const item of post.included) {
                            if (item.type === 'campaign' && item.attributes?.name) {
                                meta.authorName = item.attributes.name;
                                break;
                            }
                        }
                    }
                } catch {}
            }

            // Fallback: DOM scraping
            if (!meta.title) {
                const titleEl = document.querySelector('[data-tag="post-title"]');
                meta.title = titleEl?.textContent?.trim() || document.title;
            }
            if (!meta.authorName) {
                const authorEl = document.querySelector('[data-tag="post-card"] a[href*="patreon.com/"] > h3');
                meta.authorName = authorEl?.textContent?.trim() || '';
            }
            if (!meta.postID) {
                const match = location.pathname.match(/-(\\d+)(?:[^\\/]*)$/);
                meta.postID = match ? match[1] : '';
            }
            if (!meta.tags || !meta.tags.length) {
                meta.tags = [];
                document.querySelectorAll('a[data-tag="post-tag"] p').forEach(p => {
                    const tag = p.textContent?.trim();
                    if (tag) meta.tags.push(tag);
                });
            }
            if (!meta.createdAt) meta.createdAt = new Date().toISOString();

            return meta;
        })()
        """
        guard let dict = try await evaluateJavaScript(script, in: webView) as? [String: Any] else {
            throw ProviderError.metadataExtractionFailed
        }

        let createdAt = Self.parseISO8601Date(dict["createdAt"] as? String) ?? Date()
        let modifiedAt = Self.parseISO8601Date(dict["modifiedAt"] as? String)

        return PostMetadata(
            siteIdentifier: Self.siteIdentifier,
            postID: dict["postID"] as? String ?? "",
            title: dict["title"] as? String ?? "",
            authorName: dict["authorName"] as? String ?? "",
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            tags: dict["tags"] as? [String] ?? [],
            originalURL: webView.url ?? Self.loginURL,
            redirectChain: []
        )
    }

}
