import XCTest
import Foundation
@testable import ZephyrCore

/// PLACEVIEW operands: quote-aware parsing and named-view resolution.
/// The engine-touching click flow is covered by the manual interactive
/// run (no live PhrostEngine in the test harness).
@MainActor
final class PlaceViewCommandTests: XCTestCase {

    // MARK: - parse

    func testParseFullFormWithPoint() {
        let parsed = PlaceViewCommand.parse("\"C:/job files/model.dxf\" Lobby 50 7 -4")
        XCTAssertEqual(parsed?.modelPath, "C:/job files/model.dxf")
        XCTAssertEqual(parsed?.viewName, "Lobby")
        XCTAssertEqual(parsed?.scaleDenominator, 50)
        XCTAssertEqual(parsed?.paperX, 7)
        XCTAssertEqual(parsed?.paperY, -4)
    }

    func testParseClickFormWithoutPoint() {
        let parsed = PlaceViewCommand.parse("\"C:/m.dxf\" \"North Lobby\" 25")
        XCTAssertEqual(parsed?.modelPath, "C:/m.dxf")
        XCTAssertEqual(parsed?.viewName, "North Lobby")
        XCTAssertEqual(parsed?.scaleDenominator, 25)
        XCTAssertNil(parsed?.paperX)
        XCTAssertNil(parsed?.paperY)
    }

    func testParseRejectsBadShapes() {
        XCTAssertNil(PlaceViewCommand.parse(""))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\""))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby 0"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby -50"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby fifty"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby 50 7"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby 50 7 -4 extra"))
        XCTAssertNil(PlaceViewCommand.parse("\"C:/m.dxf\" Lobby 50 seven -4"))
    }

    // MARK: - resolveView

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

    private func viewRecord(name: String, handle: String) -> String {
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
        10.0
        41
        20.0
        71
        0
        """
    }

    private func writeDXF(_ content: String, named: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceViewCmdTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testResolveViewFindsCaseInsensitively() throws {
        let url = try writeDXF(
            dxfWithViews(viewRecord(name: "Lobby", handle: "2C") + "0\n"
                + viewRecord(name: "North Lobby", handle: "2D")),
            named: "model.dxf")
        let found = PlaceViewCommand.resolveView(modelPath: url.path, viewName: "lobby")
        XCTAssertEqual(found?.name, "Lobby")
        XCTAssertEqual(found?.targetX ?? 0, 1.0, accuracy: 1e-9)
        let multi = PlaceViewCommand.resolveView(modelPath: url.path, viewName: "NORTH LOBBY")
        XCTAssertEqual(multi?.name, "North Lobby")
    }

    func testResolveViewRejectsMissing() throws {
        let url = try writeDXF(
            dxfWithViews(viewRecord(name: "Lobby", handle: "2C")),
            named: "model.dxf")
        XCTAssertNil(PlaceViewCommand.resolveView(modelPath: url.path, viewName: "Stair"))
        XCTAssertNil(PlaceViewCommand.resolveView(modelPath: url.path, viewName: ""))
        XCTAssertNil(PlaceViewCommand.resolveView(modelPath: "C:\\job\\plan.dwg", viewName: "Lobby"))
        XCTAssertNil(PlaceViewCommand.resolveView(modelPath: "/nonexistent/model.dxf", viewName: "Lobby"))
        let empty = try writeDXF(dxfWithViews(""), named: "empty.dxf")
        XCTAssertNil(PlaceViewCommand.resolveView(modelPath: empty.path, viewName: "Lobby"))
    }
}
