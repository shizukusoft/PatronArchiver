import Foundation
import UserDefaultsKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The single source of truth for user-configurable settings.
///
/// Each setting is one ``UserDefault`` value that carries its own key and default, so both are
/// spelled once and shared: the model reads `wrappedValue` here, and SwiftUI views bind through
/// `@UserDefaultStorage(<setting>.key)` seeded with `<setting>.defaultValue`. There is no stored,
/// cached copy, so every window and the Settings scene read one and the same value.
///
/// Declaring the wrappers as `static let` values — rather than the `@UserDefault` attribute — is
/// deliberate: the attribute form would synthesize a `static var` backing, which Swift 6 rejects as
/// global mutable state. A `static let` is fine here because `UserDefault` is `Sendable`, and its
/// `nonmutating` setter still writes through the constant.
public enum AppSettings {
    public static let renderWidth = UserDefault(key: "renderWidth", defaultValue: 1920)
    public static let scrollDelay = UserDefault(key: "scrollDelay", defaultValue: 150.0)
    public static let savedDirectoryBookmark = UserDefault<Data?>(
        key: "savedDirectoryBookmark",
        defaultValue: nil
    )
    public static let includesWhereFroms = UserDefault(key: "includesWhereFroms", defaultValue: true)
    public static let includesFinderTags = UserDefault(key: "includesFinderTags", defaultValue: true)
    public static let includesContentDates = UserDefault(key: "includesContentDates", defaultValue: true)

    // MARK: - Derived

    /// The offscreen canvas the archiver renders into, for a width the caller already has.
    ///
    /// Taking the width rather than reading ``renderWidth`` here is deliberate. A property that
    /// read the stored width would look right in a SwiftUI body while registering no dependency on
    /// it, so the canvas would keep its old size until something unrelated invalidated the view.
    /// Requiring the width means a view has to observe it — with `@UserDefaultStorage` — to call
    /// this at all, and the shape stays spelled once rather than at each call site.
    ///
    /// Height follows the width at 16:9 rather than being pinned, which keeps the canvas a
    /// plausible display shape across the whole range the Settings stepper offers. The arithmetic
    /// is `CGFloat` because `renderWidth` is a raw stored value: integer division would truncate a
    /// width that did not come from the stepper.
    public static func renderSize(forWidth width: Int) -> CGSize {
        let width = CGFloat(width)
        return CGSize(width: width, height: width * 9 / 16)
    }

    /// Default archive location: the app's sandbox container `Documents` directory.
    ///
    /// Always writable without any file-access entitlement on both macOS and iOS.
    /// Users can override this by choosing their own folder (security-scoped bookmark).
    public static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// The directory archives are currently written to: the user-selected folder
    /// (resolved from its security-scoped bookmark) or ``defaultSaveDirectory``.
    public static func resolveBaseDirectory() -> URL {
        var isStale = false
        if let bookmarkData = savedDirectoryBookmark.wrappedValue,
           let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions,
            bookmarkDataIsStale: &isStale
           ) {
            return url
        }
        return defaultSaveDirectory
    }

    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = {
        #if os(macOS)
        .withSecurityScope
        #else
        []
        #endif
    }()
}
