import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif
#if canImport(MessageUI)
import MessageUI
#endif
import SwiftUI

// MARK: - FeedbackMailComposer

struct FeedbackMailComposer {
    static let emailAddress = "support+PatronArchiver@shizukusoft.com"
    static let subject = "PatronArchiver Feedback"

    private static let logSubsystems = [
        "com.shizukusoft.PatronArchiver",
        "com.shizukusoft.PatronArchiver.PatronArchiverKit",
    ]

    static func diagnosticBody() -> String {
        let appVersion = Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"
        ] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?[
            "CFBundleVersion"
        ] as? String ?? "Unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        #if os(macOS)
        let platform = "macOS"
        #elseif os(iOS)
        let platform = UIDevice.current.userInterfaceIdiom == .pad
            ? "iPadOS" : "iOS"
        #else
        let platform = "Unknown"
        #endif

        return """

            ---
            App Version: \(appVersion) (\(buildNumber))
            Platform: \(platform)
            OS Version: \(osVersion)
            """
    }

    /// Collects recent log entries from the current process.
    static func collectLogData() -> Data? {
        guard let store = try? OSLogStore(
            scope: .currentProcessIdentifier
        ) else {
            return nil
        }

        let startDate = Date.now.addingTimeInterval(-30 * 60)
        let position = store.position(date: startDate)

        let subsystemPredicates = logSubsystems.map {
            NSPredicate(format: "subsystem == %@", $0)
        }
        let predicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: subsystemPredicates
        )

        guard let entries = try? store.getEntries(
            at: position,
            matching: predicate
        ) else {
            return nil
        }

        var lines: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let hostName = ProcessInfo.processInfo.hostName

        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }

            let timestamp = dateFormatter.string(from: logEntry.date)
            let process = logEntry.process
            let pid = logEntry.processIdentifier
            let sender = logEntry.sender
            let subsystem = logEntry.subsystem
            let category = logEntry.category
            let message = logEntry.composedMessage

            lines.append(
                "\(timestamp)  \(hostName) \(process)[\(pid)]:"
                    + " (\(sender))"
                    + " [\(subsystem):\(category)]"
                    + " \(message)"
            )
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n").data(using: .utf8)
    }

    static var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: diagnosticBody()),
        ]
        return components.url
    }

    #if os(macOS)
    static func composeWithSharingService() {
        guard let service = NSSharingService(named: .composeEmail) else {
            if let url = mailtoURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        service.recipients = [emailAddress]
        service.subject = subject

        var items: [Any] = [diagnosticBody()]
        if let logData = collectLogData() {
            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PatronArchiver-logs.log")
            if (try? logData.write(to: logURL)) != nil {
                items.append(logURL)
            }
        }
        service.perform(withItems: items)
    }
    #endif
}

// MARK: - MailComposeView (iOS)

#if os(iOS)
struct MailComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(
        context: Context
    ) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([FeedbackMailComposer.emailAddress])
        controller.setSubject(FeedbackMailComposer.subject)
        controller.setMessageBody(
            FeedbackMailComposer.diagnosticBody(),
            isHTML: false
        )
        if let logData = FeedbackMailComposer.collectLogData() {
            controller.addAttachmentData(
                logData,
                mimeType: "text/plain",
                fileName: "PatronArchiver-logs.log"
            )
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: MFMailComposeViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}
#endif
