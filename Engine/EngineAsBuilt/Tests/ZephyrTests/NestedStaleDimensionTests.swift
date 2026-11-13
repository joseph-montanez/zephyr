import XCTest
import Foundation
@testable import ZephyrCore

/// Stale anonymous dimension content nested in block definitions
/// (Vivienda Unifamiliar 2.dwg: SC1/ZAPATAS/ZPATA).
///
/// Associative dimensions regenerate their anonymous (`*D`) display block on
/// load in AutoCAD, so the stored content can be stale — e.g. absolute WCS
/// coordinates for a dimension nested in a block definition. Baking that
/// content verbatim double-transforms it at every INSERT and explodes the
/// world bounds, so zoom-extents lands on empty space instead of the drawing.
/// Stale nested content is rebuilt procedurally from the dimension's own
/// definition points (the same generator dimension edits use); healthy nested
/// content keeps its verbatim bytes (including custom display tweaks).
@MainActor
final class NestedStaleDimensionTests: XCTestCase {

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("staledim_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    private func headerAndTables() -> String {
        """
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
        """
    }

    private func block(name: String, entities: String) -> String {
        """
          0
        BLOCK
          8
        0
          2
        \(name)
         70
             0
         10
        0.0
         20
        0.0
         30
        0.0
          3
        \(name)
        \(entities)
          0
        ENDBLK
        """
    }

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> String {
        """
          0
        LINE
          8
        0
         10
        \(x1)
         20
        \(y1)
         11
        \(x2)
         21
        \(y2)
        """
    }

    /// A linear DIMENSION entity in block-local coordinates, mirroring the
    /// group codes the importer reads (dim-linear.dxf fixture shape).
    private func dimension(
        name: String, defX: Double, defY: Double,
        p13x: Double, p13y: Double, p14x: Double, p14y: Double,
        textX: Double, textY: Double
    ) -> String {
        """
          0
        DIMENSION
          5
        0
        100
        AcDbEntity
          8
        0
        100
        AcDbDimension
          2
        \(name)
          3
        Standard
         10
        \(defX)
         20
        \(defY)
         30
        0.0
         11
        \(textX)
         21
        \(textY)
         31
        0.0
         13
        \(p13x)
         23
        \(p13y)
         33
        0.0
         14
        \(p14x)
         24
        \(p14y)
         34
        0.0
         42
        1.0
         70
        0
        """
    }

    func testStaleNestedDimensionContentDoesNotExplodeExtents() throws {
        // *D500 holds absolute-coordinate content (as ODA wrote it for the
        // nested dimensions) while the DIMENSION entity lives in local
        // block coordinates near the origin.
        let dxf = """
        \(headerAndTables())
          0
        SECTION
          2
        BLOCKS
        \(block(name: "*D500", entities: line(1612.0, 1757.0, 1613.0, 1758.0)))
        \(block(name: "STALEPARENT", entities: dimension(
            name: "*D500", defX: 1.0, defY: 3.162,
            p13x: 1.0, p13y: 3.0, p14x: 2.0, p14y: 3.0,
            textX: 0.5, textY: 3.2)))
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
        STALEPARENT
         10
        100.0
         20
        100.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let bounds = try XCTUnwrap(doc.renderableWorldBoundingBox())

        // Verbatim baking would double-transform the absolute content to
        // x ~ 1712 / y ~ -1858. The repaired dimension draws at the INSERT
        // plus its local definition points: x ~ 100-103, y ~ -97..-104.
        XCTAssertLessThan(bounds.max.x, 200, "stale *D content must not leak into extents")
        XCTAssertGreaterThan(bounds.min.x, 90)
        XCTAssertLessThan(bounds.min.y, -90)
        XCTAssertGreaterThan(bounds.max.y, -120)
        XCTAssertLessThan(bounds.max.x - bounds.min.x, 60)
        XCTAssertLessThan(bounds.max.y - bounds.min.y, 60)

        // The dimension still renders at its definition point (world).
        XCTAssertLessThanOrEqual(bounds.min.x, 101)
        XCTAssertGreaterThanOrEqual(bounds.max.x, 101)
        XCTAssertLessThanOrEqual(bounds.min.y, -103)
        XCTAssertGreaterThanOrEqual(bounds.max.y, -103)
    }

    func testHealthyNestedDimensionContentBakesVerbatim() throws {
        // *D501 content already sits in the parent-local frame, overlapping
        // the definition points — including custom display content (the
        // circle) a procedural rebuild would drop.
        let dxf = """
        \(headerAndTables())
          0
        SECTION
          2
        BLOCKS
        \(block(name: "*D501", entities:
            line(1.0, 3.0, 2.0, 3.0)
            + "\n  0\nCIRCLE\n  8\n0\n 10\n1.5\n 20\n3.1\n 40\n0.25"))
        \(block(name: "HEALTHYPARENT", entities: dimension(
            name: "*D501", defX: 1.0, defY: 3.5,
            p13x: 1.0, p13y: 3.0, p14x: 2.0, p14y: 3.0,
            textX: 1.5, textY: 4.0)))
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
        HEALTHYPARENT
         10
        200.0
         20
        200.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let parent = try XCTUnwrap(doc.allBlocks.first { $0.name == "HEALTHYPARENT" })
        let hasCustomCircle = parent.geometry.contains {
            if case .circle(_, let radius, _) = $0 { return abs(radius - 0.25) < 1e-9 }
            return false
        }
        XCTAssertTrue(hasCustomCircle, "healthy nested *D content must bake verbatim, custom tweaks included")

        let bounds = try XCTUnwrap(doc.renderableWorldBoundingBox())
        XCTAssertGreaterThan(bounds.min.x, 190)
        XCTAssertLessThan(bounds.max.x, 220)
    }
}
