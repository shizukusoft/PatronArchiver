import Testing
import Foundation
@testable import PatronArchiverKit

struct URLExtendedAttributesTests {
    @Test func setWhereFromsWritesPlistData() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("xattr_test_\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let urls = [URL(string: "https://example.com/page")!]
        try testFile.setWhereFroms(urls)

        // Verify xattr was set
        let bufferSize = unsafe getxattr(testFile.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        #expect(bufferSize > 0)
    }

    @Test func setUserTagsWritesPlistData() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("xattr_tag_test_\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        try testFile.setUserTags(["tag1", "tag2"])

        let bufferSize = unsafe getxattr(testFile.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
        #expect(bufferSize > 0)
    }

    @Test func setContentDatesWritesCreationDate() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("xattr_date_test_\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        try testFile.setContentDates(createdAt: createdAt, modifiedAt: nil)

        let bufferSize = unsafe getxattr(
            testFile.path,
            "com.apple.metadata:kMDItemContentCreationDate",
            nil,
            0,
            0,
            0
        )
        #expect(bufferSize > 0)

        let modBufferSize = unsafe getxattr(
            testFile.path,
            "com.apple.metadata:kMDItemContentModificationDate",
            nil,
            0,
            0,
            0
        )
        #expect(modBufferSize == -1)
    }

    @Test func setContentDatesWritesBothDates() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent(
            "xattr_both_dates_test_\(UUID().uuidString).txt"
        )
        try Data("test".utf8).write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let modifiedAt = Date(timeIntervalSince1970: 2_000_000)
        try testFile.setContentDates(createdAt: createdAt, modifiedAt: modifiedAt)

        let creationSize = unsafe getxattr(
            testFile.path,
            "com.apple.metadata:kMDItemContentCreationDate",
            nil,
            0,
            0,
            0
        )
        #expect(creationSize > 0)

        let modificationSize = unsafe getxattr(
            testFile.path,
            "com.apple.metadata:kMDItemContentModificationDate",
            nil,
            0,
            0,
            0
        )
        #expect(modificationSize > 0)
    }

    @Test func setUserTagsSkipsEmptyArray() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("xattr_empty_test_\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        try testFile.setUserTags([])

        let bufferSize = unsafe getxattr(testFile.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
        #expect(bufferSize == -1) // Not set
    }
}
