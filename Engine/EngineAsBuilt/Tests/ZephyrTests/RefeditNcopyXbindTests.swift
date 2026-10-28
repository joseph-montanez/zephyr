import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.3d in-place reference editing, nested copy, and dependent
/// symbol binding: REFEDIT session generalization (spike verdict:
/// feasible — shadow-materialized sessions with reload-and-swap
/// save-back, DWG refused), NCOPY nested picks, and XBIND for styles
/// and linetypes alongside the existing layer path.
@MainActor
final class RefeditNcopyXbindTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func titleBlock() -> CADBlock {
        CADBlock(
            name: "TAGBLK",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: nil)])
    }

    // MARK: - NCOPY

    func testNestedHitFindsBlockMember() throws {
        let document = makeDocument()
        let block = titleBlock()
        document.addBlock(block)
        let insert = CADEntity(
            layerID: zeroID(document), blockID: block.handle,
            transform: .translated(by: Vector3(x: 100, y: 50, z: 0)))
        document.addEntity(insert)

        let hit = try XCTUnwrap(CADHitTesting.nestedHitTest(
            worldX: 105, worldY: 50, document: document))
        XCTAssertEqual(hit.entity.handle, insert.handle)
        XCTAssertEqual(hit.primitiveIndex, 0)

        // Empty space: no hit.
        XCTAssertNil(CADHitTesting.nestedHitTest(
            worldX: 500, worldY: 500, document: document))
    }

    func testNCopyMakesWorldSpaceLooseEntity() throws {
        let document = makeDocument()
        let block = titleBlock()
        document.addBlock(block)
        let insert = CADEntity(
            layerID: zeroID(document), blockID: block.handle,
            transform: .translated(by: Vector3(x: 100, y: 50, z: 0)))
        document.addEntity(insert)
        let hit = try XCTUnwrap(CADHitTesting.nestedHitTest(
            worldX: 105, worldY: 50, document: document))

        let copy = try XCTUnwrap(NCopySupport.makeCopy(hit: hit, in: document))
        XCTAssertNil(copy.blockID)
        XCTAssertEqual(copy.transform, .identity)
        guard case .line(let start, let end, _) = try XCTUnwrap(
            copy.localGeometry?.first) else {
            return XCTFail("expected a loose line copy")
        }
        XCTAssertEqual(start.x, 100, accuracy: 1e-9)
        XCTAssertEqual(start.y, 50, accuracy: 1e-9)
        XCTAssertEqual(end.x, 110, accuracy: 1e-9)
        XCTAssertEqual(end.y, 50, accuracy: 1e-9)
    }

    // MARK: - XBIND styles

    func testXbindStyleRenameAndMerge() throws {
        let document = makeDocument()
        document.textStyles["SITE|Title"] = CADTextStyle(name: "SITE|Title")
        document.linetypePatterns["SITE|DASHED"] = [6.0, 3.0]

        // Bind mode renames Owner|Leaf -> Owner$0$Leaf.
        XCTAssertEqual(
            document.xbindStyle(named: "SITE|Title", bindType: 0),
            "SITE$0$Title")
        XCTAssertNil(document.textStyles["SITE|Title"])
        XCTAssertNotNil(document.textStyles["SITE$0$Title"])

        // Insert mode merges into an existing leaf name.
        document.textStyles["Title"] = .standard
        document.textStyles["SITE|Body"] = CADTextStyle(name: "SITE|Body")
        XCTAssertEqual(
            document.xbindStyle(named: "SITE|Body", bindType: 1), "Body")
        XCTAssertNil(document.textStyles["SITE|Body"])

        // Linetypes bind too.
        XCTAssertEqual(
            document.xbindStyle(named: "SITE|DASHED", bindType: 0),
            "SITE$0$DASHED")

        // Unknown names fail cleanly.
        XCTAssertNil(document.xbindStyle(named: "Nope", bindType: 0))
        XCTAssertNil(document.xbindStyle(named: "SITE|Missing", bindType: 0))
    }

    func testXbindDimStyle() {
        let document = makeDocument()
        XCTAssertNil(document.xbindStyle(named: "SITE|Arch", bindType: 0))
        document.dimensionStyles["SITE|Arch"] = .default
        XCTAssertEqual(
            document.xbindStyle(named: "SITE|Arch", bindType: 0),
            "SITE$0$Arch")
    }

    // MARK: - REFEDIT save-back

    private var xrefFileDXF: String {
        """
        0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        0
         10
        0.0
         20
        0.0
         30
        0.0
         11
        7.0
         21
        0.0
         31
        0.0
          0
        ENDSEC
          0
        EOF
        """
    }

    private func writeTempFile(contents: String, suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("refedit_\(UUID().uuidString).\(suffix)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSaveBackSwapsFileEntities() throws {
        let fileURL = try writeTempFile(contents: xrefFileDXF, suffix: "dxf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let host = makeDocument()
        host.addLayer(Layer(name: "Notes"))
        let notesID = try XCTUnwrap(host.findLayer(named: "Notes")).handle
        // Edited session content: the original line moved + a note added.
        let moved = CADEntity(
            layerID: zeroID(host),
            localGeometry: [.line(
                start: Vector3(x: 1, y: 1, z: 0),
                end: Vector3(x: 8, y: 1, z: 0), color: nil)],
            transform: .identity,
            drawOrder: 0)
        let note = CADEntity(
            layerID: notesID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 5, z: 0),
                end: Vector3(x: 3, y: 5, z: 0), color: nil)],
            transform: .identity,
            drawOrder: 1)

        let count = try RefeditSaveBack.save(
            tempEntities: [moved, note], hostDocument: host, to: fileURL)
        XCTAssertEqual(count, 2)

        // The file now holds the edited set, with the host layer carried over.
        let reopened = CADDocument()
        try reopened.importDXF(url: fileURL)
        XCTAssertEqual(reopened.allEntities.count, 2)
        XCTAssertNotNil(reopened.findLayer(named: "Notes"))
        let texts = reopened.allEntities.compactMap(\.localGeometry).flatMap { $0 }
        XCTAssertEqual(texts.count, 2)
    }

    func testSaveBackStripsEditorScratchXData() throws {
        let fileURL = try writeTempFile(contents: xrefFileDXF, suffix: "dxf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let host = makeDocument()
        var entity = CADEntity(
            layerID: zeroID(host),
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 2, y: 0, z: 0), color: nil)],
            transform: .identity)
        entity.xdata["zephyr.blockEditor.hadPrimitiveStyle"] = .int(1)
        entity.xdata["dxf.handle"] = .string("AB")

        _ = try RefeditSaveBack.save(
            tempEntities: [entity], hostDocument: host, to: fileURL)
        let reopened = CADDocument()
        try reopened.importDXF(url: fileURL)
        let saved = try XCTUnwrap(reopened.allEntities.first)
        XCTAssertNil(saved.xdata["zephyr.blockEditor.hadPrimitiveStyle"])
    }
}
