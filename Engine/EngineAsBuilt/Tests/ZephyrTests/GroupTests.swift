import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2f GROUP/UNGROUP/PICKSTYLE: group model + undo, PICKSTYLE
/// expansion (on/off/unselectable), sysvar validation, and the DXF-spike
/// round-trips (ZEPHYR_GROUP appID records + EAB section 18).
@MainActor
final class GroupTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func seedThree(_ document: CADDocument) -> [UUID] {
        let zero = zeroID(document)
        return (0..<3).map { i in
            var entity = CADEntity(
                layerID: zero,
                localGeometry: [.text(
                    position: Vector3(x: Double(i) * 10, y: 0, z: 0),
                    text: "t", height: 2.5, rotation: 0, style: "Standard",
                    alignH: 0, alignV: 0, mtextWidth: nil, color: nil)],
                transform: .identity)
            entity.layerID = zero
            let handle = entity.handle
            document.addEntity(entity)
            return handle
        }
    }

    // MARK: - model + undo

    func testCreateAndUngroup() {
        let document = makeDocument()
        let handles = seedThree(document)
        let group = try! XCTUnwrap(document.createGroup(
            named: "Walls", members: Array(handles.prefix(2))))
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(document.groups["Walls"]?.members.count, 2)
        XCTAssertTrue(document.ungroup(named: "walls"))
        XCTAssertTrue(document.groups.isEmpty)
        XCTAssertFalse(document.ungroup(named: "Walls"))
    }

    func testCreatePushesUndo() {
        let document = makeDocument()
        let handles = seedThree(document)
        let depth = document.undoManager.undoDepth
        document.createGroup(named: "G1", members: [handles[0]])
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)
        document.undo()
        XCTAssertTrue(document.groups.isEmpty)
        document.redo()
        XCTAssertEqual(document.groups["G1"]?.members, [handles[0]])
    }

    func testAnonymousNamesIncrement() {
        let document = makeDocument()
        let handles = seedThree(document)
        XCTAssertEqual(document.nextAnonymousGroupName(), "*A1")
        document.createGroup(
            named: document.nextAnonymousGroupName(), members: [handles[0]])
        XCTAssertEqual(document.nextAnonymousGroupName(), "*A2")
    }

    func testCreateDropsUnknownMembers() {
        let document = makeDocument()
        let handles = seedThree(document)
        let group = try! XCTUnwrap(document.createGroup(
            named: "G", members: [handles[0], UUID()]))
        XCTAssertEqual(group.members, [handles[0]])
        XCTAssertNil(document.createGroup(named: "Empty", members: [UUID()]))
        XCTAssertNil(document.createGroup(named: "  ", members: handles))
    }

    // MARK: - PICKSTYLE expansion

    func testExpansionOnByDefault() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.createGroup(named: "G", members: Array(handles.prefix(2)))
        XCTAssertEqual(
            document.selectionExpansion(for: handles[0]),
            Set(handles.prefix(2)))
        XCTAssertEqual(document.selectionExpansion(for: handles[2]), [handles[2]])
    }

    func testExpansionOff() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.createGroup(named: "G", members: Array(handles.prefix(2)))
        document.pickStyle = 0
        XCTAssertEqual(document.selectionExpansion(for: handles[0]), [handles[0]])
    }

    func testUnselectableGroupSkipsExpansion() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.groups["G"] = CADGroup(
            name: "G", members: Array(handles.prefix(2)), isSelectable: false)
        XCTAssertEqual(document.selectionExpansion(for: handles[0]), [handles[0]])
    }

    func testManagerExpandsThroughProvider() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.createGroup(named: "G", members: Array(handles.prefix(2)))
        let selection = CADSelectionManager()
        selection.groupExpansionProvider = { document.selectionExpansion(for: $0) }
        selection.addToSelection(handles[0])
        XCTAssertEqual(selection.selectedHandles, Set(handles.prefix(2)))
        selection.removeFromSelection(handles[1])
        XCTAssertTrue(selection.selectedHandles.isEmpty)
    }

    func testPickStyleSysvarValidation() {
        let document = makeDocument()
        let processor = CADCommandProcessor()
        XCTAssertNil(processor.lispVars.set("PICKSTYLE", .int(3), document: document))
        XCTAssertEqual(document.pickStyle, 3)
        XCTAssertNotNil(processor.lispVars.set("PICKSTYLE", .int(4), document: document))
        XCTAssertEqual(document.pickStyle, 3)
        XCTAssertNotNil(processor.lispVars.set("PICKSTYLE", .int(-1), document: document))
        if case .int(let value) = processor.lispVars.get(
            "PICKSTYLE", document: document, activeCommand: nil) {
            XCTAssertEqual(value, 3)
        } else {
            XCTFail("PICKSTYLE should read back an int")
        }
    }

    // MARK: - DXF round-trip (spike proof)

    func testDXFRoundTripPreservesGroups() throws {
        let document = makeDocument()
        let handles = seedThree(document)
        document.createGroup(named: "Walls", members: Array(handles.prefix(2)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("groups-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFWriterBridge.export(document: document, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.groups.count, 1)
        let group = try XCTUnwrap(reimported.groups.first)
        XCTAssertEqual(group.name, "Walls")
        XCTAssertEqual(group.members.count, 2)
        // Staging keys must not leak into entity xdata.
        for entity in reimported.entities {
            XCTAssertTrue(entity.xdata.keys.allSatisfy {
                !$0.hasPrefix(CADGroup.stagingPrefix)
            })
        }
    }

    // MARK: - EAB round-trip

    func testEABRoundTripPreservesGroups() throws {
        let document = makeDocument()
        let handles = seedThree(document)
        document.createGroup(named: "Walls", members: Array(handles.prefix(2)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("groups-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: document, to: url)
        let views = try EABReader.readViews(from: url)
        let groups = try XCTUnwrap(views.first).document.groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(groups["Walls"]).members),
                       Set(handles.prefix(2)))
    }
}
