import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 TXT2MTXT/FIELD: reading-order merge assembly and field-code
/// evaluation, including the open-time refresh path. (Command pick flows
/// mirror DIMREASSOCIATE; persistence uses replaceEntities and the
/// LeaderCommands snapshot-before one-undo pattern.)
final class TxtMtxtFieldTests: XCTestCase {

    private func textEntity(
        _ text: String,
        at position: Vector3,
        mtextWidth: Double? = nil
    ) -> CADEntity {
        var entity = CADEntity(
            layerID: UUID(),
            localGeometry: [.text(
                position: position, text: text, height: 2.5, rotation: 0,
                style: "Standard", alignH: 0, alignV: 0,
                mtextWidth: mtextWidth, color: nil)],
            transform: .identity)
        entity.xdata["dxf.text"] = .string(text)
        return entity
    }

    private func source(
        _ text: String, x: Double, y: Double
    ) -> Txt2MtxtCommand.Source {
        try! XCTUnwrap(Txt2MtxtCommand.sourceText(in: textEntity(
            text, at: Vector3(x: x, y: y, z: 0))))
    }

    // MARK: - TXT2MTXT assembly

    func testReadingOrderTopDownThenLeftRight() {
        let ordered = Txt2MtxtCommand.readingOrder([
            source("bottom", x: 0, y: 0),
            source("top-right", x: 5, y: 10),
            source("top-left", x: 0, y: 10),
        ])
        XCTAssertEqual(ordered.map(\.text), ["top-left", "top-right", "bottom"])
    }

    func testSourceTextRejectsMtextAndMultiPrim() {
        XCTAssertNotNil(Txt2MtxtCommand.sourceText(in: textEntity(
            "single", at: Vector3(x: 0, y: 0, z: 0))))
        XCTAssertNil(Txt2MtxtCommand.sourceText(in: textEntity(
            "multi", at: Vector3(x: 0, y: 0, z: 0), mtextWidth: 40)))
        var multi = textEntity("a", at: Vector3(x: 0, y: 0, z: 0))
        multi.localGeometry = (multi.localGeometry ?? []) + [.text(
            position: Vector3(x: 1, y: 0, z: 0), text: "b", height: 2.5,
            rotation: 0, style: "Standard", alignH: 0, alignV: 0,
            mtextWidth: nil, color: nil)]
        XCTAssertNil(Txt2MtxtCommand.sourceText(in: multi))
    }

    // MARK: - FIELD codes

    func testDateFormat() {
        let rendered = FieldEval.isoDate()
        XCTAssertNotNil(rendered.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
    }

    func testUnknownAndBareExpressions() {
        let doc = CADDocument()
        XCTAssertNil(FieldEval.evaluate("$NOPE", in: doc))
        XCTAssertNil(FieldEval.evaluate("DATE", in: doc))
        XCTAssertNil(FieldEval.evaluate("", in: doc))
    }

    func testFilenameAndTabnameDefaults() {
        let doc = CADDocument()
        XCTAssertEqual(FieldEval.evaluate("$FILENAME", in: doc), "<no file>")
        XCTAssertEqual(FieldEval.evaluate("$TABNAME", in: doc), "<no layout>")
        _ = doc.finalizeOpen(sourceFileName: "plan.dxf", layoutName: "Model")
        XCTAssertEqual(FieldEval.evaluate("$FILENAME", in: doc), "plan.dxf")
        XCTAssertEqual(FieldEval.evaluate("$TABNAME", in: doc), "Model")
    }

    func testAreaAndLengthFields() {
        let doc = CADDocument()
        let square = CADEntity(
            layerID: UUID(),
            localGeometry: [.polyline(path: CADPolyline(
                points: [
                    Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                    Vector3(x: 4, y: 3, z: 0), Vector3(x: 0, y: 3, z: 0),
                ], isClosed: true))],
            transform: .identity)
        doc.addEntity(square)
        let handle = doc.allEntities[0].handle
        XCTAssertEqual(
            FieldEval.evaluate("$AREA:\(handle.uuidString)", in: doc), "12.0000")
        XCTAssertEqual(
            FieldEval.evaluate("$LENGTH:\(handle.uuidString)", in: doc), "14.0000")
        XCTAssertNil(FieldEval.evaluate("$AREA:not-a-uuid", in: doc))
        XCTAssertNil(FieldEval.evaluate(
            "$AREA:\(UUID().uuidString)", in: doc))
    }

    // MARK: - Open-time refresh

    func testEvaluateFieldsRefreshesStaleText() {
        let doc = CADDocument()
        var carrier = textEntity("stale", at: Vector3(x: 0, y: 0, z: 0))
        carrier.xdata[FieldEval.exprKey] = .string("$DATE")
        doc.addEntity(carrier)
        let refreshed = doc.evaluateFields()
        XCTAssertEqual(refreshed, 1)
        let stored = try! XCTUnwrap(doc.allEntities.first)
        guard case .text(_, let text, _, _, _, _, _, _, _) = stored.localGeometry?[0] else {
            XCTFail("expected text primitive")
            return
        }
        XCTAssertEqual(text, FieldEval.isoDate())
        // Second pass is a no-op (no undo churn for fresh values).
        XCTAssertEqual(doc.evaluateFields(), 0)
    }

    func testEvaluateFieldsKeepsUnresolvableText() {
        let doc = CADDocument()
        var carrier = textEntity("keep me", at: Vector3(x: 0, y: 0, z: 0))
        carrier.xdata[FieldEval.exprKey] = .string("$AREA:not-a-uuid")
        doc.addEntity(carrier)
        XCTAssertEqual(doc.evaluateFields(), 0)
        let stored = try! XCTUnwrap(doc.allEntities.first)
        guard case .text(_, let text, _, _, _, _, _, _, _) = stored.localGeometry?[0] else {
            XCTFail("expected text primitive")
            return
        }
        XCTAssertEqual(text, "keep me")
    }
}
