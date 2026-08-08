import PatronArchiverKit
import SwiftUI

/// The root view of a main window.
///
/// Owns the window-scoped ``PatronArchiver`` so each macOS window archives independently, and
/// cancels its in-flight jobs when the window closes — which releases the tasks' strong reference
/// to the archiver so it can deinitialize. Also owns the Tip Jar (and, on iOS, the mail compose)
/// sheet so a Help-menu command presents it on this window rather than on every open window.
struct MainWindow: View {
    @State private var archiver: PatronArchiver = {
        let archiver = PatronArchiver()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DemoMode") {
            archiver.loadDemoJobs()
        }
        #endif
        return archiver
    }()

    @State private var showTipJarSheet = false
    #if os(iOS)
    @State private var showMailCompose = false
    #endif

    var body: some View {
        MainView(archiver: archiver)
            .onDisappear {
                archiver.cancelAllJobs()
            }
            .sheet(isPresented: $showTipJarSheet) {
                TipJarSheet()
            }
            #if os(iOS)
            .sheet(isPresented: $showMailCompose) {
                MailComposeView()
            }
            #endif
            .focusedSceneValue(\.showTipJarSheet, $showTipJarSheet)
            #if os(iOS)
            .focusedSceneValue(\.showMailCompose, $showMailCompose)
            #endif
    }
}
