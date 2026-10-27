import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.3a WBLOCK/-WBLOCK + BASE: export-document building per source,
/// DXF `$INSBASE` round-trip, EAB metadata round-trip, and BASE session
/// semantics (no undo, dirty marking left to the command).
@MainActor
final class WblockBaseTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func lineEntity(_ document: CADDocument, x: Double) -> CADEntity {
        CADEntity(
            layerID: zeroID(document),
            localGeometry: [.line(
                start: Vector3(x: x, y: 0, z: 0),
                end: Vector3(x: x + 5, y: 0, z: 0), color: nil)],
            transform: .identity)
    }

    // MARK: - BASE

    func testBaseIsSessionState() {
        let document = makeDocument()
        let depth = document.undoManager.undoDepth
        document.insertionBase = Vector3(x: 10, y: 20, z: 0)
        XCTAssertEqual(document.insertionBase.x, 10)
        XCTAssertEqual(document.insertionBase.y, 20)
        XCTAssertEqual(document.undoManager.undoDepth, depth)
    }

    func testParsePoint() {
        XCTAssertEqual(
            WblockCommand.parsePoint("10,20"),
            Vector3(x: 10, y: 20, z: 0))
        XCTAssertEqual(
            WblockCommand.parsePoint("10, 20, 5"),
            Vector3(x: 10, y: 20, z: 5))
        XCTAssertNil(WblockCommand.parsePoint("10"))
        XCTAssertNil(WblockCommand.parsePoint("a,b"))
        XCTAssertNil(WblockCommand.parsePoint(""))
    }

    // MARK: - WBLOCK export documents

    func testObjectsSourceExportsSelection() throws {
        let document = makeDocument()
        var handles: [UUID] = []
        for i in 0..<3 {
            let entity = lineEntity(document, x: Double(i) * 10)
            handles.append(entity.handle)
            document.addEntity(entity)
        }
        let base = Vector3(x: 5, y: 5, z: 0)
        let temp = try WblockCommand.exportDocument(
            .objects, blockName: "", basePoint: base,
            handles: Set(handles.prefix(2)), from: document)
        XCTAssertEqual(temp.allEntities.count, 2)
        XCTAssertEqual(temp.insertionBase, base)
        // Source untouched.
        XCTAssertEqual(document.allEntities.count, 3)
    }

    func testEntireSourceExportsAll() throws {
        let document = makeDocument()
        for i in 0..<3 {
            document.addEntity(lineEntity(document, x: Double(i) * 10))
        }
        let temp = try WblockCommand.exportDocument(
            .entire, blockName: "", basePoint: .zero,
            handles: [], from: document)
        XCTAssertEqual(temp.allEntities.count, 3)
    }

    func testBlockSourceExplodesToLooseEntities() throws {
        let document = makeDocument()
        let block = CADBlock(
            handle: UUID(), name: "Chair",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 1, z: 0), color: nil)],
            primitiveStyles: [0: CADPrimitiveStyle(
                layerName: "0", color: nil, lineType: nil, lineWeight: nil,
                lineTypeScale: nil)],
            primitiveXData: [:], dxfFlags: 0)
        document.addBlock(block)
        let temp = try WblockCommand.exportDocument(
            .block, blockName: "chair", basePoint: .zero,
            handles: [], from: document)
        XCTAssertEqual(temp.allEntities.count, 1)
        // Helper INSERT and definition are gone: loose entities only.
        XCTAssertTrue(temp.allEntities.allSatisfy { $0.blockID == nil })
        XCTAssertFalse(temp.allBlocks.contains { $0.name == "Chair" })
        XCTAssertThrowsError(try WblockCommand.exportDocument(
            .block, blockName: "Missing", basePoint: .zero,
            handles: [], from: document))
    }

    // MARK: - $INSBASE round-trips

    func testDXFInsBaseRoundTrip() throws {
        let document = makeDocument()
        document.addEntity(lineEntity(document, x: 0))
        document.insertionBase = Vector3(x: 10, y: 20, z: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("insbase-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: document, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.insBase.x, 10, accuracy: 1e-9)
        XCTAssertEqual(reimported.insBase.y, 20, accuracy: 1e-9)
        XCTAssertEqual(reimported.insBase.z, 0, accuracy: 1e-9)
    }

    func testEABInsertionBaseRoundTrip() throws {
        let document = makeDocument()
        document.addEntity(lineEntity(document, x: 0))
        document.insertionBase = Vector3(x: 7, y: 8, z: 9)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("insbase-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: document, to: url)
        let views = try EABReader.readViews(from: url)
        let base = try XCTUnwrap(views.first).document.insertionBase
        XCTAssertEqual(base.x, 7, accuracy: 1e-12)
        XCTAssertEqual(base.y, 8, accuracy: 1e-12)
        XCTAssertEqual(base.z, 9, accuracy: 1e-12)
    }
}
