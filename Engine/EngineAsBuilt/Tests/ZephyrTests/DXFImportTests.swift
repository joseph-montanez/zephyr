import XCTest
@testable import ZephyrCore

// Large-file design note:
// This suite is intentionally queued for separation into independent
// XCTestCase types (not extensions), grouped by import behavior. Shared DXF
// construction should move to a focused fixture factory. See
// Documentation/LargeFileRefactoring.md.

@MainActor
final class DXFImportTests: XCTestCase {

    @MainActor
    func testImportVisibleTableThroughAnonymousBlockAndExport() throws {
        let tableDXF = """
        0
        SECTION
          2
        HEADER
          9
        $ACADVER
          1
        AC1024
          0
        ENDSEC
          0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
         70
             1
          0
        LAYER
          2
        0
         70
             0
         62
             7
          6
        CONTINUOUS
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        *T1
         70
             1
         10
        0.0
         20
        0.0
         30
        0.0
          3
        *T1
          1

          0
        LINE
          8
        0
         10
        0.0
         20
        0.0
         11
        40.0
         21
        0.0
          0
        LINE
          8
        0
         10
        40.0
         20
        0.0
         11
        40.0
         21
        20.0
          0
        LINE
          8
        0
         10
        40.0
         20
        20.0
         11
        0.0
         21
        20.0
          0
        LINE
          8
        0
         10
        0.0
         20
        20.0
         11
        0.0
         21
        0.0
          0
        LINE
          8
        0
         10
        20.0
         20
        0.0
         11
        20.0
         21
        20.0
          0
        TEXT
          8
        0
         10
        5.0
         20
        7.0
         40
        2.5
          1
        ROOM
          7
        STANDARD
          0
        TEXT
          8
        0
         10
        25.0
         20
        7.0
         40
        2.5
          1
        AREA
          7
        STANDARD
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        ACAD_TABLE
          5
        10
        100
        AcDbEntity
          8
        0
        100
        AcDbBlockReference
          2
        *T1
         10
        100.0
         20
        200.0
         30
        0.0
        100
        AcDbTable
        280
             0
         11
        1.0
         21
        0.0
         31
        0.0
         91
             2
         92
             2
          0
        ENDSEC
          0
        EOF
        """

        let dxfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("table_\(UUID().uuidString).dxf")
        let eabURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("table_\(UUID().uuidString).eab")
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("table_\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: dxfURL)
            try? FileManager.default.removeItem(at: eabURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }
        try tableDXF.write(to: dxfURL, atomically: true, encoding: .utf8)

        let imported = try DXFImporter.importDXF(filePath: dxfURL.path)
        let tableBlock = try XCTUnwrap(imported.blocks.first { $0.name == "*T1" })
        let tableEntity = try XCTUnwrap(imported.entities.first {
            $0.blockID == tableBlock.handle
        })

        XCTAssertGreaterThanOrEqual(tableBlock.geometry.count, 7)
        XCTAssertEqual(tableEntity.transform.position.x, 100, accuracy: 1e-9)
        XCTAssertEqual(tableEntity.transform.position.y, -200, accuracy: 1e-9)

        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers,
            blocks: imported.blocks,
            entities: imported.entities)
        XCTAssertEqual(tableEntity.resolvedGeometry(in: doc)?.count, tableBlock.geometry.count)

        try EABWriter.write(document: doc, to: eabURL)
        let saved = try EABReader.readDocument(from: eabURL)
        let savedBlocks = saved.blocks
        let savedEntities = saved.entities
        let savedTable = try XCTUnwrap(savedBlocks.first { $0.name == "*T1" })
        XCTAssertEqual(savedTable.geometry.count, tableBlock.geometry.count)
        XCTAssertTrue(savedEntities.contains { $0.blockID == savedTable.handle })

        try PDFExporter.export(document: doc, to: pdfURL)
        let pdfData = try Data(contentsOf: pdfURL)
        XCTAssertGreaterThan(pdfData.count, 500)
        XCTAssertEqual(
            String(decoding: pdfData.prefix(8), as: UTF8.self),
            "%PDF-1.7")
    }

    func testImportMinimalDXF() throws {
        // Locate the test DXF file
        let testFile = findTestFile("test_minimal.dxf")
        let url = URL(fileURLWithPath: testFile)

        let doc = CADDocument()
        try doc.importDXF(url: url)

        // Should have at least the "0" layer
        XCTAssertGreaterThanOrEqual(doc.allLayers.count, 1)
        XCTAssertTrue(doc.allLayers.contains(where: { $0.name == "0" }))

        // Should have entities
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 4, "Expected 4 entities: LINE, CIRCLE, ARC, LWPOLYLINE")

        // Verify entity types by checking primitives
        var lineCount = 0
        var circleCount = 0
        var arcCount = 0
        var polyCount = 0

        for entity in entities {
            guard let geom = doc.resolvedGeometry(for: entity) else { continue }
            for prim in geom {
                switch prim {
                case .line:    lineCount += 1
                case .circle:  circleCount += 1
                case .arc:     arcCount += 1
                case .polygon: polyCount += 1
                default: break
                }
            }
        }

        XCTAssertEqual(lineCount, 1, "Expected 1 LINE")
        XCTAssertEqual(circleCount, 1, "Expected 1 CIRCLE")
        XCTAssertEqual(arcCount, 1, "Expected 1 ARC")
        XCTAssertEqual(polyCount, 1, "Expected 1 closed LWPOLYLINE")
    }

    func testImportEmptyDXF() throws {
        // Create a minimal valid DXF with no entities
        let emptyDXF = """
        0
        SECTION
          2
        ENTITIES
          0
        ENDSEC
          0
        EOF
        """

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty_\(UUID().uuidString).dxf")
        try emptyDXF.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)

        // Should still have "0" layer
        XCTAssertTrue(doc.allLayers.contains(where: { $0.name == "0" }))
        // No entities
        XCTAssertEqual(doc.allEntities.count, 0)
    }

    func testImportDXFWithBlocks() throws {
        // DXF with a block definition and an insert
        let blockDXF = """
        0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        TestBlock
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
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
        10.0
         21
        10.0
         31
        0.0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        INSERT
          8
        0
          2
        TestBlock
         10
        50.0
         20
        50.0
         30
        0.0
         41
        1.0
         42
        1.0
         43
        1.0
         50
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("block_\(UUID().uuidString).dxf")
        try blockDXF.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)

        // Should have one block definition
        let blocks = doc.allBlocks
        XCTAssertEqual(blocks.count, 1, "Expected 1 block definition")
        XCTAssertTrue(blocks.contains(where: { $0.name == "TestBlock" }))

        // The TestBlock should have line geometry
        if let block = blocks.first(where: { $0.name == "TestBlock" }) {
            XCTAssertFalse(block.geometry.isEmpty, "Block should have geometry")
        }

        // Should have one INSERT entity
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 INSERT entity")

        // The INSERT entity should reference the block
        if let entity = entities.first {
            XCTAssertNotNil(entity.blockID, "INSERT entity should reference a block")
        }
    }

    // MARK: - Helpers

    private func findTestFile(_ name: String) -> String {
        // Search from current directory upward
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            // Also check the Engine/Zephyr directory
            let altCandidate = dir.appendingPathComponent("Engine/Zephyr/\(name)")
            if FileManager.default.fileExists(atPath: altCandidate.path) {
                return altCandidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: look in the build working directory
        return name
    }

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    // MARK: - Layers & Colors

    func testImportDXFWithLayers() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        Walls
         70
        0
         62
        7
          0
        LAYER
          2
        Electrical
         70
        0
         62
        1
          0
        LAYER
          2
        Hidden
         70
        0
         62
        8
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        Walls
         10
        0.0
         20
        0.0
         30
        0.0
         11
        100.0
         21
        0.0
         31
        0.0
          0
        CIRCLE
          8
        Electrical
         10
        50.0
         20
        50.0
         30
        0.0
         40
        10.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)

        let layers = doc.allLayers
        XCTAssertGreaterThanOrEqual(layers.count, 3, "Expected at least 3 layers (Walls, Electrical, Hidden + default 0)")
        XCTAssertTrue(layers.contains(where: { $0.name == "Walls" }))
        XCTAssertTrue(layers.contains(where: { $0.name == "Electrical" }))
        XCTAssertTrue(layers.contains(where: { $0.name == "Hidden" }))
        XCTAssertTrue(layers.contains(where: { $0.name == "0" }))

        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 2)
    }

    func testImportDXFWithLayerTransparency() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        TransLayer
         70
        0
         62
        7
        1001
        Acad
        1070
        0
        1001
        AcCmTransparency
        1071
        33554470
          0
        ENDTAB
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let layers = doc.allLayers
        guard let layer = layers.first(where: { $0.name == "TransLayer" }) else {
            XCTFail("Expected layer TransLayer to exist")
            return
        }
        XCTAssertEqual(layer.opacity, 0.15, accuracy: 0.01, "Expected 0.15 opacity for 85% transparent layer")
    }

    // MARK: - Spline

    func testImportDXFWithSpline() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        SPLINE
          8
        0
         70
        4
         71
        3
         72
        5
         73
        4
         40
        0.0
         40
        0.0
         40
        0.0
         40
        100.0
         40
        100.0
         10
        0.0
         20
        0.0
         30
        0.0
         10
        33.0
         20
        50.0
         30
        0.0
         10
        66.0
         20
        0.0
         30
        0.0
         10
        100.0
         20
        50.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 SPLINE entity")

        if let entity = entities.first, let geom = doc.resolvedGeometry(for: entity) {
            // Spline fit points should produce line segments
            XCTAssertGreaterThan(geom.count, 0, "Spline should produce geometry")
        }
    }

    // MARK: - Text / MText

    func testImportDXFWithText() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        TEXT
          8
        0
         10
        10.0
         20
        20.0
         30
        0.0
         40
        5.0
          1
        Hello World
          0
        MTEXT
          8
        0
         10
        10.0
         20
        40.0
         30
        0.0
         40
        5.0
          1
        Multi Line\\PText
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 2, "Expected 2 text entities")

        // Verify xdata was set
        var textCount = 0
        for entity in entities {
            if let txt = entity.xdata["dxf.text"], case .string(let s) = txt {
                XCTAssertFalse(s.isEmpty)
                textCount += 1
            }
        }
        XCTAssertEqual(textCount, 2, "Both TEXT and MTEXT should have dxf.text xdata")
    }

    func testImportDXFWithTextStyles() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        STYLE
          0
        STYLE
          2
        Standard
         70
        0
         40
        0.0
         41
        1.0
         50
        0.0
         71
        0
         42
        2.5
          3
        simplex.shx
          0
        STYLE
          2
        MyCustomStyle
         70
        0
         40
        0.0
         41
        1.0
         50
        0.0
         71
        0
         42
        3.5
          3
        romans.shx
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        TEXT
          8
        0
          7
        MyCustomStyle
         10
        10.0
         20
        20.0
         30
        0.0
         40
        5.0
          1
        Hello Style
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        XCTAssertEqual(doc.textStyleFonts["Standard"], "simplex.shx")
        XCTAssertEqual(doc.textStyleFonts["MyCustomStyle"], "romans.shx")
        
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)
        if let entity = entities.first {
            XCTAssertEqual(entity.xdata["dxf.textStyle"], .string("MyCustomStyle"))
        }
    }

    // MARK: - Ellipse

    func testImportDXFWithEllipse() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        ELLIPSE
          8
        0
         10
        50.0
         20
        50.0
         30
        0.0
         11
        80.0
         21
        50.0
         31
        0.0
         40
        0.5
         41
        0.0
         42
        6.283185307
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 ELLIPSE")

        if let entity = entities.first, let geom = doc.resolvedGeometry(for: entity) {
            // Full ellipse should become a polygon
            let hasPolygon = geom.contains(where: {
                if case .polygon = $0 { return true }; return false
            })
            XCTAssertTrue(hasPolygon, "Full ellipse should produce polygon geometry")
        }
    }

    /// Regression (186-749 KOMPAN Draco.dxf): 3D->2D projection exports
    /// emit elliptical arcs with ~1e-6 rad spans. Those must stay sliver
    /// arcs, not be promoted to full ellipses (rendered as huge stray
    /// circles). Only an exact 0...2pi span is a full ellipse.
    func testImportDXFTinySpanEllipseIsNotFullEllipse() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        ELLIPSE
          8
        0
         10
        87.64
         20
        144.14
         30
        0.0
         11
        4.727
         21
        -8.187
         31
        0.0
         40
        0.8199
         41
        1.780812251388864
         42
        1.780813394126411
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 ELLIPSE")

        guard let entity = entities.first, let geom = doc.resolvedGeometry(for: entity) else {
            XCTFail("Expected resolved geometry")
            return
        }
        let hasFullEllipse = geom.contains(where: {
            if case .ellipse = $0 { return true }; return false
        })
        XCTAssertFalse(hasFullEllipse, "Tiny-span ellipse arc must not become a full ellipse")

        // Whatever primitive it became, its extent must stay a sliver:
        // span 1.14e-6 rad on a 9.45 major is ~1e-5 world units, while a
        // full ellipse would span ~19 x 15.5.
        var pts: [Vector3] = []
        for prim in geom {
            switch prim {
            case .spline(let cps, _, _, _, _): pts += cps
            case .point(let p, _): pts.append(p)
            case .line(let a, let b, _): pts += [a, b]
            default: break
            }
        }
        XCTAssertFalse(pts.isEmpty, "Expected spline/point geometry for the sliver arc")
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let diag = hypot((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        XCTAssertLessThan(diag, 0.01, "Sliver arc extent must stay tiny, got \(diag)")
    }

    // MARK: - Dimensions

    func testImportDXFWithDimension() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        DIMENSION
          8
        0
          2
        *D0
         10
        0.0
         20
        50.0
         30
        0.0
         11
        50.0
         21
        60.0
         31
        0.0
         70
        1
          3
        STANDARD
          1

          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 DIMENSION entity")
    }

    // MARK: - Solid / 3Dface

    func testImportDXFWithSolid() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        SOLID
          8
        0
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10.0
         21
        0.0
         31
        0.0
         12
        10.0
         22
        10.0
         32
        0.0
         13
        0.0
         23
        10.0
         33
        0.0
          0
        3DFACE
          8
        0
         10
        20.0
         20
        0.0
         30
        0.0
         11
        30.0
         21
        0.0
         31
        0.0
         12
        30.0
         22
        10.0
         32
        0.0
         13
        20.0
         23
        10.0
         33
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 2, "Expected 2 entities (SOLID + 3DFACE)")

        for entity in entities {
            guard let geom = doc.resolvedGeometry(for: entity) else { continue }
            let hasPolygon = geom.contains(where: {
                switch $0 {
                case .polygon, .fillPolygon: return true
                default: return false
                }
            })
            XCTAssertTrue(hasPolygon, "SOLID/3DFACE should produce polygon or fillPolygon geometry")
        }
    }

    // MARK: - Complex Blocks

    func testImportDXFWithComplexBlocks() throws {
        let dxf = """
        0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        Chair
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        CIRCLE
          8
        0
         10
        5.0
         20
        5.0
         30
        0.0
         40
        5.0
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
        10.0
         21
        0.0
         31
        0.0
          0
        ENDBLK
          0
        BLOCK
          8
        0
          2
        Table
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
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
        50.0
         21
        0.0
         31
        0.0
          0
        LINE
          8
        0
         10
        50.0
         20
        0.0
         30
        0.0
         11
        50.0
         21
        30.0
         31
        0.0
          0
        LINE
          8
        0
         10
        50.0
         20
        30.0
         30
        0.0
         11
        0.0
         21
        30.0
         31
        0.0
          0
        LINE
          8
        0
         10
        0.0
         20
        30.0
         30
        0.0
         11
        0.0
         21
        0.0
         31
        0.0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        INSERT
          8
        0
          2
        Table
         10
        100.0
         20
        100.0
         30
        0.0
         41
        1.0
         42
        1.0
         43
        1.0
         50
        0.0
          0
        INSERT
          8
        0
          2
        Chair
         10
        110.0
         20
        115.0
         30
        0.0
         41
        1.0
         42
        1.0
         43
        1.0
         50
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)

        let blocks = doc.allBlocks
        XCTAssertEqual(blocks.count, 2, "Expected 2 block definitions")

        let chairBlock = blocks.first(where: { $0.name == "Chair" })
        let tableBlock = blocks.first(where: { $0.name == "Table" })
        XCTAssertNotNil(chairBlock)
        XCTAssertNotNil(tableBlock)

        // Chair: 1 circle + 1 line = 2 primitives
        if let cb = chairBlock {
            XCTAssertEqual(cb.geometry.count, 2, "Chair block should have 2 primitives")
        }
        // Table: 4 lines = 4 primitives
        if let tb = tableBlock {
            XCTAssertEqual(tb.geometry.count, 4, "Table block should have 4 primitives")
        }

        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 2, "Expected 2 INSERT entities")

        for entity in entities {
            XCTAssertNotNil(entity.blockID)
        }
    }

    // MARK: - Scaled & Rotated Insert

    func testImportDXFWithScaledRotatedInsert() throws {
        // Note: DXF group code 50 (rotation angle) is in DEGREES
        let dxf = """
        0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        Arrow
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
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
        10.0
         21
        0.0
         31
        0.0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        INSERT
          8
        0
          2
        Arrow
         10
        50.0
         20
        50.0
         30
        0.0
         41
        2.0
         42
        2.0
         43
        1.0
         50
        45.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 INSERT")

        if let entity = entities.first {
            XCTAssertNotNil(entity.blockID, "INSERT should reference a block")
            // Verify position
            XCTAssertEqual(entity.transform.position.x, 50.0, accuracy: 0.01)
            XCTAssertEqual(entity.transform.position.y, -50.0, accuracy: 0.01)
            // Verify scale (note: combined scale+rotation transform makes raw scale extraction approximate)
            XCTAssertGreaterThan(entity.transform.scale.x, 1.9)
            XCTAssertGreaterThan(entity.transform.scale.y, 1.9)
            // Verify entity has a bounding box
            XCTAssertNotNil(entity.localBoundingBox)
        }
    }

    func testImportNonInsertEntitiesHaveIdentityTransform() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        0
         10
        10.0
         20
        20.0
         30
        0.0
         11
        100.0
         21
        200.0
         31
        0.0
          0
        CIRCLE
          8
        0
         10
        30.0
         20
        40.0
         30
        0.0
         40
        15.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 2)

        for entity in entities {
            XCTAssertEqual(entity.transform, Transform3D.identity, "Non-INSERT entity transform should be identity")

            if let geom = doc.resolvedGeometry(for: entity) {
                for prim in geom {
                    switch prim {
                    case .line(let start, let end, _):
                        XCTAssertEqual(start.x, 10.0)
                        XCTAssertEqual(start.y, -20.0)
                        XCTAssertEqual(end.x, 100.0)
                        XCTAssertEqual(end.y, -200.0)
                    case .circle(let center, let radius, _):
                        XCTAssertEqual(center.x, 30.0)
                        XCTAssertEqual(center.y, -40.0)
                        XCTAssertEqual(radius, 15.0)
                    default:
                        XCTFail("Unexpected primitive type")
                    }
                }
            } else {
                XCTFail("Entity should have resolved geometry")
            }
        }
    }

    func testImportDXFWithUnderlineText() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        TEXT
          8
        0
         10
        10.0
         20
        20.0
         30
        0.0
         40
        5.0
          1
        %%uGREAT ROOM
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)
        
        let textEntity = entities[0]
        XCTAssertEqual(textEntity.xdata["dxf.text"], .string("%%uGREAT ROOM"))
    }

    func testCleanMTextFormattingDirect() {
        let input1 = "{\\pxqc;\\Farchquik.shx|c0;SHEAR PANELS, 3/8\" OSB}"
        let cleaned1 = DXFEntityConverter.cleanMTextFormatting(input1)
        XCTAssertEqual(cleaned1, "SHEAR PANELS, 3/8\" OSB")

        let input2 = "{¥pxqc;¥Farchquik.shx|c0;SHEAR PANELS, 3/8\" OSB}"
        let cleaned2 = DXFEntityConverter.cleanMTextFormatting(input2)
        XCTAssertEqual(cleaned2, "SHEAR PANELS, 3/8\" OSB")
    }

    func testImportDXFWithMTextWrapping() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        10.0
         20
        20.0
         30
        0.0
         40
        6.4
         41
        69.6875
          1
        {\\pxqc;\\Farchquik.shx|c0;SHEAR PANELS, 3/8\" OSB MIN. W/ 6\" EDGE & 12\" FIELD NAILING}
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)
        
        let textEntity = entities[0]
        XCTAssertEqual(textEntity.xdata["dxf.text"], .string("SHEAR PANELS, 3/8\" OSB MIN. W/ 6\" EDGE & 12\" FIELD NAILING"))
        XCTAssertEqual(textEntity.xdata["dxf.mtextWidth"], .double(69.6875))
        XCTAssertEqual(textEntity.xdata["dxf.alignH"], .int(0)) // Left
        XCTAssertEqual(textEntity.xdata["dxf.alignV"], .int(3)) // Top
    }

    func testSHXShapeFontWrapping() throws {
        let fontFile = findTestFile("Fonts/simplex.shx")
        let url = URL(fileURLWithPath: fontFile)
        let font = try SHXShapeFont(url: url)
        
        let text = "SHEAR PANELS, 3/8\" OSB MIN. W/ 6\" EDGE & 12\" FIELD NAILING"
        
        // Render with huge maxWidth -> should fit in 1 line
        let primitivesSingle = font.renderText(text, origin: .zero, height: 6.4, alignH: 0, alignV: 0, maxWidth: 1000.0)
        
        // Render with small maxWidth -> should wrap into multiple lines
        let primitivesWrapped = font.renderText(text, origin: .zero, height: 6.4, alignH: 0, alignV: 0, maxWidth: 69.6875)
        
        XCTAssertGreaterThan(primitivesSingle.count, 0)
        XCTAssertGreaterThan(primitivesWrapped.count, 0)
        
        // Extents: Single line should be flat vertically (no vertical layout offset spacing)
        // Let's check the y values of the points in lines
        var singleYValues = Set<Double>()
        for case .line(let start, let end, _) in primitivesSingle {
            singleYValues.insert(round(start.y * 10.0) / 10.0)
            singleYValues.insert(round(end.y * 10.0) / 10.0)
        }
        
        var wrappedYValues = Set<Double>()
        for case .line(let start, let end, _) in primitivesWrapped {
            wrappedYValues.insert(round(start.y * 10.0) / 10.0)
            wrappedYValues.insert(round(end.y * 10.0) / 10.0)
        }
        
        // The wrapped lines should span much more Y variations (since there are multiple line heights)
        XCTAssertGreaterThan(wrappedYValues.count, singleYValues.count)
    }

    func testImportDXFWithPolylineBulge() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LWPOLYLINE
          8
        0
         90
        2
         70
        0
         10
        0.0
         20
        0.0
         42
        1.0
         10
        0.0
         20
        2.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)

        guard let entity = entities.first,
              let geom = doc.resolvedGeometry(for: entity),
              case .polyline(let path, _) = geom.first
        else {
            return XCTFail("Expected one bulge-aware polyline primitive")
        }

        XCTAssertEqual(geom.count, 1)
        XCTAssertEqual(path.vertices.count, 2)
        XCTAssertFalse(path.isClosed)
        XCTAssertEqual(path.vertices[0].bulge, -1.0, accuracy: 0.000001)

        let rendered = path.tessellatedPoints()
        XCTAssertGreaterThan(rendered.map(\.x).max() ?? 0, 0.9)
        XCTAssertEqual(rendered.last?.x ?? 1, 0.0, accuracy: 0.001)
        XCTAssertEqual(rendered.last?.y ?? 0, -2.0, accuracy: 0.001)
    }

    func testImportDXFWithPolylineBulgeNegative() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LWPOLYLINE
          8
        0
         90
        2
         70
        0
         10
        0.0
         20
        0.0
         42
        -1.0
         10
        0.0
         20
        2.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)

        guard let entity = entities.first,
              let geom = doc.resolvedGeometry(for: entity),
              case .polyline(let path, _) = geom.first
        else {
            return XCTFail("Expected one bulge-aware polyline primitive")
        }

        XCTAssertEqual(geom.count, 1)
        XCTAssertEqual(path.vertices.count, 2)
        XCTAssertEqual(path.vertices[0].bulge, 1.0, accuracy: 0.000001)

        let rendered = path.tessellatedPoints()
        XCTAssertLessThan(rendered.map(\.x).min() ?? 0, -0.9)
        XCTAssertEqual(rendered.last?.x ?? 1, 0.0, accuracy: 0.001)
        XCTAssertEqual(rendered.last?.y ?? 0, -2.0, accuracy: 0.001)
    }

    func testImportDXFWithHatchFills() throws {
        // DXF with HATCH (solid fill)
        let hatchSolidDXF = """
        0
        SECTION
          2
        ENTITIES
          0
        HATCH
          8
        0
          2
        SOLID
         70
        1
         71
        0
         91
        1
         92
        1
         93
        4
         10
        0.0
         20
        0.0
         10
        10.0
         20
        0.0
         10
        10.0
         20
        10.0
         10
        0.0
         20
        10.0
         97
        0
          0
        ENDSEC
          0
        EOF
        """
        let docSolid = try importDXFString(hatchSolidDXF)
        XCTAssertEqual(docSolid.allEntities.count, 1)
        if let entity = docSolid.allEntities.first, let geom = docSolid.resolvedGeometry(for: entity) {
            XCTAssertEqual(geom.count, 1)
            if case .fillPolygon(let pts, _) = geom[0] {
                XCTAssertEqual(pts.count, 4)
                // Vertex Y should be negated during import: (0,0), (10,0), (10,-10), (0,-10)
                XCTAssertEqual(pts[0].x, 0.0, accuracy: 0.001)
                XCTAssertEqual(pts[0].y, 0.0, accuracy: 0.001)
                XCTAssertEqual(pts[2].x, 10.0, accuracy: 0.001)
                XCTAssertEqual(pts[2].y, -10.0, accuracy: 0.001)
            } else {
                XCTFail("Expected fillPolygon primitive for solid hatch")
            }
        }

        // DXF with HATCH (pattern fill - ANSI31/lines)
        let hatchPatternDXF = """
        0
        SECTION
          2
        ENTITIES
          0
        HATCH
          8
        0
          2
        ANSI31
         70
        0
         71
        0
         91
        1
         92
        1
         93
        4
         10
        0.0
         20
        0.0
         10
        10.0
         20
        0.0
         10
        10.0
         20
        10.0
         10
        0.0
         20
        10.0
         97
        0
         41
        1.0
         52
        45.0
          0
        ENDSEC
          0
        EOF
        """
        let docPattern = try importDXFString(hatchPatternDXF)
        XCTAssertEqual(docPattern.allEntities.count, 1)
        if let entity = docPattern.allEntities.first, let geom = docPattern.resolvedGeometry(for: entity) {
            // Pattern fill generates multiple line primitives inside the boundary
            XCTAssertGreaterThan(geom.count, 0)
            for prim in geom {
                if case .line = prim {
                    // correct
                } else {
                    XCTFail("Expected line primitives for pattern hatch")
                }
            }
        }
    }

    func testEntityStylesAndDashing() throws {
        // DXF with a line styled with line weight, line type, and scale
        let styledDXF = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        StyledLayer
         70
        0
         62
        1
         370
        35
         6
        DASHED
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        StyledLayer
          6
        DASHED
         370
        50
         48
        2.5
         10
        0.0
         20
        0.0
         30
        0.0
         11
        100.0
         21
        0.0
         31
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(styledDXF)
        
        // Verify layer properties are parsed
        if let layer = doc.allLayers.first(where: { $0.name == "StyledLayer" }) {
            XCTAssertEqual(layer.lineWeight, 0.35, accuracy: 0.001) // 35 in DXF is 0.35mm
            XCTAssertEqual(layer.lineType, "DASHED")
        } else {
            XCTFail("Layer StyledLayer not found")
        }

        // Verify entity properties are parsed and stored in xdata
        XCTAssertEqual(doc.allEntities.count, 1)
        if let entity = doc.allEntities.first {
            XCTAssertEqual(entity.xdata["dxf.lineType"], .string("DASHED"))
            XCTAssertEqual(entity.xdata["dxf.lineWeight"], .double(0.50)) // 50 in DXF is 0.50mm
            XCTAssertEqual(entity.xdata["dxf.lineTypeScale"], .double(2.5))
        }
    }

    func testCADRendererBridgeStyling() async throws {
        // Create a snapshot with styled entities and layers
        let layerID = UUID()
        let layer = Layer(
            handle: layerID,
            name: "StyledLayer",
            isVisible: true,
            lineWeight: 0.35,
            color: .red,
            lineType: "DASHED"
        )
        
        let lineEntity = CADEntity(
            handle: UUID(),
            layerID: layerID,
            blockID: nil,
            localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 100, y: 0, z: 0))],
            transform: .identity
        )
        
        var snapLayers = [UUID: Layer]()
        snapLayers[layerID] = layer
        var snapEntities = [UUID: CADEntity]()
        snapEntities[lineEntity.handle] = lineEntity
        
        let snapshot = CADDocumentSnapshot(
            layers: snapLayers,
            blocks: [:],
            entities: snapEntities,
            constraints: [:],
            solvedTransforms: [:],
            activeLayerID: layerID,
            unit: .millimeter,
            textStyleFonts: [:]
        )
        
        // Compute PrimitiveSpecs
        let results = await CADRendererBridge.computeSpecs(fromSnapshot: snapshot, simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1)
        
        if let result = results.first {
            let specs = result.specs
            // Since lineType is DASHED, the line is subdivided into multiple dash segments
            XCTAssertGreaterThan(specs.count, 1, "Dashed line should be subdivided into multiple specs")
            for spec in specs {
                // computeSpecs produces .lines specs with lineWeight metadata.
                // The actual thick-quad expansion happens at render time in Engine+Loop.
                XCTAssertEqual(spec.type, .lines)
                XCTAssertEqual(spec.points.count, 2, "Each dash segment should have 2 points")
                XCTAssertEqual(spec.lineWeight, 0.35, accuracy: 0.001, "Line weight should be inherited from layer")
            }
        }
    }

    func testPolylineWidthImportAndBridge() async throws {
        // 1. Test importing of LWPOLYLINE with constant width (group code 43)
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LWPOLYLINE
          8
        0
         90
        2
         70
        0
         43
        3.0
         10
        0.0
         20
        0.0
         10
        10.0
         20
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)
        
        guard let entity = entities.first else {
            XCTFail("No entity found")
            return
        }
        
        XCTAssertEqual(entity.xdata["dxf.polylineWidth"], .double(3.0))
        
        // 2. Test that the bridge resolves polylineWidth to geomWidth in specs
        let layerID = entity.layerID
        let layer = Layer(handle: layerID, name: "0")
        var snapLayers = [UUID: Layer]()
        snapLayers[layerID] = layer
        var snapEntities = [UUID: CADEntity]()
        snapEntities[entity.handle] = entity
        
        let snapshot = CADDocumentSnapshot(
            layers: snapLayers,
            blocks: [:],
            entities: snapEntities,
            constraints: [:],
            solvedTransforms: [:],
            activeLayerID: layerID,
            unit: .millimeter,
            textStyleFonts: [:]
        )
        
        let results = await CADRendererBridge.computeSpecs(fromSnapshot: snapshot, simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1)
        
        if let result = results.first {
            let specs = result.specs
            XCTAssertEqual(specs.count, 1)
            XCTAssertEqual(specs[0].geomWidth, 3.0)
        }
    }

    func testMergedVeluxLogoHatch() async throws {
        let filePath = "c:/dev/as-built/A_000217.dxf"
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Skipping testMergedVeluxLogoHatch: file not present.")
            return
        }
        let (_, blocks, _, _, _, _) = try DXFImporter.importDXF(filePath: filePath)
        
        let logoBlock = blocks.first(where: { $0.name == "VELUX_LOGO_ARKITEKT" })
        XCTAssertNotNil(logoBlock)
        
        if let block = logoBlock {
            let complexFills = block.geometry.compactMap { prim -> (outer: [Vector3], holes: [[Vector3]])? in
                if case .fillComplexPolygon(let outer, let holes, _) = prim {
                    return (outer, holes)
                }
                return nil
            }
            
            XCTAssertEqual(complexFills.count, 1)
            if let firstFill = complexFills.first {
                XCTAssertGreaterThan(firstFill.outer.count, 3)
                XCTAssertEqual(firstFill.holes.count, 9)
                
                // Construct a mock entity & snapshot to trigger computeSpecs
                let layerID = UUID()
                let layer = Layer(handle: layerID, name: "VELUX_HATCH")
                let entity = CADEntity(handle: UUID(), layerID: layerID, localGeometry: block.geometry)
                
                var snapLayers = [UUID: Layer]()
                snapLayers[layerID] = layer
                var snapEntities = [UUID: CADEntity]()
                snapEntities[entity.handle] = entity
                
                let snapshot = CADDocumentSnapshot(
                    layers: snapLayers,
                    blocks: [:],
                    entities: snapEntities,
                    constraints: [:],
                    solvedTransforms: [:],
                    activeLayerID: layerID,
                    unit: .millimeter,
                    textStyleFonts: [:]
                )
                
                print("--- RUNNING BRIDGE SPECS FOR VELUX HATCH ---")
                let results = await CADRendererBridge.computeSpecs(fromSnapshot: snapshot, simplifyComplexBlocks: false)
                XCTAssertEqual(results.count, 1)
                print("Bridge compute completed.")
                
                print("--- VELUX LOGO BLOCK GEOMETRY ---")
                for (idx, prim) in block.geometry.enumerated() {
                    switch prim {
                    case .fillComplexPolygon(let outer, let holes, _):
                        print("  [\(idx)] fillComplexPolygon: outer=\(outer.count), holes=\(holes.count)")
                    case .fillPolygon(let pts, _):
                        print("  [\(idx)] fillPolygon: pts=\(pts.count)")
                    case .polygon(let pts, _):
                        print("  [\(idx)] polygon: pts=\(pts.count)")
                    case .line(let s, let e, _):
                        print("  [\(idx)] line: \(s) to \(e)")
                    case .circle(let c, let r, _):
                        print("  [\(idx)] circle: center=\(c), radius=\(r)")
                    case .arc(let c, let r, let s, let e, _):
                        print("  [\(idx)] arc: center=\(c), radius=\(r), sweep=\(s) to \(e)")
                    default:
                        print("  [\(idx)] other: \(prim)")
                    }
                }
            }
        }
    }

    func testImportDXFWithLeader() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LEADER
          8
        0
          3
        STANDARD
         71
        1
         72
        0
         73
        3
         76
        3
         40
        2.5
         41
        10.0
         10
        10.0
         20
        10.0
         30
        0.0
         10
        20.0
         20
        20.0
         30
        0.0
         10
        30.0
         20
        20.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 LEADER entity")

        if let entity = entities.first, let geom = doc.resolvedGeometry(for: entity) {
            var lineCount = 0
            var fillPolyCount = 0
            
            for prim in geom {
                switch prim {
                case .line:
                    lineCount += 1
                case .fillPolygon(let points, _):
                    XCTAssertEqual(points.count, 3, "Arrowhead should be a triangle")
                    fillPolyCount += 1
                default:
                    XCTFail("Unexpected primitive type: \(prim)")
                }
            }
            
            XCTAssertEqual(fillPolyCount, 1, "Expected 1 filled arrowhead")
            XCTAssertEqual(lineCount, 3, "Expected 3 line segments (2 leader segments + 1 underline segment)")
        }
    }

    func testImportDXFWithLeaderOffset() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LEADER
          8
        0
          3
        STANDARD
         71
        1
         72
        0
         73
        3
         76
        3
         40
        2.5
         41
        10.0
        213
        2.0
         10
        10.0
         20
        10.0
         30
        0.0
         10
        20.0
         20
        20.0
         30
        0.0
         10
        30.0
         20
        20.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """

        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1, "Expected 1 LEADER entity")

        if let entity = entities.first, let geom = doc.resolvedGeometry(for: entity) {
            var lineCount = 0
            var fillPolyCount = 0
            var lastLineStart: Vector3 = .zero
            var lastLineEnd: Vector3 = .zero
            
            for prim in geom {
                switch prim {
                case .line(let start, let end, _):
                    lineCount += 1
                    lastLineStart = start
                    lastLineEnd = end
                case .fillPolygon(let points, _):
                    XCTAssertEqual(points.count, 3, "Arrowhead should be a triangle")
                    fillPolyCount += 1
                default:
                    XCTFail("Unexpected primitive type: \(prim)")
                }
            }
            
            XCTAssertEqual(fillPolyCount, 1, "Expected 1 filled arrowhead")
            XCTAssertEqual(lineCount, 3, "Expected 3 line segments")
            
            // Last line segment is the text underline (landing extension)
            // Points list ends at (30.0, -20.0) in screen coordinates (since Y is negated)
            // Offset X is 2.0. So start X of underline should be 30.0 + 2.0 = 32.0.
            // Width is 10.0. So end X of underline should be 32.0 + 10.0 = 42.0.
            XCTAssertEqual(lastLineStart.x, 32.0, accuracy: 0.001)
            XCTAssertEqual(lastLineEnd.x, 42.0, accuracy: 0.001)
            XCTAssertEqual(lastLineStart.y, -20.0, accuracy: 0.001)
            XCTAssertEqual(lastLineEnd.y, -20.0, accuracy: 0.001)
        }
    }

    // MARK: - MTEXT alignment code and LEADER arrow scale/orientation

    func testMTextAlignmentCodeDoesNotCenterParagraph() throws {
        // AutoCAD writes \A1; (stacked-text vertical alignment, default
        // center) at the start of nearly every MTEXT string. It must not be
        // treated as paragraph justification.
        // Note: \PW/ contains a genuine \P paragraph break, so this parses
        // as two paragraphs (matching the two rendered lines).
        let formatted = MTEXTFormatter.parse("\\A1;PROVIDE 20 MIN. DOOR\\PW/ SELF CLOSING HINGES")
        XCTAssertEqual(formatted.paragraphs.count, 2)
        for paragraph in formatted.paragraphs {
            XCTAssertEqual(paragraph.alignment, 0, "\\A1; must leave paragraph alignment at inherit (0)")
        }
        XCTAssertNil(formatted.paragraphs[0].stackAlignment, "default \\A1; carries no explicit stack alignment")
        let serialized = MTEXTFormatter.serialize(formatted)
        XCTAssertFalse(serialized.contains("qc"), "round-trip must not emit paragraph-center justification, got: \(serialized)")
    }

    func testMTextExplicitStackAlignmentRoundTrips() throws {
        let formatted = MTEXTFormatter.parse("\\A0;\\S1#2; done")
        XCTAssertEqual(formatted.paragraphs[0].stackAlignment, 0)
        XCTAssertEqual(formatted.paragraphs[0].alignment, 0)
        XCTAssertTrue(MTEXTFormatter.serialize(formatted).contains("\\A0;"))

        let plain = MTEXTFormatter.parse("just text")
        XCTAssertNil(plain.paragraphs[0].stackAlignment)
        XCTAssertFalse(MTEXTFormatter.serialize(plain).contains("\\A"))
    }

    func testImportDXFWithMTextAlignmentCodeStaysLeftAnchored() throws {
        // Mirrors floorplan.dxf handle 1450: width-0 MTEXT, attachment 1
        // (top-left), raw text starting with \A1;.
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        100.0
         20
        50.0
         30
        0.0
         40
        6.0
         41
        0.0
         71
        1
          1
        \\A1;PROVIDE 20 MIN. DOOR\\PW/ SELF CLOSING HINGES
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entities = doc.allEntities
        XCTAssertEqual(entities.count, 1)
        let entity = try XCTUnwrap(entities.first)
        XCTAssertEqual(entity.xdata["dxf.alignH"], .int(0))
        XCTAssertEqual(entity.xdata["dxf.alignV"], .int(3))
        guard case .string(let json) = entity.xdata["dxf.formattedText"] else {
            return XCTFail("expected dxf.formattedText xdata")
        }
        let formatted = try JSONDecoder().decode(
            FormattedText.self, from: Data(json.utf8))
        XCTAssertEqual(formatted.paragraphs[0].alignment, 0,
                       "\\A1; must not center the paragraph")
    }

    func testImportDXFWithMTextCenterAttachmentDecomposesJustification() throws {
        // MTEXT group 71 = 5 is middle-center; the bridge renders from
        // dxf.alignH/dxf.alignV, which must reflect the attachment point.
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        100.0
         20
        50.0
         30
        0.0
         40
        6.0
         41
        0.0
         71
        5
          1
        CENTERED NOTE
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first)
        XCTAssertEqual(entity.xdata["dxf.alignH"], .int(1))
        XCTAssertEqual(entity.xdata["dxf.alignV"], .int(2))
    }

    func testImportDXFWithLegacyLeaderAppliesDimscale() throws {
        // DIMSTYLE BIGDIM: DIMSCALE 32, DIMASZ 0.15625 -> effective arrow 5.0.
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        DIMSTYLE
         70
        1
          0
        DIMSTYLE
          2
        BIGDIM
         40
        32.0
         41
        0.15625
        140
        2.5
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LEADER
          8
        0
          3
        BIGDIM
         71
        1
         72
        0
         76
        3
         10
        10.0
         20
        10.0
         30
        0.0
         10
        20.0
         20
        10.0
         30
        0.0
         10
        30.0
         20
        10.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let geom = try XCTUnwrap(doc.resolvedGeometry(for: entity))
        let tip = Vector3(x: 10.0, y: -10.0, z: 0.0)
        var arrowPoints: [Vector3] = []
        for prim in geom {
            if case .fillPolygon(let points, _) = prim {
                arrowPoints = points
            }
        }
        XCTAssertEqual(arrowPoints.count, 3, "expected closed-filled arrowhead triangle")
        XCTAssertTrue(arrowPoints.contains(where: { $0.distance(to: tip) < 1e-9 }),
                      "arrowhead tip must sit on the leader's first vertex")
        // Axial extent: the triangle corners flare sideways, so project onto
        // the leader direction instead of measuring corner distance.
        let axis5 = Vector3(x: 1.0, y: 0.0, z: 0.0)
        let projections5 = arrowPoints.map { ($0 - tip).dot(axis5) }
        XCTAssertEqual(projections5.max() ?? 0, 5.0, accuracy: 0.01,
                       "arrowhead extent must be DIMASZ x DIMSCALE (0.15625 x 32)")
        XCTAssertEqual(projections5.min() ?? 0, 0.0, accuracy: 1e-9,
                       "arrowhead base must start at the leader tip")
    }

    func testImportDXFWithLegacyLeaderCustomArrowOrientation() throws {
        // Block authored per AutoCAD convention: tip at origin, body in -X,
        // unit size. Rendered arrow must extend from the tip toward the tail.
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        DIMSTYLE
         70
        1
          0
        DIMSTYLE
          2
        CUSTDIM
          5
        MYARROW
         40
        1.0
         41
        2.0
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        MYARROW
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
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
        -1.0
         21
        0.2
         31
        0.0
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
        -1.0
         21
        -0.2
         31
        0.0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LEADER
          8
        0
          3
        CUSTDIM
         71
        1
         72
        0
         76
        2
         10
        0.0
         20
        0.0
         30
        0.0
         10
        10.0
         20
        0.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let geom = try XCTUnwrap(doc.resolvedGeometry(for: entity))
        let tip = Vector3(x: 0.0, y: 0.0, z: 0.0)
        var arrowEnds: [Vector3] = []
        for prim in geom {
            if case .line(let start, let end, _) = prim {
                // Leader segment is 10 long; arrow strokes are ~2 long.
                if start.distance(to: end) < 5.0 {
                    arrowEnds.append(start.distance(to: tip) < 1e-9 ? end : start)
                }
            }
        }
        XCTAssertEqual(arrowEnds.count, 2, "expected two custom arrow strokes, got \(geom)")
        for end in arrowEnds {
            XCTAssertGreaterThanOrEqual(end.x, -1e-9,
                "arrow body must extend toward the tail (+X), not past the tip")
        }
        let extent = arrowEnds.map { $0.distance(to: tip) }.max() ?? 0
        XCTAssertEqual(extent, 2.0, accuracy: 0.05,
                       "unit block scaled by DIMASZ (2.0) x DIMSCALE (1.0)")
    }

    func testImportDXFWithLegacyLeaderDimstyleOverrideScale() throws {
        // Per-entity DSTYLE XData overrides DIMASZ (41) and DIMSCALE (40):
        // effective arrow = 0.5 x 8.0 = 4.0.
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LEADER
          8
        0
          3
        DSTY
         71
        1
         72
        0
         76
        2
        1001
        ACAD
        1000
        DSTYLE
        1002
        {
        1070
        41
        1040
        0.5
        1070
        40
        1040
        8.0
        1002
        }
         10
        0.0
         20
        0.0
         30
        0.0
         10
        10.0
         20
        0.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let geom = try XCTUnwrap(doc.resolvedGeometry(for: entity))
        let tip = Vector3(x: 0.0, y: 0.0, z: 0.0)
        var arrowPoints: [Vector3] = []
        for prim in geom {
            if case .fillPolygon(let points, _) = prim {
                arrowPoints = points
            }
        }
        XCTAssertEqual(arrowPoints.count, 3)
        let axis4 = Vector3(x: 1.0, y: 0.0, z: 0.0)
        let projections4 = arrowPoints.map { ($0 - tip).dot(axis4) }
        XCTAssertEqual(projections4.max() ?? 0, 4.0, accuracy: 0.01,
                       "DSTYLE DIMASZ override (0.5) x DIMSCALE override (8.0)")
        XCTAssertEqual(projections4.min() ?? 0, 0.0, accuracy: 1e-9,
                       "arrowhead base must start at the leader tip")
    }

    func testDumpLosAngelesLayers() throws {
        let filePath = findTestFile("los-angeles.dxf")
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Skipping testDumpLosAngelesLayers: los-angeles.dxf not found.")
            return
        }
        let (layers, _, entities, _, _, _) = try DXFImporter.importDXF(filePath: filePath)
        print("--- los-angeles.dxf LAYERS ---")
        for layer in layers {
            print("Layer name: \(layer.name), lineWeight: \(layer.lineWeight), color: \(layer.color)")
        }

        var maxPolylineWidth = 0.0
        var entitiesWithPolylineWidth = 0
        var maxWeight = 0.0
        var entitiesWithExplicitWeight = 0
        var countGreaterThan025 = 0
        var sampleWeights: [Double] = []

        var entityTypeCounts: [String: Int] = [:]

        for entity in entities {
            let typeStr: String
            if let bid = entity.blockID {
                typeStr = "INSERT(block)"
            } else if let geom = entity.localGeometry {
                typeStr = "LOOSE(\(geom.map { "\($0)" }.joined(separator: ",")))"
            } else {
                typeStr = "EMPTY"
            }
            entityTypeCounts[typeStr, default: 0] += 1

            if let pwv = entity.xdata["dxf.polylineWidth"], case .double(let d) = pwv {
                entitiesWithPolylineWidth += 1
                if d > maxPolylineWidth {
                    maxPolylineWidth = d
                }
            }
            if let lwv = entity.xdata["dxf.lineWeight"], case .double(let d) = lwv {
                entitiesWithExplicitWeight += 1
                if d > maxWeight {
                    maxWeight = d
                }
            }
            
            // Resolve actual weight using layer table
            let layerID = entity.layerID
            let layer = layers.first(where: { $0.handle == layerID })
            let lw: Double
            if let lwv = entity.xdata["dxf.lineWeight"], case .double(let d) = lwv {
                lw = d
            } else if let l = layer {
                lw = l.lineWeight
            } else {
                lw = 0.25
            }
            
            if lw > 0.25 {
                countGreaterThan025 += 1
                if sampleWeights.count < 10 {
                    sampleWeights.append(lw)
                }
            }
        }
        
        print("--- Entity statistics ---")
        print("Total entities: \(entities.count)")
        print("Entity type counts:")
        for (k, v) in entityTypeCounts.sorted(by: { $0.value > $1.value }) {
            let prefix = k.prefix(100) // Truncate if long
            print("  \(prefix): \(v)")
        }
    }
    @MainActor
    func testMechanicalSampleImportsModelAndNamedSheets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sampleURL = repositoryRoot.appendingPathComponent("Mechanical Sample.dxf")
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            throw XCTSkip("Mechanical Sample.dxf is not available")
        }

        let imported = try DXFImporter.importDXFViews(filePath: sampleURL.path)
        XCTAssertEqual(imported.views.map(\.name), [
            "Model",
            "Assembly",
            "Casting Locator and Support",
            "Gearmotor Mount",
        ])
        XCTAssertEqual(imported.views.first?.kind, .model)
        XCTAssertTrue(imported.views.dropFirst().allSatisfy { $0.kind == .sheet })
        XCTAssertTrue(imported.views.allSatisfy { !$0.entities.isEmpty })
        XCTAssertGreaterThan(imported.views[0].entities.count, 100)
        XCTAssertTrue(imported.views.dropFirst().allSatisfy { $0.entities.count > 1 })
        XCTAssertTrue(imported.views.dropFirst().allSatisfy {
            $0.entities.contains(where: { $0.blockID != nil })
        })
        let assemblyPaperBlock = try XCTUnwrap(
            imported.blocks.first(where: { $0.name == "*Paper_Space3" })
        )
        XCTAssertGreaterThan(
            assemblyPaperBlock.geometry.count, 150,
            "Assembly sheet should include expanded anonymous dimension blocks"
        )
        XCTAssertTrue(
            assemblyPaperBlock.geometry.contains(where: {
                if case .text(_, let text, _, _, _, _, _, _, _) = $0 {
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }),
            "Assembly sheet should preserve text from anonymous dimension blocks"
        )
        let gearmotorView = try XCTUnwrap(
            imported.views.first(where: { $0.name == "Gearmotor Mount" })
        )
        XCTAssertGreaterThan(
            gearmotorView.entities.count, 1_000,
            "Gearmotor sheet should include its status-1 contextual model viewport"
        )
    }

    @MainActor
    func testPirateShipOwnerlessEntitiesRemainInModelSpace() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sampleURL = repositoryRoot.appendingPathComponent(
            "#186-841 - KOMPAN, Inc. - Pirate Ship.dxf"
        )
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            throw XCTSkip("Pirate Ship DXF is not available")
        }

        let imported = try DXFImporter.importDXFViews(filePath: sampleURL.path)
        let model = try XCTUnwrap(imported.views.first)
        XCTAssertEqual(model.kind, .model)
        XCTAssertGreaterThan(
            model.entities.count, 3_500,
            "Entities without 330/67 tags implicitly belong to model space"
        )
    }

    @MainActor
    func testMlineImportAndHandlePreservation() throws {
        let dxfContent = """
          0
        SECTION
          2
        ENTITIES
          0
        MLINE
          5
        6DC3
        330
        1F
        100
        AcDbEntity
          8
        B-WALL-2
        100
        AcDbMline
          2
        STANDARD
        340
        18
         40
        100.0
         70
             1
         71
             1
         72
             2
         73
             2
         10
        1250.0
         20
        20506.5
         30
        0.0
        210
        0.0
        220
        0.0
        230
        1.0
         11
        1250.0
         21
        20506.5
         31
        0.0
         12
        1.0
         22
        0.0
         32
        0.0
         13
        0.0
         23
        1.0
         33
        0.0
         74
             2
         41
        50.0
         41
        0.0
         75
             0
         74
             2
         41
        -50.0
         41
        0.0
         75
             0
         11
        2025.0
         21
        20506.5
         31
        0.0
         12
        1.0
         22
        0.0
         32
        0.0
         13
        0.0
         23
        1.0
         33
        0.0
         74
             2
         41
        50.0
         41
        0.0
         75
             0
         74
             2
         41
        -50.0
         41
        0.0
         75
             0
          0
        ENDSEC
          0
        SECTION
          2
        OBJECTS
          0
        MLINESTYLE
          5
        18
        100
        AcDbMlineStyle
          2
        STANDARD
         70
             0
          3
        
         62
           256
         51
        90.0
         52
        90.0
         71
             2
         49
        0.5
         62
           256
          6
        BYLAYER
         49
        -0.5
         62
           256
          6
        BYLAYER
          0
        ENDSEC
          0
        EOF
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mline_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try dxfContent.write(to: tempURL, atomically: true, encoding: .utf8)

        let imported = try DXFImporter.importDXFViews(filePath: tempURL.path)
        XCTAssertEqual(imported.entities.count, 1)
        let entity = try XCTUnwrap(imported.entities.first)
        XCTAssertEqual(entity.xdata["dxf.handle"], .string("6DC3"))
        XCTAssertEqual(entity.xdata["dxf.mlineStyle"], .string("STANDARD"))
        XCTAssertEqual(entity.xdata["dxf.mlineScale"], .double(100.0))
        XCTAssertEqual(entity.xdata["dxf.mlineJustification"], .int(1))

        let geometry = try XCTUnwrap(entity.localGeometry)
        XCTAssertEqual(geometry.count, 2)
        if case .line(let s1, let e1, _) = geometry[0],
           case .line(let s2, let e2, _) = geometry[1] {
            XCTAssertEqual(s1.x, 1250.0, accuracy: 1e-6)
            XCTAssertEqual(e1.x, 2025.0, accuracy: 1e-6)
            XCTAssertEqual(s1.y, -20556.5, accuracy: 1e-6)
            XCTAssertEqual(e1.y, -20556.5, accuracy: 1e-6)

            XCTAssertEqual(s2.x, 1250.0, accuracy: 1e-6)
            XCTAssertEqual(e2.x, 2025.0, accuracy: 1e-6)
            XCTAssertEqual(s2.y, -20456.5, accuracy: 1e-6)
            XCTAssertEqual(e2.y, -20456.5, accuracy: 1e-6)
        } else {
            XCTFail("Expected 2 line primitives for MLINE")
        }
    }

    @MainActor
    func testOverallViewportDoesNotDuplicateSheet() throws {
        // Regression test: a layout whose only viewport is the overall
        // paper-space viewport (ID 1) must show its paper geometry alone.
        // Projecting model space through it overlays a duplicate copy of any
        // sheet graphics that also exist in model space (ghost double).
        // A layout with no paper geometry at all keeps the synthetic fit
        // fallback so Model-only drawings still populate empty sheets.
        let dxfContent = """
          0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        BLOCK_RECORD
         70
             3
          0
        BLOCK_RECORD
          5
        1
          2
        *MODEL_SPACE
          0
        BLOCK_RECORD
          5
        2
          2
        *Paper_Space
          0
        BLOCK_RECORD
          5
        3
          2
        *Paper_Space0
          0
        BLOCK_RECORD
          5
        4
          2
        *Paper_Space1
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          5
        10
          2
        *MODEL_SPACE
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        ENDBLK
          0
        BLOCK
          5
        20
          2
        *Paper_Space
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        ENDBLK
          0
        BLOCK
          5
        30
          2
        *Paper_Space0
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        ENDBLK
          0
        BLOCK
          5
        31
          2
        *Paper_Space1
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        INSERT
          5
        A4
        330
        4
        100
        AcDbEntity
         60
             1
          8
        signature
        100
        AcDbBlockReference
          2
        MISSING_BLOCK
         10
        0.0
         20
        0.0
         30
        0.0
          0
        VIEWPORT
          5
        A5
        330
        4
        100
        AcDbEntity
         67
             1
          8
        0
        100
        AcDbViewport
         10
        4.0
         20
        5.5
         30
        0.0
         40
        8.0
         41
        10.0
         12
        4.0
         22
        5.5
         17
        0.0
         27
        0.0
         37
        0.0
         45
        10.0
         68
             0
         69
             0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LINE
          5
        A1
        330
        1
        100
        AcDbEntity
          8
        0
        100
        AcDbLine
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10.0
         21
        5.0
         31
        0.0
          0
        LINE
          5
        A2
        330
        2
        100
        AcDbEntity
         67
             1
          8
        0
        100
        AcDbLine
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10.0
         21
        5.0
         31
        0.0
          0
        VIEWPORT
          5
        A3
        330
        2
        100
        AcDbEntity
         67
             1
          8
        0
        100
        AcDbViewport
         10
        5.0
         20
        2.5
         30
        0.0
         40
        10.0
         41
        5.0
         12
        5.0
         22
        2.5
         17
        0.0
         27
        0.0
         37
        0.0
         45
        5.0
         68
             1
         69
             1
          0
        ENDSEC
          0
        SECTION
          2
        OBJECTS
          0
        LAYOUT
          5
        50
        330
        0
        100
        AcDbLayout
          1
        Model
         70
             1
         71
             0
         10
        0.0
         20
        0.0
         11
        12.0
         21
        9.0
        330
        1
          0
        LAYOUT
          5
        51
        330
        0
        100
        AcDbLayout
          1
        PDF
         70
             1
         71
             1
         10
        0.0
         20
        0.0
         11
        8.5
         21
        11.0
        330
        2
          0
        LAYOUT
          5
        52
        330
        0
        100
        AcDbLayout
          1
        EMPTY
         70
             1
         71
             2
         10
        0.0
         20
        0.0
         11
        8.5
         21
        11.0
        330
        3
          0
        LAYOUT
          5
        53
        330
        0
        100
        AcDbLayout
          1
        LEGACY
         70
             1
         71
             3
         10
        0.0
         20
        0.0
         11
        8.5
         21
        11.0
        330
        4
          0
        ENDSEC
          0
        EOF
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_sheet_ghost_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try dxfContent.write(to: tempURL, atomically: true, encoding: .utf8)

        let imported = try DXFImporter.importDXFViews(filePath: tempURL.path)
        XCTAssertEqual(imported.views.map(\.name), ["Model", "PDF", "EMPTY", "LEGACY"])

        let pdfView = try XCTUnwrap(imported.views.first(where: { $0.name == "PDF" }))
        XCTAssertEqual(pdfView.kind, .sheet)
        XCTAssertEqual(
            pdfView.entities.count, 1,
            "PDF sheet must show its paper line only; the overall viewport (ID 1) must not project model space on top"
        )
        XCTAssertFalse(
            pdfView.entities.contains(where: { $0.xdata["dxf.viewport.projected"] == .bool(true) }),
            "No model entity may be projected into a sheet that has no floating viewport"
        )

        let emptyView = try XCTUnwrap(imported.views.first(where: { $0.name == "EMPTY" }))
        XCTAssertEqual(emptyView.entities.count, 1)
        XCTAssertEqual(
            emptyView.entities.first?.xdata["dxf.viewport.synthetic"], .bool(true),
            "Effectively-empty sheets keep the synthetic fit fallback"
        )

        // A legacy layout whose paper holds only an invisible INSERT and
        // switched-off viewports (like SS-5's Layout1) is also effectively
        // empty: it still gets the model fit instead of rendering blank.
        let legacyView = try XCTUnwrap(imported.views.first(where: { $0.name == "LEGACY" }))
        XCTAssertEqual(legacyView.entities.count, 1)
        XCTAssertEqual(
            legacyView.entities.first?.xdata["dxf.viewport.synthetic"], .bool(true),
            "A sheet with only invisible/raster paper content keeps the synthetic fit fallback"
        )
    }
}
