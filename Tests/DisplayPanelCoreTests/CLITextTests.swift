import XCTest
@testable import DisplayPanelCore

final class CLITextTests: XCTestCase {
    func testJSONDataIsPrettyPrintedAndSorted() throws {
        let data = try CLIText.jsonData(Values(z: 2, a: 1))

        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "{\n  \"a\" : 1,\n  \"z\" : 2\n}"
        )
    }

    private struct Values: Encodable {
        let z: Int
        let a: Int
    }
}
