import XCTest
@testable import ZephyrCore

/// STB plot-style (group-390 → ACAD_PLOTSTYLENAME) import, plot mapping,
/// and canvas preview. Covers the ASD152 green-that-plots-black case:
/// layers/entities on "Style 1" of monochrome.stb.
final class PlotStyleImportTests: XCTestCase {

    private var plotStylesDir: URL {
        URL(fileURLWithPath: "Plot Styles")
    }

    private func monoSTB() throws -> PlotStyleTable {
        try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("monochrome.stb"))
    }

    // MARK: - Table lookup ("Style 1" vs "Style_1")

    func testNamedStyleResolvesSpacedName() throws {
        let table = try monoSTB()
        let pen = try XCTUnwrap(table.pen(named: "Style 1"), "DXF dictionary name must find the Style_1 pen")
        XCTAssertEqual(pen.colorPolicy, 5)
        XCTAssertEqual(pen.colorARGB, 0xFF00_0000)
        // Exact file spelling still wins first.
        XCTAssertEqual(table.pen(named: "Style_1")?.colorARGB, 0xFF00_0000)
        XCTAssertNil(table.pen(named: "No Such Style"))
    }

    // MARK: - Import resolution (390 handle → dictionary name)

    private var styleDXF: String {
        """
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
        G
        70
        0
        62
        3
        6
        Continuous
        390
        68
        0
        LAYER
        2
        H
        70
        0
        62
        2
        6
        Continuous
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
        5
        101
        8
        G
        10
        0.0
        20
        0.0
        11
        10.0
        21
        0.0
        390
        68
        0
        LINE
        5
        102
        8
        G
        10
        0.0
        20
        5.0
        11
        10.0
        21
        5.0
        390
        F
        0
        LINE
        5
        103
        8
        H
        10
        0.0
        20
        10.0
        11
        10.0
        21
        10.0
        0
        ENDSEC
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        E
        100
        AcDbDictionary
        3
        Normal
        350
        F
        3
        Style 1
        350
        68
        0
        ENDSEC
        0
        EOF
        """
    }

    private func importStyleDXF() throws -> DXFImportResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("style_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try styleDXF.write(to: url, atomically: true, encoding: .utf8)
        return try DXFImporter.importDXFViews(filePath: url.path)
    }

    private func entity(_ imported: DXFImportResult, dxfHandle: String) throws -> CADEntity {
        let view = try XCTUnwrap(imported.views.first)
        return try XCTUnwrap(view.entities.first {
            if case .string(let h)? = $0.xdata["dxf.handle"] { return h == dxfHandle } else { return false }
        })
    }

    func testImportResolvesLayerAndEntityStyles() throws {
        let imported = try importStyleDXF()
        let g = try XCTUnwrap(imported.layers.first { $0.name == "G" })
        XCTAssertEqual(g.plotStyleName, "Style 1", "390=68 must resolve through ACAD_PLOTSTYLENAME")
        let h = try XCTUnwrap(imported.layers.first { $0.name == "H" })
        XCTAssertEqual(h.plotStyleName, "Normal", "layers without 390 default to Normal")

        let styled = try entity(imported, dxfHandle: "101")
        XCTAssertEqual(styled.xdata["dxf.plotStyleName"], .string("Style 1"))
        XCTAssertEqual(LayerAccess.explicitPlotStyleName(of: styled), "Style 1")
        let normal = try entity(imported, dxfHandle: "102")
        XCTAssertEqual(LayerAccess.explicitPlotStyleName(of: normal), "Normal")
        let byLayer = try entity(imported, dxfHandle: "103")
        XCTAssertNil(LayerAccess.explicitPlotStyleName(of: byLayer), "no 390 means ByLayer")
    }

    func testPlotStyleNameResolutionRules() {
        XCTAssertEqual(
            DXFImporter.plotStyleName(xdataName: "Custom", handle: 0x68, dictionaryNameByHandle: [0x68: "Style 1"]),
            "Custom", "XDATA wins over the dictionary")
        XCTAssertEqual(
            DXFImporter.plotStyleName(xdataName: "", handle: 0x68, dictionaryNameByHandle: [0x68: "Style 1"]),
            "Style 1")
        XCTAssertEqual(
            DXFImporter.plotStyleName(xdataName: "", handle: 0xAB, dictionaryNameByHandle: [:]),
            "Normal", "unknown handles fall back to Normal")
        XCTAssertEqual(
            DXFImporter.plotStyleName(xdataName: "", handle: 0, dictionaryNameByHandle: [:]),
            "Normal")
    }

    // MARK: - Plot mapping (monochrome.stb, STB mode)

    private func styleDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        let greenID = UUID()
        let green = Layer(
            handle: greenID, name: "G", isVisible: true,
            lineWeight: 0.25, color: ColorRGBA(r: 0, g: 255, b: 0, a: 255),
            lineType: "CONTINUOUS", plotStyleName: "Style 1")
        let plainID = UUID()
        let plain = Layer(
            handle: plainID, name: "H", isVisible: true,
            lineWeight: 0.25, color: ColorRGBA(r: 0, g: 255, b: 0, a: 255),
            lineType: "CONTINUOUS", plotStyleName: "Normal")
        doc.importLayersBlocksEntities(layers: [green, plain], blocks: [], entities: [])
        doc.pstyleMode = 0
        return (doc, greenID)
    }

    private func styleSettings() -> CADPlotSettings {
        // PlotPlotStyles on, like the ASD152 sheets (flags 692).
        CADPlotSettings(plotPaperUnits: 1, styleSheet: "monochrome.stb", plotFlags: 692, plotType: 5)
    }

    private func styledEntity(layerID: UUID, styleName: String?, handleHex: String?) -> CADEntity {
        var ent = CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                  end: Vector3(x: 10, y: 0, z: 0))],
            transform: .identity)
        if let handleHex {
            ent.xdata["dxf.plotStyleHandle"] = .string(handleHex)
            ent.xdata["dxf.plotStyleName"] = .string(styleName ?? "Normal")
        }
        return ent
    }

    func testApplyPlotStylesMapsLayerStyleToBlack() throws {
        let table = try monoSTB()
        let (doc, greenID) = styleDoc()
        let ent = styledEntity(layerID: greenID, styleName: nil, handleHex: nil)
        let items: [PDFExporter.RenderItem] = [
            .geometry(entity: ent, color: ColorRGBA(r: 0, g: 255, b: 0, a: 255), lineWeightMM: 0.25)
        ]
        let mapped = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: styleSettings(),
            plotTable: table)
        guard case .geometry(_, let color, _) = mapped.first else {
            return XCTFail("expected a geometry item")
        }
        XCTAssertEqual(color.r, 0)
        XCTAssertEqual(color.g, 0)
        XCTAssertEqual(color.b, 0)
    }

    func testApplyPlotStylesHonorsExplicitNormal() throws {
        let table = try monoSTB()
        let (doc, greenID) = styleDoc()
        // Explicit "Normal" (390=F) on a Style_1 layer keeps object color.
        let ent = styledEntity(layerID: greenID, styleName: "Normal", handleHex: "F")
        let items: [PDFExporter.RenderItem] = [
            .geometry(entity: ent, color: ColorRGBA(r: 0, g: 255, b: 0, a: 255), lineWeightMM: 0.25)
        ]
        let mapped = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: styleSettings(),
            plotTable: table)
        guard case .geometry(_, let color, _) = mapped.first else {
            return XCTFail("expected a geometry item")
        }
        XCTAssertEqual(color.r, 0)
        XCTAssertEqual(color.g, 255, "explicit Normal must preserve the green")
        XCTAssertEqual(color.b, 0)
    }

    func testResolveTextPlotColorUsesEntityStyle() throws {
        let table = try monoSTB()
        let (doc, greenID) = styleDoc()
        let green = ColorRGBA(r: 0, g: 255, b: 0, a: 255)
        let layerMapped = PDFExporter.resolveTextPlotColor(
            display: green,
            source: PDFExporter.TextPlotSource(rawColor: green, layerID: greenID),
            document: doc, settings: styleSettings(),
            plotTable: table, screeningOn: false)
        XCTAssertEqual(layerMapped.r, 0)
        XCTAssertEqual(layerMapped.g, 0)
        XCTAssertEqual(layerMapped.b, 0)
        let explicitNormal = PDFExporter.resolveTextPlotColor(
            display: green,
            source: PDFExporter.TextPlotSource(rawColor: green, layerID: greenID, plotStyleName: "Normal"),
            document: doc, settings: styleSettings(),
            plotTable: table, screeningOn: false)
        XCTAssertEqual(explicitNormal.r, 0)
        XCTAssertEqual(explicitNormal.g, 255)
        XCTAssertEqual(explicitNormal.b, 0)
    }

    // MARK: - Canvas preview (ShowPlotStyles bit 2)

    private func previewSnapshot(showPlotStyles: Bool) -> CADDocumentSnapshot {
        let (doc, greenID) = styleDoc()
        let ent = CADEntity(
            layerID: greenID,
            localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                  end: Vector3(x: 10, y: 0, z: 0))],
            transform: .identity)
        doc.addEntity(ent)
        var ps = CADPlotSettings(plotPaperUnits: 1, styleSheet: "monochrome.stb")
        ps.plotFlags = showPlotStyles ? 2 : 0
        doc.plotSettings = ps
        return doc.snapshot()
    }

    func testCanvasPreviewOffKeepsObjectColor() async {
        PlotPenApplication.PlotStyleTableCache.resetForTests()
        let snapshot = previewSnapshot(showPlotStyles: false)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: snapshot, simplifyComplexBlocks: false)
        let colors = results.flatMap(\.specs).map(\.color)
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0 == (0, 255, 0, 255) },
                      "without ShowPlotStyles the green must survive, got \(colors)")
    }

    func testCanvasPreviewOnMapsStyleToBlack() async {
        PlotPenApplication.PlotStyleTableCache.resetForTests()
        let snapshot = previewSnapshot(showPlotStyles: true)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: snapshot, simplifyComplexBlocks: false)
        let colors = results.flatMap(\.specs).map(\.color)
        XCTAssertFalse(colors.isEmpty)
        XCTAssertTrue(colors.allSatisfy { $0 == (0, 0, 0, 255) },
                      "with ShowPlotStyles the Style_1 green must preview black, got \(colors)")
    }
}
