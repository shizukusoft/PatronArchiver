import PatronArchiverKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PatronArchiverApp: App {
    #if DEBUG
    static var isDemoMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoMode")
    }
    #endif

    @State
    private var transactionObserver = TransactionObserver()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                #if os(macOS)
                #if DEBUG
                // 848 = 900 (target window height) - 52 (unified title bar + toolbar chrome)
                .frame(
                    minWidth: Self.isDemoMode ? 1440 : 635,
                    maxWidth: Self.isDemoMode ? 1440 : nil,
                    minHeight: Self.isDemoMode ? 848 : 400,
                    maxHeight: Self.isDemoMode ? 848 : nil
                )
                .task {
                    if Self.isDemoMode {
                        guard let window = NSApp.keyWindow, let screen = window.screen else { return }
                        window.setFrameTopLeftPoint(
                            NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY)
                        )
                    }
                }
                #else
                .frame(
                    minWidth: 635,
                    minHeight: 400
                )
                #endif
                #endif
        }
        .commands {
            HelpCommands()
        }
        #if os(macOS)
        #if DEBUG
        .defaultSize(
            width: Self.isDemoMode ? 1440 : 635,
            height: Self.isDemoMode ? 848 : 400
        )
        .defaultPosition(.topLeading)
        #else
        .defaultSize(
            width: 635,
            height: 400
        )
        #endif
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
