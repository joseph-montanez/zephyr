import XCTest
@testable import ZephyrCore

@MainActor
final class CommandAutocompleteTests: XCTestCase {

    func testExactShortAliasOutranksLongerPrefixAlias() {
        let matches = CADCommandProcessor().matchCommands(input: "E")

        XCTAssertEqual(matches.first?.descriptor.canonicalName, "ERASE")
        XCTAssertEqual(matches.first?.matchingAlias, "E")
    }

    func testExactLongerAliasWinsWhenFullyEntered() {
        let matches = CADCommandProcessor().matchCommands(input: "EXT")

        XCTAssertEqual(matches.first?.descriptor.canonicalName, "EXTENSION")
        XCTAssertEqual(matches.first?.matchingAlias, "EXT")
    }
}
