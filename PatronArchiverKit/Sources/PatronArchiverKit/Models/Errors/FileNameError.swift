import Foundation

enum FileNameError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty:
            String(localized: "File name is empty after sanitization.", bundle: Bundle.module)
        }
    }
}
