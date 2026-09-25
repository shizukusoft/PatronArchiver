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
            .accessibilityIdentifier("urlInput")
            .onSubmit { Task { await submitURL() } }
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
        // Fill what the add button leaves, so the bar spans the width as it
        // did on iOS 26.
        max(windowWidth - 2 * Self.bottomBarContentInset - Self.bottomBarItemSpacing - addButtonWidth, 0)
        #else
        // Size the field to a fraction of the window so the side margins
        // scale with it; clamp to keep the add button visible at the minimum
        // width and avoid an over-wide field.
        min(max(windowWidth * 0.4, 220), 700)
        #endif
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
                .navigationTitle("PatronArchiver")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
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
                    ToolbarItemGroup(placement: .bottomBar) {
                        urlTextField
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .frame(width: addressFieldWidth)
                        addButton
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { width in
                                addButtonWidth = width
                            }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        openFolderButton
                    }
                    #else
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            urlTextField
                                .roundedTextFieldBorder()
                                .frame(width: addressFieldWidth)
                            addButton
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        openFolderButton
                    }
                    #endif
                }
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
