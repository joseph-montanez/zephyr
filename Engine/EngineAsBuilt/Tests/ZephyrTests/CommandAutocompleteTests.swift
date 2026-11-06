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

    func testUndoRedoAreDiscoverableCommands() {
        // UNDO/REDO are registered one-shot commands, not shortcut-only, so
        // users who don't know Cmd/Ctrl+Z can type them (AutoCAD parity).
        let processor = CADCommandProcessor()

        XCTAssertEqual(processor.matchCommands(input: "UNDO").first?.descriptor.canonicalName, "UNDO")
        XCTAssertEqual(processor.matchCommands(input: "U").first?.descriptor.canonicalName, "UNDO")
        XCTAssertEqual(processor.matchCommands(input: "REDO").first?.descriptor.canonicalName, "REDO")

        let undo = CommandDescriptor.allCommands.first { $0.canonicalName == "UNDO" }
        XCTAssertEqual(undo?.aliases, ["U"])
        XCTAssertEqual(undo?.syntax, "[<count>]")
        XCTAssertEqual(undo?.category, .modify)

        let redo = CommandDescriptor.allCommands.first { $0.canonicalName == "REDO" }
        XCTAssertEqual(redo?.syntax, "[<count>]")
    }

    func testAutoContrastIsDiscoverableCommand() {
        let processor = CADCommandProcessor()

        XCTAssertEqual(processor.matchCommands(input: "AUTOCONTRAST").first?.descriptor.canonicalName, "AUTOCONTRAST")
        XCTAssertEqual(processor.matchCommands(input: "AUTO").first?.descriptor.canonicalName, "AUTOCONTRAST")
        XCTAssertEqual(processor.matchCommands(input: "CONTRAST").first?.descriptor.canonicalName, "AUTOCONTRAST")
        XCTAssertEqual(processor.matchCommands(input: "TRUECOLORCONTRAST").first?.descriptor.canonicalName, "AUTOCONTRAST")

        let desc = CommandDescriptor.allCommands.first { $0.canonicalName == "AUTOCONTRAST" }
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.aliases, ["CONTRAST", "TRUECOLORCONTRAST"])
        XCTAssertEqual(desc?.syntax, "[ON|OFF]")
        XCTAssertEqual(desc?.category, .settings)
    }
}
