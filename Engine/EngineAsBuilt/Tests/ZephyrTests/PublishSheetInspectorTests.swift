import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 3: publish core model + sheet inspector (no UI, no execution).
/// Covers Master setup inheritance, Model/Layout space filtering, unique
/// sheet naming/dedupe, Add/Remove/Move ordering, bulk assignment, every
/// preflight status, and the metadata inspector (generated DXF/EAB
/// fixtures, live open tabs, error paths).
final class PublishSheetInspectorTests: XCTestCase {

    // MARK: - Fixtures (generated, no checked-in binaries)

    private func layeredDoc() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return doc
    }

    private func modelSetup(named name: String) -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1, plotRotation: 1,
            pageSetupName: name,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)",
            plotType: 1, standardScaleType: 0)
        ps.useStandardScale = false
        return ps
    }

    private func layoutSetup(named name: String) -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 1,
            pageSetupName: name,
            plotConfigName: "AutoCAD PDF (High Quality Print).pc3",
            canonicalMediaName: "ISO_full_bleed_A3_(420.00_x_297.00_MM)",
            plotType: 5, standardScaleType: 16)
        ps.useStandardScale = true
        return ps
    }

    private func masterMetadata() -> PublishDrawingMetadata {
        PublishDrawingMetadata(
            sourcePath: "/master/Master.dwg",
            displayName: "Master.dwg",
            tabs: [
                PublishDrawingTabMetadata(
                    name: "Model", space: .model,
                    defaultSetupName: "PDF A4 - Model",
                    defaultSetup: modelSetup(named: "PDF A4 - Model")),
                PublishDrawingTabMetadata(
                    name: "Layout1", space: .layout,
                    defaultSetupName: "PDF A3 - Layout",
                    defaultSetup: layoutSetup(named: "PDF A3 - Layout")),
            ],
            namedSetups: [
                CADNamedPageSetup(
                    name: "PDF A4 - Model",
                    settings: modelSetup(named: "PDF A4 - Model"), isModelType: true),
                CADNamedPageSetup(
                    name: "PDF A3 - Layout",
                    settings: layoutSetup(named: "PDF A3 - Layout"), isModelType: false),
            ])
    }

    private func targetMetadata(base: String = "1") -> PublishDrawingMetadata {
        PublishDrawingMetadata(
            sourcePath: "/jobs/\(base).dwg",
            displayName: "\(base).dwg",
            tabs: [
                PublishDrawingTabMetadata(name: "Model", space: .model),
                PublishDrawingTabMetadata(name: "Layout1", space: .layout),
            ])
    }

    @MainActor
    private func storeWithMasterAndTarget() -> PublishSheetStore {
        var store = PublishSheetStore()
        store.addDrawing(masterMetadata())
        store.addDrawing(targetMetadata())
        return store
    }

    private func modelRow(in store: PublishSheetStore, fromBase base: String) -> PublishSheetEntry? {
        store.sheets.first { $0.tabName == "Model" && $0.sheetName.hasPrefix("\(base)-") }
    }

    // MARK: - Master setup inheritance

    @MainActor
    func testMasterSetupInheritance() {
        var store = storeWithMasterAndTarget()
        guard let targetModel = modelRow(in: store, fromBase: "1") else {
            return XCTFail("target Model row missing")
        }
        // Target rows start unresolved: native `<None>` under plotter-named.
        XCTAssertEqual(targetModel.assignment.mode, .default)
        XCTAssertEqual(targetModel.assignment.setupName, "<Default: None>")
        XCTAssertEqual(targetModel.status, .error)

        let changed = store.assign(
            setupName: "PDF A4 - Model",
            from: "/master/Master.dwg",
            to: [targetModel.id])
        XCTAssertEqual(changed, 1)
        guard let resolved = store.sheets.first(where: { $0.id == targetModel.id }) else {
            return XCTFail("row lost after assign")
        }
        XCTAssertEqual(resolved.assignment.mode, .importedMaster)
        XCTAssertEqual(resolved.assignment.setupName, "PDF A4 - Model")
        XCTAssertEqual(resolved.assignment.masterDwgPath, "/master/Master.dwg")
        XCTAssertEqual(resolved.resolvedSetup?.pageSetupName, "PDF A4 - Model")
        XCTAssertEqual(resolved.resolvedSetup?.plotConfigName, "DWG To PDF.pc3")
        XCTAssertEqual(resolved.space, .model)
    }

    @MainActor
    func testOwnDrawingSetupStaysNamedLocal() {
        var store = storeWithMasterAndTarget()
        guard let masterModel = modelRow(in: store, fromBase: "Master") else {
            return XCTFail("master Model row missing")
        }
        let changed = store.assign(
            setupName: "PDF A4 - Model",
            from: "/master/Master.dwg",
            to: [masterModel.id])
        XCTAssertEqual(changed, 1)
        let row = try? XCTUnwrap(store.sheets.first(where: { $0.id == masterModel.id }))
        XCTAssertEqual(row?.assignment.mode, .namedLocal)
        XCTAssertNil(row?.assignment.masterDwgPath)
    }

    // MARK: - Space filtering

    @MainActor
    func testSpaceFilteringAndWrongSpaceRefused() {
        let store = storeWithMasterAndTarget()
        guard let targetModel = modelRow(in: store, fromBase: "1"),
              let targetLayout = store.sheets.first(where: {
                  $0.tabName == "Layout1" && $0.sheetName.hasPrefix("1-")
              }) else {
            return XCTFail("target rows missing")
        }
        let modelCandidates = store.candidateSetups(for: targetModel)
        XCTAssertFalse(modelCandidates.isEmpty)
        XCTAssertTrue(modelCandidates.allSatisfy { $0.setup.isModelType })
        XCTAssertTrue(modelCandidates.allSatisfy { !$0.isOwnDrawing })
        let layoutCandidates = store.candidateSetups(for: targetLayout)
        XCTAssertFalse(layoutCandidates.isEmpty)
        XCTAssertTrue(layoutCandidates.allSatisfy { !$0.setup.isModelType })

        // A Layout setup must not apply to a Model row (strict scoping).
        var mutable = store
        let changed = mutable.assign(
            setupName: "PDF A3 - Layout", to: [targetModel.id])
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(
            mutable.sheets.first(where: { $0.id == targetModel.id })?.assignment.mode,
            .default)
    }

    // MARK: - Naming / dedupe

    @MainActor
    func testUniqueSheetNamingDedupe() {
        var store = PublishSheetStore()
        store.addDrawing(targetMetadata())
        store.addDrawing(targetMetadata())
        let names = store.sheets.map(\.sheetName)
        XCTAssertEqual(names, ["1-Model", "1-Layout1", "1-Model (2)", "1-Layout1 (2)"])
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - Add / Remove / Move ordering

    @MainActor
    func testAddRemoveMoveOrdering() {
        var store = PublishSheetStore()
        store.addDrawing(masterMetadata())
        store.addDrawing(targetMetadata())
        XCTAssertEqual(
            store.sheets.map(\.sheetName),
            ["Master-Model", "Master-Layout1", "1-Model", "1-Layout1"])

        // Remove one row by offset.
        store.removeSheets(at: [1])
        XCTAssertEqual(
            store.sheets.map(\.sheetName),
            ["Master-Model", "1-Model", "1-Layout1"])

        // Move last row to the top.
        XCTAssertTrue(store.moveSheet(from: 2, to: 0))
        XCTAssertEqual(
            store.sheets.map(\.sheetName),
            ["1-Layout1", "Master-Model", "1-Model"])

        // Out-of-range moves fail without mutating.
        XCTAssertFalse(store.moveSheet(from: 9, to: 0))
        XCTAssertFalse(store.moveSheet(from: 0, to: 9))
        XCTAssertEqual(store.sheets.count, 3)

        // Remove by id.
        let doomed = store.sheets[0].id
        XCTAssertTrue(store.removeSheet(id: doomed))
        XCTAssertFalse(store.removeSheet(id: doomed))
        XCTAssertEqual(store.sheets.map(\.sheetName), ["Master-Model", "1-Model"])
    }

    @MainActor
    func testIncludeModelFlagSkipsModelRows() {
        var store = PublishSheetStore()
        store.addDrawing(targetMetadata(), includeModel: false)
        XCTAssertEqual(store.sheets.map(\.sheetName), ["1-Layout1"])
    }

    // MARK: - Bulk assignment + default reset

    @MainActor
    func testBulkAssignAcrossSpaceSelection() {
        var store = storeWithMasterAndTarget()
        let allIDs = Set(store.sheets.map(\.id))
        // One Model setup applied to a mixed selection touches Model rows only.
        let changed = store.assign(
            setupName: "PDF A4 - Model",
            from: "/master/Master.dwg",
            to: allIDs)
        XCTAssertEqual(changed, 2)
        for row in store.sheets where row.space == .model {
            XCTAssertEqual(row.assignment.mode,
                           row.sourceDwgPath == "/master/Master.dwg" ? .namedLocal : .importedMaster)
        }
        for row in store.sheets where row.space == .layout {
            XCTAssertEqual(row.assignment.mode, .default)
        }
        // Reset restores native provenance labels.
        store.assignDefault(to: allIDs)
        for row in store.sheets {
            XCTAssertEqual(row.assignment.mode, .default)
            XCTAssertTrue(row.assignment.setupName.hasPrefix("<Default: "))
        }
    }

    // MARK: - Preflight statuses

    @MainActor
    func testPreflightReady() {
        let store = storeWithMasterAndTarget()
        let masterModel = try? XCTUnwrap(modelRow(in: store, fromBase: "Master"))
        // Native Master rows carry valid setups from their own drawing.
        XCTAssertEqual(masterModel?.status, .ready)
        XCTAssertEqual(masterModel?.statusMessage, "No errors")
    }

    @MainActor
    func testPreflightMissingSetupErrorVsWarning() {
        var entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "/jobs/1.dwg",
            tabName: "Model", space: .model)
        var plotter = preflightPublishEntry(entry, publishTo: .plotterNamedInPageSetup)
        XCTAssertEqual(plotter.status, .error)
        XCTAssertFalse(plotter.message.isEmpty)
        var pdf = preflightPublishEntry(entry, publishTo: .pdf)
        XCTAssertEqual(pdf.status, .warning)

        // Assigning a setup clears both.
        var store = storeWithMasterAndTarget()
        guard let targetModel = modelRow(in: store, fromBase: "1") else {
            return XCTFail("target Model row missing")
        }
        entry = try! XCTUnwrap(store.sheets.first(where: { $0.id == targetModel.id }))
        store.assign(setupName: "PDF A4 - Model", from: "/master/Master.dwg", to: [entry.id])
        entry = try! XCTUnwrap(store.sheets.first(where: { $0.id == targetModel.id }))
        store.refreshPreflight(publishTo: .plotterNamedInPageSetup)
        entry = try! XCTUnwrap(store.sheets.first(where: { $0.id == targetModel.id }))
        XCTAssertEqual(entry.status, .ready)
        plotter = preflightPublishEntry(entry, publishTo: .plotterNamedInPageSetup)
        pdf = preflightPublishEntry(entry, publishTo: .pdf)
        XCTAssertEqual(plotter.status, .ready)
        XCTAssertEqual(pdf.status, .ready)
    }

    @MainActor
    func testPreflightUnknownPlotterWarning() {
        let entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "/jobs/1.dwg",
            tabName: "Model", space: .model,
            defaultSetupName: "Custom",
            defaultSetup: modelSetup(named: "Custom"),
            assignment: PublishSetupAssignment(
                mode: .namedLocal, setupName: "Custom",
                resolvedSetup: {
                    var ps = modelSetup(named: "Custom")
                    ps.plotConfigName = "Mystery Plotter.pc3"
                    return ps
                }()))
        let plotter = preflightPublishEntry(entry, publishTo: .plotterNamedInPageSetup)
        XCTAssertEqual(plotter.status, .warning)
        XCTAssertTrue(plotter.message.contains("Mystery Plotter.pc3"))
        // PDF output ignores the device entirely.
        let pdf = preflightPublishEntry(entry, publishTo: .pdf)
        XCTAssertEqual(pdf.status, .ready)
    }

    @MainActor
    func testPreflightInvalidPaperSizeError() {
        var bad = modelSetup(named: "Bad")
        bad.paperWidthMM = 0
        bad.paperHeightMM = -3
        let entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "/jobs/1.dwg",
            tabName: "Model", space: .model,
            defaultSetupName: "Bad", defaultSetup: bad)
        for destination in [PublishDestination.plotterNamedInPageSetup, .pdf] {
            let outcome = preflightPublishEntry(entry, publishTo: destination)
            XCTAssertEqual(outcome.status, .error, "invalid paper must error for \(destination)")
        }
    }

    // MARK: - Inspector: generated DXF fixture

    @MainActor
    func testInspectorDXFRoundTrip() throws {
        let modelDoc = layeredDoc()
        modelDoc.plotSettings = modelSetup(named: "PDF A4 - Model")
        let sheetDoc = layeredDoc()
        sheetDoc.plotSettings = layoutSetup(named: "PDF A3 - Layout")
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let setups = [
            CADNamedPageSetup(
                name: "PDF A4 - Model",
                settings: modelSetup(named: "PDF A4 - Model"), isModelType: true),
            CADNamedPageSetup(
                name: "PDF A3 - Layout",
                settings: layoutSetup(named: "PDF A3 - Layout"), isModelType: false),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFWriterBridge.export(views: views, to: url, namedSetups: setups)

        let metadata = try PublishMetadataInspector.readFile(atPath: url.path)
        XCTAssertEqual(metadata.displayName, url.lastPathComponent)
        XCTAssertEqual(metadata.tabs.map(\.name), ["Model", "Layout1"])
        XCTAssertEqual(metadata.tabs.map(\.space), [.model, .layout])
        XCTAssertEqual(Set(metadata.namedSetups.map(\.name)),
                       ["PDF A4 - Model", "PDF A3 - Layout"])
        XCTAssertEqual(metadata.setups(matching: .model).map(\.name), ["PDF A4 - Model"])
        XCTAssertEqual(metadata.setups(matching: .layout).map(\.name), ["PDF A3 - Layout"])
        // The generalized entry point agrees with the inspector.
        let viaImport = try DXFPlotSettingsImport.readMetadata(filePath: url.path)
        XCTAssertEqual(viaImport.tabs.map(\.name), ["Model", "Layout1"])

        // Sheet naming consumes the fixture end to end.
        var store = PublishSheetStore()
        let added = store.addDrawing(metadata)
        XCTAssertEqual(added.map(\.sheetName),
                       ["\(PublishSheetStore.drawingBaseName(sourcePath: url.path, displayName: ""))-Model",
                        "\(PublishSheetStore.drawingBaseName(sourcePath: url.path, displayName: ""))-Layout1"])
    }

    // MARK: - Inspector: generated EAB fixture

    @MainActor
    func testInspectorEABRoundTrip() throws {
        let modelDoc = layeredDoc()
        modelDoc.plotSettings = modelSetup(named: "PDF A4 - Model")
        let sheetDoc = layeredDoc()
        sheetDoc.plotSettings = layoutSetup(named: "PDF A3 - Layout")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(
            views: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ],
            to: url,
            namedSetups: [
                CADNamedPageSetup(
                    name: "PDF A4 - Model",
                    settings: modelSetup(named: "PDF A4 - Model"), isModelType: true),
                CADNamedPageSetup(
                    name: "PDF A3 - Layout",
                    settings: layoutSetup(named: "PDF A3 - Layout"), isModelType: false),
            ])
        let metadata = try PublishMetadataInspector.readFile(atPath: url.path)
        XCTAssertEqual(metadata.tabs.map(\.name), ["Model", "Layout1"])
        XCTAssertEqual(metadata.tabs.map(\.space), [.model, .layout])
        XCTAssertEqual(Set(metadata.namedSetups.map(\.name)),
                       ["PDF A4 - Model", "PDF A3 - Layout"])
        XCTAssertEqual(metadata.setups(matching: .model).map(\.name), ["PDF A4 - Model"])
        XCTAssertEqual(metadata.setups(matching: .layout).map(\.name), ["PDF A3 - Layout"])
    }

    // MARK: - Inspector: error paths

    @MainActor
    func testInspectorErrors() throws {
        // Missing file.
        XCTAssertThrowsError(try PublishMetadataInspector.readFile(
            atPath: "/no/such/drawing.dxf"))

        // Unsupported extension.
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: txt) }
        XCTAssertThrowsError(try PublishMetadataInspector.readFile(atPath: txt.path))
    }

    @MainActor
    func testInspectorDWGWithoutConverterReportsGap() throws {
        // DWG without an ODA converter reports the converter gap, not a parse error.
        guard !ODADWGConverter.isAvailable else {
            throw XCTSkip("ODA converter installed; converter-missing path not testable here")
        }
        let dwg = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).dwg")
        try Data([0x41, 0x43]).write(to: dwg)
        defer { try? FileManager.default.removeItem(at: dwg) }
        do {
            _ = try PublishMetadataInspector.readFile(atPath: dwg.path)
            XCTFail("expected converter-missing error")
        } catch let error as DXFPlotSettingsImport.ImportError {
            guard case .noConverter = error else {
                return XCTFail("expected .noConverter, got \(error)")
            }
        }
    }

    // MARK: - Inspector: live open tabs

    @MainActor
    func testReadOpenTabsLive() {
        let manager = TabManager()
        let modelDoc = layeredDoc()
        modelDoc.plotSettings = modelSetup(named: "PDF A4 - Model")
        let sheetDoc = layeredDoc()
        sheetDoc.plotSettings = layoutSetup(named: "PDF A3 - Layout")
        manager.addTab(DocumentTab(
            document: modelDoc,
            fileURL: URL(fileURLWithPath: "/jobs/1.dwg"),
            displayName: "1.dwg",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ],
            namedPageSetups: [CADNamedPageSetup(
                name: "PDF A4 - Model",
                settings: modelSetup(named: "PDF A4 - Model"), isModelType: true)]))

        let open = PublishMetadataInspector.readOpenTabs(from: manager)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].sourcePath, "/jobs/1.dwg")
        XCTAssertEqual(open[0].tabs.map(\.name), ["Model", "Layout1"])
        XCTAssertEqual(open[0].tabs.map(\.space), [.model, .layout])
        XCTAssertEqual(open[0].tabs[0].defaultSetupName, "PDF A4 - Model")
        XCTAssertEqual(open[0].namedSetups.map(\.name), ["PDF A4 - Model"])
        // Same entry point through the generalized import.
        XCTAssertEqual(DXFPlotSettingsImport.readOpenTabs(from: manager).count, 1)
    }
}
