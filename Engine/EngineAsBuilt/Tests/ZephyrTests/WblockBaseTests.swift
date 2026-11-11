import XCTest
import Foundation
@testable import ZephyrCore

/// WBLOCK/-WBLOCK export pipeline: per-source export documents with
/// origin shift (Objects) and pruned tables, `$INSBASE` round-trip, EAB
/// metadata round-trip, BASE session semantics (no undo, dirty marking
/// left to the command), target resolution, multi-view Entire, and an
/// ODA-gated DWG round trip.
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

    // MARK: - Target resolution (D1)

    func testResolveTarget() throws {
        let (dxfURL, dxfFormat) = try WblockCommand.resolveTarget("/tmp/plan")
        XCTAssertEqual(dxfURL.lastPathComponent, "plan.dxf")
        XCTAssertEqual(dxfFormat, .dxf)
        let (dwgURL, dwgFormat) = try WblockCommand.resolveTarget("/tmp/PLAN.DWG")
        XCTAssertEqual(dwgURL.lastPathComponent, "PLAN.DWG")
        XCTAssertEqual(dwgFormat, .dwg)
        XCTAssertThrowsError(try WblockCommand.resolveTarget("/tmp/plan.eab"))
        XCTAssertThrowsError(try WblockCommand.resolveTarget("/tmp/plan.pdf"))
    }

    func testDefaultFileNameAlwaysCarriesAnExtension() {
        XCTAssertEqual(WblockCommand.defaultFileName(base: "Chair"), "Chair.dxf")
        XCTAssertEqual(WblockCommand.defaultFileName(base: "  "), "untitled.dxf")
        // Existing drawing extensions are normalized, never doubled.
        XCTAssertEqual(WblockCommand.defaultFileName(base: "plan.dxf"), "plan.dxf")
        XCTAssertEqual(WblockCommand.defaultFileName(base: "plan.DWG"), "plan.dxf")
    }

    func testResolveDialogTarget() throws {
        // Untouched prefill follows the dropdown: the selected extension wins.
        let (dwgURL, dwgFormat) = try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Chair.dxf"),
            filterIndex: 1, offeredName: "Chair.dxf")
        XCTAssertEqual(dwgURL.lastPathComponent, "Chair.dwg")
        XCTAssertEqual(dwgFormat, .dwg)
        let (dxfURL, dxfFormat) = try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Chair.dxf"),
            filterIndex: 0, offeredName: "Chair.dxf")
        XCTAssertEqual(dxfURL.lastPathComponent, "Chair.dxf")
        XCTAssertEqual(dxfFormat, .dxf)
        // User-edited bare names gain the selected filter (DXF when unknown).
        let (bareDWG, bareDWGFormat) = try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Foo"),
            filterIndex: 1, offeredName: "Chair.dxf")
        XCTAssertEqual(bareDWG.lastPathComponent, "Foo.dwg")
        XCTAssertEqual(bareDWGFormat, .dwg)
        let (bareDXF, bareDXFFormat) = try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Foo"),
            filterIndex: -1, offeredName: "Chair.dxf")
        XCTAssertEqual(bareDXF.lastPathComponent, "Foo.dxf")
        XCTAssertEqual(bareDXFFormat, .dxf)
        // User-typed known extensions win over the dropdown; foreign ones throw.
        let (typed, typedFormat) = try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Bar.dwg"),
            filterIndex: 0, offeredName: "Chair.dxf")
        XCTAssertEqual(typed.lastPathComponent, "Bar.dwg")
        XCTAssertEqual(typedFormat, .dwg)
        XCTAssertThrowsError(try WblockCommand.resolveDialogTarget(
            url: URL(fileURLWithPath: "/tmp/Bar.eab"),
            filterIndex: 0, offeredName: "Chair.dxf"))
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
        // Objects shift to the origin (D2): loose geometry carries
        // world coords, so assert world boxes, not transforms.
        XCTAssertEqual(temp.insertionBase, .zero)
        let boxes = temp.allEntities.compactMap(\.worldBoundingBox)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(try XCTUnwrap(boxes.map(\.min.x).min()), -5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(boxes.map(\.max.x).max()), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(boxes.map(\.min.y).min()), -5, accuracy: 1e-9)
        // Source untouched.
        XCTAssertEqual(document.allEntities.count, 3)
    }

    func testEntireSourceKeepsBaseAsInsBase() throws {
        let document = makeDocument()
        document.addEntity(lineEntity(document, x: 10))
        let base = Vector3(x: 1, y: 2, z: 3)
        let temp = try WblockCommand.exportDocument(
            .entire, blockName: "", basePoint: base,
            handles: [], from: document)
        XCTAssertEqual(temp.allEntities.count, 1)
        XCTAssertEqual(temp.insertionBase, base)
        // No shift: world coords preserved.
        let positions = Set(temp.allEntities.map(\.transform.position))
        XCTAssertEqual(positions, [Vector3(x: 0, y: 0, z: 0)])
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
        XCTAssertEqual(temp.insertionBase, .zero)
        // Helper INSERT and definition are gone: loose entities only.
        XCTAssertTrue(temp.allEntities.allSatisfy { $0.blockID == nil })
        XCTAssertFalse(temp.allBlocks.contains { $0.name == "Chair" })
        XCTAssertThrowsError(try WblockCommand.exportDocument(
            .block, blockName: "Missing", basePoint: .zero,
            handles: [], from: document))
    }

    // MARK: - Block resolution (typed/picked/panel seed)

    func testResolveBlockFindsCaseInsensitively() throws {
        let document = makeDocument()
        let block = CADBlock(handle: UUID(), name: "Chair", geometry: [])
        document.addBlock(block)
        let found = try WblockCommand.resolveBlock(named: "chair", in: document)
        XCTAssertEqual(found.handle, block.handle)
        XCTAssertThrowsError(try WblockCommand.resolveBlock(named: "Missing", in: document))
    }

    func testResolveBlockRejectsXref() throws {
        let document = makeDocument()
        let xref = CADBlock(
            handle: UUID(), name: "Plan",
            geometry: [],
            xrefDescriptor: CADXrefDescriptor(savedPath: "plan.dwg"))
        XCTAssertTrue(xref.isXref)
        document.addBlock(xref)
        XCTAssertThrowsError(try WblockCommand.resolveBlock(named: "Plan", in: document))
        XCTAssertThrowsError(try WblockCommand.exportDocument(
            .block, blockName: "Plan", basePoint: .zero,
            handles: [], from: document))
        // Source untouched: no helper entities, definition intact.
        XCTAssertTrue(document.allEntities.isEmpty)
        XCTAssertTrue(document.allBlocks.contains { $0.name == "Plan" })
    }

    // MARK: - Pruned tables (D3)

    func testPruneDropsUnreferencedTables() throws {
        let document = makeDocument()
        let used = Layer(name: "Used")
        let unused = Layer(name: "Unused")
        document.addLayer(used)
        document.addLayer(unused)
        document.textStyles["Scratch"] = CADTextStyle(name: "Scratch")
        let usedBlock = CADBlock(
            handle: UUID(), name: "UsedBlock",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 0, z: 0), color: nil)])
        let orphanBlock = CADBlock(
            handle: UUID(), name: "Orphan",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 2, y: 0, z: 0), color: nil)])
        document.addBlock(usedBlock)
        document.addBlock(orphanBlock)
        let insert = CADEntity(
            layerID: used.handle, blockID: usedBlock.handle,
            transform: .identity)
        document.addEntity(insert)
        let temp = try WblockCommand.exportDocument(
            .objects, blockName: "", basePoint: .zero,
            handles: [insert.handle], from: document)
        XCTAssertNil(temp.findLayer(named: "Unused"))
        XCTAssertNotNil(temp.findLayer(named: "Used"))
        XCTAssertNotNil(temp.findLayer(named: "0"))
        XCTAssertTrue(temp.allBlocks.contains { $0.name == "UsedBlock" })
        XCTAssertFalse(temp.allBlocks.contains { $0.name == "Orphan" })
        XCTAssertNil(temp.textStyles["Scratch"])
        XCTAssertNotNil(temp.textStyles["Standard"])
    }

    // MARK: - Dimension shift (D2 metadata + *D display)

    func testObjectsShiftMovesDimensions() throws {
        let document = makeDocument()
        // Production dimensions pair a *D display block (world-baked
        // geometry) with an INSERT entity carrying raw metadata.
        let display = CADBlock(
            handle: UUID(), name: "*D1",
            geometry: [.line(
                start: Vector3(x: 10, y: 0, z: 0),
                end: Vector3(x: 20, y: 0, z: 0), color: nil)])
        document.addBlock(display)
        var entity = CADEntity(layerID: zeroID(document))
        entity.blockID = display.handle
        entity.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
            styleName: "Standard",
            type: .linearOrRotated,
            measurement: 10,
            defPoint: Vector3(x: 10, y: 5, z: 0),
            defPoint2: Vector3(x: 10, y: 0, z: 0),
            defPoint3: Vector3(x: 20, y: 0, z: 0),
            textMidpoint: Vector3(x: 15, y: 5, z: 0)))
        document.addEntity(entity)
        let temp = try WblockCommand.exportDocument(
            .objects, blockName: "", basePoint: Vector3(x: 10, y: 0, z: 0),
            handles: [entity.handle], from: document)
        // Metadata rides the shift (the writer reads it raw).
        let shifted = try XCTUnwrap(temp.allEntities.first?.dimensionMetadata?.value)
        XCTAssertEqual(shifted.defPoint, Vector3(x: 0, y: 5, z: 0))
        XCTAssertEqual(shifted.defPoint2, Vector3(x: 0, y: 0, z: 0))
        XCTAssertEqual(shifted.defPoint3, Vector3(x: 10, y: 0, z: 0))
        XCTAssertEqual(shifted.textMidpoint, Vector3(x: 5, y: 5, z: 0))
        XCTAssertEqual(shifted.measurement, 10)
        // The *D display block moves too (reimport display source).
        let block = try XCTUnwrap(temp.block(for: display.handle))
        XCTAssertEqual(block.geometry, [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0), color: nil)])
        // The DXF round trip lands at the origin with live metadata.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wblock-dim-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: temp, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.entities.count, 1)
        let meta = try XCTUnwrap(
            reimported.entities.first?.dimensionMetadata?.value)
        XCTAssertEqual(meta.defPoint.x, 0, accuracy: 1e-6)
        XCTAssertEqual(meta.defPoint2.x, 0, accuracy: 1e-6)
        XCTAssertEqual(meta.textMidpoint.x, 5, accuracy: 1e-6)
        let displayBox = try XCTUnwrap(
            reimported.entities.first?.worldBoundingBox)
        XCTAssertEqual(displayBox.min.x, 0, accuracy: 1e-6)
        XCTAssertEqual(displayBox.max.x, 10, accuracy: 1e-6)
    }

    // MARK: - Multi-view Entire (D5)

    func testExportViewsEntireCoversAllViews() throws {
        let modelDoc = makeDocument()
        modelDoc.addEntity(lineEntity(modelDoc, x: 0))
        let sheetDoc = makeDocument()
        sheetDoc.addEntity(lineEntity(sheetDoc, x: 100))
        let tab = DocumentTab(drawingViews: [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ])
        let views = try WblockCommand.exportViews(
            source: .entire, blockName: "", basePoint: .zero,
            handles: [], tab: tab)
        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(views[0].document.allEntities.count, 1)
        XCTAssertEqual(views[1].document.allEntities.count, 1)
        XCTAssertEqual(views[1].kind, .sheet)
        XCTAssertEqual(views[1].name, "Layout1")
    }

    // MARK: - `$INSBASE` round-trips

    func testObjectsShiftRoundTripDXF() throws {
        let document = makeDocument()
        let entity = lineEntity(document, x: 10)
        document.addEntity(entity)
        let temp = try WblockCommand.exportDocument(
            .objects, blockName: "", basePoint: Vector3(x: 10, y: 0, z: 0),
            handles: [entity.handle], from: document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wblock-shift-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: temp, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.entities.count, 1)
        XCTAssertEqual(reimported.insBase.x, 0, accuracy: 1e-9)
        XCTAssertEqual(reimported.insBase.y, 0, accuracy: 1e-9)
        XCTAssertEqual(reimported.insBase.z, 0, accuracy: 1e-9)
        let bbox = try XCTUnwrap(reimported.entities.first?.worldBoundingBox)
        XCTAssertEqual(bbox.min.x, 0, accuracy: 1e-6)
        XCTAssertEqual(bbox.max.x, 5, accuracy: 1e-6)
        XCTAssertEqual(bbox.min.y, 0, accuracy: 1e-6)
    }

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

    // MARK: - DWG via ODA (D1)

    func testWriteExportDWGRoundtrip() throws {
        guard ODADWGConverter.isAvailable else {
            throw XCTSkip("ODA FileConverter not installed; run INSTALLODA")
        }
        let document = makeDocument()
        let entity = lineEntity(document, x: 10)
        document.addEntity(entity)
        let temp = try WblockCommand.exportDocument(
            .objects, blockName: "", basePoint: Vector3(x: 10, y: 0, z: 0),
            handles: [entity.handle], from: document)
        let views = [DrawingView(name: "Model", kind: .model, document: temp)]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WblockDWG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dwgURL = dir.appendingPathComponent("plan.dwg")
        try WblockCommand.writeExport(
            views: views, to: dwgURL, format: .dwg, dxfVersion: .r2018)

        // Modern (R13+) DWG files begin with the 6-byte version magic.
        let data = try Data(contentsOf: dwgURL)
        XCTAssertGreaterThan(data.count, 32)
        XCTAssertEqual(String(data: data.prefix(6), encoding: .utf8), "AC1032")

        // Geometry survives DWG -> DXF at the origin.
        let backDXF = dir.appendingPathComponent("back.dxf")
        try ODADWGConverter.convertSync(
            input: dwgURL, output: backDXF, toFormat: "DXF")
        let reimported = try DXFImporter.importDXFViews(filePath: backDXF.path)
        XCTAssertEqual(reimported.entities.count, 1)
        XCTAssertEqual(reimported.insBase.x, 0, accuracy: 1e-9)
        let bbox = try XCTUnwrap(reimported.entities.first?.worldBoundingBox)
        XCTAssertEqual(bbox.min.x, 0, accuracy: 1e-6)
        XCTAssertEqual(bbox.max.x, 5, accuracy: 1e-6)
    }
}
