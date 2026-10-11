import Foundation
import WebKit

extension WKWebView {
    /// Brings the live DOM into a state that serializes faithfully, for any archive format that
    /// captures markup — WebKit's own webarchive and our MHTML alike.
    ///
    /// This is the one sanctioned exception to the non-invasive DOM rule, and it exists because
    /// both serializers write `<style>` elements from their text children. Neither reads the CSSOM:
    /// WebKit's `MarkupAccumulator` only reconstructs a stylesheet from `cssText` on the Safari
    /// Save-As path, which the public `createWebArchiveData` never takes, and neither knows about
    /// `document.adoptedStyleSheets` at all. So anything a page applied at runtime — styled-components
    /// inserting rules straight into the sheet, a component library adopting a constructed
    /// stylesheet — would be missing from the archive unless it is written back into the DOM first.
    ///
    /// The three operations mirror Chromium's MHTML serializer (`frame_serializer.cc`), which faces
    /// the same problem:
    /// 1. A `<style>` whose `sheet.cssRules` no longer match its text is rewritten from the CSSOM.
    ///    Only the diverged ones: `cssText` loses comments, whitespace, and shorthand, so a sheet
    ///    the page left alone keeps its original text.
    /// 2. Each adopted stylesheet is appended to `<head>` as a `<style>`, since it has no element
    ///    of its own to be serialized through.
    /// 3. A literal `</style` inside a `<style>` is escaped as `\3C /style`, which the HTML parser
    ///    would otherwise take for the end of the element. Both serializers emit style text raw.
    ///
    /// Safe to call more than once — each format calls it before capturing rather than trusting
    /// that another already did. A rewritten sheet compares equal to itself on the next pass, and
    /// the adopted stylesheets are marked so they are not appended a second time.
    func prepareDOMForSerialization() async throws {
        // An IIFE so nothing leaks into the page's global scope. It returns a count rather than
        // nothing because the async `evaluateJavaScript` has no representation for `undefined`.
        let script = """
        (() => {
            let rewritten = 0;

            document.querySelectorAll('style').forEach(style => {
                if (!style.sheet) return;
                try {
                    const cssomText = Array.from(style.sheet.cssRules).map(r => r.cssText).join('\\n');
                    const sourceText = style.textContent.trim();
                    if (cssomText && cssomText !== sourceText) {
                        style.textContent = cssomText;
                        rewritten += 1;
                    }
                } catch {}
            });

            const adoptedAlreadyInjected = document.head.querySelector('style[data-adopted-stylesheet]') !== null;
            if (!adoptedAlreadyInjected && document.adoptedStyleSheets && document.adoptedStyleSheets.length > 0) {
                for (const sheet of document.adoptedStyleSheets) {
                    try {
                        const cssText = Array.from(sheet.cssRules).map(r => r.cssText).join('\\n');
                        if (cssText) {
                            const styleEl = document.createElement('style');
                            styleEl.setAttribute('data-adopted-stylesheet', '');
                            styleEl.textContent = cssText;
                            document.head.appendChild(styleEl);
                            rewritten += 1;
                        }
                    } catch {}
                }
            }

            document.querySelectorAll('style').forEach(style => {
                if (style.textContent.includes('</style')) {
                    style.textContent = style.textContent.replace(/<\\/style/gi, '\\\\3C /style');
                    rewritten += 1;
                }
            });

            return rewritten;
        })()
        """
        _ = try await evaluateJavaScript(script)
    }

    /// WebKit's webarchive of the current page, as it stands in the DOM right now.
    ///
    /// The archive serializes the live document rather than the bytes the page loaded from, so
    /// everything `LazyContentLoader` brought in is included. What it does not do is consult the
    /// CSSOM — call ``prepareDOMForSerialization()`` first when the result is meant to be viewed,
    /// as opposed to mined for its subresources.
    func webArchiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            createWebArchiveData { continuation.resume(with: $0) }
        }
    }

    /// Writes a webarchive of the current page to `url`.
    ///
    /// - Parameter url: Where to write the archive. Fails if a file is already there.
    func writeWebArchive(to url: URL) async throws {
        try await prepareDOMForSerialization()
        let data = try await webArchiveData()
        try await Self.write(data, to: url)
    }

    /// Renders the current page as a full-page-height PDF and writes it to `url`.
    ///
    /// - Parameter url: Where to write the PDF. Fails if a file is already there.
    func writeFullPagePDF(to url: URL) async throws {
        let contentHeight = try await evaluateJavaScript(
            "document.documentElement.scrollHeight"
        ) as? Double ?? 0

        let config = WKPDFConfiguration()
        config.rect = CGRect(
            x: 0,
            y: 0,
            width: frame.width,
            height: contentHeight
        )

        // WebKit renders to `Data` and offers nothing to stream into, so the document is in memory
        // for as long as it takes to write it out. Writing here rather than handing the data back
        // is what keeps it from being held for the rest of the job.
        let data = try await pdf(configuration: config)
        try await Self.write(data, to: url)
    }

    /// `@concurrent` so the write does not land on the main actor, which is where every caller of
    /// ``writeWebArchive(to:)`` and ``writeFullPagePDF(to:)`` necessarily is — a web view is
    /// main-actor isolated.
    ///
    /// `withoutOverwriting` rather than `atomic`: media downloads are landing in the same directory
    /// while this runs, and a name collision has to fail rather than quietly replace one of them.
    /// The two options are mutually exclusive, and atomicity buys nothing here — the file is being
    /// written into a staging directory that is discarded whole if anything goes wrong.
    @concurrent
    private static func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .withoutOverwriting)
    }
}
