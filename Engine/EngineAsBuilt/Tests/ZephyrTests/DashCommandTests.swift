import XCTest
@testable import ZephyrCore

/// Phase 0.5 tests: the DRAWORDER umbrella options, the CHPROP apply math
/// (single undo step, scripted-compatible xdata), and the shared text
/// entity builder. All headless: option plumbing and document edits, not
/// live-pointer interaction (which stays a manual sweep per the plan).
@MainActor
final class DashCommandTests: XCTestCase {

    func testDrawOrderUmbrellaOptions() {
        let options = DrawOrderUmbrellaCommand().commandTextOptions(for: "")
        XCTAssertEqual(
            Set(options.map { $0.value }),
            ["A", "U", "F", "B"])
    }

    func testParseColorTokens() {
        XCTAssertEqual(
            ChangePropertiesCommand.parseColor("BYLAYER"), .byLayer)
        XCTAssertEqual(
            ChangePropertiesCommand.parseColor("byblock"), .byLayer)
        XCTAssertEqual(
            ChangePropertiesCommand.parseColor("1"), .aci(1))
        XCTAssertEqual(
            ChangePropertiesCommand.parseColor("255"), .aci(255))
        XCTAssertNil(ChangePropertiesCommand.parseColor("0"))
        XCTAssertNil(ChangePropertiesCommand.parseColor("256"))
        XCTAssertNil(ChangePropertiesCommand.parseColor("red"))
        XCTAssertEqual(
            ChangePropertiesCommand.parseColor("255,0,0"),
            .rgb(ColorRGBA(r: 255, g: 0, b: 0)))
        XCTAssertNil(ChangePropertiesCommand.parseColor("255,0"))
    }

    func testApplyColorIsSingleUndoStep() {
        let doc = CADDocument()
        let layer = Layer(name: "L1", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: nil)],
            transform: .identity)
        doc.addEntity(entity)
        let handle = entity.handle
        let depthBefore = doc.undoManager.undoDepth

        let count = ChangePropertiesCommand.apply(
            .color(.aci(1)), to: [handle], in: doc)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depthBefore + 1)

        let stored = doc.entity(for: handle)
        XCTAssertEqual(stored?.xdata["dxf.colorIndex"], .int(1))
        XCTAssertNil(stored?.xdata["dxf.color24"])

        _ = ChangePropertiesCommand.apply(
            .color(.byLayer), to: [handle], in: doc)
        let cleared = doc.entity(for: handle)
        XCTAssertNil(cleared?.xdata["dxf.colorIndex"])
        XCTAssertNil(cleared?.xdata["dxf.color24"])
    }

    func testApplyLayerAndLineType() {
        let doc = CADDocument()
        let a = Layer(name: "A", color: .white)
        let b = Layer(name: "B", color: .white)
        doc.importLayersBlocksEntities(layers: [a, b], blocks: [], entities: [])
        let entity = CADEntity(
            layerID: a.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 5, y: 0, z: 0), color: nil)],
            transform: .identity)
        doc.addEntity(entity)

        _ = ChangePropertiesCommand.apply(
            .layer(b.handle), to: [entity.handle], in: doc)
        XCTAssertEqual(doc.entity(for: entity.handle)?.layerID, b.handle)

        _ = ChangePropertiesCommand.apply(
            .lineType("DASHED"), to: [entity.handle], in: doc)
        XCTAssertEqual(
            doc.entity(for: entity.handle)?.xdata["dxf.lineType"],
            .string("DASHED"))
        _ = ChangePropertiesCommand.apply(
            .lineType(nil), to: [entity.handle], in: doc)
        XCTAssertNil(doc.entity(for: entity.handle)?.xdata["dxf.lineType"])

        _ = ChangePropertiesCommand.apply(
            .lineWeight(0.5), to: [entity.handle], in: doc)
        XCTAssertEqual(
            doc.entity(for: entity.handle)?.xdata["dxf.lineWeight"],
            .double(0.5))
    }

    func testMakeTextEntityContract() {
        let layerID = UUID()
        let entity = TextCommand.makeTextEntity(
            text: "Hello",
            styleName: "Standard",
            fontName: "txt.shx",
            height: 2.5,
            rotation: 0,
            alignH: 0,
            alignV: 0,
            mtextWidth: 0,
            insertPos: Vector3(x: 1, y: 2, z: 0),
            layerID: layerID)
        XCTAssertEqual(entity.layerID, layerID)
        XCTAssertEqual(entity.xdata["dxf.text"], .string("Hello"))
        XCTAssertEqual(entity.xdata["dxf.textStyle"], .string("Standard"))
        XCTAssertEqual(entity.xdata["dxf.textHeight"], .double(2.5))
        XCTAssertEqual(entity.xdata["dxf.alignH"], .int(0))
        XCTAssertEqual(entity.xdata["dxf.alignV"], .int(0))
        XCTAssertNotNil(entity.xdata["dxf.formattedText"])
        // Zero height clamps instead of producing degenerate geometry.
        let flat = TextCommand.makeTextEntity(
            text: "x", styleName: "Standard", fontName: "txt.shx",
            height: 0, rotation: 0, alignH: 0, alignV: 0, mtextWidth: 0,
            insertPos: .zero, layerID: layerID)
        XCTAssertEqual(flat.xdata["dxf.textHeight"], .double(1e-9))
    }
}

// MARK: - Equatable support for parse assertions

extension ChangePropertiesCommand.PropColor: Equatable {
    public static func == (
        lhs: ChangePropertiesCommand.PropColor,
        rhs: ChangePropertiesCommand.PropColor
    ) -> Bool {
        switch (lhs, rhs) {
        case (.byLayer, .byLayer): return true
        case (.aci(let a), .aci(let b)): return a == b
        case (.rgb(let a), .rgb(let b)):
            return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
        default: return false
        }
    }
}
