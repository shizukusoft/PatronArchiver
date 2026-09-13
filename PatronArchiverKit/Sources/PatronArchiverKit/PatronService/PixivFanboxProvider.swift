import Foundation
import WebKit

struct PixivFanboxProvider: PatronServiceProviding {
    // Computed rather than stored: `Regex` is not `Sendable`, so a `static let` would need
    // `nonisolated(unsafe)`. Building the patterns per access keeps them unshared, and the only
    // caller matches a URL once per archive job.
    static var matchPatterns: [Regex<Substring>] {
        [
            /https:\/\/[^\/]+\.fanbox\.cc\/posts\/.+/,
            /https:\/\/www\.fanbox\.cc\/@[^\/]+\/posts\/.+/,
        ]
    }
    static let loginURL = URL(string: "https://www.fanbox.cc/login")!
    static let accountCheckURL = URL(string: "https://www.fanbox.cc/user/settings")!
    static let siteIdentifier = "pixivFANBOX"

    static func isLoggedIn(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "FANBOXSESSID" && $0.value.contains("_") }
    }

    @MainActor static func extractAccountInfo(in webView: WKWebView) async throws -> AccountInfo? {
        let tracker = RedirectTracker()
        _ = try await tracker.load(accountCheckURL, in: webView)

        // Read user name from <meta id="metadata"> content JSON via DOM
        // (avoids outerHTML quote-style normalization breaking regex parsing).
        let script = """
        (() => {
            const meta = document.querySelector('meta#metadata');
            if (!meta) return null;
            try {
                const data = JSON.parse(meta.content);
                return data?.context?.user?.name ?? null;
            } catch { return null; }
        })()
        """
        guard let name = try await webView.evaluateJavaScript(script) as? String,
              !name.isEmpty else {
            return nil
        }
        return AccountInfo(displayName: name)
    }

    func preloadContent(in webView: WKWebView) async throws {
        // Load all comments by clicking the "See more" / "더 보기" / "もっと見る" button
        for _ in 0..<UInt16.max {
            let result = try await evaluateJavaScript("""
                (() => {
                    const before = document.querySelectorAll('[class*="RootCommentWrapper"]').length;
                    const btn = document.querySelector('[class*="ReadMoreWrapper"] button');
                    if (btn) {
                        btn.click();
                        return { clicked: 1, before };
                    }
                    return { clicked: 0, before };
                })()
            """, in: webView) as? [String: Int]

            guard let result,
                  let clicked = result["clicked"], clicked > 0,
                  let before = result["before"]
            else { break }

            // Wait until new comments appear or timeout
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                let current = try await evaluateJavaScript(
                    "document.querySelectorAll('[class*=\"RootCommentWrapper\"]').length",
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

            // Article type: links with target=_blank (download links) — full size originals
            document.querySelectorAll('article a[target="_blank"]').forEach(a => {
                const href = a.href;
                if (href && (href.includes('downloads.fanbox.cc') || href.includes('fanbox.pixiv.net'))) {
                    media.push({ url: href, type: 'image', filename: null, downloadAttribute: a.download || null });
                }
            });

            // Image posts: img tags inside article, NOT inside a download link
            document.querySelectorAll('article img').forEach(img => {
                if (img.src && !img.closest('a[target="_blank"]') && !media.some(m => m.url === img.src)) {
                    media.push({ url: img.src, type: 'image', filename: null, downloadAttribute: null });
                }
            });

            // File posts: download links
            document.querySelectorAll('a[href*="downloads.fanbox.cc"]').forEach(a => {
                if (!media.some(m => m.url === a.href)) {
                    const nameEl = a.closest('[class*="File"]')?.querySelector('[class*="name"], [class*="Name"]');
                    media.push({
                        url: a.href,
                        type: 'archive',
                        filename: nameEl?.textContent?.trim() || null,
                        downloadAttribute: a.download || null,
                    });
                }
            });

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

            // Post ID from URL
            const pathMatch = location.pathname.match(/posts\\/(\\d+)/);
            meta.postID = pathMatch ? pathMatch[1] : '';

            // Title — PostTitle class (not generic h1 which matches author name first)
            const titleEl = document.querySelector('[class*="PostTitle"]');
            meta.title = titleEl?.textContent?.trim() || document.title;

            // Author — UserNameText in creator header (not CreatorName which matches footer recommendations)
            const authorEl = document.querySelector('[class*="UserNameText"]');
            if (authorEl) {
                meta.authorName = authorEl.textContent.trim();
            } else {
                const hostMatch = location.hostname.match(/^([^.]+)\\.fanbox\\.cc$/);
                if (hostMatch) {
                    meta.authorName = hostMatch[1];
                }
            }

            // Date — from ld+json structured data
            const ldJson = document.querySelector('script[type="application/ld+json"]');
            if (ldJson) {
                try {
                    const ldData = JSON.parse(ldJson.textContent);
                    const entries = Array.isArray(ldData) ? ldData : [ldData];
                    const blogPost = entries.find(e => e['@type'] === 'BlogPosting');
                    if (blogPost) {
                        if (blogPost.dateModified) {
                            meta.modifiedAt = new Date(blogPost.dateModified).toISOString();
                        }
                        if (blogPost.datePublished) {
                            meta.createdAt = new Date(blogPost.datePublished).toISOString();
                        }
                    }
                } catch {}
            }
            if (!meta.createdAt) {
                meta.createdAt = new Date().toISOString();
            }

            // Tags
            meta.tags = Array.from(document.querySelectorAll('[class*="Tag__Text"]'))
                .map(el => el.textContent.trim())
                .filter(t => t.length > 0);

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
