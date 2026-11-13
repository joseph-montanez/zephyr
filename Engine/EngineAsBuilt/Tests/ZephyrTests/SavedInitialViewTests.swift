import XCTest
import Foundation
@testable import ZephyrCore

/// Saved `*ACTIVE` viewport handling on open (Vivienda Unifamiliar 2.dwg).
///
/// The open flow restores the drawing's saved Model view when it is sane and
/// overlaps the content, and otherwise keeps the zoom-extents fit. The
/// Vivienda file's converted `*ACTIVE` (center −20.4/−81.7 file-flipped,
/// height 151) misses the drawings (x 954–1556) entirely, so it must fall
/// back to extents rather than open on empty space.
@MainActor
final class SavedInitialViewTests: XCTestCase {

    /// VPORT records live in TABLES (there is no top-level VPORTS section
    /// in DXF), so the table is spliced after the LAYER table.
    private func vportTable(_ vport: String? = nil) -> String {
        guard let vport else { return "" }
        return """
          0
        TABLE
          2
        VPORT
         70
             1
        \(vport)
          0
        ENDTAB
        """
    }

    private func dxf(
        entities: String,
        vport: String? = nil
    ) -> String {
        let vportTable = vportTable(vport)
        var sections = """
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
        \(vportTable)
          0
        ENDSEC
          0
        SECTION
          2
        BLOCKS
          0
        ENDSEC
        """
        sections += """

          0
        SECTION
          2
        ENTITIES
        \(entities)
          0
        ENDSEC
          0
        EOF
        """
        return sections
    }

    private func vport(
        name: String = "*ACTIVE",
        centerX: Double = 100, centerY: Double = 200,
        dirX: Double = 0, dirY: Double = 0, dirZ: Double = 1,
        height: Double = 50, twist: Double = 0
    ) -> String {
        """
          0
        VPORT
          2
        \(name)
         70
             0
         10
        0.0
         20
        0.0
         11
        1.0
         21
        1.0
         12
        \(centerX)
         22
        \(centerY)
         16
        \(dirX)
         26
        \(dirY)
         36
        \(dirZ)
         40
        \(height)
         41
        1.0
         50
        0.0
         51
        \(twist)
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

    private func importViews(_ dxf: String) throws -> DXFImportResult {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("savedview_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        return try DXFImporter.importDXFViews(filePath: tmpFile.path)
    }

    private func openTab(_ dxf: String) throws -> DocumentTab {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("savedview_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let manager = TabManager()
        let idx = try manager.openTab(url: tmpFile)
        return manager.tabs[idx]
    }

    // MARK: - Import

    func testSavedViewParsedWithYFlip() throws {
        let imported = try importViews(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(centerX: 100, centerY: 200, height: 50)))
        XCTAssertEqual(
            imported.modelSavedView,
            SavedModelView(centerX: 100, centerY: -200, height: 50))
    }

    func testMissingVportsYieldsNilSavedView() throws {
        let imported = try importViews(dxf(entities: line(0, 0, 10, 10)))
        XCTAssertNil(imported.modelSavedView)
    }

    func testUnnormalizedTopDownDirectionAccepted() throws {
        // Converters emit non-unit direction vectors (the Vivienda file
        // carries magnitude ~579); normalization must keep the record usable
        // so the overlap gate, not the import filter, decides its fate.
        let imported = try importViews(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(
                centerX: 100, centerY: 200,
                dirX: 2.27373675443216e-13, dirY: 0, dirZ: 578.751964252184)))
        XCTAssertEqual(
            imported.modelSavedView,
            SavedModelView(centerX: 100, centerY: -200, height: 50))
    }

    func testNonPlanSavedViewRejectedAtImport() throws {
        let imported = try importViews(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(centerX: 100, centerY: 200, dirX: 1, dirY: 0, dirZ: 0)))
        XCTAssertNil(imported.modelSavedView)
    }

    func testTwistedSavedViewRejectedAtImport() throws {
        let imported = try importViews(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(centerX: 100, centerY: 200, twist: 45)))
        XCTAssertNil(imported.modelSavedView)
    }

    func testZeroHeightSavedViewRejectedAtImport() throws {
        let imported = try importViews(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(centerX: 100, centerY: 200, height: 0)))
        XCTAssertNil(imported.modelSavedView)
    }

    // MARK: - Gate

    private func content(
        _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
    ) -> BoundingBox3D {
        BoundingBox3D(
            min: Vector3(x: minX, y: minY, z: 0),
            max: Vector3(x: maxX, y: maxY, z: 0))
    }

    func testOverlappingSavedViewRestores() {
        // Vivienda-shaped content with a sane saved view over the drawings.
        let saved = SavedModelView(centerX: 1255, centerY: -1666, height: 200)
        XCTAssertTrue(SavedInitialView.shouldRestore(
            saved: saved,
            content: content(954, -1803, 1556, -1529),
            viewportWidth: 1920, viewportHeight: 1080))
    }

    func testViviendaStaleSavedViewFallsBackToExtents() {
        // The converted Vivienda *ACTIVE (Y-flipped): misses the drawings.
        let saved = SavedModelView(centerX: -20.429, centerY: -81.659, height: 151.276)
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: saved,
            content: content(954, -1803, 1556, -1529),
            viewportWidth: 1920, viewportHeight: 1080))
    }

    func testGateRejectsDegenerateInputs() {
        let box = content(0, 0, 100, 100)
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: SavedModelView(centerX: 50, centerY: 50, height: 0),
            content: box, viewportWidth: 1920, viewportHeight: 1080))
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: SavedModelView(centerX: 50, centerY: 50, height: .nan),
            content: box, viewportWidth: 1920, viewportHeight: 1080))
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: SavedModelView(centerX: 50, centerY: 50, height: 1e18),
            content: box, viewportWidth: 1920, viewportHeight: 1080))
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: SavedModelView(centerX: 50, centerY: 50, height: 50),
            content: nil, viewportWidth: 1920, viewportHeight: 1080))
        XCTAssertFalse(SavedInitialView.shouldRestore(
            saved: SavedModelView(centerX: 50, centerY: 50, height: 50),
            content: box, viewportWidth: 0, viewportHeight: 1080))
    }

    // MARK: - Camera math

    func testCameraCentersSavedView() {
        let framed = SavedInitialView.camera(
            saved: SavedModelView(centerX: 10, centerY: -20, height: 50),
            viewportX: 0, viewportY: 0,
            viewportWidth: 800, viewportHeight: 600,
            windowWidth: 800, windowHeight: 600,
            rotation: 0)
        XCTAssertEqual(framed.zoom, 12, accuracy: 1e-9)
        XCTAssertEqual(framed.offsetX, 10, accuracy: 1e-9)
        XCTAssertEqual(framed.offsetY, -20, accuracy: 1e-9)
    }

    // MARK: - Live readout (VIEWCTR / VIEWSIZE inverse)

    func testLiveViewInvertsCamera() {
        let saved = SavedModelView(centerX: 10, centerY: -20, height: 50)
        let framed = SavedInitialView.camera(
            saved: saved,
            viewportX: 0, viewportY: 0,
            viewportWidth: 800, viewportHeight: 600,
            windowWidth: 800, windowHeight: 600,
            rotation: 0)
        let live = SavedInitialView.liveView(
            offsetX: framed.offsetX, offsetY: framed.offsetY, zoom: framed.zoom,
            rotation: 0,
            viewportX: 0, viewportY: 0,
            viewportWidth: 800, viewportHeight: 600,
            windowWidth: 800, windowHeight: 600)
        XCTAssertEqual(live.centerX, 10, accuracy: 1e-9)
        XCTAssertEqual(live.centerY, -20, accuracy: 1e-9)
        XCTAssertEqual(live.height, 50, accuracy: 1e-9)
    }

    func testLiveViewRoundTripsOffsetViewportAndRotation() {
        for rotation in [0.0, 0.3, -1.2] {
            let saved = SavedModelView(centerX: 1255, centerY: -1666, height: 200)
            let framed = SavedInitialView.camera(
                saved: saved,
                viewportX: 270, viewportY: 150,
                viewportWidth: 2000, viewportHeight: 1200,
                windowWidth: 2560, windowHeight: 1440,
                rotation: rotation)
            let live = SavedInitialView.liveView(
                offsetX: framed.offsetX, offsetY: framed.offsetY, zoom: framed.zoom,
                rotation: rotation,
                viewportX: 270, viewportY: 150,
                viewportWidth: 2000, viewportHeight: 1200,
                windowWidth: 2560, windowHeight: 1440)
            XCTAssertEqual(live.centerX, 1255, accuracy: 1e-6)
            XCTAssertEqual(live.centerY, -1666, accuracy: 1e-6)
            XCTAssertEqual(live.height, 200, accuracy: 1e-9)
        }
    }

    func testLiveViewHeightMatchesZoom() {
        let live = SavedInitialView.liveView(
            offsetX: 0, offsetY: 0, zoom: 4.295201572984616,
            rotation: 0,
            viewportX: 0, viewportY: 0,
            viewportWidth: 2806, viewportHeight: 1810,
            windowWidth: 2806, windowHeight: 1810)
        XCTAssertEqual(live.height, 1810 / 4.295201572984616, accuracy: 1e-9)
    }

    // MARK: - Sysvar echo (VIEWCTR / VIEWSIZE)

    func testEchoRegisteredAsCommands() {
        for name in ["VIEWCTR", "VIEWSIZE"] {
            let desc = CommandDescriptor.allCommands.first { $0.canonicalName == name }
            XCTAssertNotNil(desc, "\(name) must be a registered command")
            XCTAssertTrue(desc?.aliases.isEmpty ?? false)
        }
    }

    func testEchoFormatsReadout() {
        XCTAssertEqual(
            CADCommandProcessor.liveSysvarEcho(
                name: "VIEWCTR",
                center: Vector3(x: 1254.709585, y: -1665.826979, z: 0),
                height: 421.5),
            "VIEWCTR = 1254.709585,-1665.826979,0.000000 (read-only)")
        XCTAssertEqual(
            CADCommandProcessor.liveSysvarEcho(
                name: "VIEWSIZE", center: .zero, height: 421.5),
            "VIEWSIZE = 421.500000 (read-only)")
        XCTAssertNil(CADCommandProcessor.liveSysvarEcho(
            name: "ZOOM", center: .zero, height: 1))
        XCTAssertNil(CADCommandProcessor.liveSysvarEcho(
            name: "VIEWCTR2", center: .zero, height: 1))
    }

    // MARK: - Tab threading

    func testOpenTabThreadsSavedView() throws {
        let tab = try openTab(dxf(
            entities: line(95, 195, 105, 205),
            vport: vport(centerX: 100, centerY: 200, height: 50)))
        XCTAssertEqual(
            tab.initialModelView,
            SavedModelView(centerX: 100, centerY: -200, height: 50))
    }

    func testOpenTabWithoutVportsLeavesNilSavedView() throws {
        let tab = try openTab(dxf(entities: line(0, 0, 10, 10)))
        XCTAssertNil(tab.initialModelView)
    }
}
