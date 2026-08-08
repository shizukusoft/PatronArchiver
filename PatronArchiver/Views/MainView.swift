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
    #else
    /// Width for the toolbar URL field, derived from the window width so the
    /// field grows and shrinks as the window is resized. SwiftUI's toolbar does
    /// not stretch a principal item to fill, so we size it from measured geometry.
    @State private var addressFieldWidth: CGFloat = 280
    #endif

    /// Observed rather than read from ``AppSettings`` at the point of use: a static read registers
    /// no SwiftUI dependency, so a Render Width change in Settings would leave this window's web
    /// view at the old size until some unrelated state happened to invalidate the view.
    @UserDefaultStorage(AppSettings.renderWidth.key)
    private var renderWidth = AppSettings.renderWidth.defaultValue

    private var renderSize: CGSize {
        CGSize(width: CGFloat(renderWidth), height: 1080)
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

    var body: some View {
        NavigationStack {
            JobListView(archiver: archiver)
                .background {
                    archiveWebViewArea
                }
                #if os(macOS)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { windowWidth in
                    // Size the field to a fraction of the window so the side
                    // margins scale with it; clamp to keep the add button visible
                    // at the minimum width and avoid an over-wide field.
                    addressFieldWidth = min(max(windowWidth * 0.4, 220), 700)
                }
                #endif
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
                        addButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        openFolderButton
                    }
                    #else
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            urlTextField
                                .textFieldStyle(.roundedBorder)
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

        let resolved = await URLResolver.resolve(inputURL)

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
