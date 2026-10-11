/// The page formats a job writes alongside a post's media.
///
/// The formats are independent — none conflicts with another — so they are flags rather than a
/// choice. An empty set is valid: the job then saves media only.
///
/// `Codable` comes from the standard library's `RawRepresentable` defaults, so a value encodes as
/// its bare integer. That integer is what ``AppSettings/archiveFormats`` persists, which makes the
/// bit assignments below part of the stored format: never renumber or reuse one.
public struct ArchiveFormats: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// WebKit's native archive, written by `WKWebView.createWebArchiveData`.
    public static let webArchive = Self(rawValue: 1 << 0)
    /// An RFC 2557 archive, written by `MHTMLArchiver`.
    public static let mhtml = Self(rawValue: 1 << 1)
    /// A full-page-height rendering, written by `WKWebView.writeFullPagePDF(to:)`.
    public static let pdf = Self(rawValue: 1 << 2)
}
