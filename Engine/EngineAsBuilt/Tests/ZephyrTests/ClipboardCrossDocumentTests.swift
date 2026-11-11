import Foundation
import XCTest
@testable import ZephyrCore

/// Cross-document clipboard paste (COPYCLIP/COPYBASE → PASTECLIP/PASTEORIG/
/// PASTEBLOCK): the entry must carry every definition the target document
/// needs, remapped by NAME with the target winning collisions.
@MainActor
final class ClipboardCrossDocumentTests: XCTestCase {

    private func makeDoc(unit: CADUnit = .millimeter) -> CADDocument {
        let doc = CADDocument()
        doc.unit = unit
        doc.addLayer(Layer(name: "0", color: .white))
        return doc
    }

    private func line(
        _ doc: CADDocument, layer: Layer,
        from: Vector3, to: Vector3
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(start: from, end: to, color: nil)])
        doc.addEntity(entity)
        return entity
    }

    private func capture(
        _ doc: CADDocument, _ handles: UUID...,
        basePoint: Vector3? = nil
    ) -> CADClipboardEntry {
        let entry = CADClipboardCapture.capture(
            from: doc, handles: Set(handles),
            basePointOverride: basePoint)
        XCTAssertNotNil(entry, "capture must succeed for live entities")
        return entry!
    }

    /// Every pasted entity must resolve its layer and block, or it renders
    /// nothing (the reported "paste shows in Blocks UI but not on canvas").
    private func assertCoherent(
        _ doc: CADDocument, file: StaticString = #file, line ln: UInt = #line
    ) {
        for entity in doc.allEntities {
            XCTAssertNotNil(
                doc.layer(for: entity.layerID),
                "dangling layer on pasted entity", file: file, line: ln)
            if let bid = entity.blockID {
                XCTAssertNotNil(
                    doc.block(for: bid),
                    "dangling block on pasted entity", file: file, line: ln)
            }
        }
    }

    // MARK: - Layers

    func testPasteRemapsLayerByName() {
        let source = makeDoc()
        let sourceWalls = Layer(name: "Walls", color: .white)
        source.addLayer(sourceWalls)
        let entity = line(
            source, layer: sourceWalls,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))

        let target = makeDoc()
        let targetWalls = Layer(name: "wALLs", color: .white)
        target.addLayer(targetWalls)

        let result = target.importClipboardEntry(
            capture(source, entity.handle), mode: .original)
        XCTAssertEqual(result.handles.count, 1)
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(
            pasted.layerID, targetWalls.handle,
            "same-named target layer wins, not the source UUID")
        assertCoherent(target)
        let bounds = target.renderableWorldBoundingBox()
        XCTAssertNotNil(bounds, "pasted line must be renderable")
        XCTAssertEqual(bounds?.max.x ?? 0, 10, accuracy: 1e-9)
    }

    func testMissingLayerIsImported() {
        let source = makeDoc()
        let walls = Layer(name: "Walls", color: .white)
        source.addLayer(walls)
        let entity = line(
            source, layer: walls,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 4, y: 0, z: 0))

        let target = makeDoc()
        let result = target.importClipboardEntry(
            capture(source, entity.handle), mode: .original)
        XCTAssertEqual(result.handles.count, 1)
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(
            target.layer(for: pasted.layerID)?.name, "Walls")
        assertCoherent(target)
    }

    // MARK: - Blocks

    func testNamedBlockCollisionTargetWins() {
        let source = makeDoc()
        let layer = source.allLayers[0]
        var sourceBlock = CADBlock(
            name: "Door_36",
            geometry: [.line(
                start: .zero, end: Vector3(x: 1, y: 0, z: 0), color: nil)])
        sourceBlock.updateBoundingBox()
        source.addBlock(sourceBlock)
        let insert = CADEntity(
            layerID: layer.handle, blockID: sourceBlock.handle)
        source.addEntity(insert)

        let target = makeDoc()
        var targetBlock = CADBlock(
            name: "door_36",
            geometry: [.line(
                start: Vector3(x: 100, y: 100, z: 0),
                end: Vector3(x: 101, y: 100, z: 0), color: nil)])
        targetBlock.updateBoundingBox()
        target.addBlock(targetBlock)

        let result = target.importClipboardEntry(
            capture(source, insert.handle), mode: .original)
        XCTAssertEqual(result.handles.count, 1)
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(
            pasted.blockID, targetBlock.handle,
            "target definition wins the name collision")
        XCTAssertEqual(
            target.allBlocks.filter {
                $0.name.caseInsensitiveCompare("Door_36") == .orderedSame
            }.count, 1)
        assertCoherent(target)
    }

    func testAnonymousBlocksClonePerPaste() {
        let source = makeDoc()
        let layer = source.allLayers[0]
        var anon = CADBlock(
            name: "*D1",
            geometry: [.line(
                start: .zero, end: Vector3(x: 2, y: 0, z: 0), color: nil)])
        anon.updateBoundingBox()
        source.addBlock(anon)
        let insert = CADEntity(
            layerID: layer.handle, blockID: anon.handle)
        source.addEntity(insert)

        let target = makeDoc()
        let entry = capture(source, insert.handle)
        let first = target.importClipboardEntry(entry, mode: .original)
        let second = target.importClipboardEntry(entry, mode: .original)
        XCTAssertEqual(first.handles.count, 1)
        XCTAssertEqual(second.handles.count, 1)
        XCTAssertNotEqual(first.handles[0], second.handles[0])
        let firstBlock = target.entity(for: first.handles[0])!.blockID!
        let secondBlock = target.entity(for: second.handles[0])!.blockID!
        XCTAssertNotEqual(
            firstBlock, secondBlock,
            "anonymous definitions must clone per paste")
        assertCoherent(target)
    }

    func testAttributeValuesSurvivePaste() {
        let source = makeDoc()
        let layer = source.allLayers[0]
        let def = CADAttributeDefinition(tag: "ROOM", defaultValue: "A")
        var block = CADBlock(
            name: "Tag",
            geometry: [.line(
                start: .zero, end: Vector3(x: 1, y: 0, z: 0), color: nil)],
            attributeDefinitions: [def])
        block.updateBoundingBox()
        source.addBlock(block)
        var insert = CADEntity(layerID: layer.handle, blockID: block.handle)
        insert.attributeValues = ["ROOM": CADAttributeValue(value: "B101")]
        source.addEntity(insert)

        let target = makeDoc()
        let result = target.importClipboardEntry(
            capture(source, insert.handle), mode: .original)
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(pasted.attributeValues["ROOM"]?.value, "B101")
        assertCoherent(target)
    }

    // MARK: - Anchors, units, modes

    func testCopyClipAnchorsLowerLeft() {
        let source = makeDoc()
        let layer = source.allLayers[0]
        let entity = line(
            source, layer: layer,
            from: Vector3(x: 10, y: 10, z: 0),
            to: Vector3(x: 20, y: 10, z: 0))
        let entry = capture(source, entity.handle)
        XCTAssertEqual(entry.basePoint.x, 10, accuracy: 1e-9)
        XCTAssertEqual(entry.basePoint.y, 10, accuracy: 1e-9)

        let target = makeDoc()
        let result = target.importClipboardEntry(
            entry, mode: .anchored(insertion: Vector3(x: 100, y: 100, z: 0)))
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(
            pasted.worldBoundingBox?.min.x ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(
            pasted.worldBoundingBox?.min.y ?? 0, 100, accuracy: 1e-9)
    }

    func testCopyBaseAnchorAndUnitScale() {
        let source = makeDoc() // millimeters
        let layer = source.allLayers[0]
        let entity = line(
            source, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0),
            to: Vector3(x: 25.4, y: 0, z: 0))
        let entry = capture(
            source, entity.handle,
            basePoint: Vector3(x: 5, y: 0, z: 0))
        XCTAssertEqual(entry.basePoint.x, 5, accuracy: 1e-9)

        let target = makeDoc(unit: .inch)
        let result = target.importClipboardEntry(entry, mode: .original)
        let pasted = target.entity(for: result.handles[0])!
        XCTAssertEqual(
            pasted.worldBoundingBox?.max.x ?? 0, 1.0, accuracy: 1e-9,
            "25.4mm pastes as 1in")
    }

    func testPasteBlockCreatesAnonymousBlock() {
        let source = makeDoc()
        let layer = source.allLayers[0]
        let entity = line(
            source, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0),
            to: Vector3(x: 6, y: 0, z: 0))

        let target = makeDoc()
        let insertion = Vector3(x: 7, y: 8, z: 0)
        let result = target.importClipboardEntry(
            capture(source, entity.handle),
            mode: .block(insertion: insertion))
        XCTAssertEqual(result.handles.count, 1)
        let instance = target.entity(for: result.handles[0])!
        XCTAssertEqual(instance.transform.position.x, 7, accuracy: 1e-9)
        XCTAssertEqual(instance.transform.position.y, 8, accuracy: 1e-9)
        let block = target.block(for: try! XCTUnwrap(instance.blockID))
        XCTAssertTrue(
            block?.name.hasPrefix("*A") ?? false,
            "paste-as-block must be anonymous, got \(block?.name ?? "nil")")
        XCTAssertFalse(block?.geometry.isEmpty ?? true)
        assertCoherent(target)
    }

    func testEmptyEntryIsNoOp() {
        let target = makeDoc()
        let depth = target.undoManager.undoDepth
        let entry = CADClipboardEntry(entities: [], basePoint: .zero)
        let result = target.importClipboardEntry(entry, mode: .original)
        XCTAssertTrue(result.handles.isEmpty)
        XCTAssertEqual(target.undoManager.undoDepth, depth)
    }

    // MARK: - Undo

    func testPasteIsSingleUndoStep() {
        let source = makeDoc()
        let walls = Layer(name: "Walls", color: .white)
        source.addLayer(walls)
        let entity = line(
            source, layer: walls,
            from: Vector3(x: 0, y: 0, z: 0),
            to: Vector3(x: 3, y: 0, z: 0))

        let target = makeDoc()
        let depth = target.undoManager.undoDepth
        let result = target.importClipboardEntry(
            capture(source, entity.handle), mode: .original)
        XCTAssertEqual(result.handles.count, 1)
        XCTAssertEqual(target.undoManager.undoDepth, depth + 1)
        target.undo()
        XCTAssertEqual(target.allEntities.count, 0)
    }

    // MARK: - Styles and media

    func testTextStyleAndImageCarried() {
        let source = makeDoc()
        source.textStyles["Notes"] = CADTextStyle(name: "Notes")
        let asset = CADImageAsset(
            name: "abc123", originalFilename: "clip.png",
            mimeType: "image/png", pixelWidth: 4, pixelHeight: 4,
            sha256: "abc123", data: Data([0, 1, 2, 3]))
        source.addImageAsset(asset)
        let layer = source.allLayers[0]
        let text = CADEntity(
            layerID: layer.handle,
            localGeometry: [.text(
                position: .zero, text: "hi", height: 2.5, rotation: 0,
                style: "Notes", alignH: 0, alignV: 0, mtextWidth: nil,
                color: nil)])
        source.addEntity(text)
        let image = CADEntity(
            layerID: layer.handle,
            localGeometry: [.image(
                insertion: .zero,
                uAxis: Vector3(x: 4, y: 0, z: 0),
                vAxis: Vector3(x: 0, y: 4, z: 0),
                imageName: "abc123")])
        source.addEntity(image)

        let target = makeDoc()
        let result = target.importClipboardEntry(
            capture(source, text.handle, image.handle), mode: .original)
        XCTAssertEqual(result.handles.count, 2)
        XCTAssertNotNil(target.textStyles["Notes"])
        XCTAssertNotNil(target.imageStore["abc123"])
        assertCoherent(target)
    }
}
