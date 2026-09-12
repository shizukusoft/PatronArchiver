import Testing
@testable import PatronArchiverKit

struct StringFileNameTests {
    @Test func sanitizedFileNameReplacesSlash() {
        #expect("hello/world".sanitizedFileName() == "hello_world")
    }

    @Test func sanitizedFileNameReplacesColon() {
        #expect("2026-03-04 15:30".sanitizedFileName() == "2026-03-04 15\\30")
    }

    @Test func sanitizedFileNameReplacesSlashAndColon() {
        #expect("path/to:file".sanitizedFileName() == "path_to\\file")
    }

    @Test func sanitizedFileNameOfEmptyStringIsNil() {
        #expect("".sanitizedFileName() == nil)
    }

    @Test func sanitizedFileNameOfWhitespaceOnlyIsNil() {
        #expect("   ".sanitizedFileName() == nil)
    }

    @Test func sanitizedFileNameTruncatesLongNames() throws {
        let longName = String(repeating: "a", count: 300)
        let result = try #require(longName.sanitizedFileName())
        #expect(result.utf8.count <= 255)
    }

    @Test func sanitizedFileNameTruncatesLongStemPreservingExtension() throws {
        let longName = String(repeating: "a", count: 300) + ".mhtml"
        let result = try #require(longName.sanitizedFileName())
        #expect(result.utf8.count <= 255)
        #expect(result.hasSuffix(".mhtml"))
    }

    @Test func sanitizedFileNameTrimsWhitespace() {
        #expect("  hello  ".sanitizedFileName() == "hello")
    }

    @Test func sanitizedFileNamePreservesNormalCharacters() {
        #expect("my_file-name (1).txt".sanitizedFileName() == "my_file-name (1).txt")
    }
}
