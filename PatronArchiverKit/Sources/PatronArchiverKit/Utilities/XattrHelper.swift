import Foundation

enum XattrHelper {
    static func setWhereFroms(_ urls: [URL], on path: String) throws {
        let strings = urls.map(\.absoluteString)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: strings,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:kMDItemWhereFroms", to: plistData, on: path)
    }

    static func setContentDates(
        createdAt: Date,
        modifiedAt: Date?,
        on path: String
    ) throws {
        let creationData = try PropertyListSerialization.data(
            fromPropertyList: createdAt,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute(
            "com.apple.metadata:kMDItemContentCreationDate",
            to: creationData,
            on: path
        )

        if let modifiedAt {
            let modificationData = try PropertyListSerialization.data(
                fromPropertyList: modifiedAt,
                format: .binary,
                options: 0
            )
            try setExtendedAttribute(
                "com.apple.metadata:kMDItemContentModificationDate",
                to: modificationData,
                on: path
            )
        }
    }

    static func setUserTags(_ tags: [String], on path: String) throws {
        guard !tags.isEmpty else { return }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", to: plistData, on: path)
    }

    /// Writes a single extended attribute, bridging `Data` to the raw pointer pair `setxattr`
    /// expects.
    ///
    /// `setxattr` only borrows the buffer for the duration of the call, and `path`/`name` are
    /// bridged as null-terminated C strings that stay alive across it — hence the `unsafe`
    /// acknowledgements under strict memory safety.
    ///
    /// Named `setExtendedAttribute` rather than `setxattr` so the call below resolves to the C
    /// function instead of recursing into this one.
    private static func setExtendedAttribute(
        _ name: String,
        to data: Data,
        on path: String
    ) throws {
        let result = unsafe data.withUnsafeBytes { buffer in
            unsafe setxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
