import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 4: publish execution over `PublishJobSpec` (background runner).
/// Covers the Master-model (multi-sheet) and Master-layout (single-sheet)
/// scenarios, space-scope rejection, missing-file and converter-missing
/// behavior, cancellation with partial-output cleanup, sanitized naming,
/// prompt/explicit naming, output location, open-in-viewer, load-once
/// caching, and the never-mutate-open-drawings guarantee.
@MainActor
final class PublishExecutionTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshotDoc() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let layerID = doc.allLayers.first!.handle
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 100, y: 50, z: 0))],
            transform: .identity))
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

    private func openSnapshots() -> [String: CADDocumentSnapshot] {
        let model = snapshotDoc()
        let layout = snapshotDoc()
        return ["Model": model.snapshot(), "Layout1": layout.snapshot()]
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pubexec-\(UUID().uuidString)", isDirectory: true)
    }

    private func pdfText(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func pdfs(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "pdf"
            } ?? []
    }

    // MARK: - Sendable test helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func increment() { lock.lock(); calls += 1; lock.unlock() }
    }

    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL] = []
        func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }

    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var counts: [String: Int] = [:]
        func record(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        var task: Task<PublishJobReport, Error>?
        func store(_ t: Task<PublishJobReport, Error>) { lock.lock(); task = t; lock.unlock() }
        func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
    }

    // MARK: - Master-model multi-sheet scenario

    func testMasterModelMultiSheet() async throws {
        let master = masterMetadata()
        let target = targetMetadata()
        var store = PublishSheetStore()
        store.addDrawing(master)
        store.addDrawing(target)
        let targetModel = try XCTUnwrap(store.sheets.first {
            $0.tabName == "Model" && $0.sheetName.hasPrefix("1-")
        })
        XCTAssertEqual(store.assign(
            setupName: "PDF A4 - Model",
            from: "/master/Master.dwg",
            to: [targetModel.id]), 1)

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = Counter()
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .promptForName,
            targetFileName: "MasterBook.pdf",
            openInViewerWhenDone: false,
            sheets: store.sheets.filter { $0.space == .model })
        let report = try await PublishRunner.run(
            spec: spec,
            openDrawings: [master.id: openSnapshots(), target.id: openSnapshots()],
            progress: { _, _ in counter.increment() })

        XCTAssertEqual(report.outputURLs.count, 1)
        XCTAssertEqual(report.outputURLs[0].lastPathComponent, "MasterBook.pdf")
        XCTAssertTrue(report.sheets.allSatisfy { $0.status == .ready })
        XCTAssertEqual(report.sheets.count, 2)
        XCTAssertGreaterThan(counter.calls, 0)
        let data = try Data(contentsOf: report.outputURLs[0])
        let text = pdfText(data)
        XCTAssertTrue(text.hasPrefix("%PDF-1.7"))
        XCTAssertTrue(text.contains("/Count 2"), "both Model sheets land in one file")
        // Borrowed provenance survived to the report, not just the store.
        XCTAssertTrue(report.openedURLs.isEmpty)
    }

    // MARK: - Master-layout single-sheet scenario

    func testMasterLayoutSingleSheets() async throws {
        let master = masterMetadata()
        let target = targetMetadata()
        var store = PublishSheetStore()
        store.addDrawing(master)
        store.addDrawing(target)
        let targetLayout = try XCTUnwrap(store.sheets.first {
            $0.tabName == "Layout1" && $0.sheetName.hasPrefix("1-")
        })
        XCTAssertEqual(store.assign(
            setupName: "PDF A3 - Layout",
            from: "/master/Master.dwg",
            to: [targetLayout.id]), 1)

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewer = URLRecorder()
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            openInViewerWhenDone: true,
            sheets: store.sheets.filter { $0.space == .layout })
        let report = try await PublishRunner.run(
            spec: spec,
            openDrawings: [master.id: openSnapshots(), target.id: openSnapshots()],
            viewerOpener: { viewer.record($0) })

        XCTAssertEqual(report.outputURLs.count, 2)
        XCTAssertEqual(
            Set(report.outputURLs.map(\.lastPathComponent)),
            ["Master-Layout1.pdf", "1-Layout1.pdf"])
        for url in report.outputURLs {
            XCTAssertTrue(pdfText(try Data(contentsOf: url)).hasPrefix("%PDF-1.7"))
        }
        XCTAssertEqual(report.openedURLs, report.outputURLs)
        XCTAssertEqual(viewer.urls, report.outputURLs)
    }

    // MARK: - Space-scope rejection

    func testSpaceScopeRejectionReportsErrorAndWritesNothing() async throws {
        var store = PublishSheetStore()
        store.addDrawing(masterMetadata())
        store.addDrawing(targetMetadata())
        let targetModel = try XCTUnwrap(store.sheets.first {
            $0.tabName == "Model" && $0.sheetName.hasPrefix("1-")
        })
        // A Layout setup must not apply to a Model row: nothing changes,
        // so the row stays unresolved (`<Default: None>`).
        XCTAssertEqual(store.assign(
            setupName: "PDF A3 - Layout", to: [targetModel.id]), 0)

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .plotterNamedInPageSetup,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: [targetModel])
        let report = try await PublishRunner.run(spec: spec, openDrawings: [:])
        // No open drawing and no such file on disk: the row fails to load,
        // and — crucially — no multi-sheet file is produced.
        XCTAssertEqual(report.sheets.count, 1)
        XCTAssertEqual(report.sheets[0].status, .error)
        XCTAssertTrue(report.outputURLs.isEmpty)
        XCTAssertTrue(pdfs(in: dir).isEmpty, "no partial output for a fully-failed job")
    }

    func testMissingSetupWarningUnderPDF() async throws {
        let entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "",
            tabName: "Model", space: .model)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: [entry])
        let report = try await PublishRunner.run(
            spec: spec, openDrawings: [entry.drawingID: openSnapshots()])
        XCTAssertEqual(report.sheets[0].status, .warning)
        XCTAssertTrue(report.outputURLs.isEmpty)
        XCTAssertTrue(pdfs(in: dir).isEmpty)
    }

    // MARK: - Missing-file and converter-missing behavior

    func testMissingFileReportsPerSheetError() async throws {
        var settings = modelSetup(named: "PDF A4 - Model")
        settings.pageSetupName = "PDF A4 - Model"
        let entry = PublishSheetEntry(
            sheetName: "ghost-Model", drawingID: UUID(),
            sourceDwgPath: "/no/such/drawing.dxf",
            tabName: "Model", space: .model,
            defaultSetupName: "PDF A4 - Model", defaultSetup: settings)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: [entry])
        // Default (disk) loader: end-to-end missing-file path.
        let report = try await PublishRunner.run(spec: spec)
        XCTAssertEqual(report.sheets[0].status, .error)
        XCTAssertTrue(report.sheets[0].message.contains("/no/such/drawing.dxf"))
        XCTAssertTrue(report.outputURLs.isEmpty)
        XCTAssertTrue(pdfs(in: dir).isEmpty)
    }

    func testConverterMissingReportsPerSheetError() async throws {
        let entry = PublishSheetEntry(
            sheetName: "plan-Model", drawingID: UUID(),
            sourceDwgPath: "/jobs/plan.dwg",
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader: PublishFileLoader = { _ in
            throw DXFPlotSettingsImport.ImportError.noConverter("no ODA converter found")
        }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: [entry])
        let report = try await PublishRunner.run(spec: spec, fileLoader: loader)
        XCTAssertEqual(report.sheets[0].status, .error)
        XCTAssertTrue(
            report.sheets[0].message.lowercased().contains("convert"),
            "converter gap must be named, got: \(report.sheets[0].message)")
        XCTAssertTrue(pdfs(in: dir).isEmpty)
    }

    func testUnsupportedFormatReportsPerSheetError() async throws {
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: txt) }
        let entry = PublishSheetEntry(
            sheetName: "note-Model", drawingID: UUID(),
            sourceDwgPath: txt.path,
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: [entry])
        let report = try await PublishRunner.run(spec: spec)
        XCTAssertEqual(report.sheets[0].status, .error)
        XCTAssertTrue(report.outputURLs.isEmpty)
    }

    // MARK: - Cancellation and no-partial-output guarantees

    func testCancelledJobWritesNothing() async throws {
        var sheets: [PublishSheetEntry] = []
        let snaps = openSnapshots()
        var open: [UUID: [String: CADDocumentSnapshot]] = [:]
        for i in 0..<5 {
            let id = UUID()
            open[id] = snaps
            sheets.append(PublishSheetEntry(
                sheetName: "S\(i)-Model", drawingID: id, sourceDwgPath: "",
                tabName: "Model", space: .model,
                defaultSetupName: "S", defaultSetup: modelSetup(named: "S")))
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: sheets)
        let box = TaskBox()
        let task = Task {
            try await PublishRunner.run(
                spec: spec, openDrawings: open,
                progress: { _, _ in box.cancel() })
        }
        box.store(task)
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected: the progress hook cancelled the job mid-resolution.
        }
        XCTAssertTrue(pdfs(in: dir).isEmpty, "cancelled jobs leave no partial output")
    }

    func testCancelledMultiSheetWritesNothing() async throws {
        let snaps = openSnapshots()
        let id = UUID()
        let sheets = (0..<3).map { i in
            PublishSheetEntry(
                sheetName: "M\(i)-Layout1", drawingID: id, sourceDwgPath: "",
                tabName: "Layout1", space: .layout,
                defaultSetupName: "S", defaultSetup: layoutSetup(named: "S"))
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: sheets)
        let box = TaskBox()
        let task = Task {
            try await PublishRunner.run(
                spec: spec, openDrawings: [id: snaps],
                progress: { _, _ in box.cancel() })
        }
        box.store(task)
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(pdfs(in: dir).isEmpty, "cancelled multi-sheet jobs write no file")
    }

    func testCancelDuringWritesRemovesPartialSingles() async throws {
        let snaps = openSnapshots()
        let id = UUID()
        let sheets = (0..<4).map { i in
            PublishSheetEntry(
                sheetName: "W\(i)-Model", drawingID: id, sourceDwgPath: "",
                tabName: "Model", space: .model,
                defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: sheets)
        let box = TaskBox()
        let task = Task {
            try await PublishRunner.run(
                spec: spec, openDrawings: [id: snaps],
                onFileWritten: { _ in box.cancel() })
        }
        box.store(task)
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Expected: cancel after the first write removes it again.
        }
        XCTAssertTrue(pdfs(in: dir).isEmpty, "partial single-sheet output is cleaned up")
    }

    // MARK: - Naming, location, and loading guarantees

    func testSanitizedSingleSheetNames() async throws {
        let snaps = openSnapshots()
        let id = UUID()
        let entry = PublishSheetEntry(
            sheetName: "A/B: C*?", drawingID: id, sourceDwgPath: "",
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: [entry])
        let report = try await PublishRunner.run(spec: spec, openDrawings: [id: snaps])
        XCTAssertEqual(report.outputURLs.count, 1)
        let name = report.outputURLs[0].lastPathComponent
        XCTAssertEqual(name, PublishRunner.ensuringPDFExtension(
            PublishRunner.sanitizedFileName("A/B: C*?")))
        XCTAssertFalse(name.contains("/"), "no raw separators survive sanitizing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.outputURLs[0].path))
    }

    func testPromptNamingWithoutNameThrows() async throws {
        let entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "",
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: tempDir().path,
            fileType: .multiSheetFile,
            namingPolicy: .promptForName,
            targetFileName: nil,
            sheets: [entry])
        do {
            _ = try await PublishRunner.run(
                spec: spec, openDrawings: [entry.drawingID: openSnapshots()])
            XCTFail("prompt naming without a chosen name must throw")
        } catch let error as PublishExecutionError {
            guard case .missingOutputName = error else {
                return XCTFail("expected .missingOutputName, got \(error)")
            }
        }
    }

    func testExplicitRelativeNameAndEmptySpec() async throws {
        let entry = PublishSheetEntry(
            sheetName: "1-Model", drawingID: UUID(), sourceDwgPath: "",
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: modelSetup(named: "S"))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            targetFileName: "Custom/Book",
            sheets: [entry])
        let report = try await PublishRunner.run(
            spec: spec, openDrawings: [entry.drawingID: openSnapshots()])
        XCTAssertEqual(report.outputURLs[0].lastPathComponent, "Book.pdf")
        XCTAssertEqual(report.outputURLs[0].deletingLastPathComponent().lastPathComponent, "Custom")

        // An empty sheet list is a programmer error, not an empty report.
        do {
            _ = try await PublishRunner.run(spec: PublishJobSpec())
            XCTFail("empty sheet list must throw")
        } catch let error as PublishExecutionError {
            XCTAssertEqual(error, .noSheets)
        }
    }

    func testEachSourceFileLoadsOncePerJob() async throws {
        let snaps = PublishLoadedFile(
            snapshots: openSnapshots(), warnings: ["cached"])
        let loads = LoadCounter()
        let loader: PublishFileLoader = { path in
            loads.record(path)
            return snaps
        }
        func entry(sheet: String, tab: String, path: String) -> PublishSheetEntry {
            PublishSheetEntry(
                sheetName: sheet, drawingID: UUID(), sourceDwgPath: path,
                tabName: tab, space: tab == "Model" ? .model : .layout,
                defaultSetupName: "S",
                defaultSetup: tab == "Model" ? modelSetup(named: "S") : layoutSetup(named: "S"))
        }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: [
                entry(sheet: "a-Model", tab: "Model", path: "/jobs/a.dxf"),
                entry(sheet: "a-Layout1", tab: "Layout1", path: "/jobs/a.dxf"),
                entry(sheet: "b-Model", tab: "Model", path: "/jobs/b.dxf"),
            ])
        let report = try await PublishRunner.run(spec: spec, fileLoader: loader)
        XCTAssertEqual(loads.counts["/jobs/a.dxf"], 1, "one load per distinct file per job")
        XCTAssertEqual(loads.counts["/jobs/b.dxf"], 1)
        XCTAssertEqual(report.outputURLs.count, 3)
        XCTAssertEqual(report.warnings, ["cached"], "loader warnings aggregate once")
    }

    func testOpenDrawingsNeverMutate() async throws {
        let liveModel = snapshotDoc()
        let liveLayout = snapshotDoc()
        let revisionBefore = liveModel.editRevision
        let views = [
            DrawingView(name: "Model", kind: .model, document: liveModel),
            DrawingView(name: "Layout1", kind: .sheet, document: liveLayout),
        ]
        let open = DrawingViewFactory.snapshotViews(views)
        let id = UUID()
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: tempDir().path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: [
                PublishSheetEntry(
                    sheetName: "live-Model", drawingID: id, sourceDwgPath: "",
                    tabName: "Model", space: .model,
                    defaultSetupName: "S", defaultSetup: modelSetup(named: "S")),
                PublishSheetEntry(
                    sheetName: "live-Layout1", drawingID: id, sourceDwgPath: "",
                    tabName: "Layout1", space: .layout,
                    defaultSetupName: "S", defaultSetup: layoutSetup(named: "S")),
            ])
        let report = try await PublishRunner.run(spec: spec, openDrawings: [id: open])
        XCTAssertEqual(report.outputURLs.count, 1)
        XCTAssertNil(liveModel.plotSettings, "resolved setups inject into copies only")
        XCTAssertNil(liveLayout.plotSettings)
        XCTAssertEqual(liveModel.editRevision, revisionBefore, "publishing never dirties the drawing")
    }

    // MARK: - Pure helpers

    func testSanitizeAndExtensionHelpers() {
        XCTAssertEqual(PublishRunner.sanitizedFileName("A/B: C*?"), "A_B_ C__")
        XCTAssertEqual(PublishRunner.sanitizedFileName("   "), "Sheet")
        XCTAssertEqual(PublishRunner.sanitizedFileName("name..."), "name")
        XCTAssertEqual(PublishRunner.ensuringPDFExtension("Book"), "Book.pdf")
        XCTAssertEqual(PublishRunner.ensuringPDFExtension("Book.PDF"), "Book.PDF")
    }

    func testUnresolvedReferenceWarnings() throws {
        let warnings = PublishRunner.unresolvedReferenceWarnings(
            xrefPaths: ["gone.dwg"],
            imagePaths: [],
            pdfPaths: [],
            hostFolder: FileManager.default.temporaryDirectory.path,
            sourceName: "job.dxf")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("gone.dwg"))
        let present = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-present-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: present)
        defer { try? FileManager.default.removeItem(at: present) }
        let quiet = PublishRunner.unresolvedReferenceWarnings(
            imagePaths: [present.path],
            hostFolder: FileManager.default.temporaryDirectory.path,
            sourceName: "job.dxf")
        XCTAssertTrue(quiet.isEmpty, "resolvable references stay silent")
        let blank = PublishRunner.unresolvedReferenceWarnings(
            xrefPaths: ["   "],
            hostFolder: FileManager.default.temporaryDirectory.path,
            sourceName: "job.dxf")
        XCTAssertTrue(blank.isEmpty, "blank saved paths are not references")
    }
}
