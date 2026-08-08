import PatronArchiverKit
import SwiftUI
import UniformTypeIdentifiers
import UserDefaultsKit
import WebKit
#if canImport(MessageUI)
import MessageUI
#endif

struct SettingsView: View {
    @UserDefaultStorage(AppSettings.renderWidth.key)
    private var renderWidth = AppSettings.renderWidth.defaultValue

    @UserDefaultStorage(AppSettings.scrollDelay.key)
    private var scrollDelay = AppSettings.scrollDelay.defaultValue

    @UserDefaultStorage(AppSettings.savedDirectoryBookmark.key)
    private var savedDirectoryBookmark = AppSettings.savedDirectoryBookmark.defaultValue

    @UserDefaultStorage(AppSettings.includesWhereFroms.key)
    private var includesWhereFroms = AppSettings.includesWhereFroms.defaultValue

    @UserDefaultStorage(AppSettings.includesFinderTags.key)
    private var includesFinderTags = AppSettings.includesFinderTags.defaultValue

    @UserDefaultStorage(AppSettings.includesContentDates.key)
    private var includesContentDates = AppSettings.includesContentDates.defaultValue

    @State private var verificationWebViews: [String: WKWebView] = [:]
    @State private var isPickingFolder = false
    @State private var loginEntry: SiteEntry?
    @State private var accountStatuses: [String: AccountStatus] = [:]

    #if os(iOS)
    @Environment(\.openURL) private var openURL
    @State private var showMailCompose = false
    #endif

    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private var renderSize: CGSize {
        CGSize(width: CGFloat(renderWidth), height: 1080)
    }

    private var siteEntries: [SiteEntry] {
        PatronServiceManager.userVisibleProviderTypes.map { providerType in
            SiteEntry(
                identifier: providerType.siteIdentifier,
                loginURL: providerType.loginURL,
                providerType: providerType
            )
        }
    }

    @ViewBuilder
    private var verificationWebViewArea: some View {
        ZStack {
            ForEach(verificationWebViews.keys.sorted(), id: \.self) { identifier in
                if let webView = verificationWebViews[identifier] {
                    ArchiveWebViewRepresentable(webView: webView)
                        .frame(width: renderSize.width, height: renderSize.height)
                        .scaleEffect(
                            1.0 / max(renderSize.width, renderSize.height),
                            anchor: .topLeading
                        )
                        .frame(width: 1, height: 1, alignment: .topLeading)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(siteEntries) { entry in
                    let status = accountStatuses[entry.identifier] ?? .unknown
                    HStack {
                        Label(entry.identifier, systemImage: "globe")
                        Spacer()
                        switch status {
                        case .unknown, .verifying:
                            ProgressView()
                                #if os(macOS)
                                .controlSize(.small)
                                #endif
                        case .notSignedIn:
                            Text("Not signed in")
                                .foregroundStyle(.tertiary)
                        case .verified(let info):
                            Text(info.displayName)
                                .foregroundStyle(.secondary)
                        case .verificationFailed:
                            Text("Verification failed")
                                .foregroundStyle(.red)
                        }
                        switch status {
                        case .notSignedIn:
                            Button("Sign In") {
                                loginEntry = entry
                            }
                        case .verified, .verificationFailed, .verifying:
                            Button("Sign Out") {
                                Task {
                                    await logout(for: entry)
                                }
                            }
                        case .unknown:
                            EmptyView()
                        }
                    }
                }
            }

            Section("Rendering") {
                Stepper(
                    "Render Width: \(renderWidth)px",
                    value: $renderWidth,
                    in: 800...3840,
                    step: 160
                )

                HStack {
                    Text("Scroll Delay")
                    Spacer()
                    TextField("ms", value: $scrollDelay, format: .number)
                        .frame(width: 80)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    Text("ms")
                }
            }

            Section("Metadata") {
                Toggle("Where Froms", isOn: $includesWhereFroms)
                Toggle("Finder Tags", isOn: $includesFinderTags)
                Toggle("Content Dates", isOn: $includesContentDates)
            }

            Section("Storage") {
                HStack {
                    Text("Save Location")
                    Spacer()
                    if let bookmark = savedDirectoryBookmark,
                       let url = try? {
                        var isStale = false
                        return try URL(
                            resolvingBookmarkData: bookmark,
                            options: Self.bookmarkResolutionOptions,
                            bookmarkDataIsStale: &isStale
                        )
                       }() {
                        Text(url.lastPathComponent)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Default")
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Choose Folder...") {
                    isPickingFolder = true
                }
                .fileImporter(
                    isPresented: $isPickingFolder,
                    allowedContentTypes: [.folder]
                ) { result in
                    if case .success(let url) = result {
                        savedDirectoryBookmark = try? url.bookmarkData(
                            options: Self.bookmarkCreationOptions,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                    }
                }

                if savedDirectoryBookmark != nil {
                    Button("Reset to Default") {
                        savedDirectoryBookmark = nil
                    }
                }
            }

            #if os(iOS)
            Section("Support") {
                TipJarView()
            }

            Section("Feedback") {
                Button("Send Feedback...") {
                    if MFMailComposeViewController.canSendMail() {
                        showMailCompose = true
                    } else if let url = FeedbackMailComposer.mailtoURL {
                        openURL(url)
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .background {
            verificationWebViewArea
        }
        #if os(macOS)
        .frame(width: 450)
        .padding()
        #endif
        .task {
            await checkAllLoginStatus()
        }
        .onDisappear {
            for status in accountStatuses.values {
                if case .verifying(let task) = status {
                    task.cancel()
                }
            }
        }
        .sheet(item: $loginEntry) { entry in
            NavigationStack {
                LoginWebView(
                    url: entry.loginURL,
                    providerType: entry.providerType,
                    websiteDataStore: PatronArchiver.websiteDataStore,
                    onLoginDetected: {
                        loginEntry = nil
                    }
                )
                .navigationTitle("Sign In")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            loginEntry = nil
                        }
                    }
                }
            }
            #if os(macOS)
            .frame(width: 800, height: 600)
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showMailCompose) {
            MailComposeView()
        }
        #endif
        .onChange(of: loginEntry) { oldValue, newValue in
            if newValue == nil, let closedEntry = oldValue {
                Task {
                    // Brief delay to allow cookies to propagate
                    try? await Task.sleep(for: .milliseconds(500))
                    await checkLoginStatus(for: closedEntry.providerType)
                }
            }
        }
    }

    private func checkAllLoginStatus() async {
        let providerTypes = PatronServiceManager.userVisibleProviderTypes

        // 1. Fast cookie-based login check (concurrent)
        await withTaskGroup(of: (String, Bool).self) { group in
            for providerType in providerTypes {
                let identifier = providerType.siteIdentifier
                group.addTask {
                    let loggedIn = await PatronArchiver.isLoggedIn(for: providerType)
                    return (identifier, loggedIn)
                }
            }
            for await (identifier, loggedIn) in group {
                if !loggedIn {
                    accountStatuses[identifier] = .notSignedIn
                }
            }
        }

        // 2. Verify logged-in providers (concurrent, fresh WKWebView per provider).
        for providerType in providerTypes {
            let identifier = providerType.siteIdentifier
            if case .notSignedIn = accountStatuses[identifier] ?? .unknown { continue }
            verify(providerType)
        }
    }

    private func verify(_ providerType: any PatronServiceProviding.Type) {
        let identifier = providerType.siteIdentifier

        if case .verifying(let oldTask) = accountStatuses[identifier] {
            oldTask.cancel()
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PatronArchiver.websiteDataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: renderSize),
            configuration: configuration
        )
        verificationWebViews[identifier] = webView

        let task = Task {
            defer {
                if verificationWebViews[identifier] === webView {
                    verificationWebViews[identifier] = nil
                }
            }

            // WKWebView only renders when attached to the window — wait for layout. Without an
            // attachment the account page never renders, so report failure instead of asking for
            // account info the provider could not possibly extract.
            guard await webView.waitUntilAttached() else {
                if !Task.isCancelled {
                    accountStatuses[identifier] = .verificationFailed
                }
                return
            }

            let info = await PatronArchiver.fetchAccountInfo(
                for: providerType,
                in: webView
            )
            if !Task.isCancelled {
                accountStatuses[identifier] = info.map(AccountStatus.verified) ?? .verificationFailed
            }
        }
        accountStatuses[identifier] = .verifying(task)
    }

    private func logout(for entry: SiteEntry) async {
        if case .verifying(let task) = accountStatuses[entry.identifier] {
            task.cancel()
        }

        var hostsToClear: Set<String> = []
        if let host = entry.loginURL.host() {
            hostsToClear.insert(host)
        }
        if let alternate = entry.providerType.alternateProviderType,
           let host = alternate.loginURL.host() {
            hostsToClear.insert(host)
        }

        let cookieStore = PatronArchiver.websiteDataStore.httpCookieStore
        let allCookies = await cookieStore.allCookies()

        for cookie in allCookies where hostsToClear.contains(where: { Self.cookie(cookie, matches: $0) }) {
            await cookieStore.deleteCookie(cookie)
        }

        accountStatuses[entry.identifier] = .notSignedIn
    }

    private static func cookie(_ cookie: HTTPCookie, matches host: String) -> Bool {
        if cookie.domain.hasPrefix(".") {
            let domain = String(cookie.domain.dropFirst())
            return host == domain || host.hasSuffix("." + domain)
        }
        return host == cookie.domain
    }

    private func checkLoginStatus(for providerType: any PatronServiceProviding.Type) async {
        let identifier = providerType.siteIdentifier

        let loggedIn = await PatronArchiver.isLoggedIn(for: providerType)
        guard loggedIn else {
            if case .verifying(let task) = accountStatuses[identifier] {
                task.cancel()
            }
            accountStatuses[identifier] = .notSignedIn
            return
        }

        verify(providerType)
    }
}

private struct SiteEntry: Identifiable, Equatable {
    let identifier: String
    let loginURL: URL
    let providerType: any PatronServiceProviding.Type
    var id: String { identifier }

    static func == (lhs: SiteEntry, rhs: SiteEntry) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

private enum AccountStatus {
    case unknown
    case notSignedIn
    case verifying(Task<Void, Never>)
    case verified(AccountInfo)
    case verificationFailed
}
