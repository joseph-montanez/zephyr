import XCTest
@testable import ZephyrCore

@MainActor
final class EABRoundtripTests: XCTestCase {

    func testEABRoundtripWithColorsAndText() throws {
        let doc = CADDocument()

        // 1. Setup Layer
        let layerColor = ColorRGBA(r: 10, g: 20, b: 30, a: 255)
        let layer = Layer(name: "TestLayer", color: layerColor)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])

        // 2. Setup Primitives with Colors
        let primColor1 = ColorRGBA(r: 255, g: 0, b: 0, a: 255)
        let primColor2 = ColorRGBA(r: 0, g: 255, b: 0, a: 255)
        let primColor3 = ColorRGBA(r: 0, g: 0, b: 255, a: 255)
        let primColor4 = ColorRGBA(r: 255, g: 255, b: 0, a: 255)
        let primColor5 = ColorRGBA(r: 255, g: 0, b: 255, a: 255)
        let primColor6 = ColorRGBA(r: 0, g: 255, b: 255, a: 255)
        let primColor7 = ColorRGBA(r: 100, g: 150, b: 200, a: 255)
        let primColor8 = ColorRGBA(r: 50, g: 75, b: 100, a: 255)
        let textColor = ColorRGBA(r: 120, g: 240, b: 60, a: 255)

        let pointPrim = CADPrimitive.point(position: Vector3(x: 1, y: 2, z: 3), color: primColor1)
        let linePrim = CADPrimitive.line(start: Vector3(x: 4, y: 5, z: 6), end: Vector3(x: 7, y: 8, z: 9), color: primColor2)
        let rectPrim = CADPrimitive.rect(origin: Vector3(x: 10, y: 11, z: 12), size: Vector3(x: 5, y: 6, z: 0), color: primColor3)
        let fillRectPrim = CADPrimitive.fillRect(origin: Vector3(x: 15, y: 16, z: 17), size: Vector3(x: 7, y: 8, z: 0), color: primColor4)
        let polygonPrim = CADPrimitive.polygon(points: [Vector3(x: 1, y: 1, z: 0), Vector3(x: 2, y: 3, z: 0)], color: primColor5)
        let fillPolygonPrim = CADPrimitive.fillPolygon(points: [Vector3(x: 4, y: 4, z: 0), Vector3(x: 5, y: 6, z: 0)], color: primColor6)
        let circlePrim = CADPrimitive.circle(center: Vector3(x: 20, y: 21, z: 22), radius: 4.5, color: primColor7)
        let arcPrim = CADPrimitive.arc(center: Vector3(x: 30, y: 31, z: 32), radius: 10.0, startAngle: 0.1, endAngle: 1.5, color: primColor8)
        let polylinePrim = CADPrimitive.polyline(
            path: CADPolyline(vertices: [
                CADPolylineVertex(
                    position: Vector3(x: 0, y: 0, z: 0),
                    bulge: -0.5,
                    startWidth: 0.25,
                    endWidth: 0.5),
                CADPolylineVertex(position: Vector3(x: 5, y: 0, z: 0)),
                CADPolylineVertex(position: Vector3(x: 5, y: 5, z: 0), bulge: 0.25),
            ], isClosed: true),
            color: primColor1)
        let textPrim = CADPrimitive.text(
            position: Vector3(x: 40, y: 41, z: 42),
            text: "Roundtrip Test",
            height: 2.5,
            rotation: 0.78,
            style: "FancyStyle",
            alignH: 1,
            alignV: 2,
            mtextWidth: 15.0,
            color: textColor
        )

        let geom = [
            pointPrim, linePrim, rectPrim, fillRectPrim,
            polygonPrim, fillPolygonPrim, circlePrim, arcPrim, polylinePrim, textPrim
        ]

        // 3. Create a Block Definition
        let block = CADBlock(name: "TestBlock", geometry: geom)
        doc.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])

        // 4. Create an INSERT Entity referencing the Block
        let entity = CADEntity(layerID: layer.handle, blockID: block.handle, transform: .identity)
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [entity])

        // 5. Serialize to temporary EAB file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try EABWriter.write(document: doc, to: tempURL)

        // 6. Deserialize (write(document:) stores a view archive, so read it back as views)
        let views = try EABReader.readViews(from: tempURL)
        let readDoc = try XCTUnwrap(views.first).document
        let readLayers = readDoc.allLayers
        let readBlocks = readDoc.allBlocks
        let readEntities = readDoc.allEntities

        // 7. Verify Results
        XCTAssertEqual(readLayers.count, doc.allLayers.count)
        let readLayer = readLayers.first(where: { $0.name == "TestLayer" })
        XCTAssertNotNil(readLayer)
        XCTAssertEqual(readLayer?.color.r, layerColor.r)
        XCTAssertEqual(readLayer?.color.g, layerColor.g)
        XCTAssertEqual(readLayer?.color.b, layerColor.b)

        XCTAssertEqual(readBlocks.count, 1)
        let readBlock = readBlocks.first!
        XCTAssertEqual(readBlock.name, "TestBlock")
        XCTAssertEqual(readBlock.geometry.count, geom.count)

        // Verify primitives
        for (i, expected) in geom.enumerated() {
            let actual = readBlock.geometry[i]
            switch (expected, actual) {
            case let (.point(p1, c1), .point(p2, c2)):
                XCTAssertEqual(p1, p2)
                XCTAssertEqual(c1, c2)
            case let (.line(s1, e1, c1), .line(s2, e2, c2)):
                XCTAssertEqual(s1, s2)
                XCTAssertEqual(e1, e2)
                XCTAssertEqual(c1, c2)
            case let (.rect(o1, sz1, c1), .rect(o2, sz2, c2)):
                XCTAssertEqual(o1, o2)
                XCTAssertEqual(sz1, sz2)
                XCTAssertEqual(c1, c2)
            case let (.fillRect(o1, sz1, c1), .fillRect(o2, sz2, c2)):
                XCTAssertEqual(o1, o2)
                XCTAssertEqual(sz1, sz2)
                XCTAssertEqual(c1, c2)
            case let (.polygon(pts1, c1), .polygon(pts2, c2)):
                XCTAssertEqual(pts1, pts2)
                XCTAssertEqual(c1, c2)
            case let (.fillPolygon(pts1, c1), .fillPolygon(pts2, c2)):
                XCTAssertEqual(pts1, pts2)
                XCTAssertEqual(c1, c2)
            case let (.circle(ctr1, r1, c1), .circle(ctr2, r2, c2)):
                XCTAssertEqual(ctr1, ctr2)
                XCTAssertEqual(r1, r2)
                XCTAssertEqual(c1, c2)
            case let (.arc(ctr1, r1, sa1, ea1, c1), .arc(ctr2, r2, sa2, ea2, c2)):
                XCTAssertEqual(ctr1, ctr2)
                XCTAssertEqual(r1, r2)
                XCTAssertEqual(sa1, sa2)
                XCTAssertEqual(ea1, ea2)
                XCTAssertEqual(c1, c2)
            case let (.polyline(path1, c1), .polyline(path2, c2)):
                XCTAssertEqual(path1, path2)
                XCTAssertEqual(c1, c2)
            case let (.text(p1, t1, h1, rot1, s1, ah1, av1, mw1, c1), .text(p2, t2, h2, rot2, s2, ah2, av2, mw2, c2)):
                XCTAssertEqual(p1, p2)
                XCTAssertEqual(t1, t2)
                XCTAssertEqual(h1, h2)
                XCTAssertEqual(rot1, rot2)
                XCTAssertEqual(s1, s2)
                XCTAssertEqual(ah1, ah2)
                XCTAssertEqual(av1, av2)
                XCTAssertEqual(mw1, mw2)
                XCTAssertEqual(c1, c2)
            default:
                XCTFail("Mismatch at index \(i): expected \(expected), got \(actual)")
            }
        }

        XCTAssertEqual(readEntities.count, 1)
        let readEntity = readEntities.first!
        XCTAssertEqual(readEntity.blockID, block.handle)
        XCTAssertEqual(readEntity.layerID, layer.handle)
    }

    func testEABRoundtripWithOversizedTablePrimitiveInBlock() throws {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])

        let column = DataTableColumn(name: "Payload")
        let longValue = String(repeating: "A", count: 70_000)
        let data = DataTableData(
            columns: [column],
            rows: [DataTableRow(cells: [
                DataTableCell(columnID: column.id, value: .string(longValue))
            ])],
            title: "Oversized table")
        let block = CADBlock(
            name: "TableBlock",
            geometry: [.table(data: data, origin: .zero, color: nil)])
        doc.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip_long_table_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try EABWriter.write(document: doc, to: tempURL)
        let views = try EABReader.readViews(from: tempURL)
        let readDoc = try XCTUnwrap(views.first).document
        let readBlock = try XCTUnwrap(readDoc.allBlocks.first { $0.name == "TableBlock" })
        let readPrimitive = try XCTUnwrap(readBlock.geometry.first)
        guard case .table(let readData, _, _) = readPrimitive else {
            return XCTFail("Expected table primitive, got \(readPrimitive)")
        }
        XCTAssertEqual(readData.title, "Oversized table")
        XCTAssertEqual(readData.rows.first?.cells.first?.value, .string(longValue))
    }

    @MainActor
    func testEABAutosaveRoundtripFromImportedDXFWithOversizedTablePayload() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/bench/golden/multiline_text.dxf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))

        let imported = try DXFImporter.importDXF(filePath: fixtureURL.path)
        XCTAssertFalse(imported.entities.isEmpty)

        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers,
            blocks: imported.blocks,
            entities: imported.entities)

        let column = DataTableColumn(name: "Payload")
        let longValue = String(repeating: "Z", count: 70_000)
        let data = DataTableData(
            columns: [column],
            rows: [DataTableRow(cells: [
                DataTableCell(columnID: column.id, value: .string(longValue))
            ])])
        doc.importLayersBlocksEntities(
            layers: [],
            blocks: [CADBlock(
                name: "ImportedLongTable",
                geometry: [.table(data: data, origin: .zero, color: nil)])],
            entities: [])

        let eabURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave_long_table_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: eabURL) }

        let snapshots = [doc.buildSaveSnapshot(
            viewName: "Model",
            viewKind: .model,
            cameraState: .default)]
        try EABWriter.write(snapshots: snapshots, to: eabURL)

        let views = try EABReader.readViews(from: eabURL)
        let readDoc = try XCTUnwrap(views.first).document
        XCTAssertEqual(readDoc.allEntities.count, imported.entities.count)
        let readBlock = try XCTUnwrap(
            readDoc.allBlocks.first { $0.name == "ImportedLongTable" })
        let readPrimitive = try XCTUnwrap(readBlock.geometry.first)
        guard case .table(let readData, _, _) = readPrimitive else {
            return XCTFail("Expected table primitive, got \(readPrimitive)")
        }
        XCTAssertEqual(readData.rows.first?.cells.first?.value, .string(longValue))
    }

    func testBinaryStringLongLengthSentinelAndLegacyBoundary() {
        let legacyBoundary = String(repeating: "B", count: 65_535)
        let legacyWriter = BinaryWriter()
        legacyWriter.writeUInt16(65_535)
        legacyWriter.writeBytes(Data(legacyBoundary.utf8))
        let legacyReader = BinaryReader(data: legacyWriter.bytes)
        XCTAssertEqual(legacyReader.readString(), legacyBoundary)

        let boundary = String(repeating: "C", count: 65_535)
        let long = String(repeating: "D", count: 70_000)
        let writer = BinaryWriter()
        writer.writeString(boundary)
        writer.writeString(long)
        let reader = BinaryReader(data: writer.bytes, usesLongStringSentinel: true)
        XCTAssertEqual(reader.readString(), boundary)
        XCTAssertEqual(reader.readString(), long)
    }

    @MainActor
    func testCreateTextAndSelection() throws {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        
        let text = "Hello"
        let height = 2.5
        let insertPos = Vector3(x: 10.0, y: 20.0, z: 0.0)
        
        let prim = CADPrimitive.text(
            position: .zero,
            text: text,
            height: height,
            rotation: 0.0,
            style: "simplex.shx",
            alignH: 0,
            alignV: 0,
            mtextWidth: nil
        )
        
        var entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [prim],
            transform: Transform3D.translated(by: insertPos)
        )
        
        entity.xdata["dxf.text"] = .string(text)
        entity.xdata["dxf.textStyle"] = .string("simplex.shx")
        entity.xdata["dxf.textHeight"] = .double(height)
        entity.xdata["dxf.alignH"] = .int(0)
        entity.xdata["dxf.alignV"] = .int(0)
        
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [entity])
        
        // 1. Verify entity exists
        XCTAssertEqual(doc.allEntities.count, 1)
        let added = doc.allEntities.first!
        XCTAssertEqual(added.layerID, layer.handle)
        
        // 2. Verify bounding box is not empty and is in the correct place
        let wbb = added.worldBoundingBox
        XCTAssertNotNil(wbb)
        if let box = wbb {
            print("World box: min=(\(box.min.x), \(box.min.y)), max=(\(box.max.x), \(box.max.y))")
            XCTAssertEqual(box.min.x, 10.0, accuracy: 1e-5)
            // simplex.shx draws "Hello" with an ink span of 69 SHX units
            // (advance 75 units, cap height 21), so the box spans the
            // rendered ink, not the legacy 0.6 * height * character-count
            // estimate (which gave 17.5).
            XCTAssertEqual(box.max.x, 10.0 + 2.5 * 69.0 / 21.0, accuracy: 1e-5)
            XCTAssertEqual(box.min.y, 20.0 - 2.5, accuracy: 1e-5) // grows down to -2.5
            XCTAssertEqual(box.max.y, 20.0, accuracy: 1e-5)
        }
        
        // 3. Test selection hit test
        let selectionManager = CADSelectionManager()
        
        // Let's rebuild the document spatial grid so hitTest works
        doc.rebuildEntityGrid()
        
        // Click exactly inside the bounds: (10.5, 19.0)
        let hit = selectionManager.hitTest(worldX: 10.5, worldY: 19.0, document: doc, threshold: 3.0)
        XCTAssertEqual(hit, added.handle, "Expected hitTest to select the text entity")
        
        // Click far away: (50.0, 50.0)
        let miss = selectionManager.hitTest(worldX: 50.0, worldY: 50.0, document: doc, threshold: 3.0)
        XCTAssertNil(miss, "Expected hitTest to miss the text entity")
    }
}
