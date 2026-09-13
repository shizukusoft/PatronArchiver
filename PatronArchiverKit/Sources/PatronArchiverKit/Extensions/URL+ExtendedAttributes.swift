import Foundation

extension URL {
    func setWhereFroms(_ urls: [URL]) throws {
        let strings = urls.map(\.absoluteString)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: strings,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:kMDItemWhereFroms", to: plistData)
    }

    func setContentDates(createdAt: Date, modifiedAt: Date?) throws {
        let creationData = try PropertyListSerialization.data(
            fromPropertyList: createdAt,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:kMDItemContentCreationDate", to: creationData)

        if let modifiedAt {
            let modificationData = try PropertyListSerialization.data(
                fromPropertyList: modifiedAt,
                format: .binary,
                options: 0
            )
            try setExtendedAttribute(
                "com.apple.metadata:kMDItemContentModificationDate",
                to: modificationData
            )
        }
    }

    func setUserTags(_ tags: [String]) throws {
        guard !tags.isEmpty else { return }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", to: plistData)
    }

    /// Writes a single extended attribute, bridging `Data` to the raw pointer pair `setxattr`
    /// expects.
    ///
    /// `setxattr` only borrows the buffer and the path for the duration of the call, and `name`
    /// is bridged as a null-terminated C string that stays alive across it — hence the `unsafe`
    /// acknowledgements under strict memory safety.
    ///
    /// Named `setExtendedAttribute` rather than `setxattr` so the call below resolves to the C
    /// function instead of recursing into this one.
    private func setExtendedAttribute(_ name: String, to data: Data) throws {
        let result = unsafe withUnsafeFileSystemRepresentation { path in
            unsafe data.withUnsafeBytes { buffer in
                unsafe setxattr(path, name, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
