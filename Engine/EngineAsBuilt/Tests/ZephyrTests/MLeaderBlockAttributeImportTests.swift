import XCTest
@testable import ZephyrCore

/// Regression: ODA File Converter DXF output repeats AcDbText placement
/// groups (71/72/11) inside the AcDbAttributeDefinition subclass of an
/// ATTDEF, with a trailing 72 = 0. The reader must not let those
/// duplicates clobber the real justification/alignment point from the
/// AcDbText subclass, or MLeader block-content callouts (e.g.
/// _DetailCallout "1 / A-05") render left-aligned at the insertion
/// point instead of centered on the alignment point.
///
/// Fixture is a minimal reproduction of handle 3249 in
/// architectural_-_annotation_scaling_and_multileaders.dwg.
@MainActor
final class MLeaderBlockAttributeImportTests: XCTestCase {

    private enum AttdefLayout {
        /// AutoCAD: placement groups only under AcDbText.
        case autocad
        /// ODA: AcDbText groups repeated (72 = 0) under AcDbAttributeDefinition.
        case odaDuplicates
        /// Zephyr writer: no AcDbText marker; all groups under the
        /// AcDbAttributeDefinition marker.
        case zephyrWriter
    }

    private func attdef(
        handle: String, tag: String, prompt: String,
        insertion: (Double, Double), alignment: (Double, Double),
        layout: AttdefLayout
    ) -> String {
        func d(_ v: Double) -> String { "\(v)" }
        // Multiline literals drop their final newline; add it back so
        // concatenated DXF lines never merge.
        let header = """
          0
        ATTDEF
          5
        \(handle)
        330
        30
        100
        AcDbEntity
          8
        Mleader
        """ + "\n"
        let attributeTail = """
          3
        \(prompt)
          2
        \(tag)
         70
             0
        """ + "\n"
        switch layout {
        case .autocad:
            return header + """
            100
            AcDbText
             10
            \(d(insertion.0))
             20
            \(d(insertion.1))
             30
            0.0
             40
            0.09375
              1
            \(tag)
             72
                 1
             11
            \(d(alignment.0))
             21
            \(d(alignment.1))
             31
            0.0
            100
            AcDbAttributeDefinition
            280
                 0
            """ + "\n" + attributeTail + """
            280
                 0
            """ + "\n"
        case .odaDuplicates:
            return header + """
            100
            AcDbText
             10
            \(d(insertion.0))
             20
            \(d(insertion.1))
             30
            0.0
             40
            0.09375
              1
            \(tag)
             72
                 1
             11
            \(d(alignment.0))
             21
            \(d(alignment.1))
             31
            0.0
            100
            AcDbAttributeDefinition
            """ + "\n" + attributeTail + """
            280
                 0
             71
                 1
             72
                 0
             11
            \(d(alignment.0))
             21
            \(d(alignment.1))
             31
            0.0
            """ + "\n"
        case .zephyrWriter:
            // Zephyr writers put every group after the attribute marker
            // and write the alignment point as both 10 and 11.
            return header + """
            100
            AcDbAttributeDefinition
             10
            \(d(alignment.0))
             20
            \(d(alignment.1))
             30
            0.0
             40
            0.09375
              1
            \(tag)
             72
                 1
             74
                 0
             11
            \(d(alignment.0))
             21
            \(d(alignment.1))
             31
            0.0
            """ + "\n" + attributeTail
        }
    }

    private func makeDXF(layout: AttdefLayout) -> String {
        let attdef1 = attdef(
            handle: "34", tag: "VIEWNUMBER", prompt: "Enter view number",
            insertion: (-0.46875, 0.0208333333333357),
            alignment: (0.0, 0.0208333333333357), layout: layout)
        let attdef2 = attdef(
            handle: "35", tag: "SHEETNUMBER", prompt: "Enter sheet number",
            insertion: (-0.5, -0.15625),
            alignment: (0.0, -0.15625), layout: layout)
        return """
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
             2
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
        LAYER
          2
        Mleader
         70
             0
         62
             5
          6
        CONTINUOUS
          0
        ENDTAB
          0
        TABLE
          2
        BLOCK_RECORD
         70
             2
          0
        BLOCK_RECORD
          5
        20
        100
        AcDbSymbolTableRecord
        100
        AcDbBlockTableRecord
          2
        *Model_Space
         70
             0
          0
        BLOCK_RECORD
          5
        30
        100
        AcDbSymbolTableRecord
        100
        AcDbBlockTableRecord
          2
        _TESTCALLOUT
         70
             0
          0
        ENDTAB
          0
        TABLE
          2
        STYLE
         70
             1
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
        txt.shx
          4

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
        21
        330
        20
        100
        AcDbEntity
          8
        0
        100
        AcDbBlockBegin
          2
        *Model_Space
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          3
        *Model_Space
          1

          0
        ENDBLK
          5
        22
        330
        20
        100
        AcDbEntity
          8
        0
        100
        AcDbBlockEnd
          0
        BLOCK
          5
        31
        330
        30
        100
        AcDbEntity
          8
        0
        100
        AcDbBlockBegin
          2
        _TESTCALLOUT
         70
             2
         10
        0.0
         20
        0.0
         30
        0.0
          3
        _TESTCALLOUT
          1

          0
        CIRCLE
          5
        32
        330
        30
        100
        AcDbEntity
          8
        0
          6
        ByBlock
         62
             0
        100
        AcDbCircle
         10
        0.0
         20
        0.0
         30
        0.0
         40
        0.25
          0
        LINE
          5
        33
        330
        30
        100
        AcDbEntity
          8
        0
          6
        ByBlock
         62
             0
        100
        AcDbLine
         10
        0.25
         20
        0.0
         30
        0.0
         11
        -0.25
         21
        0.0
         31
        0.0
        \(attdef1)
        \(attdef2)
          0
        ENDBLK
          5
        36
        330
        30
        100
        AcDbEntity
          8
        0
        100
        AcDbBlockEnd
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        MULTILEADER
          5
        40
        330
        20
        100
        AcDbEntity
          8
        Mleader
        100
        AcDbMLeader
        270
             2
        300
        CONTEXT_DATA{
         40
        48.0
         10
        506.181504841209
         20
        273.8855908716496
         30
        0.0
         41
        3.0
        140
        9.0
        145
        4.32
        290
             0
        296
             1
        341
        30
         15
        518.181504841208
         25
        273.8855908716491
         35
        0.0
         16
        48.0
         26
        48.0
         36
        48.0
         46
        0.0
        302
        LEADER{
        290
             1
        291
             1
         10
        489.8159073383212
         20
        273.8855908716496
         30
        0.0
         11
        1.0
         21
        0.0
         31
        0.0
         90
             0
         40
        16.36559750288778
        304
        LEADER_LINE{
         10
        472.2450337336725
         20
        256.3926854409219
         30
        0.0
         91
             0
        305
        }
        271
             0
        303
        }
        272
             9
        273
             9
        301
        }
        340
        99
        170
             1
        290
             1
        291
             1
         41
        0.36
         42
        0.0
        172
             1
        173
             1
         95
             1
        174
             1
        175
             0
        292
             0
        344
        30
         10
        1.0
         20
        1.0
         30
        1.0
         43
        0.0
        330
        34
        177
             1
         44
        0.0
        302
        1
        330
        35
        177
             2
         44
        0.0
        302
        A-05
         45
        48.0
        271
             0
        272
             9
        273
             9
          0
        ENDSEC
          0
        EOF

        """
    }

    private func importedLeader(layout: AttdefLayout) throws -> CADEntity {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("mleader-callout-\(layout)-\(UUID().uuidString).dxf")
        try makeDXF(layout: layout).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try DXFImporter.importDXFViews(filePath: url.path)
        var seen = Set<UUID>()
        var all: [CADEntity] = []
        for e in result.entities where seen.insert(e.handle).inserted { all.append(e) }
        for view in result.views {
            for e in view.entities where seen.insert(e.handle).inserted { all.append(e) }
        }
        return try XCTUnwrap(
            all.first { $0.leaderData?.value.blockName == "_TESTCALLOUT" },
            "no block-content leader imported for layout \(layout)")
    }

    private func assertCentered(layout: AttdefLayout) throws {
        let entity = try importedLeader(layout: layout)
        let data = try XCTUnwrap(entity.leaderData?.value)
        let attrs = try XCTUnwrap(data.blockAttributes)
        XCTAssertEqual(attrs.count, 2)

        // Attribute placement comes from the AcDbText alignment point
        // (0, dy in block space; Y negated in Zephyr coordinates),
        // justified center -- not the insertion point, not left-aligned.
        let view = try XCTUnwrap(attrs.first { $0.tag == "VIEWNUMBER" })
        XCTAssertEqual(view.text, "1")
        XCTAssertEqual(view.alignH, 1, "VIEWNUMBER justification lost (\(layout))")
        XCTAssertEqual(view.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(view.position.y, -0.0208333333333357, accuracy: 1e-9)

        let sheet = try XCTUnwrap(attrs.first { $0.tag == "SHEETNUMBER" })
        XCTAssertEqual(sheet.text, "A-05")
        XCTAssertEqual(sheet.alignH, 1, "SHEETNUMBER justification lost (\(layout))")
        XCTAssertEqual(sheet.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(sheet.position.y, 0.15625, accuracy: 1e-9)

        // Baked geometry: both texts anchor on the circle center X.
        let geometry = try XCTUnwrap(entity.localGeometry)
        var circleCenterX: Double?
        var texts: [(String, Vector3, Int)] = []
        for prim in geometry {
            switch prim {
            case let .polygon(points, _):
                let xs = points.map(\.x)
                if let lo = xs.min(), let hi = xs.max(), hi - lo > 20 {
                    circleCenterX = (lo + hi) / 2
                }
            case let .text(position, text, _, _, _, alignH, _, _, _):
                texts.append((text, position, alignH))
            default:
                break
            }
        }
        let centerX = try XCTUnwrap(circleCenterX, "callout circle not in geometry")
        XCTAssertEqual(centerX, 518.181504841208, accuracy: 1e-6)
        XCTAssertEqual(texts.count, 2)
        for (text, pos, alignH) in texts {
            XCTAssertEqual(pos.x, centerX, accuracy: 1e-6,
                           "'\(text)' not anchored on circle center (\(layout))")
            XCTAssertEqual(alignH, 1, "'\(text)' not center-justified (\(layout))")
        }
    }

    func testODADuplicateAttdefGroupsKeepCenterJustification() throws {
        try assertCentered(layout: .odaDuplicates)
    }

    func testAutoCADAttdefLayoutKeepsCenterJustification() throws {
        try assertCentered(layout: .autocad)
    }

    func testZephyrWriterAttdefLayoutKeepsCenterJustification() throws {
        try assertCentered(layout: .zephyrWriter)
    }
}
