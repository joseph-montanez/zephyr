import XCTest
@testable import ZephyrCore

/// Command-surface tests for the Phase 2.4 parametric constraints slice:
/// the four commands must be discoverable through autocomplete (alias
/// table + descriptor synthesis, exactly like TABLE/MEASURE/CLIP were)
/// and must expose the same clickable option palettes every other
/// option-driven command shows in the command-line window.
///
/// Live `start()` behavior (opening the command line) needs a
/// `PhrostEngine`, which the test harness cannot construct, so these
/// tests pin everything up to that boundary: table rows, synthesized
/// descriptors, alias resolution, and option contents.
@MainActor
final class ConstraintCommandUITests: XCTestCase {

    /// Mirror of the runtime calls in `AppCommandRegistration`.
    private func registerConstraintCommands(on processor: CADCommandProcessor) {
        processor.registerFeatureCommand(
            name: "GEOMCONSTRAINT",
            aliases: ["GCON"],
            factory: { GeomconstraintCommand() }
        )
        processor.registerFeatureCommand(
            name: "DELCONSTRAINT",
            aliases: [],
            factory: { DelconstraintCommand() }
        )
        processor.registerFeatureCommand(
            name: "CONSTRAINTBAR",
            aliases: ["CBAR"],
            factory: { ConstraintbarCommand() }
        )
        processor.registerFeatureCommand(
            name: "AUTOCONSTRAIN",
            aliases: [],
            factory: { AutoconstrainCommand() }
        )
    }

    // MARK: - Alias table

    func testConstraintAliasTableRows() {
        for name in ["GEOMCONSTRAINT", "AUTOCONSTRAIN", "DELCONSTRAINT", "CONSTRAINTBAR"] {
            let row = CADCommandAliasTable.entry(canonicalName: name)
            XCTAssertNotNil(row, "\(name) needs an alias-table row for autocomplete")
            XCTAssertEqual(row?.category, .modify)
            XCTAssertFalse(row?.isReservedStub ?? true, "\(name) is implemented, not a stub")
        }
        XCTAssertEqual(
            CADCommandAliasTable.entry(canonicalName: "GEOMCONSTRAINT")?.aliases,
            ["GCON"])
        XCTAssertEqual(
            CADCommandAliasTable.entry(canonicalName: "CONSTRAINTBAR")?.aliases,
            ["CBAR"])
    }

    // MARK: - Descriptor synthesis (autocomplete discoverability)

    func testConstraintDescriptorsSynthesizedOnRegistration() {
        let processor = CADCommandProcessor()
        registerConstraintCommands(on: processor)
        for name in ["GEOMCONSTRAINT", "AUTOCONSTRAIN", "DELCONSTRAINT", "CONSTRAINTBAR"] {
            XCTAssertNotNil(
                CommandDescriptor.allCommands.first { $0.canonicalName == name },
                "\(name) must seed an autocomplete descriptor on registration")
        }
        let geom = CommandDescriptor.allCommands.first {
            $0.canonicalName == "GEOMCONSTRAINT"
        }
        XCTAssertTrue(geom?.aliases.contains("GCON") ?? false)
        let cbar = CommandDescriptor.allCommands.first {
            $0.canonicalName == "CONSTRAINTBAR"
        }
        XCTAssertTrue(cbar?.aliases.contains("CBAR") ?? false)
    }

    func testConstraintAliasesResolveThroughMatch() {
        let processor = CADCommandProcessor()
        registerConstraintCommands(on: processor)
        XCTAssertTrue(
            processor.matchCommands(input: "GCON").prefix(3)
                .map { $0.descriptor.canonicalName }.contains("GEOMCONSTRAINT"))
        XCTAssertTrue(
            processor.matchCommands(input: "CBAR").prefix(3)
                .map { $0.descriptor.canonicalName }.contains("CONSTRAINTBAR"))
        XCTAssertTrue(
            processor.matchCommands(input: "AUTOCONSTRAIN").prefix(3)
                .map { $0.descriptor.canonicalName }.contains("AUTOCONSTRAIN"))
        XCTAssertTrue(
            processor.matchCommands(input: "DELCONSTRAINT").prefix(3)
                .map { $0.descriptor.canonicalName }.contains("DELCONSTRAINT"))
    }

    // MARK: - Option palettes

    func testGeomconstraintOptionsCoverAllKinds() {
        let options = GeomconstraintCommand().commandTextOptions(for: "")
        XCTAssertEqual(
            Set(options.map(\.value)),
            ["H", "V", "C", "P", "PE", "E", "F"])
        // Typing narrows the palette instead of hiding it.
        XCTAssertEqual(
            GeomconstraintCommand().commandTextOptions(for: "H").map(\.value), ["H"])
        XCTAssertTrue(
            GeomconstraintCommand().commandTextOptions(for: "PERP").map(\.value).contains("PE"))
    }

    func testDelconstraintOffersAll() {
        let options = DelconstraintCommand().commandTextOptions(for: "")
        XCTAssertTrue(options.map(\.value).contains("ALL"))
    }

    func testConstraintbarOffersShowHide() {
        let options = ConstraintbarCommand().commandTextOptions(for: "")
        XCTAssertEqual(Set(options.map(\.value)), ["SHOW", "HIDE"])
    }
}
