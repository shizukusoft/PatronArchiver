# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Migrated the support contact email and privacy policy hosting to the shizukusoft.com domain
- Feedback email diagnostic logs now cover the whole process instead of only the app's own subsystems, capturing framework-level activity for easier diagnosis

## [1.1.1] - 2026-06-14

### Changed

- Migrated the app and StoreKit product bundle identifiers to the com.shizukusoft namespace and updated the macOS signing team

### Fixed

- Patreon post URLs in its new format that includes the creator path segment not being recognized, so they could not be added
- macOS toolbar Add button being pushed into the overflow menu at the default window width; the URL field now resizes with the window

## [1.1] - 2026-06-04

### Added

- Korean and Japanese localizations for app UI and error strings
- Korean and Japanese App Store metadata
- Optional secondary sign-in offered after a primary SubscribeStar account is signed in
- "Open Save Folder" toolbar button to open the current archive location (Finder on macOS, Files on iOS)

### Changed

- Consolidated shared build settings (code signing, Swift features, device family) to project level
- Enabled compilation caching, mergeable libraries, and strict memory safety
- Raised deployment targets to macOS 15.6 and iOS 18.6
- Moved macOS window sizing from view to scene level with defaultSize and defaultPosition
- Replaced manual Content-Disposition parsing with RFC 6266-compliant parser supporting filename* (ext-value)
- Added HTML download attribute as media filename fallback before URL path component
- Renamed UI labels for clarity: "Overwrite" → "Replace", "Remove" → "Delete", "Login/Logout" → "Sign In/Sign Out", "Save Directory" → "Save Location"
- Made error strings localizable with String(localized:bundle:)
- Switched account verification to WebView-based DOM extraction with per-provider status and cancellation in Settings
- SubscribeStar provider uses subscribestar.com as the primary domain; subscribestar.adult URLs continue to work via URL routing
- Default archive location moved to the app's sandbox container Documents folder (previously the Downloads folder on macOS)

### Fixed

- SubscribeStar.adult post title including extra text after line breaks (e.g. URLs)
- Patreon account verification failing on the client-rendered settings page

## [1.0.0+rc.3] - 2026-03-15

## [1.0.0+rc.2] - 2026-03-15

## [1.0.0+rc.1] - 2026-03-15

### Added

- Tip Jar with consumable IAP for optional support
- Send Feedback mail composer on iOS and macOS
- Diagnostic log attachment in feedback emails
- Help menu commands for Tip Jar and Send Feedback
- Transaction.updates listener via TransactionObserver for pending transaction handling

### Changed

- Set app accent color to system green

### Fixed

- iOS bottom toolbar items not grouped together
- macOS principal toolbar items not grouped together
- Duplicate newline in feedback mail diagnostic body

## [1.0.0+alpha.7] - 2026-03-14

### Added

- Allow archiving public posts without login

## [1.0.0+alpha.6] - 2026-03-13

### Added

- Multilingual Privacy Policy pages for GitHub Pages
- Support URL, marketing URL, and copyright to App Store metadata
- Custom domain patronarchiver.sinoru.dev for GitHub Pages

### Fixed

- Patreon media extraction collecting comment images on text-only posts
- SubscribeStar.adult post title parsing for non-heading titles

### Changed

- Moved ITSAppUsesNonExemptEncryption to target level and allow arbitrary loads
- Shortened App Store subtitle and promotional text to meet character limits
- Removed direct service name mentions from App Store subtitle and description

## [1.0.0+alpha.5] - 2026-03-11

### Changed

- Merged preloading status into loading with granular progress
- Consolidated URLSession management and absorbed LoginChecker into PatronArchiver

### Removed

- BGContinuedProcessingTask due to incompatibility with WKWebView background rendering

## [1.0.0+alpha.4] - 2026-03-10

### Fixed

- pixivFANBOX posts not loading all comments

## [1.0.0+alpha.3] - 2026-03-10

### Changed

- Moved platform build settings (deployment targets, SDKROOT, supported platforms) to project level
- Added app category (Utilities) and explicit code sign identity

## [1.0.0+alpha.2] - 2026-03-10

### Changed

- Set ITSAppUsesNonExemptEncryption to NO in build settings

## [1.0.0+alpha.1] - 2026-03-10

### Added

- pixivFANBOX provider support
- Patreon provider support
- SubscribeStar.adult provider support
- MHTML archiving with RFC 2557 compliance
- PDF export
- Media file downloads with concurrent processing
- Lazy content loading via scroll-based IntersectionObserver triggering
- iOS background task support with BGContinuedProcessingTask
- URL redirect resolution before enqueueing
- Per-file progress tracking for media downloads
- Where Froms and Finder Tags xattr metadata options
- Overwrite confirmation for existing post folders
- Content dates metadata on post folders
- Service folder in save path structure
- String Catalog localization support
- App icon for Icon Composer
- iOS Files app access to Documents directory
- App Store metadata document
- Test plan and UI tests
- GitHub funding configuration

### Fixed

- Cookie domain matching with dot-boundary validation per RFC 6265
- Content-Disposition filename parsing to remove trailing quotes
- Preloader scroll not awaited by callAsyncJavaScript
- iOS render window covering app UI
- RedirectTracker to only track main frame navigations
- Race condition between jobs by awaiting about:blank load completion
- Fanbox date parsing and job row display
- Swift concurrency warnings across codebase

### Changed

- Redesigned UI with NavigationStack, toolbar URL input, and HIG-compliant interactions
- Extracted core logic into PatronArchiverKit Swift package
- Encoded MHTML Subject header with RFC 2047 B-encoding
- Used WKWebView desktop User-Agent for URLSession resource downloads
- Replaced JSON stringify/parse roundtrip with native WKWebView object bridging
- Used Data instead of String for MHTML assembly and QP encoding
- Embedded LazyContentLoader.js via SPM resources
- Adopted Swift 6.0 strict concurrency with MainActor isolation
- Replaced glob-based URL matching with Swift Regex

[Unreleased]: https://github.com/shizukusoft/PatronArchiver/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/shizukusoft/PatronArchiver/compare/v1.1...v1.1.1
[1.1]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+rc.3...v1.1
[1.0.0+rc.3]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+rc.2...v1.0.0+rc.3
[1.0.0+rc.2]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+rc.1...v1.0.0+rc.2
[1.0.0+rc.1]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.7...v1.0.0+rc.1
[1.0.0+alpha.7]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.6...v1.0.0+alpha.7
[1.0.0+alpha.6]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.5...v1.0.0+alpha.6
[1.0.0+alpha.5]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.4...v1.0.0+alpha.5
[1.0.0+alpha.4]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.3...v1.0.0+alpha.4
[1.0.0+alpha.3]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.2...v1.0.0+alpha.3
[1.0.0+alpha.2]: https://github.com/shizukusoft/PatronArchiver/compare/v1.0.0+alpha.1...v1.0.0+alpha.2
[1.0.0+alpha.1]: https://github.com/shizukusoft/PatronArchiver/releases/tag/v1.0.0+alpha.1
