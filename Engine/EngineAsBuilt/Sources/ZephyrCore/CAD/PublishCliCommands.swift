import Foundation

// =========================================================================
// MARK: - Publish CLI flows (Phase 6: `+PUBLISH` preloading, `-PUBLISH`)
// -------------------------------------------------------------------------
// `+PUBLISH [file.dsd]` opens the PUBLISH dialog, preloading the given
// sheet list when one is named (otherwise the dialog preloads the open
// drawings, as before). `-PUBLISH` is the command-line flow for scripts:
// it prompts for a sheet-list (`.dsd`) file, publishes every row in the
// foreground (no background task), and writes a per-sheet CSV log next
// to the `.dsd` (`PublishDSDLog`). All I/O flows through
// `PublishCliContext` so the prompt flow is unit-testable without an
// engine; the file format is the Zephyr-internal tolerant `.dsd` subset
// documented on `PublishDSD` (not AutoCAD grammar).
// =========================================================================

/// Pending dialog preload, set by `+PUBLISH <file.dsd>` and consumed on
/// the next PUBLISH dialog open (replace mode).
@MainActor
public enum PublishDialogPreload {
    public static var pendingDSDPath: String? = nil
}

/// Host services for a `-PUBLISH` CLI session (production: engine-backed).
@MainActor
public struct PublishCliContext {
    public var printLine: (String) -> Void
    /// Raw `.dsd` text for a path (default: read from disk).
    public var readTextFile: (String) throws -> String
    /// Drawing metadata for a source path, nil when missing/unreadable
    /// (rows still list from a stub record, as in the dialog).
    public var metadataProvider: (String) -> PublishDrawingMetadata?
    public var openDrawings: [UUID: [String: CADDocumentSnapshot]]
    public var fileLoader: PublishFileLoader?
    /// Foreground publish: runs to completion, then calls the completion
    /// (production hops through `PublishRunner.run` on a Task and writes
    /// the CSV log beside the `.dsd`).
    public var publish: (
        _ spec: PublishJobSpec,
        _ dsdPath: String,
        _ completion: @escaping @Sendable (PublishJobReport, URL?) -> Void
    ) -> Void
    /// Called when the session ends (clears processor modal state).
    public var onFinish: () -> Void

    public init(
        printLine: @escaping (String) -> Void = { print($0) },
        readTextFile: @escaping (String) throws -> String = {
            try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
        },
        metadataProvider: @escaping (String) -> PublishDrawingMetadata? = { _ in nil },
        openDrawings: [UUID: [String: CADDocumentSnapshot]] = [:],
        fileLoader: PublishFileLoader? = nil,
        publish: @escaping (
            PublishJobSpec, String, @escaping @Sendable (PublishJobReport, URL?) -> Void
        ) -> Void = { _, _, completion in completion(PublishJobReport(), nil) },
        onFinish: @escaping () -> Void = {}
    ) {
        self.printLine = printLine
        self.readTextFile = readTextFile
        self.metadataProvider = metadataProvider
        self.openDrawings = openDrawings
        self.fileLoader = fileLoader
        self.publish = publish
        self.onFinish = onFinish
    }
}

/// One modal `-PUBLISH` run. Created by `start(ctx:)`, fed with `handle`.
@MainActor
public final class PublishCliSession {
    private var step: Int = 0
    private var dsdPath: String = ""

    private init() {}

    // MARK: - Entry

    /// Start a session and print the first prompt (also the commandPrompt).
    @discardableResult
    public static func start(ctx: PublishCliContext) -> PublishCliSession {
        let session = PublishCliSession()
        ctx.printLine("Enter sheet list (.dsd) file name:")
        return session
    }

    /// The prompt to display in the command line while modal.
    public func currentPrompt(ctx _: PublishCliContext) -> String {
        step == 0 ? "Enter sheet list (.dsd) file name:" : "Publishing..."
    }

    // MARK: - Input

    public func handle(_ text: String, ctx: PublishCliContext) {
        guard step == 0 else { return } // publishing; completion ends us
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ctx.printLine("Enter sheet list (.dsd) file name:")
            return
        }
        let loaded: PublishDSDJob
        do {
            loaded = try PublishDSD.parse(try ctx.readTextFile(trimmed))
        } catch {
            ctx.printLine("Load failed: \(error.localizedDescription)")
            ctx.printLine("Enter sheet list (.dsd) file name:")
            return
        }
        let resolved = PublishCLIRun.resolveSpec(
            job: loaded, metadataProvider: ctx.metadataProvider)
        guard !resolved.spec.sheets.isEmpty else {
            ctx.printLine("No sheets in '\(trimmed)'.")
            ctx.printLine("Enter sheet list (.dsd) file name:")
            return
        }
        dsdPath = trimmed
        step = 1
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        ctx.printLine("Loaded \(resolved.spec.sheets.count) sheets from \(name)"
            + (resolved.unresolved == 0 ? "." : " (\(resolved.unresolved) assignment(s) no longer resolve)."))
        ctx.printLine("Publishing...")
        ctx.publish(resolved.spec, trimmed) { [weak self] report, logURL in
            MainActor.assumeIsolated {
                self?.finishPublish(report: report, logURL: logURL, ctx: ctx)
            }
        }
    }

    private func finishPublish(
        report: PublishJobReport, logURL: URL?, ctx: PublishCliContext
    ) {
        let ok = report.sheets.filter { $0.status == .ready }.count
        for sheet in report.sheets where sheet.status != .ready {
            ctx.printLine("\(sheet.sheetName): \(sheet.status.rawValue) — \(sheet.message)")
        }
        if report.outputURLs.isEmpty {
            ctx.printLine("No files written: every sheet failed (\(ok)/\(report.sheets.count) ready).")
        } else if report.outputURLs.count == 1, let first = report.outputURLs.first {
            ctx.printLine("Published \(ok)/\(report.sheets.count) sheets to \(first.path).")
        } else {
            ctx.printLine("Published \(ok)/\(report.sheets.count) sheets to \(report.outputURLs.count) files.")
        }
        if !report.warnings.isEmpty {
            ctx.printLine("\(report.warnings.count) warning(s).")
        }
        if let logURL {
            ctx.printLine("Log: \(logURL.path).")
        }
        ctx.onFinish()
    }

    private func finish(ctx: PublishCliContext) {
        ctx.onFinish()
    }
}

// MARK: - Foreground run (shared by the session, the processor, tests)

/// Script-facing `-PUBLISH` pipeline: load a `.dsd` sheet list, resolve
/// rows against drawing metadata, publish in the foreground, and write
/// the CSV log beside the `.dsd`.
@MainActor
public enum PublishCLIRun {
    /// Read + parse one sheet list (throws file-system or parse errors).
    public static func loadJob(
        atPath path: String,
        readFile: (String) throws -> String = {
            try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
        }
    ) throws -> PublishDSDJob {
        try PublishDSD.parse(try readFile(path))
    }

    /// Resolve a parsed job to a runnable spec (replace mode) plus the
    /// count of assignments that no longer resolve.
    public static func resolveSpec(
        job: PublishDSDJob,
        metadataProvider: (String) -> PublishDrawingMetadata?
    ) -> (spec: PublishJobSpec, unresolved: Int) {
        var store = PublishSheetStore()
        let unresolved = store.applyDSDJob(
            job, mode: .replace, metadataProvider: metadataProvider)
        let spec = PublishJobSpec(
            publishTo: job.publishTo,
            outputDirectory: job.outputDirectory,
            fileType: job.fileType,
            namingPolicy: job.namingPolicy,
            targetFileName: job.targetFileName,
            includeLayerInfo: job.includeLayerInfo,
            mergeControl: job.mergeControl,
            numberOfCopies: job.numberOfCopies,
            includePlotStamp: job.includePlotStamp,
            publishInBackground: false,
            openInViewerWhenDone: job.openInViewerWhenDone,
            sheets: store.sheets)
        return (spec, unresolved)
    }

    /// Full foreground run: load, resolve, publish, log. Returns the job
    /// report and the written log URL. Throws on load/parse errors, an
    /// empty sheet list, or prompt naming without a chosen name (same as
    /// `PublishRunner.run`); per-sheet failures stay in the report.
    @discardableResult
    public static func runForeground(
        dsdPath: String,
        openDrawings: [UUID: [String: CADDocumentSnapshot]] = [:],
        fileLoader: PublishFileLoader? = nil,
        plotContext: PDFExporter.PlotContext = .default,
        readFile: (String) throws -> String = {
            try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
        },
        metadataProvider: (String) -> PublishDrawingMetadata? = { _ in nil }
    ) async throws -> (report: PublishJobReport, logURL: URL) {
        let job = try loadJob(atPath: dsdPath, readFile: readFile)
        let resolved = resolveSpec(job: job, metadataProvider: metadataProvider)
        let report = try await PublishRunner.run(
            spec: resolved.spec, openDrawings: openDrawings,
            fileLoader: fileLoader, plotContext: plotContext)
        let logURL = try PublishDSDLog.write(
            report: report, spec: resolved.spec, besideDSDPath: dsdPath)
        return (report, logURL)
    }
}
