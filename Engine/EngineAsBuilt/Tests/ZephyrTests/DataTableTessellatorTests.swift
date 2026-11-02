import XCTest
@testable import ZephyrCore

/// Table visuals tessellated under a non-identity transform must carry
/// world-sized text: the entity-level text paths (screen
/// `CADPrimitiveGenerator`, PDF `PDFPrimitives`) scale `.text` height by the
/// transform they render under, so pre-transformed cell text that kept its
/// local height exported ~4x too small on scaled title-block tables
/// (Pirate Ship sheet: group-140 height 3.18 in 5.0-high rows).
final class DataTableTessellatorTests: XCTestCase {

    private func makeData(textHeight: Double = 3.18) -> DataTableData {
        let column = DataTableColumn(name: "C1", width: 20)
        let cell = DataTableCell(columnID: column.id, value: .string("ABC-123"))
        return DataTableData(
            columns: [column],
            rows: [DataTableRow(cells: [cell])],
            rowHeights: [5.0],
            defaultRowHeight: 5.0,
            defaultColumnWidth: 20,
            textHeight: textHeight)
    }

    private func cellTexts(from prims: [CADPrimitive])
        -> [(text: String, height: Double, mtextWidth: Double?)] {
        prims.compactMap { prim -> (String, Double, Double?)? in
            guard case .text(_, let text, let height, _, _, _, _, let mw, _) = prim else {
                return nil
            }
            return (text, height, mw)
        }
    }

    func testIdentityTransformLeavesTextHeight() {
        let data = makeData()
        let prims = DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero, transform: .identity)
        let texts = cellTexts(from: prims)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts[0].height, 3.18, accuracy: 1e-9)
        XCTAssertNotNil(texts[0].mtextWidth)
    }

    func testScaledTransformScalesTextHeightAndWidth() {
        let data = makeData()
        let plain = cellTexts(from: DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero, transform: .identity))
        let scaled = cellTexts(from: DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero,
            transform: .scaled(by: Vector3(x: 4, y: 4, z: 1))))
        XCTAssertEqual(scaled.count, 1)
        XCTAssertEqual(scaled[0].height, 3.18 * 4, accuracy: 1e-9)
        XCTAssertEqual(
            scaled[0].mtextWidth ?? -1, (plain[0].mtextWidth ?? -1) * 4,
            accuracy: 1e-9)
    }

    func testNonUniformTransformUsesAxisMagnitudes() {
        let data = makeData()
        let plain = cellTexts(from: DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero, transform: .identity))
        let scaled = cellTexts(from: DataTableTessellator.generateVisualPrimitives(
            data: data, origin: .zero,
            transform: .scaled(by: Vector3(x: 2, y: 5, z: 1))))
        XCTAssertEqual(scaled.count, 1)
        // Height follows the Y basis (the axis glyphs stand on); the
        // reference width follows X.
        XCTAssertEqual(scaled[0].height, 3.18 * 5, accuracy: 1e-9)
        XCTAssertEqual(
            scaled[0].mtextWidth ?? -1, (plain[0].mtextWidth ?? -1) * 2,
            accuracy: 1e-9)
    }
}
