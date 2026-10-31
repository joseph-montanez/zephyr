import XCTest
@testable import ZephyrCore

/// Paper-space Phase 1: PSPACE/MSPACE view switching, TILEMODE/CVPORT/CTAB
/// space state, and $TILEMODE written from the active space on export.
final class PaperSpacePhase1Tests: XCTestCase {

    private func makeDocument(layerName: String) -> CADDocument {
        let document = CADDocument()
        document.importLayersBlocksEntities(
            layers: [Layer(name: layerName, color: .white)],
            blocks: [],
            entities: [])
        return document
    }

    @MainActor
    private func makeManager(withSheet: Bool) -> TabManager {
        let modelDoc = makeDocument(layerName: "ModelLayer")
        var views = [DrawingView(name: "Model", kind: .model, document: modelDoc)]
        if withSheet {
            views.append(DrawingView(
                name: "Layout1", kind: .sheet,
                document: makeDocument(layerName: "SheetLayer")))
        }
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Phase1", drawingViews: views))
        return manager
    }

    @MainActor
    func testSwitchToPaperSpaceAndBackUpdatesTileMode() {
        let manager = makeManager(withSheet: true)
        XCTAssertEqual(manager.tileMode, 1)
        XCTAssertEqual(manager.currentViewportID, 2)
        XCTAssertFalse(manager.isPaperSpace)
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1"])

        XCTAssertTrue(manager.switchToPaperSpace())
        XCTAssertTrue(manager.isPaperSpace)
        XCTAssertEqual(manager.tileMode, 0)
        XCTAssertEqual(manager.currentViewportID, 1)
        XCTAssertEqual(manager.activeViewName, "Layout1")
        XCTAssertEqual(manager.spaceState.currentLayoutName, "Layout1")

        // Already in paper space: stays put and still succeeds.
        XCTAssertTrue(manager.switchToPaperSpace())
        XCTAssertEqual(manager.activeTab?.activeViewIndex, 1)

        XCTAssertTrue(manager.switchToModelSpace())
        XCTAssertEqual(manager.tileMode, 1)
        XCTAssertEqual(manager.activeViewName, "Model")
        XCTAssertEqual(manager.spaceState, DrawingSpaceState(
            tileMode: 1, currentViewportID: 2,
            currentLayoutName: "Model", paperLayoutNames: ["Layout1"]))
    }

    @MainActor
    func testSwitchToPaperSpaceWithoutSheetsFailsHonestly() {
        let manager = makeManager(withSheet: false)
        XCTAssertFalse(manager.switchToPaperSpace())
        XCTAssertEqual(manager.tileMode, 1)
        XCTAssertEqual(manager.activeViewName, "Model")
        XCTAssertEqual(manager.paperLayoutNames, [])
        XCTAssertTrue(manager.switchToModelSpace())
    }

    private func tileModeHeaderValue(inDXFAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(of: "$TILEMODE"), i + 2 < lines.count else {
            XCTFail("$TILEMODE header not found")
            return ""
        }
        XCTAssertEqual(lines[i + 1], "70")
        return lines[i + 2]
    }

    func testExportWritesTileModeFromActiveSpace() throws {
        let views = [
            DrawingView(
                name: "Model", kind: .model,
                document: makeDocument(layerName: "ModelLayer")),
            DrawingView(
                name: "Layout1", kind: .sheet,
                document: makeDocument(layerName: "SheetLayer")),
        ]
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilemode-model-\(UUID().uuidString).dxf")
        let paperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilemode-paper-\(UUID().uuidString).dxf")
        defer {
            try? FileManager.default.removeItem(at: modelURL)
            try? FileManager.default.removeItem(at: paperURL)
        }
        try DXFExporter.export(views: views, to: modelURL, tileMode: 1)
        try DXFExporter.export(views: views, to: paperURL, tileMode: 0)
        XCTAssertEqual(try tileModeHeaderValue(inDXFAt: modelURL), "1")
        XCTAssertEqual(try tileModeHeaderValue(inDXFAt: paperURL), "0")
    }
}
