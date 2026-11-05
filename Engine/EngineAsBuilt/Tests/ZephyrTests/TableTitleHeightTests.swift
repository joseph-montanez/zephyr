import XCTest
@testable import ZephyrCore

/// Pirate Ship title-block regression: style-less ACAD_TABLE cells must
/// inherit the *T display-block MTEXT height/style, and table cell text
/// must survive the style fixed-height rule with an explicit height.
@MainActor
final class TableTitleHeightTests: XCTestCase {

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("titletest_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    @MainActor
    func testStyleLessTableRecoversDisplayBlockTextHeight() throws {
        let dxf = """
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
        TABLE
          2
        STYLE
         70
             2
          0
        STYLE
          2
        STANDARD
         70
             0
         40
        2.0
         41
        1.0
         50
        0.0
         71
             0
         42
        2.0
          3
        lucon.TTF
          4

          0
        STYLE
          2
        CADdetails-DETAILTITLE
         70
             0
         40
        4.77
         41
        1.0
         50
        0.0
         71
             0
         42
        4.77
          3
        ARIALN.TTF
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
          8
        0
          2
        *T2
         70
             1
         10
        0.0
         20
        0.0
         30
        0.0
          3
        *T2
          1

          0
        MTEXT
          8
        CADdetails-6-HEAVY
         10
        0.06
         20
        -3.5
         30
        0.0
         40
        4.77
         41
        165.53
         71
             4
          1
        PLAY SYSTEMS: SHIPS & CASTLES
          7
        CADdetails-DETAILTITLE
         73
             1
         44
        1.0
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
        FE96
        100
        AcDbEntity
          8
        CADdetails-6-HEAVY
        100
        AcDbBlockReference
          2
        *T2
         10
        35.28
         20
        22.98
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
             1
         92
             1
        141
        7.0
        142
        165.65
        301
        CELL_VALUE
         93
                 6
         90
                 4
          1
        PLAY SYSTEMS: SHIPS & CASTLES
         94
                 0
        300

        302
        PLAY SYSTEMS: SHIPS & CASTLES
        304
        ACVALUE_END
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)

        let tableEntity = try XCTUnwrap(doc.allEntities.first(where: { entity in
            (entity.localGeometry ?? []).contains {
                if case .table = $0 { return true }; return false
            }
        }))
        let tablePrim = try XCTUnwrap((tableEntity.localGeometry ?? []).first(where: {
            if case .table = $0 { return true }; return false
        }))
        guard case .table(let data, _, _) = tablePrim else {
            return XCTFail("expected a native table primitive")
        }
        XCTAssertEqual(data.textHeight, 4.77, accuracy: 1e-6)
        XCTAssertEqual(data.textStyleName, "CADdetails-DETAILTITLE")
        let style = CADTextStyle.resolve(data.textStyleName, in: doc.textStyles)
        XCTAssertEqual(style.fixedHeight, 4.77, accuracy: 1e-6)
        let visuals = DataTableTessellator.generateVisualPrimitives(data: data, origin: .zero)
        let heights = visuals.compactMap { prim -> Double? in
            guard case .text(_, _, let h, _, _, _, _, _, _) = prim else { return nil }
            return h
        }
        XCTAssertEqual(heights.count, 1)
        XCTAssertEqual(heights.first ?? -1, 4.77, accuracy: 1e-6)
    }

    @MainActor
    func testTableTextVisualsCarryExplicitHeightOverride() throws {
        // Table cell heights are explicit (group 140 or display-block
        // recovery) and must survive the style fixed-height rule, like
        // MTEXT nominal heights with an explicit-height flag.
        let column = DataTableColumn(name: "C1", width: 20)
        let cell = DataTableCell(columnID: column.id, value: .string("PLAY SYSTEMS"))
        let data = DataTableData(
            columns: [column],
            rows: [DataTableRow(cells: [cell])],
            rowHeights: [7.0],
            defaultRowHeight: 7.0,
            defaultColumnWidth: 20,
            textHeight: 4.77,
            textStyleName: "CADdetails-DETAILTITLE")
        let expanded = CADRendererBridge.expandedGeometryWithTableTextOverrides(
            geometry: [.table(data: data, origin: .zero, color: nil)],
            primitiveStyles: [:],
            primitiveXData: [:])
        let textItems = expanded.geometry.filter {
            if case .text = $0.primitive { return true }; return false
        }
        XCTAssertEqual(textItems.count, 1)
        let xd = expanded.xdata[textItems[0].index] ?? [:]
        XCTAssertEqual(xd["dxf.textHeightOverride"], .int(1))
        XCTAssertEqual(xd["dxf.textEntityType"], .string("MTEXT"))
    }
}
