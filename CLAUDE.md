# PatronArchiver

> User-facing project intro: see [README.md](README.md).

## Absolute Principles

### Non-invasive DOM

**The most important principle.** Do not directly modify the page's HTML/DOM.

- Setting `img.src` directly, or changing CSS classes / `style` attributes, is forbidden. Instead, drive the site's own JS state transitions by scrolling via `LazyContentLoader`.
- DOM **reads** (querySelector, getComputedStyle, outerHTML) are allowed.
- The only exception: minimal, unavoidable mutations required for MHTML serialization. Allowed scope:
  1. **Mutable stylesheet reconstruction**: When styled-components and similar libraries mutate the CSSOM at runtime, `style.textContent` (the original) diverges from `sheet.cssRules` (what's actually applied). Without replacing with `cssRules` before the `outerHTML` capture, styles will break in the resulting MHTML.
  2. **Adopted stylesheet injection**: `document.adoptedStyleSheets` does not exist in the DOM, so it is not included in `outerHTML`. It must be injected as a `<style>` element to be captured.
  3. **`</style>` escaping**: If a `</style` sequence appears inside a `<style>` element, the HTML parser will misidentify the tag boundary. It must be replaced with the CSS hex escape (`\3C`).
- **Chromium validation reference** (`third_party/blink/renderer/core/frame/frame_serializer.cc`):
  - Chrome performs the same three operations. The difference is that Blink uses internal APIs (`IsMutable()`, `CSSRule::cssText()`), whereas we compare the CSSOM directly from JS.
  - Chrome comment: *"CSS serialization isn't perfect, it's better to leave the original `<style>` element if possible"* (L689) — reconstructing via `cssText` loses comments, whitespace, shorthand, etc., so selectively reconstructing only the JS-mutated stylesheets is the best approach.
  - Chrome comment: *"this process is lossy, and may not perfectly reflect the intended style"* (L1118) — acknowledges the inherent limits of CSS serialization.
  - `</style>` escaping uses the same form as Chrome (`\3C/style`, case-insensitive).
  - The mutable-only selective reconstruction is gated behind the `kMHTML_Improvements` feature flag (disabled by default). Currently shipping Chrome (legacy) reconstructs every `<style>` via `cssText`, so our "reconstruct only what changed" approach aligns with Chrome's improvement direction.

### LazyContentLoader ↔ dumper responsibility boundary

Bringing content to a fully loaded state is **the responsibility of `LazyContentLoader` (`WKWebView.loadLazyContent`)**. Page dumpers (MHTML, PDF) only capture the current DOM as-is. Do not try to solve loading issues inside the dumpers.

### No third-party dependencies

Use only Apple-bundled frameworks (Foundation, WebKit, SwiftUI, etc.) plus packages published under `github.com/apple/*` or `github.com/swiftlang/*` (treated as first-party Apple/Swift ecosystem). No other dependencies.

## Standards & Verification

- MHTML (RFC 2557), Quoted-Printable (RFC 2045, including encoding of trailing whitespace/tabs at line ends), Date header (RFC 2822). When in doubt, do not guess — search and verify.
- Verify MHTML quality by comparing against **Chrome's "Save as" output** for the same page: number of resource parts, encoding methods, and rendered result.

## Gotchas

- `WKWebView` only renders when attached to a view hierarchy. It is currently displayed via SwiftUI's `ArchiveWebViewRepresentable`; wait for `window != nil` before proceeding.
- `WKHTTPCookieStore` ↔ `HTTPCookieStorage` are not synchronized automatically → set cookies manually via `WKWebsiteDataStore.urlRequest(for:)`.
- Fast scrolling causes lazy-load misses. `LazyContentLoader` must scroll incrementally in 50%-of-viewport steps so that IntersectionObserver fires correctly.
- `callAsyncJavaScript` wraps the script in an async function body, so top-level `await` is usable. Wrapping it again in an async IIFE means no Promise is returned and the call completes immediately.
- In styled-components environments, use partial-match selectors like `[class*="PostTitle"]` (class names change every build).
- iOS background tasks are not implemented; `BGContinuedProcessingTask` was attempted but removed (1.0.0+alpha.5) due to WKWebView's lack of background rendering support.

## App Store Metadata

- In all App Store metadata other than Promotional Text and Keywords (Subtitle, Description, etc.), do not directly mention specific service names (Patreon, pixivFANBOX, SubscribeStar.adult, etc.).

## Code Conventions

- Type-dependent functionality → `extension` (e.g., `WKWebView.mhtml(dataStore:)`)
- Independent utilities → place as `static func` on the related class/struct
- Common protocol helpers → default implementation in a protocol extension
- Synchronous JS scripts (`evaluateJavaScript`) are wrapped in an IIFE to avoid global pollution
- Logging: `OSLog` `Logger`, subsystem `com.shizukusoft.PatronArchiver`, mark personal data as `.private`
