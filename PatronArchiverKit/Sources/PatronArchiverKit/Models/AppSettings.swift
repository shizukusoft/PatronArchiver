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

    public static var renderSize: CGSize {
        CGSize(width: CGFloat(renderWidth.wrappedValue), height: 1080)
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
