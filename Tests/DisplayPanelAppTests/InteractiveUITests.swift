import Foundation
import XCTest

/// Native windows, menus and sheets require an explicit opt-in, even with fake displays.
func requireInteractiveUI(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard environment["DISPLAYPANEL_TEST_INTERACTIVE_UI"] == "1" else {
        throw XCTSkip("Native UI test: set DISPLAYPANEL_TEST_INTERACTIVE_UI=1 and select the relevant test with --filter.")
    }
}

final class InteractiveUITestGateTests: XCTestCase {
    func testDefaultAndNonExplicitValuesSkipBeforeRunningUI() {
        for environment in [[:], ["DISPLAYPANEL_TEST_INTERACTIVE_UI": "0"],
                            ["DISPLAYPANEL_TEST_INTERACTIVE_UI": "true"],
                            ["CI": "true"], ["DISPLAYPANEL_SETTINGS_FIXTURE_OUTPUT": "/tmp/fixture"]] {
            XCTAssertThrowsError(try requireInteractiveUI(environment: environment)) { error in
                XCTAssertTrue(error is XCTSkip)
            }
        }
    }

    func testExplicitOptInAllowsTestBodyWithoutPresentingUIHere() {
        XCTAssertNoThrow(try requireInteractiveUI(environment: ["DISPLAYPANEL_TEST_INTERACTIVE_UI": "1"]))
    }
}
