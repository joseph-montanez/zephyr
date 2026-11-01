import Foundation

// =========================================================================
// MARK: - Plot CLI sessions (Phase 4 step 25)
//
// Command-line state machines for `-PAGESETUP`, `-PLOT`, and `-PSETUPIN`.
// All I/O flows through `PlotCliContext` so the flows are unit-testable
// without an engine: tests inject a bare `TabManager`, capture prints, and
// stub the save-file hoop.
//
// Conventions mirror the spec §5 prompt flows verbatim (including `?`
// listings and `*` wildcards for `-PSETUPIN`). DXF details (bit meanings,
// scale table, centering math) reuse `CADPlotSettings`,
// `PlotSettingsValidator`, and `PaperSheetGeometry`.
// =========================================================================

/// Host services for a CLI plot session (production: engine-backed).

@MainActor
public struct PlotCliContext {
    public var tabManager: TabManager
    public var printLine: (String) -> Void
    /// Suggested PDF name → picked URL (nil = cancelled).
    public var requestSavePDF: (String, @escaping @Sendable (URL?) -> Void) -> Void
    /// Registry snapshot: PAPERUPDATE, PLOTOFFSET, PLOTTRANSPARENCYOVERRIDE.
    public var paperUpdate: Int
    public var plotOffset: Int
    public var transparencyOverride: Int
    /// Called when the session ends (clears processor modal state).
    public var onFinish: () -> Void

    public init(tabManager: TabManager,
                printLine: @escaping (String) -> Void = { print($0) },
                requestSavePDF: @escaping (String, @escaping @Sendable (URL?) -> Void) -> Void = { _, completion in completion(nil) },
                paperUpdate: Int = 0,
                plotOffset: Int = 0,
                transparencyOverride: Int = 1,
                onFinish: @escaping () -> Void = {}) {
        self.tabManager = tabManager
        self.printLine = printLine
        self.requestSavePDF = requestSavePDF
        self.paperUpdate = paperUpdate
        self.plotOffset = plotOffset
        self.transparencyOverride = transparencyOverride
        self.onFinish = onFinish
    }
}

/// One modal CLI run. Created by `start(flow:ctx:)`, fed with `handle`.

@MainActor
public final class PlotCliSession {
    public enum Flow {
        case pageSetup
        case plot
        case psetupin
    }

    private let flow: Flow
    private var step: Int = 0
    // Shared working state.
    private var layoutName: String = ""
    private var draft = CADPlotSettings()
    private var detailed = false
    private var plotted = false
    // PSETUPIN state.
    private var pendingImports: [CADNamedPageSetup] = []
    private var conflictQueue: [CADNamedPageSetup] = []

    private init(flow: Flow) { self.flow = flow }

    // MARK: - Entry

    /// Start a session: seeds state from the active tab and prints the
    /// first prompt. Returns the prompt (also used as commandPrompt).
    @discardableResult
    public static func start(flow: Flow, ctx: PlotCliContext) -> PlotCliSession {
        let session = PlotCliSession(flow: flow)
        session.begin(ctx: ctx)
        return session
    }

    private func begin(ctx: PlotCliContext) {
        let manager = ctx.tabManager
        let current = manager.activeViewName ?? "Model"
        switch flow {
        case .pageSetup:
            layoutName = current
            ctx.printLine("Enter layout name or [?] <\(current)>:")
        case .plot:
            if let name = manager.activeTab.flatMap({ $0.drawingViews[$0.activeViewIndex] }).map({ $0.name }),
               let view = manager.activeTab?.drawingViews.first(where: { $0.name == name }) {
                layoutName = name
                draft = view.document.plotSettings ?? CADPlotSettings(
                    paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
            } else {
                layoutName = current
            }
            ctx.printLine("Detailed plot configuration? [Yes/No] <No>:")
        case .psetupin:
            ctx.printLine("Enter file name:")
        }
    }

    /// The prompt to display in the command line while modal.
    public func currentPrompt(ctx: PlotCliContext) -> String {
        switch flow {
        case .pageSetup:
            return step == 0
                ? "Enter layout name or [?] <\(layoutName)>:"
                : "Enter page setup name, [?] to list, or . for none:"
        case .plot:
            return PlotCliPrompts.prompt(step: step, layoutName: layoutName, draft: draft)
        case .psetupin:
            if !conflictQueue.isEmpty {
                return "Setup '\(conflictQueue[0].name)' already exists. Redefine? [Yes/No] <N>:"
            }
            return step == 0 ? "Enter file name:" : "Enter user defined page setup to import or [?]:"
        }
    }

    // MARK: - Input

    public func handle(_ text: String, ctx: PlotCliContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch flow {
        case .pageSetup: handlePageSetup(trimmed, ctx: ctx)
        case .plot: handlePlot(trimmed, ctx: ctx)
        case .psetupin: handlePSetupIn(trimmed, ctx: ctx)
        }
    }

    private func finish(ctx: PlotCliContext) {
        ctx.onFinish()
    }

    // MARK: - -PAGESETUP

    private func handlePageSetup(_ text: String, ctx: PlotCliContext) {
        let manager = ctx.tabManager
        if step == 0 {
            if text == "?" {
                let names = manager.activeTab?.drawingViews.map(\.name) ?? []
                ctx.printLine(names.joined(separator: ", "))
                ctx.printLine("Enter layout name or [?]:")
                return
            }
            let name = text.isEmpty ? layoutName : text
            guard let view = manager.activeTab?.drawingViews.first(where: {
                $0.kind == .sheet && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                ctx.printLine("Unknown sheet layout '\(name)'.")
                ctx.printLine("Enter layout name or [?]:")
                return
            }
            layoutName = view.name
            let current = view.document.plotSettings?.pageSetupName ?? ""
            step = 1
            ctx.printLine("Enter page setup name, [?] to list, or . for none <\(current.isEmpty ? "None" : current)>:")
            return
        }
        // step 1: setup choice
        if text == "?" {
            let names = manager.activeTab?.namedPageSetups.map(\.name) ?? []
            ctx.printLine(names.isEmpty ? "(no named page setups)" : names.joined(separator: ", "))
            ctx.printLine("Enter page setup name, [?] to list, or . for none:")
            return
        }
        if text.isEmpty || text == "." || text.caseInsensitiveCompare("None") == .orderedSame {
            // Clear the association directly (commitPlotSettings preserves
            // Code 1 by design; <None> explicitly empties it).
            if let tab = manager.activeTab,
               let index = tab.drawingViews.firstIndex(where: {
                   $0.kind == .sheet && $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
               }) {
                let doc = tab.drawingViews[index].document
                doc.undoManager.pushUndo(doc.snapshot())
                doc.plotSettings?.pageSetupName = ""
                doc.markEdited()
                ctx.printLine("Layout '\(layoutName)' set to <None>.")
            }
            finish(ctx: ctx)
            return
        }
        if manager.applyNamedSetupToLayout(text, layoutName: layoutName) {
            ctx.printLine("Applied '\(text)' to \(layoutName).")
            finish(ctx: ctx)
        } else {
            ctx.printLine("Unknown page setup '\(text)'.")
            ctx.printLine("Enter page setup name, [?] to list, or . for none:")
        }
    }

    // MARK: - -PLOT (19-step state machine, spec §5)

    private func handlePlot(_ text: String, ctx: PlotCliContext) {
        let manager = ctx.tabManager
        let up = text.uppercased()
        func yes(_ s: String, def: Bool) -> Bool? {
            if s.isEmpty { return def }
            if s == "Y" || s == "YES" { return true }
            if s == "N" || s == "NO" { return false }
            return nil
        }
        switch step {
        case 0: // Detailed plot configuration?
            guard let detailed = yes(up, def: false) else {
                ctx.printLine("Detailed plot configuration? [Yes/No] <No>:")
                return
            }
            self.detailed = detailed
            if detailed {
                step = 1
                ctx.printLine("Enter a layout name or [?] <\(layoutName)>:")
            } else {
                step = 16 // jump to write-to-file
                ctx.printLine("Write the plot to a file [Yes/No] <N>:")
            }
        case 1: // layout
            if up == "?" {
                let names = manager.activeTab?.drawingViews.map(\.name) ?? []
                ctx.printLine(names.joined(separator: ", "))
                ctx.printLine("Enter a layout name or [?] <\(layoutName)>:")
                return
            }
            let name = text.isEmpty ? layoutName : text
            guard let view = manager.activeTab?.drawingViews.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                ctx.printLine("Unknown layout '\(name)'.")
                ctx.printLine("Enter a layout name or [?] <\(layoutName)>:")
                return
            }
            layoutName = view.name
            draft = view.document.plotSettings ?? draft
            step = 2
            let cur = draft.plotConfigName.isEmpty ? "None" : draft.plotConfigName
            ctx.printLine("Enter an output device name or [?] <\(cur)>:")
        case 2: // device
            if up == "?" {
                ctx.printLine(PlotDeviceCatalog.builtins.map(\.name).joined(separator: ", "))
                ctx.printLine("Enter an output device name or [?]:")
                return
            }
            if !text.isEmpty {
                let result = PlotSettingsValidator.applyDeviceChange(
                    settings: draft, newDeviceName: text, paperUpdate: ctx.paperUpdate)
                draft = result.settings
                if let warning = result.warning { ctx.printLine(warning) }
            }
            step = 3
            let cur = draft.canonicalMediaName.isEmpty
                ? "None" : PlotDeviceCatalog.displayName(forCanonical: draft.canonicalMediaName)
            ctx.printLine("Enter paper size or [?] <\(cur)>:")
        case 3: // paper size
            if up == "?" {
                let device = PlotDeviceCatalog.device(named: draft.plotConfigName)
                let media = device?.media ?? []
                ctx.printLine(media.isEmpty
                    ? "(no media list for this device — type a canonical media name)"
                    : media.map(\.displayName).joined(separator: ", "))
                ctx.printLine("Enter paper size or [?]:")
                return
            }
            if !text.isEmpty {
                let device = PlotDeviceCatalog.device(named: draft.plotConfigName)
                let match = device?.media.first(where: {
                    $0.canonicalName.caseInsensitiveCompare(text) == .orderedSame
                        || $0.displayName.caseInsensitiveCompare(text) == .orderedSame
                })
                if let match {
                    draft = PlotSettingsValidator.applyPaperSize(settings: draft, media: match)
                } else {
                    // Accept raw canonical names (custom media round-trips).
                    draft.canonicalMediaName = text
                    draft.paperName = text
                    ctx.printLine("Note: '\(text)' is not in the device media list; kept as custom.")
                }
            }
            step = 4
            let cur = draft.plotPaperUnits == 0 ? "Inches" : "Millimeters"
            ctx.printLine("Enter paper units [Inches/Millimeters] <\(cur)>:")
        case 4: // paper units
            if !up.isEmpty {
                if up == "INCHES" || up == "IN" { draft.plotPaperUnits = 0 }
                else if up.hasPrefix("MILLI") || up == "MM" { draft.plotPaperUnits = 1 }
                else {
                    ctx.printLine("Enter paper units [Inches/Millimeters]:")
                    return
                }
            }
            step = 5
            let cur = (draft.plotRotation == 1 || draft.plotRotation == 3) ? "Landscape" : "Portrait"
            ctx.printLine("Enter drawing orientation [Portrait/Landscape] <\(cur)>:")
        case 5: // orientation
            if !up.isEmpty {
                let upside = draft.plotRotation >= 2
                if up.hasPrefix("PORTRAIT") || up == "P" {
                    draft.plotRotation = upside ? 2 : 0
                } else if up.hasPrefix("LANDSCAPE") || up == "L" {
                    draft.plotRotation = upside ? 3 : 1
                } else {
                    ctx.printLine("Enter drawing orientation [Portrait/Landscape]:")
                    return
                }
            }
            step = 6
            ctx.printLine("Plot upside down? [Yes/No] <No>:")
        case 6: // upside down
            guard let upside = yes(up, def: false) else {
                ctx.printLine("Plot upside down? [Yes/No] <No>:")
                return
            }
            let landscape = draft.plotRotation == 1 || draft.plotRotation == 3
            draft.plotRotation = landscape ? (upside ? 3 : 1) : (upside ? 2 : 0)
            step = 7
            ctx.printLine("Enter plot area [Display/Extents/Layout/View/Window] <Layout>:")
        case 7: // plot area
            if !up.isEmpty {
                let types = ["DISPLAY": 0, "EXTENTS": 1, "LIMITS": 2, "VIEW": 3, "WINDOW": 4, "LAYOUT": 5]
                guard let t = types[up] else {
                    ctx.printLine("Enter plot area [Display/Extents/Layout/View/Window]:")
                    return
                }
                draft.plotType = t
                draft = PlotSettingsValidator.enforcePlotTypeRules(settings: draft)
            }
            step = 8
            let scaleDef = PlotCliPrompts.scaleDefault(draft: draft)
            ctx.printLine("Enter plot scale (Plotted Millimeters=Drawing Units) or [Fit] <" + scaleDef + ">:")
        case 8: // scale
            if up == "FIT" {
                draft.standardScaleType = 0
                draft.useStandardScale = false
            } else if !text.isEmpty {
                if let parsed = PlotCliPrompts.parseScale(text) {
                    draft.standardScaleType = parsed.type
                    draft.useStandardScale = parsed.useStandard
                    if !parsed.useStandard {
                        draft.customScaleNumerator = parsed.num
                        draft.customScaleDenominator = parsed.den
                    }
                } else {
                    ctx.printLine("Enter plot scale (Plotted Millimeters=Drawing Units) or [Fit]:")
                    return
                }
            }
            step = 9
            let offDef = PlotCliPrompts.offsetDefault(draft: draft)
            ctx.printLine("Enter plot offset (x,y) or [Center] <" + offDef + ">:")
        case 9: // offset
            if up == "CENTER" {
                draft.plotFlags |= 4
                recenterDraft(ctx: ctx)
            } else if !text.isEmpty {
                let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                    ctx.printLine("Enter plot offset (x,y) or [Center]:")
                    return
                }
                // Prompt units follow the paper units; storage is mm.
                let toMM = draft.plotPaperUnits == 0 ? 25.4 : 1.0
                draft.plotOriginXMM = x * toMM
                draft.plotOriginYMM = y * toMM
                draft.plotFlags &= ~4
            }
            step = 10
            ctx.printLine("Plot with plot styles? [Yes/No] <Yes>:")
        case 10: // plot styles
            guard let on = yes(up, def: true) else {
                ctx.printLine("Plot with plot styles? [Yes/No] <Yes>:")
                return
            }
            draft = PlotSettingsValidator.applyingPlotStylesToggled(settings: draft, on: on)
            step = 11
            ctx.printLine("Enter plot style table name or [?] (enter . for none) <\(draft.styleSheet.isEmpty ? "None" : draft.styleSheet)>:")
        case 11: // style table
            if up == "?" {
                ctx.printLine(PlotCliPrompts.styleTableOptions().joined(separator: ", "))
                ctx.printLine("Enter plot style table name or [?] (enter . for none):")
                return
            }
            if text == "." { draft.styleSheet = "" }
            else if !text.isEmpty { draft.styleSheet = text }
            step = 12
            ctx.printLine("Plot with lineweights? [Yes/No] <Yes>:")
        case 12: // lineweights
            guard let on = yes(up, def: true) else {
                ctx.printLine("Plot with lineweights? [Yes/No] <Yes>:")
                return
            }
            if on { draft.plotFlags |= 128 } else { draft.plotFlags &= ~128 }
            step = 13
            ctx.printLine("Scale lineweights with plot scale? [Yes/No] <No>:")
        case 13: // scale lineweights
            guard let on = yes(up, def: false) else {
                ctx.printLine("Scale lineweights with plot scale? [Yes/No] <No>:")
                return
            }
            if on { draft.plotFlags |= 64 } else { draft.plotFlags &= ~64 }
            step = 14
            ctx.printLine("Plot paper space first? [Yes/No] <No>:")
        case 14: // paperspace first (= NOT draw-viewports-first)
            guard let first = yes(up, def: false) else {
                ctx.printLine("Plot paper space first? [Yes/No] <No>:")
                return
            }
            if first { draft.plotFlags &= ~512 } else { draft.plotFlags |= 512 }
            step = 15
            ctx.printLine("Hide paperspace objects? [Yes/No] <No>:")
        case 15: // hide paperspace
            guard let hide = yes(up, def: false) else {
                ctx.printLine("Hide paperspace objects? [Yes/No] <No>:")
                return
            }
            if hide { draft.plotFlags |= 8 } else { draft.plotFlags &= ~8 }
            step = 16
            ctx.printLine("Write the plot to a file [Yes/No] <N>:")
        case 16: // write to file
            guard let toFile = yes(up, def: false) else {
                ctx.printLine("Write the plot to a file [Yes/No] <N>:")
                return
            }
            if toFile {
                writePlotToFile(ctx: ctx) { [weak self] in
                    self?.plotted = true
                    self?.step = 17
                    if let self { ctx.printLine("Save changes to page setup [Yes/No]? <N>") }
                }
                return // async continuation re-prompts
            }
            step = 17
            ctx.printLine("Save changes to page setup [Yes/No]? <N>")
        case 17: // save changes
            guard let save = yes(up, def: false) else {
                ctx.printLine("Save changes to page setup [Yes/No]? <N>")
                return
            }
            if save {
                if commitPlotSettings(manager: ctx.tabManager, layoutName: layoutName, settings: draft) {
                    ctx.printLine("Page setup saved.")
                } else {
                    ctx.printLine("Could not save page setup.")
                }
            }
            step = 18
            ctx.printLine("Proceed with plot [Yes/No] <Y>:")
        case 18: // proceed
            guard let go = yes(up, def: true) else {
                ctx.printLine("Proceed with plot [Yes/No] <Y>:")
                return
            }
            if go, !plotted {
                writePlotToFile(ctx: ctx) { [weak self] in
                    if let self { self.finish(ctx: ctx) }
                }
                return
            }
            finish(ctx: ctx)
        default:
            finish(ctx: ctx)
        }
    }

    private func recenterDraft(ctx: PlotCliContext) {
        guard let printable = PaperSheetGeometry.overlayRects(for: draft)?.printable else { return }
        let pw = printable.maxX - printable.minX
        let ph = printable.maxY - printable.minY
        let area: (w: Double, h: Double)
        if let doc = ctx.tabManager.activeTab?.drawingViews.first(where: {
            $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
        })?.document, draft.plotType == 1, // Extents
           let bb = doc.renderableWorldBoundingBox() {
            area = (bb.max.x - bb.min.x, bb.max.y - bb.min.y)
        } else if let rect = PaperSheetGeometry.staticPlotAreaRect(for: draft) {
            area = (rect.maxX - rect.minX, rect.maxY - rect.minY)
        } else {
            area = (pw, ph)
        }
        let s = draft.effectiveScaleFactor.isFinite ? draft.effectiveScaleFactor : 1
        let m = PaperSheetGeometry.permutedMargins(for: draft)
        let off = PlotSettingsValidator.centeredOffset(
            printableWidth: pw, printableHeight: ph,
            plotAreaWidth: area.w, plotAreaHeight: area.h,
            scale: s, plotOffset: ctx.plotOffset,
            marginLeft: m.left, marginBottom: m.bottom)
        let div = PaperSheetGeometry.unitDivisor(for: draft)
        draft.plotOriginXMM = off.x * div
        draft.plotOriginYMM = off.y * div
    }

    /// Continuation for the async save-file hoop. `@unchecked Sendable` so
    /// the `@Sendable` file-dialog completion can carry MainActor-bound
    /// session state across; everything runs back on the main actor.
    private final class PlotFileContinuation: @unchecked Sendable {
        weak var session: PlotCliSession?
        var draft: CADPlotSettings
        let layoutName: String
        let snapshot: CADDocumentSnapshot
        let ctx: PlotCliContext
        let then: () -> Void

        init(session: PlotCliSession?, draft: CADPlotSettings, layoutName: String,
             snapshot: CADDocumentSnapshot, ctx: PlotCliContext, then: @escaping () -> Void) {
            self.session = session
            self.draft = draft
            self.layoutName = layoutName
            self.snapshot = snapshot
            self.ctx = ctx
            self.then = then
        }
    }

    private func writePlotToFile(ctx: PlotCliContext, then: @escaping () -> Void) {
        guard let doc = ctx.tabManager.activeTab?.drawingViews.first(where: {
            $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
        })?.document else {
            ctx.printLine("Layout '\(layoutName)' no longer exists.")
            then()
            return
        }
        // Plot with the draft (unsaved) settings via a snapshot copy.
        let box = PlotFileContinuation(
            session: self, draft: draft, layoutName: layoutName,
            snapshot: doc.snapshot(), ctx: ctx, then: then)
        ctx.requestSavePDF("\(layoutName).pdf") { [box] url in
            MainActor.assumeIsolated {
                box.session?.finishPlotToFile(url: url, box: box)
            }
        }
    }

    private func finishPlotToFile(url: URL?, box: PlotFileContinuation) {
        guard let url else {
            box.ctx.printLine("Plot cancelled.")
            box.then()
            return
        }
        let tempDoc = CADDocument()
        tempDoc.restore(from: box.snapshot)
        tempDoc.plotSettings = box.draft
        tempDoc.layoutSettings = box.draft.layoutSettings
        let context = PDFExporter.PlotContext(
            transparencyOverride: box.ctx.transparencyOverride,
            plotOffset: box.ctx.plotOffset,
            plotTableLoader: PDFExporter.defaultPlotTableLoader)
        do {
            let data = try PDFExporter.generatePDF(
                document: tempDoc, backgroundColor: .white, plotContext: context)
            try data.write(to: url, options: .atomic)
            box.ctx.tabManager.recordLastPlotSettings(box.draft)
            box.ctx.printLine("Plotted to \(url.path).")
        } catch {
            box.ctx.printLine("Plot failed: \(error).")
        }
        box.then()
    }

    // MARK: - -PSETUPIN

    private func handlePSetupIn(_ text: String, ctx: PlotCliContext) {
        if !conflictQueue.isEmpty {
            let pending = conflictQueue[0]
            let up = text.uppercased()
            if up == "Y" || up == "YES" {
                ctx.tabManager.updateNamedSetup(name: pending.name, with: pending.settings)
                ctx.printLine("Redefined '\(pending.name)'.")
                conflictQueue.removeFirst()
            } else if up.isEmpty || up == "N" || up == "NO" {
                ctx.printLine("Skipped '\(pending.name)'.")
                conflictQueue.removeFirst()
            } else {
                ctx.printLine("Setup '\(pending.name)' already exists. Redefine? [Yes/No] <N>:")
                return
            }
            promptNextConflictOrFinish(ctx: ctx)
            return
        }
        if step == 0 {
            if text.isEmpty {
                ctx.printLine("Enter file name:")
                return
            }
            do {
                pendingImports = try DXFPlotSettingsImport.readNamedSetups(filePath: text)
            } catch {
                ctx.printLine("Cannot read page setups: \(error).")
                ctx.printLine("Enter file name:")
                return
            }
            if pendingImports.isEmpty {
                ctx.printLine("No named page setups in that file.")
                finish(ctx: ctx)
                return
            }
            step = 1
            ctx.printLine("Enter user defined page setup to import or [?]:")
            return
        }
        // step 1: name / ? / wildcards
        if text == "?" {
            ctx.printLine(pendingImports.map(\.name).joined(separator: ", "))
            ctx.printLine("Enter user defined page setup to import or [?]:")
            return
        }
        if text.isEmpty {
            finish(ctx: ctx)
            return
        }
        let matches = pendingImports.filter {
            PlotCliPrompts.wildcardMatch(pattern: text, name: $0.name)
        }
        if matches.isEmpty {
            ctx.printLine("No page setup matches '\(text)'.")
            ctx.printLine("Enter user defined page setup to import or [?]:")
            return
        }
        let existing = Set((ctx.tabManager.activeTab?.namedPageSetups ?? []).map { $0.name.uppercased() })
        var imported = 0
        for setup in matches {
            if existing.contains(setup.name.uppercased()) {
                conflictQueue.append(setup)
            } else if ctx.tabManager.createNamedSetup(
                name: setup.name, from: setup.settings, isModelType: setup.isModelType) {
                imported += 1
            } else {
                ctx.printLine("Skipped invalid setup '\(setup.name)'.")
            }
        }
        if imported > 0 {
            ctx.printLine("Imported \(imported) page setup(s).")
        }
        promptNextConflictOrFinish(ctx: ctx)
    }

    private func promptNextConflictOrFinish(ctx: PlotCliContext) {
        if let next = conflictQueue.first {
            ctx.printLine("Setup '\(next.name)' already exists. Redefine? [Yes/No] <N>:")
        } else {
            finish(ctx: ctx)
        }
    }
}

// MARK: - Prompt text, scale parsing, wildcards (pure, tested)


@MainActor
public enum PlotCliPrompts {
    public static func prompt(step: Int, layoutName: String, draft: CADPlotSettings) -> String {
        switch step {
        case 0: return "Detailed plot configuration? [Yes/No] <No>:"
        case 1: return "Enter a layout name or [?] <\(layoutName)>:"
        default: return "Enter a value:"
        }
    }

    public static func scaleDefault(draft: CADPlotSettings) -> String {
        if draft.standardScaleType == 0 { return "Fit" }
        if !draft.useStandardScale {
            return "\(fmtNum(draft.customScaleNumerator))=\(fmtNum(draft.customScaleDenominator))"
        }
        return PlotSettingsValidator.scaleLabel(for: draft.standardScaleType)
    }

    public static func offsetDefault(draft: CADPlotSettings) -> String {
        if draft.plotFlags & 4 != 0 { return "Center" }
        let div: Double = draft.plotPaperUnits == 0 ? 25.4 : 1.0
        return "\(fmtNum(draft.plotOriginXMM / div)),\(fmtNum(draft.plotOriginYMM / div))"
    }

    private static func fmtNum(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v)
    }

    /// Parsed scale: standard type, or custom numerator/denominator.
    public struct ParsedScale: Equatable {
        public var type: Int
        public var useStandard: Bool
        public var num: Double
        public var den: Double
    }

    /// Accepts `Fit`, `<num>=<den>`, or a standard label (`1:50`, `1"=1'`…).
    public static func parseScale(_ text: String) -> ParsedScale? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "FIT" {
            return ParsedScale(type: 0, useStandard: false, num: 1, den: 1)
        }
        if trimmed.contains("=") {
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let num = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let den = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  num > 0, den > 0, den.isFinite, num.isFinite else { return nil }
            return ParsedScale(type: 16, useStandard: false, num: num, den: den)
        }
        for t in 1...32 {
            if PlotSettingsValidator.scaleLabel(for: t).caseInsensitiveCompare(trimmed) == .orderedSame {
                return ParsedScale(type: t, useStandard: true, num: 1, den: 1)
            }
        }
        return nil
    }

    /// Parse a custom scale factor: `a:b` ratio, `a=b` ratio, or a number.
    public static func parseScaleFactor(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let a = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let b = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  a > 0, b > 0, a.isFinite, b.isFinite else { return nil }
            return a / b
        }
        if trimmed.contains("=") {
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let a = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let b = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  a > 0, b > 0, a.isFinite, b.isFinite else { return nil }
            return a / b
        }
        guard let v = Double(trimmed), v > 0, v.isFinite else { return nil }
        return v
    }

    /// Case-insensitive `*` (any run) / `?` (single char) wildcard match.
    public static func wildcardMatch(pattern: String, name: String) -> Bool {
        // Exact match (with or without wildcards present) always works.
        if pattern.caseInsensitiveCompare(name) == .orderedSame { return true }
        guard pattern.contains("*") || pattern.contains("?") else { return false }
        return matchGlob(Array(pattern.uppercased()), Array(name.uppercased()))
    }

    private static func matchGlob(_ pattern: [Character], _ name: [Character]) -> Bool {
        var pi = 0, ni = 0, star: Int? = nil, match = 0
        while ni < name.count {
            if pi < pattern.count && (pattern[pi] == "?" || pattern[pi] == name[ni]) {
                pi += 1; ni += 1
            } else if pi < pattern.count && pattern[pi] == "*" {
                star = pi; match = ni; pi += 1
            } else if let s = star {
                pi = s + 1; match += 1; ni = match
            } else {
                return false
            }
        }
        while pi < pattern.count && pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }

    /// Style-table choices for the `?` listing (dir may be absent → empty).
    public static func styleTableOptions() -> [String] {
        let fm = FileManager.default
        for dir in ["Plot Styles", "./Plot Styles"] {
            if let items = try? fm.contentsOfDirectory(atPath: dir) {
                let matches = items.filter {
                    let l = $0.lowercased()
                    return l.hasSuffix(".ctb") || l.hasSuffix(".stb")
                }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                if !matches.isEmpty { return matches }
            }
        }
        return []
    }
}

// MARK: - Lightweight named-setup reader (no full drawing import)


@MainActor
public enum DXFPlotSettingsImport {
    public enum ImportError: Error, LocalizedError {
        case missingFile(String)
        case unsupportedFormat(String)
        case noConverter(String)

        public var errorDescription: String? {
            switch self {
            case .missingFile(let p): return "File not found: \(p)"
            case .unsupportedFormat(let e): return "PSETUPIN needs .dxf/.dwt/.dwg (got \(e))."
            case .noConverter(let why): return "DWG conversion unavailable (\(why))."
            }
        }
    }

    /// Read only the `ACAD_PLOTSETTINGS` entries (plus per-layout Code-1
    /// associations left untouched) without importing drawing geometry.
    public static func readNamedSetups(filePath: String) throws -> [CADNamedPageSetup] {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.missingFile(filePath)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "dxf" || ext == "dwt" {
            let reader = try DXFReader().readFile(at: url.path)
            return reader.plotSettingsEntries.map {
                CADNamedPageSetup(name: $0.name, settings: $0.settings, isModelType: $0.isModelType)
            }
        }
        if ext == "dwg" {
            guard ODADWGConverter.isAvailable else {
                throw ImportError.noConverter("no ODA converter found")
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("psetupin-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try ODADWGConverter.convertSync(input: url, output: tmp, toFormat: "DXF")
            let reader = try DXFReader().readFile(at: tmp.path)
            return reader.plotSettingsEntries.map {
                CADNamedPageSetup(name: $0.name, settings: $0.settings, isModelType: $0.isModelType)
            }
        }
        throw ImportError.unsupportedFormat(ext.isEmpty ? "(none)" : ".\(ext)")
    }
}

// MARK: - Shared commit helper

/// Copy settings into a layout (one undoable document step).
@MainActor
@discardableResult
func commitPlotSettings(manager: TabManager, layoutName: String, settings: CADPlotSettings) -> Bool {
    guard let tab = manager.activeTab,
          let index = tab.drawingViews.firstIndex(where: {
              $0.kind == .sheet && $0.name.caseInsensitiveCompare(layoutName) == .orderedSame
          }) else { return false }
    var applied = settings
    applied.pageSetupName = tab.drawingViews[index].document.plotSettings?.pageSetupName ?? ""
    let doc = tab.drawingViews[index].document
    doc.undoManager.pushUndo(doc.snapshot())
    doc.plotSettings = applied
    doc.layoutSettings = applied.layoutSettings
    doc.unit = (applied.plotPaperUnits == 0) ? .inch : .millimeter
    doc.markEdited()
    manager.onActiveTabChanged?()
    return true
}
