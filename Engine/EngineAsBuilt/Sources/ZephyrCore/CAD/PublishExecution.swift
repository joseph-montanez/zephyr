import Foundation

// =========================================================================
// MARK: - Publish execution (Phase 4)
// -------------------------------------------------------------------------
// Background batch-publish runner over a `PublishJobSpec`.
//
// Boundaries (deliberate):
// - Open drawings are NEVER touched: callers pass value-type
//   `CADDocumentSnapshot`s keyed by drawing ID. Every page renders from a
//   snapshot restored into a throwaway `CADDocument` with the row's
//   resolved setup injected there, so the source drawings cannot mutate
//   (mirrors `PDFExporter.generateMultiPagePDF`, which the multi-sheet
//   path reuses page for page).
// - Each distinct source file loads ONCE per job (canonical-path cache);
//   open-drawing snapshots short-circuit disk entirely.
// - Xrefs / image + PDF-underlay saved paths resolve against the source
//   file's own folder (`XrefPathResolver`); unresolvable references become
//   job warnings, never errors.
// - Multi-sheet output renders fully in memory, then writes once: a failed
//   or cancelled multi-sheet job leaves no file behind. Single-sheet
//   outputs are sanitized per-sheet names with in-job dedupe; a
//   cancellation removes whatever the job already wrote and rethrows.
// - Per-sheet validation failures (missing file, missing setup, unknown
//   tab, bad paper) are REPORTED per row while valid rows still publish —
//   AutoCAD PUBLISH keeps good sheets and logs the rest. Only programmer
//   errors (empty sheet list, prompt naming with no chosen name) throw.
// - `publishTo` selects preflight strictness upstream; execution always
//   produces PDF files (the engine's only file output). Job-level
//   `mergeControl` / `includeLayerInfo` ride each row's resolved setup
//   `pdfOptions` (see `PDFExporter.effectiveOptions`); `numberOfCopies`
//   and `includePlotStamp` are print-device concerns with no file-output
//   meaning in v1. `publishInBackground` is satisfied structurally: `run`
//   is async over snapshots and never touches live documents.
// - `openInViewerWhenDone` fires through the injected `viewerOpener`
//   (production: `NativeFileDialog.openInSystemViewer`); best effort.
// =========================================================================

/// One drawing file loaded once per job: per-tab snapshots plus the
/// unresolved-reference warnings found while resolving against the
/// source folder.
public struct PublishLoadedFile: Sendable {
    public var snapshots: [String: CADDocumentSnapshot]
    public var warnings: [String]

    public init(
        snapshots: [String: CADDocumentSnapshot] = [:],
        warnings: [String] = []
    ) {
        self.snapshots = snapshots
        self.warnings = warnings
    }
}

/// Disk loader for one source path. Receives the entry's `sourceDwgPath`.
public typealias PublishFileLoader = @Sendable (String) throws -> PublishLoadedFile

/// Outcome for one sheet row.
public struct PublishSheetReport: Sendable, Equatable {
    public var id: UUID
    public var sheetName: String
    public var status: PublishSheetStatus
    public var message: String
    public var outputURL: URL?

    public init(
        id: UUID,
        sheetName: String,
        status: PublishSheetStatus,
        message: String,
        outputURL: URL? = nil
    ) {
        self.id = id
        self.sheetName = sheetName
        self.status = status
        self.message = message
        self.outputURL = outputURL
    }
}

/// Whole-job outcome: per-sheet rows in spec order, written files in
/// write order, aggregated warnings, and every URL handed to the viewer.
public struct PublishJobReport: Sendable, Equatable {
    public var sheets: [PublishSheetReport]
    public var outputURLs: [URL]
    public var warnings: [String]
    public var openedURLs: [URL]

    public init(
        sheets: [PublishSheetReport] = [],
        outputURLs: [URL] = [],
        warnings: [String] = [],
        openedURLs: [URL] = []
    ) {
        self.sheets = sheets
        self.outputURLs = outputURLs
        self.warnings = warnings
        self.openedURLs = openedURLs
    }
}

public enum PublishExecutionError: Error, LocalizedError, Equatable {
    case noSheets
    case missingOutputName(String)

    public var errorDescription: String? {
        switch self {
        case .noSheets:
            return "Nothing to publish: the sheet list is empty."
        case .missingOutputName(let detail):
            return "No output name: \(detail)"
        }
    }
}

public enum PublishRunner {

    // MARK: - File names

    /// Strip filename-hostile characters (`<>:"/\|?*` + controls), trim
    /// edge whitespace/dots, deflect Windows reserved device names
    /// (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9` —
    /// reserved with or without an extension, so `CON.pdf` is illegal
    /// too), cap length. Never empty (falls back).
    public static func sanitizedFileName(_ name: String, fallback: String = "Sheet") -> String {
        let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var out = name.components(separatedBy: illegal).joined(separator: "_")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return fallback }
        // Windows refuses reserved device stems even with an extension
        // (`CON`, `con.pdf`, `COM1.log`, …), case-insensitively.
        let stem = out.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? out
        if windowsReservedStems.contains(stem.uppercased()) { out = "_" + out }
        if out.count > 120 {
            out = String(out.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { return fallback }
        }
        return out
    }

    /// Windows reserved device stems (compared case-insensitively against
    /// the name up to the first `.`; `ensuringPDFExtension` appends `.pdf`
    /// after this check, so `CON` → `_CON.pdf`, which Windows accepts).
    static let windowsReservedStems: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// Keep an existing `.pdf` extension (any case), else append one.
    public static func ensuringPDFExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        if ext.caseInsensitiveCompare("pdf") == .orderedSame { return name }
        if name.hasSuffix(".") { return name + "pdf" }
        return name + ".pdf"
    }

    // MARK: - Reference warnings

    /// Resolve every saved reference path against the source file's folder;
    /// each unresolvable one becomes a warning (rendering proceeds without
    /// it). Pure: unit-testable without fixtures.
    public static func unresolvedReferenceWarnings(
        xrefPaths: [String] = [],
        imagePaths: [String] = [],
        pdfPaths: [String] = [],
        hostFolder: String,
        sourceName: String
    ) -> [String] {
        var warnings: [String] = []
        func check(_ savedPath: String, kind: String) {
            let trimmed = savedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let found = XrefPathResolver.resolve(
                savedPath: trimmed,
                immediateHostFolder: hostFolder,
                documentFolder: hostFolder)
            if found == nil {
                warnings.append(
                    "Unresolved \(kind) reference in \(sourceName): '\(trimmed)'; sheet renders without it.")
            }
        }
        for path in xrefPaths { check(path, kind: "xref") }
        for path in imagePaths { check(path, kind: "image") }
        for path in pdfPaths { check(path, kind: "PDF underlay") }
        return warnings
    }

    // MARK: - Default disk loader (one file, via the shared factory)

    /// Load one source file into per-tab snapshots. DXF/DWT import through
    /// `DrawingViewFactory` (the same funnel as `TabManager.openTab`); DWG
    /// converts via ODA first; EAB reads views directly. Errors reuse
    /// `DXFPlotSettingsImport.ImportError` so PUBLISH, `-PSETUPIN`, and the
    /// inspector report identical missing-file / converter-missing /
    /// unsupported-format messages.
    public static func defaultFileLoader(path: String) throws -> PublishLoadedFile {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DXFPlotSettingsImport.ImportError.missingFile(path)
        }
        let hostFolder = url.deletingLastPathComponent().path
        switch url.pathExtension.lowercased() {
        case "dxf", "dwt":
            let imported = try DXFImporter.importDXFViews(filePath: url.path)
            let views = DrawingViewFactory.makeDrawingViews(
                from: imported, sourceFileName: url.lastPathComponent)
            return PublishLoadedFile(
                snapshots: snapshotsByTabName(views),
                warnings: unresolvedReferenceWarnings(
                    xrefPaths: imported.pendingXrefs.map(\.savedPath),
                    imagePaths: imported.imageDefinitions.map(\.savedPath),
                    pdfPaths: imported.pdfDefinitions.map(\.savedPath),
                    hostFolder: hostFolder,
                    sourceName: url.lastPathComponent))
        case "dwg":
            guard ODADWGConverter.isAvailable else {
                throw DXFPlotSettingsImport.ImportError.noConverter("no ODA converter found")
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("publish-run-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try ODADWGConverter.convertSync(input: url, output: tmp, toFormat: "DXF")
            let imported = try DXFImporter.importDXFViews(filePath: tmp.path)
            let views = DrawingViewFactory.makeDrawingViews(
                from: imported, sourceFileName: url.lastPathComponent)
            return PublishLoadedFile(
                snapshots: snapshotsByTabName(views),
                warnings: unresolvedReferenceWarnings(
                    xrefPaths: imported.pendingXrefs.map(\.savedPath),
                    imagePaths: imported.imageDefinitions.map(\.savedPath),
                    pdfPaths: imported.pdfDefinitions.map(\.savedPath),
                    hostFolder: hostFolder,
                    sourceName: url.lastPathComponent))
        case "eab":
            let views = try EABReader.readViews(from: url)
            var imagePaths: [String] = []
            var pdfPaths: [String] = []
            for view in views {
                imagePaths.append(contentsOf: view.document.imageDefinitions.values.map(\.savedPath))
                pdfPaths.append(contentsOf: view.document.pdfDefinitions.values.map(\.savedPath))
            }
            return PublishLoadedFile(
                snapshots: snapshotsByTabName(views),
                warnings: unresolvedReferenceWarnings(
                    imagePaths: imagePaths,
                    pdfPaths: pdfPaths,
                    hostFolder: hostFolder,
                    sourceName: url.lastPathComponent))
        default:
            let ext = url.pathExtension
            throw DXFPlotSettingsImport.ImportError.unsupportedFormat(
                ext.isEmpty ? "(none)" : ".\(ext)")
        }
    }

    /// Snapshot every view document keyed by view name (first wins on
    /// pathological case-variant duplicates).
    public static func snapshotsByTabName(_ views: [DrawingView]) -> [String: CADDocumentSnapshot] {
        Dictionary(
            views.map { ($0.name, $0.document.snapshot()) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Case-insensitive tab lookup.
    public static func snapshot(
        forTab tabName: String,
        in snapshots: [String: CADDocumentSnapshot]
    ) -> CADDocumentSnapshot? {
        for (name, snapshot) in snapshots {
            if name.caseInsensitiveCompare(tabName) == .orderedSame { return snapshot }
        }
        return nil
    }

    // MARK: - Output targets

    /// Directory for job outputs: the spec's explicit folder, else the
    /// first sheet source's folder, else the temp directory. Created.
    public static func resolveOutputDirectory(
        spec: PublishJobSpec
    ) throws -> URL {
        let trimmed = spec.outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
            return url
        }
        for sheet in spec.sheets {
            let path = sheet.sourceDwgPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return URL(fileURLWithPath: path).deletingLastPathComponent()
            }
        }
        return FileManager.default.temporaryDirectory
    }

    /// Single target for a multi-sheet file. Prompt naming consumes the
    /// explicit (prompt-picked) name and throws without one; auto naming
    /// uses the explicit name when given, else `<first drawing base>.pdf`.
    /// An absolute proposed path is honored as-is; a relative one joins
    /// the output directory (parents created).
    public static func resolveMultiSheetTarget(
        spec: PublishJobSpec,
        directory: URL
    ) throws -> URL {
        let proposed: String
        if let picked = spec.targetFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !picked.isEmpty {
            proposed = picked
        } else if spec.namingPolicy == .promptForName {
            throw PublishExecutionError.missingOutputName(
                "Naming is 'Prompt for name' but no file name was chosen; the job cannot start.")
        } else {
            let first = spec.sheets.first
            let base = PublishSheetStore.drawingBaseName(
                sourcePath: first?.sourceDwgPath ?? "",
                displayName: first?.sheetName ?? "Publish")
            proposed = ensuringPDFExtension(sanitizedFileName(base, fallback: "Publish"))
            return directory.appendingPathComponent(proposed, isDirectory: false)
        }
        let ns = proposed as NSString
        let file = ensuringPDFExtension(sanitizedFileName(
            ns.lastPathComponent, fallback: "Publish"))
        let dirPart = ns.deletingLastPathComponent
        if (proposed as NSString).isAbsolutePath {
            let parent = dirPart.isEmpty ? directory.path : dirPart
            let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
            try FileManager.default.createDirectory(
                at: parentURL, withIntermediateDirectories: true)
            return parentURL.appendingPathComponent(file, isDirectory: false)
        }
        var target = directory
        if !dirPart.isEmpty && dirPart != "." {
            target = target.appendingPathComponent(dirPart, isDirectory: true)
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true)
        }
        return target.appendingPathComponent(file, isDirectory: false)
    }

    /// Per-sheet targets for single-sheet files (`<SheetName>.pdf`,
    /// sanitized, deduped case-insensitively within the job).
    public static func resolveSingleSheetTargets(
        sheets: [PublishSheetEntry],
        directory: URL
    ) -> [URL] {
        var used = Set<String>()
        return sheets.map { sheet in
            var base = sanitizedFileName(sheet.sheetName)
            var candidate = ensuringPDFExtension(base)
            var n = 2
            while used.contains(candidate.lowercased()) {
                base = sanitizedFileName(sheet.sheetName) + " (\(n))"
                candidate = ensuringPDFExtension(base)
                n += 1
            }
            used.insert(candidate.lowercased())
            return directory.appendingPathComponent(candidate, isDirectory: false)
        }
    }

    // MARK: - Atomic write (Windows-safe remove-then-move fallback)

    static func atomicWrite(data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
#if os(Windows)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
#else
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
#endif
    }

    // MARK: - Page rendering (restored copies, resolved setup injected)

    /// Restore one snapshot into a throwaway document, inject the row's
    /// resolved setup there, and render a single-page PDF. The source
    /// drawing is never touched.
    static func renderSingleSheetPDF(
        snapshot: CADDocumentSnapshot,
        settings: CADPlotSettings,
        backgroundColor: ColorRGBA? = .white,
        plotContext: PDFExporter.PlotContext = .default
    ) throws -> Data {
        try Task.checkCancellation()
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)
        tempDoc.plotSettings = settings
        tempDoc.layoutSettings = settings.layoutSettings
        return try PDFExporter.generatePDF(
            document: tempDoc, backgroundColor: backgroundColor,
            plotContext: plotContext)
    }

    static func multiPageSource(
        snapshot: CADDocumentSnapshot,
        settings: CADPlotSettings
    ) -> PDFExporter.PDFMultiPageSource {
        PDFExporter.PDFMultiPageSource(
            snapshot: snapshot, plotSettings: settings,
            backgroundColor: .white)
    }

    // MARK: - Job run

    /// Publish every row of `spec` to PDF.
    ///
    /// - `openDrawings`: live-tab snapshots by `PublishSheetEntry.drawingID`
    ///   (tab name → snapshot). Entries found here never touch disk.
    /// - `fileLoader`: disk funnel (defaults to `defaultFileLoader`);
    ///   each distinct source path loads at most once per job.
    /// - `progress`: `(finished, total)` after each sheet resolves.
    /// - `onFileWritten`: called after each file lands on disk (observability).
    /// - `viewerOpener`: called once per written file when
    ///   `spec.openInViewerWhenDone`.
    ///
    /// Throws `PublishExecutionError` for an empty sheet list or prompt
    /// naming without a chosen name, `CancellationError` on cancellation
    /// (anything already written is removed first), and the underlying
    /// I/O error when a write fails (same cleanup).
    public static func run(
        spec: PublishJobSpec,
        openDrawings: [UUID: [String: CADDocumentSnapshot]] = [:],
        fileLoader: PublishFileLoader? = nil,
        plotContext: PDFExporter.PlotContext = .default,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        onFileWritten: (@Sendable (URL) -> Void)? = nil,
        viewerOpener: (@Sendable (URL) -> Void)? = nil
    ) async throws -> PublishJobReport {
        guard !spec.sheets.isEmpty else { throw PublishExecutionError.noSheets }
        try Task.checkCancellation()
        let loader = fileLoader ?? defaultFileLoader
        let directory = try resolveOutputDirectory(spec: spec)

        // ---- Load: one file read per distinct source path. ----
        var loadedByKey: [String: PublishLoadedFile] = [:]
        var loadFailures: [String: Error] = [:]
        func cacheKey(for path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        }
        var warnings: [String] = []
        var warned = Set<String>()
        func appendWarnings(_ fresh: [String]) {
            for warning in fresh where warned.insert(warning).inserted {
                warnings.append(warning)
            }
        }

        // ---- Resolve every row to a renderable page (or an error). ----
        struct ReadyPage {
            var entry: PublishSheetEntry
            var snapshot: CADDocumentSnapshot
            var settings: CADPlotSettings
        }
        var ready: [ReadyPage] = []
        var reports: [PublishSheetReport] = []
        reports.reserveCapacity(spec.sheets.count)

        for (index, entry) in spec.sheets.enumerated() {
            try Task.checkCancellation()
            func fail(_ message: String, status: PublishSheetStatus = .error) {
                reports.append(PublishSheetReport(
                    id: entry.id, sheetName: entry.sheetName,
                    status: status, message: message))
                progress?(index + 1, spec.sheets.count)
            }
            // Source snapshots: open drawing first, else the once-per-job cache.
            let snapshots: [String: CADDocumentSnapshot]?
            if let open = openDrawings[entry.drawingID] {
                snapshots = open
            } else {
                let trimmed = entry.sourceDwgPath.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    fail("Cannot load '\(entry.sheetName)': the drawing was never saved and is not open.")
                    continue
                }
                let key = cacheKey(for: trimmed)
                if loadedByKey[key] == nil, loadFailures[key] == nil {
                    do {
                        loadedByKey[key] = try loader(trimmed)
                    } catch {
                        loadFailures[key] = error
                    }
                }
                if let failure = loadFailures[key] {
                    fail("Cannot load '\(trimmed)': \(failure.localizedDescription)")
                    continue
                }
                snapshots = loadedByKey[key]?.snapshots
                if let fresh = loadedByKey[key]?.warnings { appendWarnings(fresh) }
            }
            guard let snapshot = snapshot(forTab: entry.tabName, in: snapshots ?? [:]) else {
                fail("Layout '\(entry.tabName)' not found in '\(entry.sourceDwgPath)'.")
                continue
            }
            guard let settings = entry.resolvedSetup else {
                if spec.publishTo == .plotterNamedInPageSetup {
                    fail("No page setup assigned to '\(entry.sheetName)'; pick a setup or import one from the Master drawing.")
                } else {
                    fail("No page setup assigned to '\(entry.sheetName)'; the PDF preset will be used.",
                         status: .warning)
                }
                continue
            }
            guard settings.paperWidthMM > 0, settings.paperHeightMM > 0,
                  settings.paperWidthMM.isFinite, settings.paperHeightMM.isFinite else {
                fail("Invalid paper size (\(settings.paperWidthMM) x \(settings.paperHeightMM) mm) for '\(entry.sheetName)'.")
                continue
            }
            ready.append(ReadyPage(entry: entry, snapshot: snapshot, settings: settings))
            progress?(index + 1, spec.sheets.count)
        }

        // ---- Render everything in memory before writing anything. ----
        var written: [URL] = []
        func cleanup(_ urls: [URL]) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        do {
            switch spec.fileType {
            case .multiSheetFile:
                let target = try resolveMultiSheetTarget(spec: spec, directory: directory)
                if ready.isEmpty {
                    // All-or-nothing: no valid pages means no file at all.
                    return PublishJobReport(sheets: reports, warnings: warnings)
                }
                var sources: [PDFExporter.PDFMultiPageSource] = []
                sources.reserveCapacity(ready.count)
                for page in ready {
                    try Task.checkCancellation()
                    sources.append(multiPageSource(
                        snapshot: page.snapshot, settings: page.settings))
                }
                try Task.checkCancellation()
                let data = try PDFExporter.generateMultiPagePDF(
                    sources: sources, plotContext: plotContext)
                try Task.checkCancellation()
                try atomicWrite(data: data, to: target)
                written.append(target)
                onFileWritten?(target)
                for page in ready {
                    reports.append(PublishSheetReport(
                        id: page.entry.id, sheetName: page.entry.sheetName,
                        status: .ready, message: "Published to \(target.lastPathComponent).",
                        outputURL: target))
                }
            case .singleSheetFiles:
                let targets = resolveSingleSheetTargets(
                    sheets: ready.map(\.entry), directory: directory)
                var payloads: [Data] = []
                payloads.reserveCapacity(ready.count)
                for page in ready {
                    payloads.append(try renderSingleSheetPDF(
                        snapshot: page.snapshot, settings: page.settings,
                        plotContext: plotContext))
                }
                try Task.checkCancellation()
                for (index, target) in targets.enumerated() {
                    try Task.checkCancellation()
                    try atomicWrite(data: payloads[index], to: target)
                    written.append(target)
                    onFileWritten?(target)
                }
                for (page, target) in zip(ready, targets) {
                    reports.append(PublishSheetReport(
                        id: page.entry.id, sheetName: page.entry.sheetName,
                        status: .ready, message: "Published to \(target.lastPathComponent).",
                        outputURL: target))
                }
            }
        } catch is CancellationError {
            cleanup(written)
            throw CancellationError()
        } catch {
            cleanup(written)
            throw error
        }
        progress?(spec.sheets.count, spec.sheets.count)

        // ---- Preserve spec order in the report. ----
        let order = Dictionary(
            uniqueKeysWithValues: spec.sheets.enumerated().map { ($1.id, $0) })
        reports.sort {
            (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max)
        }

        // ---- Open in viewer (best effort, after success). ----
        var opened: [URL] = []
        if spec.openInViewerWhenDone, let opener = viewerOpener {
            for url in written {
                opener(url)
                opened.append(url)
            }
        }
        return PublishJobReport(
            sheets: reports, outputURLs: written,
            warnings: warnings, openedURLs: opened)
    }
}
