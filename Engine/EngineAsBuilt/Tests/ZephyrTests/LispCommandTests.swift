import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Step-3 driver tests: the headless-testable surface of LispCommand
/// (point-text parsing, .scr tokenizing, script-file runs). start()/cancel()
/// need a live PhrostEngine and are covered by the manual interactive run.
@MainActor
final class LispCommandTests: XCTestCase {

    func testParsePointText() {
        XCTAssertEqual(LispCommand.parsePointText("10,20", base: nil), [10, 20])
        XCTAssertEqual(LispCommand.parsePointText("10,20,5", base: nil), [10, 20, 5])
        XCTAssertEqual(LispCommand.parsePointText("10 20", base: nil), [10, 20])
        XCTAssertEqual(LispCommand.parsePointText("  1.5 , -2.5  ", base: nil), [1.5, -2.5])
        // Bare number: single-element escape for getdist/getangle.
        XCTAssertEqual(LispCommand.parsePointText("7.5", base: nil), [7.5])
        // Relative @ form offsets from the base point.
        XCTAssertEqual(
            LispCommand.parsePointText("@1,2", base: [10, 10]), [11, 12])
        XCTAssertNil(LispCommand.parsePointText("@1,2", base: nil))
        // Garbage never partially parses.
        XCTAssertNil(LispCommand.parsePointText("10,abc", base: nil))
        XCTAssertNil(LispCommand.parsePointText("hello", base: nil))
        XCTAssertNil(LispCommand.parsePointText("1,2,3,4", base: nil))
        XCTAssertNil(LispCommand.parsePointText("", base: nil))
    }

    func testParseScriptLine() {
        let values = LispCommand.parseScriptLine("10,20 5 2.5 _C")
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0].asPoint, [10, 20])
        XCTAssertEqual(values[1], .int(5))
        XCTAssertEqual(values[2], .real(2.5))
        XCTAssertEqual(values[3], .string("_C"))
    }

    func testRunScriptFile() async throws {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.activeLayerID = doc.findLayer(named: "0")?.handle
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("step3test.scr")
        try """
        ; draw a line and a circle, then undo the circle
        _.LINE
        0,0
        10,0

        _.CIRCLE
        5,5
        2.0
        _.UNDO
        1
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try await LispCommand.runScriptFile(argument: scriptURL.path, host: host)
        XCTAssertEqual(doc.allEntities.count, 1, "circle undone, line kept")
        let typeName = LispEntityAdapter.dxfTypeName(
            entity: try XCTUnwrap(doc.allEntities.first), document: doc)
        XCTAssertEqual(typeName, "LINE")
    }

    func testRunScriptFileRejectsUnknownCommand() async throws {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("step3bad.scr")
        try "_.PLOT\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        do {
            try await LispCommand.runScriptFile(argument: scriptURL.path, host: host)
            XCTFail("unknown script command should fail")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("SCRIPT line 1"), "\(error)")
        }
    }

    func testOpenFilter() {
        let load = LispCommand.openFilter(for: .load)
        XCTAssertEqual(load?.extensions, ["lsp", "mnl"])
        let script = LispCommand.openFilter(for: .script)
        XCTAssertEqual(script?.extensions, ["scr"])
        XCTAssertNil(LispCommand.openFilter(for: .eval))
    }

    func testBareEnterDescriptors() {
        // Bare Enter must execute (the picker supplies the file).
        XCTAssertTrue(LispDescriptors.load.bareEnterExecutes)
        XCTAssertTrue(LispDescriptors.script.bareEnterExecutes)
        XCTAssertFalse(LispDescriptors.eval.bareEnterExecutes)
        // UNDO/REDO take an optional step count: bare Enter performs one step
        // (AutoCAD parity) instead of waiting for an argument.
        for name in ["UNDO", "REDO"] {
            let descriptor = CommandDescriptor.allCommands.first { $0.canonicalName == name }
            XCTAssertNotNil(descriptor, "\(name) must be a registered command")
            XCTAssertTrue(descriptor?.bareEnterExecutes ?? false)
        }
        // Spot-check: other parameterized commands still wait for arguments.
        // RIBBONMODE is the same deal as UNDO/REDO: bare Enter reports the
        // current mode instead of waiting for a keyword.
        let optionalArgumentCommands: Set<String> = [
            "LOAD", "SCRIPT", "UNDO", "REDO", "RIBBONMODE", "VPRESIZE",
            // Plot: bare Enter lists (SCALELISTEDIT) or opens the file
            // picker (PSETUPIN) instead of waiting for arguments.
            "PSETUPIN", "SCALELISTEDIT", "-SCALELISTEDIT",
            // LAYOUT: bare Enter enters the modal option prompt.
            "LAYOUT",
        ]
        let others = CommandDescriptor.allCommands.filter {
            !$0.syntax.isEmpty
                && !optionalArgumentCommands.contains($0.canonicalName)
        }
        XCTAssertFalse(others.isEmpty)
        for desc in others {
            XCTAssertFalse(
                desc.bareEnterExecutes,
                "\(desc.canonicalName) must keep parameter-entry behavior")
        }
    }
}
