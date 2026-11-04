import XCTest
import Foundation
@testable import ZephyrCore

/// Save As DWG: dialog filter plumbing, extension resolution, ODA version
/// mapping, and (when the converter is installed) a real DXF -> DWG
/// roundtrip through `saveActiveTabAs`.
@MainActor
final class DWGSaveAsTests: XCTestCase {

    private func makeManager() -> TabManager {
        let viewDoc = CADDocument()
        let layer = Layer(name: "TestLayer", color: ColorRGBA(r: 10, g: 20, b: 30, a: 255))
        viewDoc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let line = CADPrimitive.line(
            start: Vector3(x: 4, y: 5, z: 6), end: Vector3(x: 7, y: 8, z: 9),
            color: ColorRGBA(r: 255, g: 0, b: 0, a: 255))
        let block = CADBlock(name: "TestBlock", geometry: [line])
        viewDoc.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])
        viewDoc.importLayersBlocksEntities(
            layers: [], blocks: [],
            entities: [CADEntity(layerID: layer.handle, blockID: block.handle, transform: .identity)])
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: CADDocument(), fileURL: nil, displayName: "Untitled",
            drawingViews: [DrawingView(name: "Model", kind: .model, document: viewDoc)]))
        return manager
    }

    func testDrawingSaveFiltersOfferDWG() {
        let exts = NativeFileDialog.drawingSaveFilters.map { $0.extensions }
        XCTAssertEqual(exts.first, ["dxf"], "DXF stays the default (native, no external tool)")
        XCTAssertTrue(exts.contains(["dwg"]), "Save As must offer DWG")
        XCTAssertTrue(exts.contains(["eab"]))
        XCTAssertTrue(exts.contains(["pdf"]))
    }

    func testResolvedSaveURLKeepsTypedExtension() {
        let filters = NativeFileDialog.drawingSaveFilters
        let dwgIndex = filters.firstIndex { $0.extensions == ["dwg"] }!
        // Typed extension wins even under a different filter.
        XCTAssertEqual(
            NativeFileDialog.resolvedSaveURL(
                URL(fileURLWithPath: "/tmp/plan.dxf"),
                selectedFilterIndex: dwgIndex).lastPathComponent,
            "plan.dxf")
        XCTAssertEqual(
            NativeFileDialog.resolvedSaveURL(
                URL(fileURLWithPath: "/tmp/PLAN.DWG"),
                selectedFilterIndex: 0).lastPathComponent,
            "PLAN.DWG")
    }

    func testResolvedSaveURLAppendsSelectedFilter() {
        let filters = NativeFileDialog.drawingSaveFilters
        let dwgIndex = filters.firstIndex { $0.extensions == ["dwg"] }!
        XCTAssertEqual(
            NativeFileDialog.resolvedSaveURL(
                URL(fileURLWithPath: "/tmp/site plan"),
                selectedFilterIndex: dwgIndex).lastPathComponent,
            "site plan.dwg")
        XCTAssertEqual(
            NativeFileDialog.resolvedSaveURL(
                URL(fileURLWithPath: "/tmp/layout"),
                selectedFilterIndex: 0).lastPathComponent,
            "layout.dxf")
    }

    func testResolvedSaveURLIgnoresUnusableFilter() {
        let filters = NativeFileDialog.drawingSaveFilters
        let allIndex = filters.firstIndex { $0.extensions == ["*"] }!
        for index in [-1, 99, allIndex] {
            XCTAssertEqual(
                NativeFileDialog.resolvedSaveURL(
                    URL(fileURLWithPath: "/tmp/notes"),
                    selectedFilterIndex: index).lastPathComponent,
                "notes")
        }
    }

    func testOdaVersionMapping() {
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2018), "ACAD2018")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2013), "ACAD2013")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2010), "ACAD2010")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2007), "ACAD2007")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2004), "ACAD2004")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r2000), "ACAD2000")
        // Older versions have no direct ODA name: keep previous behavior.
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r14), "ACAD2018")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .r12), "ACAD2018")
        XCTAssertEqual(ODADWGConverter.odaVersion(for: .unknown), "ACAD2018")
    }

    func testSaveActiveTabAsDWGRoundtrip() throws {
        guard ODADWGConverter.isAvailable else {
            throw XCTSkip("ODA FileConverter not installed; run INSTALLODA")
        }
        let manager = makeManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DWGSaveAsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plan.dwg")

        try manager.saveActiveTabAs(url: url)

        // Modern (R13+) DWG files begin with the 6-byte version magic,
        // e.g. AC1032 for the default AutoCAD 2018 output.
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 32)
        XCTAssertEqual(String(data: data.prefix(6), encoding: .utf8), "AC1032")

        // The tab now points at the DWG, and the geometry survives DWG -> DXF.
        XCTAssertEqual(manager.activeTab?.fileURL?.pathExtension.lowercased(), "dwg")
        XCTAssertNoThrow(try manager.openTab(url: url))
        let reopened = try XCTUnwrap(manager.activeTab)
        XCTAssertEqual(reopened.drawingViews.first?.document.allEntities.count, 1)
        XCTAssertNotNil(reopened.drawingViews.first?.document.allLayers.first(where: { $0.name == "TestLayer" }))
    }
}
