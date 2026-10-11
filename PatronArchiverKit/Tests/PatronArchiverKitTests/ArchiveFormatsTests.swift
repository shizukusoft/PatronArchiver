import Foundation
import Testing
@testable import PatronArchiverKit

struct ArchiveFormatsTests {
    /// The setting is persisted as this integer, so the encoding — a bare number, not a keyed
    /// `{"rawValue": …}` container — and the bit assignments are both part of the stored format.
    @Test func encodesAsBareInteger() throws {
        let formats: ArchiveFormats = [.webArchive, .pdf]
        let data = try JSONEncoder().encode(formats)
        #expect(String(decoding: data, as: UTF8.self) == "5")

        let decoded = try JSONDecoder().decode(ArchiveFormats.self, from: data)
        #expect(decoded == formats)
    }

    @Test func bitAssignmentsAreStable() {
        #expect(ArchiveFormats.webArchive.rawValue == 1)
        #expect(ArchiveFormats.mhtml.rawValue == 2)
        #expect(ArchiveFormats.pdf.rawValue == 4)
    }

    @Test func defaultIsWebArchiveAndPDF() {
        #expect(AppSettings.archiveFormats.defaultValue == [.webArchive, .pdf])
    }
}
