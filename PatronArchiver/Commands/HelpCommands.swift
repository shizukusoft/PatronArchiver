import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

struct HelpCommands: Commands {
    @FocusedValue(\.showTipJarSheet) private var showTipJarSheet: Binding<Bool>?
    #if os(iOS)
    @FocusedValue(\.showMailCompose) private var showMailCompose: Binding<Bool>?
    #endif

    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Send Feedback...") {
                #if os(macOS)
                FeedbackMailComposer.composeWithSharingService()
                #elseif canImport(MessageUI)
                if MFMailComposeViewController.canSendMail() {
                    showMailCompose?.wrappedValue = true
                } else if let url = FeedbackMailComposer.mailtoURL {
                    openURL(url)
                }
                #else
                if let url = FeedbackMailComposer.mailtoURL {
                    openURL(url)
                }
                #endif
            }
            #if os(iOS)
            .disabled(showMailCompose == nil)
            #endif

            Divider()

            Button("\(Text("Tip Jar"))...") {
                showTipJarSheet?.wrappedValue = true
            }
            .disabled(showTipJarSheet == nil)
        }
    }
}
