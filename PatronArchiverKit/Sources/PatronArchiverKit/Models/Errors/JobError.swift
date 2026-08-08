import Foundation

enum JobError: LocalizedError {
    case unsupportedSite
    case overwriteDeclined
    case webViewNotAttached

    var errorDescription: String? {
        switch self {
        case .unsupportedSite:
            String(localized: "This site is not supported.", bundle: Bundle.module)
        case .overwriteDeclined:
            String(localized: "Replace declined by user.", bundle: Bundle.module)
        case .webViewNotAttached:
            String(localized: "Archiving could not start. Please try again.", bundle: Bundle.module)
        }
    }
}
