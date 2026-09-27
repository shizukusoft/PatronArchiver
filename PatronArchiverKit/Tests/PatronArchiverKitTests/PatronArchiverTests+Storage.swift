import Testing
import Foundation
@testable import PatronArchiverKit

extension PatronArchiverTests {
    @Test func postFolderURLFormatsCorrectly() throws {
        let metadata = PostMetadata(
            siteIdentifier: "Patreon",
            postID: "12345",
            title: "Test Post Title",
            authorName: "TestAuthor",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: nil,
            tags: [],
            originalURL: URL(string: "https://patreon.com/posts/12345")!,
            redirectChain: []
        )

        let baseDir = URL(filePath: "/tmp/test")
        let result = try PatronArchiver.postFolderURL(for: metadata, in: baseDir)

        let path = result.absoluteString.removingPercentEncoding ?? result.absoluteString
        #expect(path.contains("Patreon/TestAuthor"))
        #expect(path.contains("12345"))
        #expect(path.contains("Test Post Title"))
    }

    @Test func postFolderURLUsesModifiedDateWhenPresent() throws {
        let created = Date(timeIntervalSince1970: 0)
        let modified = Date(timeIntervalSince1970: 1_000_000)
        let metadata = PostMetadata(
            siteIdentifier: "pixivFANBOX",
            postID: "67890",
            title: "Modified Post",
            authorName: "Author",
            createdAt: created,
            modifiedAt: modified,
            tags: [],
            originalURL: URL(string: "https://example.fanbox.cc/@author/posts/67890")!,
            redirectChain: []
        )

        let baseDir = URL(filePath: "/tmp/test")
        let result = try PatronArchiver.postFolderURL(for: metadata, in: baseDir)

        // Should use modified date, not created date
        // 1970-01-12 for modified (epoch + 1_000_000 seconds)
        let path = result.absoluteString.removingPercentEncoding ?? result.absoluteString
        #expect(path.contains("1970"))
    }

    @Test func postFolderURLSanitizesCharacters() throws {
        let metadata = PostMetadata(
            siteIdentifier: "Patreon",
            postID: "99999",
            title: "Title/With:Special",
            authorName: "Author/Name",
            createdAt: Date(),
            modifiedAt: nil,
            tags: [],
            originalURL: URL(string: "https://patreon.com/posts/99999")!,
            redirectChain: []
        )

        let baseDir = URL(filePath: "/tmp/test")
        let result = try PatronArchiver.postFolderURL(for: metadata, in: baseDir)
        let lastComponent = result.lastPathComponent

        #expect(!lastComponent.contains("/"))
        #expect(!lastComponent.contains(":"))
    }

    /// A title that fits once `.pdf` is appended can still overflow with `.webarchive`, so the stem
    /// is cut against the longest extension in play — and shared by every page file.
    @Test func pageFileStemLeavesRoomForLongestExtension() throws {
        let title = String(repeating: "a", count: 250)
        let stem = try PatronArchiver.pageFileStem(for: title, fitting: ["pdf", "webarchive"])

        #expect("\(stem).webarchive".utf8.count == 255)
        #expect("\(stem).pdf".utf8.count <= 255)
    }

    @Test func pageFileStemCutsMultibyteTitleOnCharacterBoundary() throws {
        let title = String(repeating: "가", count: 100) // 300 bytes in UTF-8
        let stem = try PatronArchiver.pageFileStem(for: title, fitting: ["webarchive"])

        #expect("\(stem).webarchive".utf8.count <= 255)
        #expect(stem.allSatisfy { $0 == "가" })
    }

    @Test func pageFileStemKeepsShortTitle() throws {
        let stem = try PatronArchiver.pageFileStem(for: "  Short: Title  ", fitting: ["webarchive"])
        #expect(stem == "Short\\ Title")
    }
}
