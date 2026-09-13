import Foundation
import WebKit

extension WKWebView {
    /// Renders the current page as a full-page-height PDF and writes it to `url`.
    ///
    /// - Parameter url: Where to write the PDF. Any existing file there is replaced.
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
    /// ``writeFullPagePDF(to:)`` necessarily is — a web view is main-actor isolated.
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
