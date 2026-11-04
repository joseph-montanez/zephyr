import XCTest
import Foundation
@testable import ZephyrCore

/// VIEW table parsing + Sheet Views grouping. Fixtures are hand-built
/// minimal DXF (TABLES/VIEW only); group codes follow the public DXF
/// reference (2 name, 5 handle, 10/20 center, 11/21/31 direction,
/// 12/22/32 target, 40/41 extent, 50 twist, 70 flags, 71 view mode).
@MainActor
final class SheetSetSheetViewsTests: XCTestCase {

    private func dxfWithViews(_ records: String) -> String {
        """
        0
        SECTION
        2
        TABLES
        0
        TABLE
        2
        VIEW
        70
        2
        \(records)0
        ENDTAB
        0
        ENDSEC
        0
        EOF
        """
    }

    private func viewRecord(name: String, handle: String, height: String = "10", width: String = "20") -> String {
        """
        0
        VIEW
        5
        \(handle)
        330
        1A
        100
        AcDbSymbolTableRecord
        100
        AcDbViewTableRecord
        2
        \(name)
        70
        0
        10
        5.0
        20
        5.0
        11
        0.0
        21
        0.0
        31
        1.0
        12
        1.0
        22
        2.0
        32
        3.0
        40
        \(height)
        41
        \(width)
        42
        50.0
        43
        0.0
        44
        0.0
        50
        0.0
        71
        0
        """
    }

    private func writeDXF(_ content: String, named: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetViewsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testViewTableParsesNameHandleAndExtent() throws {
        let body = dxfWithViews(viewRecord(name: "Lobby", handle: "2C"))
        let reader = try DXFReader().readString(body)
        let views = reader.views
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?.name, "Lobby")
        XCTAssertEqual(views.first?.handle, 0x2C)
        XCTAssertEqual(views.first?.height, 10)
        XCTAssertEqual(views.first?.width, 20)
        XCTAssertEqual(views.first?.target.x, 1.0)
        XCTAssertEqual(views.first?.target.z, 3.0)
        XCTAssertEqual(views.first?.direction.z, 1.0)
    }

    func testReadViewsSortsByName() throws {
        let body = dxfWithViews(
            viewRecord(name: "Stair", handle: "2D") + "0\n" +
            viewRecord(name: "Atrium", handle: "2E"))
        let url = try writeDXF(body, named: "a.dxf")
        let views = try XCTUnwrap(SheetSetSheetViews.readViews(atPath: url.path))
        XCTAssertEqual(views.map(\.name), ["Atrium", "Stair"])
        XCTAssertEqual(views.first?.handle, "2E")
        XCTAssertEqual(views.first?.targetX ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(views.first?.targetY ?? 0, 2.0, accuracy: 1e-9)
    }

    func testReadViewsRejectsNonDXFAndMissing() {
        XCTAssertNil(SheetSetSheetViews.readViews(atPath: "C:\\job\\plan.dwg"))
        XCTAssertNil(SheetSetSheetViews.readViews(atPath: "/nonexistent/plan.dxf"))
    }

    func testViewsByDrawingDedupsSkipsAndSorts() throws {
        let withViews = try writeDXF(
            dxfWithViews(viewRecord(name: "Lobby", handle: "2C")), named: "b.dxf")
        let noViews = try writeDXF(dxfWithViews(""), named: "a.dxf")
        var set = SheetSet(name: "S")
        set.sheets = [
            SheetSetSheet(number: "A1", absoluteFile: withViews.path),
            SheetSetSheet(number: "A2", absoluteFile: withViews.path),
            SheetSetSheet(number: "A3", absoluteFile: noViews.path),
            SheetSetSheet(number: "A4", absoluteFile: "C:\\job\\plan.dwg"),
        ]
        let groups = SheetSetSheetViews.viewsByDrawing(for: set)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "b.dxf")
        XCTAssertEqual(groups.first?.views.map(\.name), ["Lobby"])
    }
}
