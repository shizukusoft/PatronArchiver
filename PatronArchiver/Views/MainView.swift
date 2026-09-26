import PatronArchiverKit
import SwiftUI
import UserDefaultsKit
#if canImport(AppKit)
import AppKit
#endif

struct MainView: View {
    private let archiver: PatronArchiver

    @State private var urlText = ""
    @State private var isResolving = false
    #if os(iOS)
    @State private var showSettings = false
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Width of the add button, measured so the URL field can fill the rest of
    /// the bottom bar.
    @State private var addButtonWidth: CGFloat = 0
    #endif
    @State private var windowWidth: CGFloat = 0

    /// Observed rather than read from ``AppSettings`` at the point of use: a static read registers
    /// no SwiftUI dependency, so a Render Width change in Settings would leave this window's web
    /// view at the old size until some unrelated state happened to invalidate the view.
    @UserDefaultStorage(AppSettings.renderWidth.key)
    private var renderWidth = AppSettings.renderWidth.defaultValue

    private var renderSize: CGSize {
        AppSettings.renderSize(forWidth: renderWidth)
    }

    init(archiver: PatronArchiver) {
        self.archiver = archiver
    }

    @ViewBuilder
    private var urlTextField: some View {
        TextField("Enter post URL...", text: $urlText)
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("urlInput")
            .onSubmit { Task { await submitURL() } }
    }

    /// The URL field and add button as they sit in the center of the top
    /// toolbar, in a regular-width window.
    private var addressBar: some View {
        HStack(spacing: 8) {
            urlTextField
                #if os(macOS)
                .textFieldStyle(.plain)
                #endif
                .frame(width: addressFieldWidth)
            addButton
        }
        .padding(.horizontal)
        #if os(iOS)
        // The top bar gives its principal item no background of its own, so
        // draw the capsule the bottom bar puts around the same controls in a
        // compact window. 44pt is the HIG's default control size on iOS,
        // which the bar's own buttons also meet.
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive())
        #endif
    }

    @ViewBuilder
    private var addButton: some View {
        if isResolving {
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
        } else {
            Button { Task { await submitURL() } } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text("Add"))
            .accessibilityIdentifier("addButton")
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var openFolderButton: some View {
        Button {
            openSaveLocation()
        } label: {
            Image(systemName: "folder")
        }
        .accessibilityLabel(Text("Open Save Folder"))
        .accessibilityIdentifier("openFolderButton")
    }

    #if os(iOS)
    /// Distance from the window edge to the bottom bar's content: the bar's
    /// margin outside its capsule plus the capsule's padding. Measured on
    /// iOS 26.5 and 27.0, where the system lays these out identically.
    private static let bottomBarContentInset: CGFloat = 34
    /// Spacing the bottom bar puts between the URL field and the add button.
    private static let bottomBarItemSpacing: CGFloat = 14
    #endif

    /// Width for the toolbar URL field, derived from the window width so the
    /// field grows and shrinks as the window is resized. SwiftUI's toolbar does
    /// not stretch an item to fill (the iOS 27 bottom bar sizes it to its text),
    /// so we size it from measured geometry.
    private var addressFieldWidth: CGFloat {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            // Fill what the add button leaves, so the bottom bar spans the
            // width as it did on iOS 26.
            return max(windowWidth - 2 * Self.bottomBarContentInset - Self.bottomBarItemSpacing - addButtonWidth, 0)
        }
        #endif
        // Size the field to a fraction of the window so the side margins
        // scale with it; clamp to keep the add button visible at the minimum
        // width and avoid an over-wide field.
        return min(max(windowWidth * 0.4, 220), 700)
    }

    var body: some View {
        NavigationStack {
            JobListView(archiver: archiver)
                .background {
                    archiveWebViewArea
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    windowWidth = width
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityIdentifier("settingsButton")
                    }
                    // A compact window keeps the field within thumb reach at the
                    // bottom; a regular one centers it at the top, as on macOS.
                    if horizontalSizeClass == .compact {
                        ToolbarItemGroup(placement: .bottomBar) {
                            urlTextField
                                .frame(width: addressFieldWidth)
                            addButton
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.size.width
                                } action: { width in
                                    addButtonWidth = width
                                }
                        }
                    } else {
                        ToolbarItem(placement: .principal) {
                            addressBar
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        openFolderButton
                    }
                    #else
                    ToolbarItem(placement: .principal) {
                        addressBar
                    }
                    ToolbarItem(placement: .primaryAction) {
                        openFolderButton
                    }
                    #endif
                }
                #if os(macOS)
                .toolbar(removing: .title)
                #endif
                #if os(iOS)
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showSettings = false
                                    }
                                }
                            }
                    }
                }
                #endif
        }
    }

    @ViewBuilder
    private var archiveWebViewArea: some View {
        ArchiveWebViewRepresentable(webView: archiver.webView)
            .frame(width: renderSize.width, height: renderSize.height)
            .scaleEffect(
                1.0 / max(renderSize.width, renderSize.height),
                anchor: .topLeading
            )
            .frame(width: 1, height: 1, alignment: .topLeading)
            .opacity(0.01)
            .allowsHitTesting(false)
    }

    private func submitURL() async {
        let urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inputURL = URL(string: urlString), inputURL.scheme != nil else { return }

        isResolving = true
        defer { isResolving = false }

        let resolved = await inputURL.resolvingRedirects(using: PatronArchiver.urlSession)

        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return }

        archiver.enqueue(url: url)
        urlText = ""
    }

    /// Opens the current save location in Finder (macOS) or the Files app (iOS).
    private func openSaveLocation() {
        let url = AppSettings.resolveBaseDirectory()
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        let path = url.path(percentEncoded: false)
        if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let sharedURL = URL(string: "shareddocuments://\(encoded)") {
            openURL(sharedURL)
        }
        #endif
    }
}
