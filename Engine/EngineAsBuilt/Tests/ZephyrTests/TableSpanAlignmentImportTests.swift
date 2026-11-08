import XCTest
@testable import ZephyrCore

/// Drive Roller "Parts List" regression: AutoCAD renders the ACAD_TABLE
/// title row as one cell spanning every column (DXF groups 175/176 give
/// the cell border width/height in cells, 173 flags the merged/virtual
/// cells it covers) and centers every cell that carries no group-170
/// override, because the TABLESTYLE row styles align middle-center.
/// The importer must keep both facts instead of dropping them.
@MainActor
final class TableSpanAlignmentImportTests: XCTestCase {

    /// Builds a minimal 3x3 ACAD_TABLE in the exact group layout ODA
    /// emits for the Drive Roller parts list, plus a TABLESTYLE whose
    /// three repeated row-style blocks use distinct alignments so the
    /// repeat order (data, title, header) is observable.
    private func makeDXF() -> String {
        var dxf = ""
        func pair(_ code: Int, _ value: String) { dxf += "\(code)\n\(value)\n" }
        func cell(text: String, merged: Int, colSpan: Int, rowSpan: Int, alignment: Int?) {
            pair(171, "1")
            pair(172, "0")
            pair(173, "\(merged)")
            pair(174, "0")
            pair(175, "\(colSpan)")
            pair(176, "\(rowSpan)")
            pair(145, "0.0")
            if let alignment { pair(170, "\(alignment)") }
            pair(140, "2.0")
            pair(301, "CELL_VALUE")
            pair(93, "6")
            pair(90, "512")
            pair(94, "0")
            pair(300, "")
            pair(302, text)
            pair(304, "ACVALUE_END")
        }

        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1032")
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "ENTITIES")
        pair(0, "ACAD_TABLE")
        pair(5, "8EC")
        pair(100, "AcDbEntity"); pair(8, "Table")
        pair(100, "AcDbBlockReference")
        pair(2, "*T1"); pair(10, "0.0"); pair(20, "0.0"); pair(30, "0.0")
        pair(100, "AcDbTable")
        pair(342, "65")
        pair(11, "1.0"); pair(21, "0.0"); pair(31, "0.0")
        pair(91, "3"); pair(92, "3")
        pair(141, "4.0"); pair(141, "4.0"); pair(141, "4.0")
        pair(142, "10.0"); pair(142, "20.0"); pair(142, "30.0")
        // Title row: one real cell spanning all 3 columns + 2 virtuals.
        cell(text: "Parts List", merged: 0, colSpan: 3, rowSpan: 1, alignment: nil)
        cell(text: "", merged: 1, colSpan: 1, rowSpan: 1, alignment: nil)
        cell(text: "", merged: 1, colSpan: 1, rowSpan: 1, alignment: nil)
        // Header row: no overrides.
        cell(text: "Item", merged: 0, colSpan: 1, rowSpan: 1, alignment: nil)
        cell(text: "Qty", merged: 0, colSpan: 1, rowSpan: 1, alignment: nil)
        cell(text: "Part", merged: 0, colSpan: 1, rowSpan: 1, alignment: nil)
        // Data row: first cell inherits the style, rest override ML (4).
        cell(text: "1", merged: 0, colSpan: 1, rowSpan: 1, alignment: nil)
        cell(text: "VW02-210", merged: 0, colSpan: 1, rowSpan: 1, alignment: 4)
        cell(text: "Gear", merged: 0, colSpan: 1, rowSpan: 1, alignment: 4)
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "OBJECTS")
        pair(0, "TABLESTYLE")
        pair(5, "65")
        pair(330, "0")
        pair(100, "AcDbTableStyle")
        pair(3, "Standard")
        pair(70, "0"); pair(71, "0")
        pair(40, "0.06"); pair(41, "0.06")
        pair(280, "0"); pair(281, "0")
        // Repeated row styles, in file order: data, title, header.
        for alignment in [6, 2, 8] {
            pair(7, "Standard"); pair(140, "0.18"); pair(170, "\(alignment)")
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
        return dxf
    }

    @MainActor
    private func makeSuppressedTitleBlockDXF() -> String {
        var dxf = ""
        func pair(_ code: Int, _ value: String) { dxf += "\(code)\n\(value)\n" }
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1032")
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "ENTITIES")
        pair(0, "ACAD_TABLE")
        pair(5, "FE96")
        pair(100, "AcDbEntity"); pair(8, "CADdetails-6-HEAVY")
        pair(100, "AcDbBlockReference")
        pair(2, "*T2"); pair(10, "0.0"); pair(20, "0.0"); pair(30, "0.0")
        pair(100, "AcDbTable")
        pair(280, "0")
        pair(342, "FE4C")
        pair(11, "1.0"); pair(21, "0.0"); pair(31, "0.0")
        pair(90, "22"); pair(91, "1"); pair(92, "1")
        pair(93, "3"); pair(94, "0"); pair(95, "0"); pair(96, "0")
        pair(280, "1"); pair(281, "1")
        pair(141, "7.0"); pair(142, "165.65")
        pair(171, "1"); pair(172, "0"); pair(173, "0"); pair(174, "0")
        pair(175, "1"); pair(176, "1"); pair(145, "0.0")
        pair(140, "2.0")
        pair(301, "CELL_VALUE"); pair(93, "6"); pair(90, "512"); pair(94, "0")
        pair(300, ""); pair(302, "PLAY SYSTEMS: SHIPS & CASTLES"); pair(304, "ACVALUE_END")
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "OBJECTS")
        pair(0, "TABLESTYLE")
        pair(5, "FE4C"); pair(330, "0")
        pair(100, "AcDbTableStyle")
        pair(3, "Standard"); pair(70, "0"); pair(71, "0")
        pair(40, "0.06"); pair(41, "0.06")
        pair(280, "0"); pair(281, "0")
        for alignment in [4, 5, 5] {
            pair(7, "Standard"); pair(140, "0.18"); pair(170, "\(alignment)")
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
        return dxf
    }

    @MainActor
    func testTableEntitySuppressionFallsBackToDataAlignment() throws {
        let dxfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablesuppress_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: dxfURL) }
        try makeSuppressedTitleBlockDXF().write(to: dxfURL, atomically: true, encoding: .utf8)
        let imported = try DXFImporter.importDXF(filePath: dxfURL.path)
        let tableEntity = try XCTUnwrap(imported.entities.first)
        let tablePrim = try XCTUnwrap((tableEntity.localGeometry ?? []).first)
        guard case .table(let data, _, _) = tablePrim else {
            return XCTFail("ACAD_TABLE should import as a native table, got \(tablePrim)")
        }
        XCTAssertEqual(data.rows.count, 1)
        XCTAssertEqual(data.columns.count, 1)
        let cell = data.rows[0].cells[0]
        XCTAssertEqual(cell.horizontalAlignment, .left)
        XCTAssertEqual(cell.verticalAlignment, .middle)
        let visuals = DataTableTessellator.generateVisualPrimitives(data: data, origin: .zero)
        let text = try XCTUnwrap(visuals.compactMap { prim -> (Vector3, Int)? in
            guard case .text(let pos, let value, _, _, _, let alignH, _, _, _) = prim,
                  value == "PLAY SYSTEMS: SHIPS & CASTLES" else { return nil }
            return (pos, alignH)
        }.first)
        XCTAssertEqual(text.1, 0)
        XCTAssertEqual(text.0.x, 0.06, accuracy: 1e-9)
    }

    func testTitleSpanAndStyleAlignmentSurviveImport() throws {
        let dxfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablespan_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: dxfURL) }
        try makeDXF().write(to: dxfURL, atomically: true, encoding: .utf8)

        let imported = try DXFImporter.importDXF(filePath: dxfURL.path)
        let tableEntity = try XCTUnwrap(imported.entities.first)
        let tablePrim = try XCTUnwrap((tableEntity.localGeometry ?? []).first)
        guard case .table(let data, _, _) = tablePrim else {
            return XCTFail("ACAD_TABLE should import as a native table, got \(tablePrim)")
        }

        XCTAssertEqual(data.rows.count, 3)
        XCTAssertEqual(data.columns.count, 3)

        // Span: title anchor covers all columns, covered cells flagged.
        let title = data.rows[0].cells[0]
        XCTAssertEqual(title.colSpan, 3)
        XCTAssertEqual(title.rowSpan, 1)
        XCTAssertFalse(title.coveredByMerge)
        XCTAssertTrue(data.rows[0].cells[1].coveredByMerge)
        XCTAssertTrue(data.rows[0].cells[2].coveredByMerge)

        // Alignment inherited from TABLESTYLE row styles (data/title/header
        // repeat order): title = top-center, header = bottom-center,
        // data = middle-right; explicit group 170 wins over the style.
        XCTAssertEqual(title.horizontalAlignment, .center)
        XCTAssertEqual(title.verticalAlignment, .top)
        XCTAssertEqual(data.rows[1].cells[0].horizontalAlignment, .center)
        XCTAssertEqual(data.rows[1].cells[0].verticalAlignment, .bottom)
        XCTAssertEqual(data.rows[2].cells[0].horizontalAlignment, .right)
        XCTAssertEqual(data.rows[2].cells[0].verticalAlignment, .middle)
        XCTAssertEqual(data.rows[2].cells[1].horizontalAlignment, .left)
        XCTAssertEqual(data.rows[2].cells[1].verticalAlignment, .middle)

        // Rendering: the merged title rect spans the full table width
        // (10 + 20 + 30, zero cell margin on imported tables) and its
        // text is centered in that rect, as AutoCAD draws it.
        let layout = DataTableTessellator.layout(data: data, origin: .zero)
        let titleRect = try XCTUnwrap(DataTableTessellator.cellRect(
            data: data, layout: layout, row: 0, column: 0))
        XCTAssertEqual(titleRect.width, 60, accuracy: 1e-9)

        let visuals = DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero)
        let titleText = try XCTUnwrap(visuals.compactMap { prim -> (Vector3, Int)? in
            guard case .text(let pos, let text, _, _, _, let alignH, _, _, _) = prim,
                  text == "Parts List" else { return nil }
            return (pos, alignH)
        }.first)
        XCTAssertEqual(titleText.1, 1)
        XCTAssertEqual(titleText.0.x, 30, accuracy: 1e-9)
    }
}
