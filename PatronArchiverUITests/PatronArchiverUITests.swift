import XCTest

final class PatronArchiverUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launch()
        app.activate()
    }

    @MainActor
    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testURLInputFieldExists() throws {
        let textField = app.textFields["urlInput"]
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddButtonExists() throws {
        let button = app.buttons["addButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyStateShowsNoJobs() throws {
        let emptyState = app.descendants(matching: .any)["emptyState"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
    }
}
