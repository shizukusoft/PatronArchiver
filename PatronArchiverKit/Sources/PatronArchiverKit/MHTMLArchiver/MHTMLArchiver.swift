import Foundation
import PropertyList
import WebKit

// MARK: - MHTMLArchiver

/// RFC 2557 MHTML archive generator.
///
/// Creates an MHTML archive from the current state of a web view,
/// using the browser's webarchive as a resource cache to minimize
/// network requests and falling back to URLSession for missing resources.
@MainActor
struct MHTMLArchiver {
    private let webView: WKWebView
    private let urlSession: URLSession

    /// Creates an archiver for the given web view.
    ///
    /// - Parameters:
    ///   - webView: The web view whose current page will be archived.
    ///   - urlSession: The URL session to use for downloading missing resources.
    init(_ webView: WKWebView, urlSession: URLSession) {
        self.webView = webView
        self.urlSession = urlSession
    }

    /// Generates an MHTML archive of the web view's current page.
    ///
    /// - Returns: The MHTML data.
    /// - Throws: `MHTMLError` if the page URL is unavailable or resource collection fails.
    func archive() async throws -> Data {
        guard let pageURL = webView.url else {
            throw MHTMLError.noPageURL
        }

        // 1. Snapshot loaded resources via webarchive (browser cache, no network)
        let cache: [String: Resource]
        do {
            let webArchiveData: Data = try await withCheckedThrowingContinuation { continuation in
                webView.createWebArchiveData { continuation.resume(with: $0) }
            }
            let cachedResources = Self.parseWebArchiveResources(webArchiveData)
            cache = Dictionary(
                cachedResources.map { ($0.url.absoluteString, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            cache = [:]
        }

        // 2. Run JS to modify DOM (mutable stylesheets, adopted stylesheets, etc.)
        //    and capture outerHTML + resource URLs + iframe info
        let collectResult = try await collectPageResources()

        // 3. Resolve resources: webarchive cache first, URLSession fallback
        let dataStore = webView.configuration.websiteDataStore

        let requestedURLs = collectResult.resourceURLs.compactMap { URL(string: $0) }
        var resources: [Resource] = []
        var missingURLs: [URL] = []

        for url in requestedURLs {
            if let cached = cache[url.absoluteString] {
                resources.append(cached)
            } else {
                missingURLs.append(url)
            }
        }

        let downloaded = await Self.downloadResources(
            urls: missingURLs, dataStore: dataStore, urlSession: urlSession
        )
        resources.append(contentsOf: downloaded)

        // 4. CSS 2nd pass: extract sub-resource URLs, resolve from cache or download
        let resolvedURLs = Set(resources.map(\.url.absoluteString))
        let cssSubresourceURLs = Self.extractCSSSubresourceURLs(from: resources)
            .filter { !resolvedURLs.contains($0.absoluteString) }

        var cssResources: [Resource] = []
        var missingCSSURLs: [URL] = []
        for url in cssSubresourceURLs {
            if let cached = cache[url.absoluteString] {
                cssResources.append(cached)
            } else {
                missingCSSURLs.append(url)
            }
        }
        cssResources.append(contentsOf: await Self.downloadResources(
            urls: missingCSSURLs, dataStore: dataStore, urlSession: urlSession
        ))

        // 5. Iframe sub-documents
        let iframeResources = await Self.collectIframeResources(
            iframes: collectResult.iframes, dataStore: dataStore, urlSession: urlSession
        )

        let allResources = resources + cssResources + iframeResources

        // 6. Assemble MHTML
        return await Self.assembleMHTML(
            pageURL: pageURL,
            title: collectResult.title,
            html: collectResult.html,
            resources: allResources
        )
    }
}

// MARK: - Resource Type

extension MHTMLArchiver {
    /// A collected web resource with its URL, Content-Type, and raw data.
    struct Resource: Sendable {
        let url: URL
        let contentType: String
        let data: Data
    }
}

// MARK: - JS Resource Collection

private struct CollectResult {
    let html: String
    let title: String
    let resourceURLs: [String]
    let iframes: [IframeInfo]
}

private struct IframeInfo {
    let url: String
    let html: String? // nil for cross-origin iframes
}

extension MHTMLArchiver {
    fileprivate func collectPageResources() async throws -> CollectResult {
        let script = """
        (() => {
            const resources = new Set();

            // --- Collect resource URLs from DOM elements ---

            // img src
            document.querySelectorAll('img[src]').forEach(img => {
                if (img.src && !img.src.startsWith('data:')) resources.add(img.src);
            });

            // img srcset
            document.querySelectorAll('img[srcset]').forEach(img => {
                img.srcset.split(',').forEach(entry => {
                    const url = entry.trim().split(/\\s+/)[0];
                    if (url && !url.startsWith('data:')) {
                        try { resources.add(new URL(url, location.href).href); } catch {}
                    }
                });
            });

            // link stylesheets
            document.querySelectorAll('link[rel="stylesheet"][href]').forEach(link => {
                resources.add(link.href);
            });

            // video, audio, source
            document.querySelectorAll('video[src], audio[src], source[src]').forEach(el => {
                if (el.src && !el.src.startsWith('data:')) resources.add(el.src);
            });

            // picture source srcset
            document.querySelectorAll('picture source[srcset]').forEach(source => {
                source.srcset.split(',').forEach(entry => {
                    const url = entry.trim().split(/\\s+/)[0];
                    if (url && !url.startsWith('data:')) {
                        try { resources.add(new URL(url, location.href).href); } catch {}
                    }
                });
            });

            // --- Collect URLs from CSS rules (inline <style> and linked stylesheets) ---

            function extractURLsFromRules(rules, baseHref) {
                for (let i = 0; i < rules.length; i++) {
                    const rule = rules[i];
                    const urlMatches = rule.cssText.matchAll(/url\\(["']?([^"')]+)["']?\\)/g);
                    for (const m of urlMatches) {
                        if (m[1].startsWith('data:')) continue;
                        try {
                            resources.add(new URL(m[1], baseHref).href);
                        } catch {}
                    }
                    // Recurse into nested rules (@media, @supports, etc.)
                    if (rule.cssRules) extractURLsFromRules(rule.cssRules, baseHref);
                }
            }

            for (let i = 0; i < document.styleSheets.length; i++) {
                const sheet = document.styleSheets[i];
                try {
                    const baseHref = sheet.href || location.href;
                    extractURLsFromRules(sheet.cssRules, baseHref);
                } catch {
                    // Cross-origin stylesheet — can't access rules; Swift 2nd pass handles it
                }
            }

            // inline style background-image
            document.querySelectorAll('[style*="url("]').forEach(el => {
                const matches = el.style.cssText.matchAll(/url\\(["']?([^"')]+)["']?\\)/g);
                for (const m of matches) {
                    if (m[1].startsWith('data:')) continue;
                    try { resources.add(new URL(m[1], location.href).href); } catch {}
                }
            });

            // --- Serialize mutable stylesheets (styled-components, etc.) ---

            document.querySelectorAll('style').forEach(style => {
                if (!style.sheet) return;
                try {
                    const cssomText = Array.from(style.sheet.cssRules).map(r => r.cssText).join('\\n');
                    const sourceText = style.textContent.trim();
                    // Replace if CSSOM differs from source (mutable stylesheet)
                    if (cssomText && cssomText !== sourceText) {
                        style.textContent = cssomText;
                    }
                } catch {}
            });

            // --- Adopted stylesheets ---

            if (document.adoptedStyleSheets && document.adoptedStyleSheets.length > 0) {
                for (const sheet of document.adoptedStyleSheets) {
                    try {
                        const cssText = Array.from(sheet.cssRules).map(r => r.cssText).join('\\n');
                        if (cssText) {
                            const styleEl = document.createElement('style');
                            styleEl.setAttribute('data-adopted-stylesheet', '');
                            styleEl.textContent = cssText;
                            document.head.appendChild(styleEl);
                        }
                    } catch {}
                }
            }

            // --- Escape </style> inside <style> tags to prevent MHTML parser breakage ---

            document.querySelectorAll('style').forEach(style => {
                if (style.textContent.includes('</style')) {
                    style.textContent = style.textContent.replace(/<\\/style/gi, '\\\\3C /style');
                }
            });

            // --- Collect iframe sub-documents ---

            const iframes = [];
            document.querySelectorAll('iframe[src]').forEach(iframe => {
                if (!iframe.src || iframe.src.startsWith('data:') || iframe.src === 'about:blank') return;
                const info = { url: iframe.src, html: null };
                try {
                    if (iframe.contentDocument && iframe.contentDocument.documentElement) {
                        info.html = iframe.contentDocument.documentElement.outerHTML;
                    }
                } catch {}
                iframes.push(info);
            });

            const html = document.documentElement.outerHTML;
            return JSON.stringify({
                html: html,
                title: document.title || '',
                resources: Array.from(resources).filter(u => u.startsWith('http')),
                iframes: iframes
            });
        })()
        """

        guard let jsonString = try await webView.evaluateJavaScript(script) as? String,
              let jsonData = jsonString.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let html = result["html"] as? String,
              let resourceURLs = result["resources"] as? [String]
        else {
            throw MHTMLError.collectionFailed
        }

        let title = result["title"] as? String ?? ""

        var iframes: [IframeInfo] = []
        if let iframeArray = result["iframes"] as? [[String: Any]] {
            for item in iframeArray {
                guard let url = item["url"] as? String else { continue }
                let html = item["html"] as? String
                iframes.append(IframeInfo(url: url, html: html))
            }
        }

        return CollectResult(
            html: html,
            title: title,
            resourceURLs: resourceURLs,
            iframes: iframes
        )
    }
}

// MARK: - WebArchive Parsing

extension MHTMLArchiver {
    /// Extracts sub-resources from a binary plist webarchive, deduplicating by URL.
    ///
    /// Read into a `PropertyListValue` rather than the `Any` `PropertyListSerialization` deals in:
    /// the shape below is the same walk either way, but the tree is typed, so a key that holds the
    /// wrong kind answers `nil` here instead of needing a cast to say so. It also keeps the reading
    /// tolerant — a webarchive is WebKit's to write, and one malformed entry should cost that entry
    /// rather than the whole archive, which is what decoding into a fixed type would do.
    private nonisolated static func parseWebArchiveResources(_ data: Data) -> [Resource] {
        guard let archive = try? PropertyListValue(data: data) else {
            return []
        }

        var resources: [Resource] = []
        var seen = Set<String>()
        extractSubresources(from: archive, into: &resources, seen: &seen)
        return resources
    }

    private nonisolated static func extractSubresources(
        from archive: PropertyListValue,
        into resources: inout [Resource],
        seen: inout Set<String>
    ) {
        for item in archive["WebSubresources"]?.array ?? [] {
            guard let urlString = item["WebResourceURL"]?.string,
                  let data = item["WebResourceData"]?.data,
                  let mimeType = item["WebResourceMIMEType"]?.string,
                  seen.insert(urlString).inserted,
                  let url = URL(string: urlString)
            else { continue }

            var contentType = mimeType
            if let encoding = item["WebResourceTextEncodingName"]?.string,
               !encoding.isEmpty, mimeType.hasPrefix("text/") {
                contentType = "\(mimeType); charset=\(encoding)"
            }

            resources.append(Resource(url: url, contentType: contentType, data: data))
        }

        for subframe in archive["WebSubframeArchives"]?.array ?? [] {
            extractSubresources(from: subframe, into: &resources, seen: &seen)
        }
    }
}

// MARK: - Resource Download

extension MHTMLArchiver {
    @concurrent
    private static func downloadResources(
        urls: [URL],
        dataStore: WKWebsiteDataStore,
        urlSession: URLSession
    ) async -> [Resource] {
        // Batch urlRequest creation to minimize main actor hops
        var requests: [URL: URLRequest] = [:]
        for url in urls {
            var urlRequest = URLRequest(url: url)
            await dataStore.addCookies(to: &urlRequest)
            requests[url] = urlRequest
        }

        return await withTaskGroup(of: Resource?.self) { group in
            for url in urls {
                let request = requests[url]!
                group.addTask {
                    do {
                        let (data, response) = try await urlSession.data(for: request)
                        let contentType = (response as? HTTPURLResponse)?
                            .value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                        return Resource(url: url, contentType: contentType, data: data)
                    } catch {
                        return nil
                    }
                }
            }
            var results: [Resource] = []
            for await resource in group {
                if let resource { results.append(resource) }
            }
            return results
        }
    }
}

// MARK: - Iframe Sub-document Collection

extension MHTMLArchiver {
    @concurrent
    fileprivate static func collectIframeResources(
        iframes: [IframeInfo],
        dataStore: WKWebsiteDataStore,
        urlSession: URLSession
    ) async -> [Resource] {
        // Batch urlRequest creation for cross-origin iframes
        var requestsBuilder: [String: URLRequest] = [:]
        for iframe in iframes where iframe.html == nil {
            guard let url = URL(string: iframe.url) else { continue }
            var urlRequest = URLRequest(url: url)
            await dataStore.addCookies(to: &urlRequest)
            requestsBuilder[iframe.url] = urlRequest
        }
        let requests = requestsBuilder

        return await withTaskGroup(of: Resource?.self) { group in
            for iframe in iframes {
                let iframeURL = iframe.url
                let iframeHTML = iframe.html
                group.addTask {
                    guard let url = URL(string: iframeURL) else { return nil }

                    if let html = iframeHTML {
                        // Same-origin: already captured from contentDocument
                        return Resource(
                            url: url,
                            contentType: "text/html; charset=utf-8",
                            data: Data(html.utf8)
                        )
                    } else {
                        // Cross-origin: download via URLSession
                        guard let request = requests[iframeURL] else { return nil }
                        do {
                            let (data, response) = try await urlSession.data(for: request)
                            let contentType = (response as? HTTPURLResponse)?
                                .value(forHTTPHeaderField: "Content-Type") ?? "text/html"
                            return Resource(
                                url: url, contentType: contentType, data: data
                            )
                        } catch {
                            return nil
                        }
                    }
                }
            }
            var results: [Resource] = []
            for await resource in group {
                if let resource { results.append(resource) }
            }
            return results
        }
    }
}

// MARK: - CSS Subresource Extraction (2nd Pass)

extension MHTMLArchiver {
    private nonisolated static func extractCSSSubresourceURLs(from resources: [Resource]) -> [URL] {
        let cssURLPattern = /url\(["']?([^"')]+)["']?\)/

        var discovered: [URL] = []
        for resource in resources {
            guard resource.contentType.hasPrefix("text/css") else { continue }
            guard let cssText = String(data: resource.data, encoding: .utf8) else { continue }

            for match in cssText.matches(of: cssURLPattern) {
                let urlString = String(match.1)
                if urlString.hasPrefix("data:") { continue }
                if let resolved = URL(string: urlString, relativeTo: resource.url)?.absoluteURL {
                    discovered.append(resolved)
                }
            }
        }

        // Deduplicate
        var seen = Set<String>()
        return discovered.filter { seen.insert($0.absoluteString).inserted }
    }
}

// MARK: - MHTML Assembly

extension MHTMLArchiver {
    @concurrent
    private static func assembleMHTML(
        pageURL: URL,
        title: String,
        html: String,
        resources: [Resource]
    ) async -> Data {
        let boundary = "----=_Part_\(UUID().uuidString)"
        let dateString = MHTMLDateFormatter.shared.string(from: Date())

        var mhtml = Data()

        func append(_ string: String) {
            mhtml.append(contentsOf: string.utf8)
        }

        // MHTML header (RFC 2557 + Chromium conventions)
        append("From: <Saved by PatronArchiver>\r\n")
        append("Snapshot-Content-Location: \(pageURL.absoluteString)\r\n")
        append("Subject: \(rfc2047Encode(title.isEmpty ? pageURL.absoluteString : title))\r\n")
        append("Date: \(dateString)\r\n")
        append("MIME-Version: 1.0\r\n")
        append("Content-Type: multipart/related; type=\"text/html\"; boundary=\"\(boundary)\"\r\n")
        append("\r\n")

        // HTML part
        append("--\(boundary)\r\n")
        append("Content-Type: text/html; charset=\"utf-8\"\r\n")
        append("Content-Transfer-Encoding: quoted-printable\r\n")
        append("Content-Location: \(pageURL.absoluteString)\r\n")
        append("\r\n")
        mhtml.append(quotedPrintableEncode(html))
        append("\r\n")

        // Resource parts
        for resource in resources {
            append("--\(boundary)\r\n")
            append("Content-Type: \(resource.contentType)\r\n")

            if isTextBasedContentType(resource.contentType),
               let text = String(data: resource.data, encoding: .utf8)
            {
                append("Content-Transfer-Encoding: quoted-printable\r\n")
                append("Content-Location: \(resource.url.absoluteString)\r\n")
                append("\r\n")
                mhtml.append(quotedPrintableEncode(text))
            } else {
                append("Content-Transfer-Encoding: base64\r\n")
                append("Content-Location: \(resource.url.absoluteString)\r\n")
                append("\r\n")
                mhtml.append(resource.data.base64EncodedData(options: .lineLength76Characters))
            }
            append("\r\n")
        }

        append("--\(boundary)--\r\n")

        return mhtml
    }
}

// MARK: - Content-Type Classification

/// Determines whether the given Content-Type should use quoted-printable encoding.
private func isTextBasedContentType(_ contentType: String) -> Bool {
    let mimeType = contentType
        .split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces)
        .lowercased() ?? ""

    if mimeType.hasPrefix("text/") { return true }
    if mimeType == "image/svg+xml" { return true }
    if mimeType == "application/javascript" { return true }
    if mimeType == "application/json" { return true }
    if mimeType == "application/xml" { return true }
    if mimeType.hasSuffix("+xml") { return true }
    return false
}

// MARK: - Quoted-Printable Encoding (RFC 2045)

private let crlf: [UInt8] = [0x0D, 0x0A]
private let softLineBreak: [UInt8] = [0x3D, 0x0D, 0x0A] // "=\r\n"
private let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

private func quotedPrintableEncode(_ string: String) -> Data {
    let bytes = Array(string.utf8)
    var result = Data()
    result.reserveCapacity(bytes.count + bytes.count / 10)
    var lineLength = 0
    let count = bytes.count

    var i = 0
    while i < count {
        let byte = bytes[i]

        // CR LF — emit line break and reset
        if byte == 0x0D, i + 1 < count, bytes[i + 1] == 0x0A {
            result.append(contentsOf: crlf)
            lineLength = 0
            i += 2
            continue
        }

        // Bare LF — normalize to CRLF
        if byte == 0x0A {
            result.append(contentsOf: crlf)
            lineLength = 0
            i += 1
            continue
        }

        // Bare CR — normalize to CRLF
        if byte == 0x0D {
            result.append(contentsOf: crlf)
            lineLength = 0
            i += 1
            continue
        }

        // Determine the encoded form
        let encoded: [UInt8]
        if byte == 0x3D { // '='
            encoded = [0x3D, 0x33, 0x44] // "=3D"
        } else if byte == 0x20 || byte == 0x09 { // space or tab
            // RFC 2045: trailing whitespace at line end must be encoded
            let isTrailing = isTrailingWhitespace(bytes: bytes, from: i)
            if isTrailing {
                encoded = [0x3D, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]
            } else {
                encoded = [byte]
            }
        } else if byte >= 0x21, byte <= 0x7E {
            encoded = [byte]
        } else {
            encoded = [0x3D, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]
        }

        // Soft line break if needed (max 76 chars including soft break "=")
        if lineLength + encoded.count > 75 {
            result.append(contentsOf: softLineBreak)
            lineLength = 0
        }

        result.append(contentsOf: encoded)
        lineLength += encoded.count
        i += 1
    }

    return result
}

/// Check if the whitespace byte at `from` is trailing (followed only by whitespace until line end or EOF).
private func isTrailingWhitespace(bytes: [UInt8], from index: Int) -> Bool {
    var j = index + 1
    while j < bytes.count {
        let b = bytes[j]
        if b == 0x0D || b == 0x0A {
            return true
        }
        if b != 0x20 && b != 0x09 {
            return false
        }
        j += 1
    }
    // EOF counts as trailing
    return true
}

// MARK: - RFC 2047 Encoded-Word (Subject Header)

/// Encodes a string for use in an RFC 2047 header field.
///
/// Returns the original string if it is pure ASCII. Otherwise, produces
/// one or more `=?UTF-8?B?…?=` encoded-words separated by `CRLF SPACE`,
/// splitting at UTF-8 character boundaries so that each encoded-word
/// does not exceed 75 characters (RFC 2047 §2).
private func rfc2047Encode(_ text: String) -> String {
    // If all ASCII, no encoding needed
    if text.utf8.allSatisfy({ $0 < 0x80 }) {
        return text
    }

    let prefix = "=?UTF-8?B?"  // 10 chars
    let suffix = "?="           // 2 chars
    // Max base64 per encoded-word: 75 - 12 (overhead) = 63, rounded down to multiple of 4 → 60
    // 60 base64 chars encode 45 bytes
    let maxInputBytes = 45

    let utf8 = Array(text.utf8)
    var words: [String] = []
    var offset = 0

    while offset < utf8.count {
        var end = min(offset + maxInputBytes, utf8.count)
        // Ensure we don't split a multi-byte UTF-8 character
        while end < utf8.count, isContinuationByte(utf8[end]) {
            end -= 1
        }
        // Also ensure we don't split backwards past offset
        if end <= offset {
            end = offset + 1
            while end < utf8.count, isContinuationByte(utf8[end]) {
                end += 1
            }
        }

        let chunk = Data(utf8[offset..<end])
        let encoded = chunk.base64EncodedString()
        words.append("\(prefix)\(encoded)\(suffix)")
        offset = end
    }

    return words.joined(separator: "\r\n ")
}

/// Returns `true` if the byte is a UTF-8 continuation byte (10xxxxxx).
private func isContinuationByte(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
}

// MARK: - RFC 2822 Date Formatter

private enum MHTMLDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
