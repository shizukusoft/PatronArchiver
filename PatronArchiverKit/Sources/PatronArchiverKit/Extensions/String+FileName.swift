import Foundation

extension String {
    private static let maxFileNameBytes = 255

    /// The receiver made safe for use as a single path component, or `nil` if nothing usable
    /// remains.
    ///
    /// Replaces the path separator and the Finder-visible colon, drops NUL, trims surrounding
    /// whitespace, and truncates the stem so the whole name fits the file system's 255-byte limit
    /// while keeping the extension intact.
    func sanitizedFileName() -> String? {
        var sanitized = self
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "\\")
            .replacingOccurrences(of: "\0", with: "")

        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.isEmpty {
            return nil
        }

        // Split into stem and extension at the last "."
        let stem: String
        let ext: String
        if let dotIndex = sanitized.lastIndex(of: "."), dotIndex != sanitized.startIndex {
            stem = String(sanitized[..<dotIndex])
            ext = String(sanitized[dotIndex...]) // includes the "."
        } else {
            stem = sanitized
            ext = ""
        }

        let extBytes = ext.utf8.count
        let maxStemBytes = Self.maxFileNameBytes - extBytes

        if stem.utf8.count > maxStemBytes {
            var truncated = stem
            while truncated.utf8.count > maxStemBytes {
                truncated.removeLast()
            }
            truncated = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
            if truncated.isEmpty { return nil }
            return truncated + ext
        }

        return sanitized
    }
}
