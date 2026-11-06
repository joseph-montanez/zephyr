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

    func testBareCommandsOpenPromptFlows() {
        // Space == Enter: a bare command opens its prompt flow (pending
        // session or modal command) instead of waiting for same-line
        // arguments. LOAD/SCRIPT still supply the file via picker.
        XCTAssertEqual(LispDescriptors.load.syntax, "<file>")
        XCTAssertEqual(LispDescriptors.script.syntax, "<file>")
        XCTAssertEqual(LispDescriptors.eval.syntax, "<expression>")
        let processor = CADCommandProcessor()
        processor.executeCommand("UNDO")
        XCTAssertEqual(processor.pendingPromptCommand, "UNDO")
        processor.executeCommand("")
        XCTAssertNil(processor.pendingPromptCommand)
        processor.executeCommand("REDO")
        XCTAssertEqual(processor.pendingPromptCommand, "REDO")
        // No command name or alias contains a space: one token per submit.
        for desc in CommandDescriptor.allCommands {
            for match in desc.allMatches {
                XCTAssertFalse(
                    match.contains(where: { $0.isWhitespace }),
                    "\(desc.canonicalName) has a spaced match '\(match)'")
            }
        }
    }
}
