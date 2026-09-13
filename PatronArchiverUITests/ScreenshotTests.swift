import XCTest

final class ScreenshotTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchArguments.append("-DemoMode")
        app.launch()
        app.activate()

        #if os(macOS)
        // Workaround: macos-26-arm64 runner images >= 20260402 fail to
        // auto-present the WindowGroup's main window when XCTest launches
        // the app under runsForEachTargetApplicationUIConfiguration.
        // Force a new window via the standard ⌘N command.
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        #endif
    }

    @MainActor
    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testScreenshotMainView() {
        // Wait for app to fully launch
        let textField = app.textFields["urlInput"]
        XCTAssertTrue(textField.waitForExistence(timeout: 10))

        // Verify demo data loaded (empty state should not appear)
        XCTAssertFalse(app.descendants(matching: .any)["emptyState"].firstMatch.exists)

        let appAttachment = XCTAttachment(screenshot: app.screenshot())
        appAttachment.name = "App"
        appAttachment.lifetime = .keepAlways
        add(appAttachment)

        #if os(macOS)
        let window = app.windows["PatronArchiver"]
        let windowAttachment = XCTAttachment(screenshot: window.screenshot())
        windowAttachment.name = "PatronArchiver Window"
        windowAttachment.lifetime = .keepAlways
        add(windowAttachment)
        #endif
    }
}
