import XCTest
@testable import ZephyrCore

/// DXF round-trip for the two layer fields with no standard DXF group code:
/// reconciled status and plot-style name. Both travel in ZEPHYR_LAYER XDATA
/// (1000 "RECONCILED:0" / "PLOTSTYLE:<name>"); files without that XDATA keep
/// the legacy defaults (reconciled, "Normal"). EAB v23 already carries both.
@MainActor
final class LayerParityDXFLayerXDataTests: XCTestCase {

    private func roundTrip(_ layers: [Layer]) throws -> CADDocument {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: layers, blocks: [], entities: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_xdata_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFWriterBridge.export(document: doc, to: url)
        let back = CADDocument()
        try back.importDXF(url: url)
        return back
    }

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_xdata_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    func testUnreconciledRoundTripsThroughDXF() throws {
        let back = try roundTrip([Layer(name: "XrefWalls", isReconciled: false)])
        let layer = try XCTUnwrap(back.allLayers.first(where: { $0.name == "XrefWalls" }))
        XCTAssertFalse(layer.isReconciled, "RECONCILED:0 must survive DXF export/import")
    }

    func testPlotStyleNameRoundTripsThroughDXF() throws {
        let back = try roundTrip([Layer(name: "Struc", plotStyleName: "Conceptual")])
        let layer = try XCTUnwrap(back.allLayers.first(where: { $0.name == "Struc" }))
        XCTAssertEqual(layer.plotStyleName, "Conceptual", "PLOTSTYLE XDATA must survive DXF export/import")
        XCTAssertNotNil(layer.plotStyleHandle, "group 390 handle still preserved")
    }

    func testDefaultLayersEmitNoLayerXData() throws {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: [Layer(name: "Walls")], blocks: [], entities: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_xdata_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFWriterBridge.export(document: doc, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("ZEPHYR_LAYER"), "default layers stay byte-identical (no XDATA)")
    }

    func testHandBuiltLayerXDataImports() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        XrefPlan
         70
        0
         62
        7
        1001
        ZEPHYR_LAYER
        1000
        RECONCILED:0
        1000
        PLOTSTYLE:Fire
          0
        ENDTAB
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let layer = try XCTUnwrap(doc.allLayers.first(where: { $0.name == "XrefPlan" }))
        XCTAssertFalse(layer.isReconciled)
        XCTAssertEqual(layer.plotStyleName, "Fire")
    }
}
