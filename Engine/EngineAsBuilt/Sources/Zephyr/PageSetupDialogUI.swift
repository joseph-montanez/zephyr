import ZephyrCore
import Foundation
import ImGui

/// Page Setup dialog (`Page Setup - <Layout Name>`): ten control groups,
/// live Partial Preview, and the conditional PDF Options sub-dialog.
/// Edits a draft; OK commits (layout → one undoable document step;
/// named setup → `updateNamedSetup` with bound-layout propagation),
/// Cancel discards.
@MainActor
struct PageSetupDialogUI {
    private static var draftKey: String = ""
    private static var draft = CADPlotSettings()
    private static var draftIsSetup = false
    private static var draftName = ""
    private static var message = ""
    private static var pdfOpen = false
    private static var pdfDraft = PDFOptions()
    private static var styleFiles: [String] = []

    /// Shared draft access for the PLOT dialog (step 22): points the same
    /// draft at a layout or named setup, then `renderGroups` edits it.
    static var currentMessage: String {
        get { message }
        set { message = newValue }
    }

    static var currentDraft: CADPlotSettings {
        get { draft }
        set { draft = newValue }
    }

    /// Load the draft from the dialog edit target. False when invalid.
    @discardableResult
    static func ensureDraft(engine: PhrostEngine) -> Bool {
        guard let tab = engine.tabManager.activeTab,
              let editName = engine.ui.pageSetupEditName else { return false }
        let isSetup = engine.ui.pageSetupEditIsSetup
        let key = "\(tab.id.uuidString):\(isSetup ? "S" : "L"):\(editName)"
        if draftKey != key {
            draftKey = key
            draftIsSetup = isSetup
            draftName = editName
            message = ""
            pdfOpen = false
            if isSetup {
                draft = tab.namedPageSetups.first(where: {
                    $0.name.caseInsensitiveCompare(editName) == .orderedSame
                })?.settings ?? CADPlotSettings()
                styleFiles = availableStyleFiles(pstyleMode: 1)
            } else {
                let doc = tab.drawingViews.first(where: {
                    $0.kind == .sheet && $0.name.caseInsensitiveCompare(editName) == .orderedSame
                })?.document
                draft = doc?.plotSettings ?? CADPlotSettings(
                    paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
                styleFiles = availableStyleFiles(pstyleMode: doc?.pstyleMode ?? 1)
            }
        }
        return true
    }

    /// The ten editing groups + conditional PDF Options sub-dialog.
    static func renderGroups(engine: PhrostEngine, dw: Float, dh: Float) {
        if igBeginChild_Str("##PageSetupGroups", ImVec2(x: -1, y: -52), 1, 0) {
            renderPageSetupGroup()
            renderPrinterGroup(engine: engine)
            renderPaperGroup()
            renderPlotAreaGroup()
            renderOffsetGroup(engine: engine)
            renderScaleGroup(customScales: engine.tabManager.activeTab?.customScaleFactors ?? [])
            renderStyleGroup()
            renderShadeGroup(engine: engine)
            renderOptionsGroup()
            renderOrientationGroup()
        }
        igEndChild()
        if pdfOpen {
            renderPDFOptions(engine: engine, dw: dw, dh: dh)
        }
    }

    /// Commit the draft (layout → one undoable step; setup → propagate).
    /// Returns false when the target vanished.
    @discardableResult
    static func commitDraft(engine: PhrostEngine) -> Bool {
        guard let tab = engine.tabManager.activeTab else { return false }
        if draft.plotFlags & 4 != 0 { recenter(plotOffset: plotOffsetMode(engine: engine)) }
        if draftIsSetup {
            var stored = draft
            stored.pageSetupName = draftName
            if tab.namedPageSetups.contains(where: {
                $0.name.caseInsensitiveCompare(draftName) == .orderedSame
            }) {
                engine.tabManager.updateNamedSetup(name: draftName, with: stored)
            } else {
                engine.tabManager.createNamedSetup(name: draftName, from: stored)
            }
            engine.tabManager.recordLastPlotSettings(stored)
        } else {
            guard let index = tab.drawingViews.firstIndex(where: {
                $0.kind == .sheet && $0.name.caseInsensitiveCompare(draftName) == .orderedSame
            }) else {
                message = "Layout '\(draftName)' no longer exists."
                return false
            }
            var applied = draft
            applied.pageSetupName = tab.drawingViews[index].document.plotSettings?.pageSetupName ?? ""
            let doc = tab.drawingViews[index].document
            doc.undoManager.pushUndo(doc.snapshot())
            doc.plotSettings = applied
            doc.layoutSettings = applied.layoutSettings
            doc.unit = (applied.plotPaperUnits == 0) ? .inch : .millimeter
            doc.markEdited()
            engine.tabManager.recordLastPlotSettings(applied)
        }
        return true
    }

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        guard ensureDraft(engine: engine) else {
            engine.ui.pageSetupDialogActive = false
            return
        }

        let width: Float = 720
        let height: Float = min(760, dh - 40)
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        let title = draftIsSetup ? "Page Setup - \(draftName)" : "Page Setup - \(draftName)"
        guard igBegin("\(title)##PageSetupDialog", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            engine.ui.pageSetupDialogActive = false
            return
        }

        renderGroups(engine: engine, dw: dw, dh: dh)

        if igButton("Preview...", ImVec2(x: 90, y: 0)) {
            message = "Live preview arrives with the PREVIEW command (Phase 3)."
        }
        ImGuiSameLine(0, 8)
        if igButton("OK", ImVec2(x: 90, y: 0)) {
            if commitDraft(engine: engine) {
                engine.ui.pageSetupDialogActive = false
            }
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 90, y: 0)) {
            engine.ui.pageSetupDialogActive = false
        }
        ImGuiSameLine(0, 8)
        if igButton("Help", ImVec2(x: 90, y: 0)) {
            message = "Page Setup: paper, plotter, scale, and pen rules per layout."
        }
        if !message.isEmpty {
            ImGuiTextWrappedV(message)
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.pageSetupDialogActive = false
        }
    }

    // MARK: - Group 1: Page setup

    private static func renderPageSetupGroup() {
        ImGuiTextV("Page setup  [DWG]")
        ImGuiTextV("Name: \(draftIsSetup ? draftName : draftName)")
    }

    // MARK: - Group 2: Printer/plotter

    private static func renderPrinterGroup(engine: PhrostEngine) {
        igSeparator()
        ImGuiTextV("Printer/plotter")
        let devices = PlotDeviceCatalog.builtins
        let currentName = draft.plotConfigName.isEmpty ? "None" : draft.plotConfigName
        var known = devices.contains {
            $0.name.caseInsensitiveCompare(draft.plotConfigName) == .orderedSame
        }
        if ImGuiBeginCombo("Name", currentName, 0) {
            for device in devices {
                let selected = device.name.caseInsensitiveCompare(currentName) == .orderedSame
                if ImGuiSelectable(device.name, selected, 0, ImVec2(x: 0, y: 0)) {
                    applyDevice(engine: engine, name: device.name)
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            if !draft.plotConfigName.isEmpty, !known {
                if ImGuiSelectable(draft.plotConfigName, true, 0, ImVec2(x: 0, y: 0)) {}
            }
            ImGuiEndCombo()
        }
        known = devices.contains {
            $0.name.caseInsensitiveCompare(draft.plotConfigName) == .orderedSame
        }
        _ = known

        let device = PlotDeviceCatalog.device(named: draft.plotConfigName)
        ImGuiTextV("Plotter: \(device?.plotterDescription ?? "Unknown device (kept from file)")")
        ImGuiTextV("Where: \(device?.whereText ?? "")")
        ImGuiBeginDisabled(true)
        _ = igButton("Properties...", ImVec2(x: 110, y: 0))
        ImGuiEndDisabled()
        if device?.isPDF == true {
            ImGuiSameLine(0, 8)
            if igButton("PDF Options...", ImVec2(x: 110, y: 0)) {
                pdfDraft = draft.pdfOptions
                pdfOpen = true
            }
        }
        renderPartialPreview()
    }

    private static func applyDevice(engine: PhrostEngine, name: String) {
        let paperUpdate = engine.commandProcessor.systemVariable("PAPERUPDATE")
        let pu: Int
        if case .int(let i) = paperUpdate { pu = i } else { pu = 0 }
        let result = PlotSettingsValidator.applyDeviceChange(
            settings: draft, newDeviceName: name, paperUpdate: pu)
        draft = result.settings
        message = result.warning ?? ""
    }

    // MARK: - Partial Preview (live schematic thumbnail)

    private static func renderPartialPreview() {
        ImGuiTextV("Partial Preview (hover for sizes)")
        let avail = ImGuiGetContentRegionAvail()
        let w = max(Float(200), avail.x - 16)
        let h: Float = 150
        if igBeginChild_Str("##PartialPreview", ImVec2(x: w, y: h), 1, 0) {
            if let rects = PaperSheetGeometry.overlayRects(for: draft) {
                let dl = ImGuiGetWindowDrawList()!
                let origin = ImGuiGetCursorScreenPos()
                let sheetW = rects.paper.maxX - rects.paper.minX
                let sheetH = rects.paper.maxY - rects.paper.minY
                guard sheetW > 0, sheetH > 0 else { return }
                let s = min((Double(w) - 50) / sheetW, (Double(h) - 30) / sheetH)
                func pt(_ x: Double, _ y: Double) -> ImVec2 {
                    ImVec2(x: origin.x + Float((x - rects.paper.minX) * s) + 8,
                           y: origin.y + Float((rects.paper.maxY - y) * s) + 8)
                }
                let pMin = pt(rects.paper.minX, rects.paper.minY)
                let pMax = pt(rects.paper.maxX, rects.paper.maxY)
                ImDrawListAddRectFilled(dl, pMin, pMax,
                    col(255, 255, 255, 255), 0.0, 0)
                ImDrawListAddRect(dl, pMin, pMax,
                    col(120, 120, 120, 255), 0.0, 1.0, 0)
                let dMin = pt(rects.printable.minX, rects.printable.minY)
                let dMax = pt(rects.printable.maxX, rects.printable.maxY)
                dashedRect(dl, dMin, dMax, col(110, 110, 110, 255))
                // Effective plot area: translucent fill + hatch.
                if let area = PaperSheetGeometry.staticPlotAreaRect(for: draft) {
                    let aMin = pt(area.minX, area.minY)
                    let aMax = pt(area.maxX, area.maxY)
                    ImDrawListAddRectFilled(dl, aMin, aMax,
                        col(90, 140, 250, 60), 0.0, 0)
                    // Red clipping warning when the area escapes the printable box.
                    let clipped = area.minX < rects.printable.minX - 1e-9
                        || area.minY < rects.printable.minY - 1e-9
                        || area.maxX > rects.printable.maxX + 1e-9
                        || area.maxY > rects.printable.maxY + 1e-9
                    if clipped {
                        ImDrawListAddRect(dl, aMin, aMax,
                            col(220, 40, 40, 255), 0.0, 2.0, 0)
                    }
                    let dims = "\(String(format: "%.1f", draft.paperWidthMM)) x " +
                        "\(String(format: "%.1f", draft.paperHeightMM)) " +
                        "\(draft.plotPaperUnits == 0 ? "in" : "mm")"
                    ImDrawListAddText(dl,
                        ImVec2(x: pMin.x, y: pMax.y + 2),
                        col(220, 220, 220, 255), dims, nil)
                }
                if ImGuiIsItemHovered(0) {
                    ImGuiBeginTooltip()
                    ImGuiTextV("Paper: \(PlotDeviceCatalog.displayName(forCanonical: draft.canonicalMediaName))")
                    ImGuiTextV(String(format: "Printable: %.1f x %.1f %@",
                        rects.printable.maxX - rects.printable.minX,
                        rects.printable.maxY - rects.printable.minY,
                        draft.plotPaperUnits == 0 ? "in" : "mm"))
                    ImGuiEndTooltip()
                }
            } else {
                ImGuiTextV("No paper size set.")
            }
        }
        igEndChild()
    }

    private static func col(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> ImU32 {
        igGetColorU32_Vec4(ImVec4(x: Float(r) / 255, y: Float(g) / 255,
                                  z: Float(b) / 255, w: Float(a) / 255))
    }

    /// Integer drag via the float slider (no ImGuiDragInt wrapper exists).
    private static func dragInt(_ label: String, value: inout Int,
                                speed: Float, lo: Int, hi: Int) -> Bool {
        var f = Float(value)
        if ImGuiDragFloat(label, &f, speed, Float(lo), Float(hi),
                            "%.0f", ImGuiSliderFlags(0)) {
            value = Swift.min(Swift.max(Int(f.rounded()), lo), hi)
            return true
        }
        return false
    }

    private static func dashedRect(_ dl: UnsafeMutablePointer<ImDrawList>!,
                                   _ a: ImVec2, _ b: ImVec2, _ col: ImU32) {
        let dash: Float = 5, gap: Float = 4
        func dashLine(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) {
            let dx = bx - ax, dy = by - ay
            let total = (dx * dx + dy * dy).squareRoot()
            guard total > 0.001 else { return }
            var t: Float = 0
            var guardCount = 0
            while t < total, guardCount < 200 {
                let t1 = min(t + dash, total)
                ImDrawListAddLine(dl,
                    ImVec2(x: ax + dx * (t / total), y: ay + dy * (t / total)),
                    ImVec2(x: ax + dx * (t1 / total), y: ay + dy * (t1 / total)), col, 1.0)
                t += dash + gap
                guardCount += 1
            }
        }
        dashLine(a.x, a.y, b.x, a.y)
        dashLine(b.x, a.y, b.x, b.y)
        dashLine(b.x, b.y, a.x, b.y)
        dashLine(a.x, b.y, a.x, a.y)
    }

    // MARK: - Group 3: Paper size

    private static func renderPaperGroup() {
        igSeparator()
        ImGuiTextV("Paper size")
        let device = PlotDeviceCatalog.device(named: draft.plotConfigName)
        let media = device?.media ?? []
        let currentDisplay = draft.canonicalMediaName.isEmpty
            ? "—" : PlotDeviceCatalog.displayName(forCanonical: draft.canonicalMediaName)
        if ImGuiBeginCombo("Paper size", currentDisplay, 0) {
            for m in media {
                let selected = m.canonicalName.caseInsensitiveCompare(draft.canonicalMediaName) == .orderedSame
                if ImGuiSelectable(m.displayName, selected, 0, ImVec2(x: 0, y: 0)) {
                    draft = PlotSettingsValidator.applyPaperSize(settings: draft, media: m)
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
    }

    // MARK: - Group 4: Plot area

    private static func renderPlotAreaGroup() {
        igSeparator()
        ImGuiTextV("Plot area")
        let labels = ["Display", "Extents", "Limits", "View", "Window", "Layout"]
        let current = (0..<labels.count).contains(draft.plotType) ? labels[draft.plotType] : "Layout"
        if ImGuiBeginCombo("What to plot", current, 0) {
            for (index, label) in labels.enumerated() {
                if ImGuiSelectable(label, index == draft.plotType, 0, ImVec2(x: 0, y: 0)) {
                    var next = draft
                    next.plotType = index
                    draft = PlotSettingsValidator.enforcePlotTypeRules(settings: next)
                }
            }
            ImGuiEndCombo()
        }
        if draft.plotType == 3 {
            inputText("View name", value: &draft.plotViewName)
            ImGuiTextV("(Named views are not authored in v1; the Code-6 name round-trips.)")
        }
        if draft.plotType == 4 {
            ImGuiTextV("Window corners (paper space):")
            var x1 = Float(draft.plotWindowMinX), y1 = Float(draft.plotWindowMinY)
            var x2 = Float(draft.plotWindowMaxX), y2 = Float(draft.plotWindowMaxY)
            if ImGuiDragFloat("X1", &x1, 1.0, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
                draft.plotWindowMinX = Double(x1)
            }
            if ImGuiDragFloat("Y1", &y1, 1.0, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
                draft.plotWindowMinY = Double(y1)
            }
            if ImGuiDragFloat("X2", &x2, 1.0, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
                draft.plotWindowMaxX = Double(x2)
            }
            if ImGuiDragFloat("Y2", &y2, 1.0, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
                draft.plotWindowMaxY = Double(y2)
            }
            ImGuiTextV("(Window < pick arrives with interactive picking; numeric entry for v1.)")
        }
    }

    // MARK: - Group 5: Plot offset

    static func plotOffsetMode(engine: PhrostEngine) -> Int {
        if case .int(let v) = engine.commandProcessor.systemVariable("PLOTOFFSET") { return v }
        return 0
    }

    private static func renderOffsetGroup(engine: PhrostEngine) {
        igSeparator()
        let po: Int
        if case .int(let i) = engine.commandProcessor.systemVariable("PLOTOFFSET") { po = i } else { po = 0 }
        ImGuiTextV(po == 1 ? "Plot offset (origin set to edge of paper)"
                            : "Plot offset (origin set to printable area)")
        let centered = draft.plotFlags & 4 != 0
        let editable = PlotSettingsValidator.isOffsetEditable(
            plotType: draft.plotType, centered: centered)
        if !editable { ImGuiBeginDisabled(true) }
        var ox = Float(draft.plotOriginXMM), oy = Float(draft.plotOriginYMM)
        if ImGuiDragFloat("X", &ox, 0.5, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
            draft.plotOriginXMM = Double(ox)
        }
        if ImGuiDragFloat("Y", &oy, 0.5, -1e6, 1e6, "%.2f", ImGuiSliderFlags(0)) {
            draft.plotOriginYMM = Double(oy)
        }
        if !editable { ImGuiEndDisabled() }
        var center = centered
        let centerEnabled = PlotSettingsValidator.isCenterEnabled(plotType: draft.plotType)
        if !centerEnabled { ImGuiBeginDisabled(true) }
        if ImGuiCheckbox("Center the plot", &center) {
            if center { draft.plotFlags |= 4 } else { draft.plotFlags &= ~4 }
            recenter(plotOffset: plotOffsetMode(engine: engine))
        }
        if !centerEnabled { ImGuiEndDisabled() }
    }

    private static func recenter(plotOffset: Int = 0) {
        guard draft.plotFlags & 4 != 0 else { return }
        guard let printable = PaperSheetGeometry.overlayRects(for: draft)?.printable else { return }
        let pw = printable.maxX - printable.minX, ph = printable.maxY - printable.minY
        // Without live extents, center the printable area on itself at 1:1
        // for Layout-like areas; Window/Limits use their static rects.
        let area = PaperSheetGeometry.staticPlotAreaRect(for: draft)
        let aw = (area.map { $0.maxX - $0.minX }) ?? pw
        let ah = (area.map { $0.maxY - $0.minY }) ?? ph
        let s = draft.effectiveScaleFactor.isFinite ? draft.effectiveScaleFactor : 1
        let m = PaperSheetGeometry.permutedMargins(for: draft)
        // PLOTOFFSET read lazily: margins added only for edge-of-paper mode.
        let off = PlotSettingsValidator.centeredOffset(
            printableWidth: pw, printableHeight: ph,
            plotAreaWidth: aw, plotAreaHeight: ah, scale: s,
            plotOffset: plotOffset, marginLeft: m.left, marginBottom: m.bottom)
        // Store in mm (draft fields are mm; convert from paper units).
        let div = PaperSheetGeometry.unitDivisor(for: draft)
        draft.plotOriginXMM = off.x * div
        draft.plotOriginYMM = off.y * div
    }

    // MARK: - Group 6: Plot scale

    private static func renderScaleGroup(customScales: [Double] = []) {
        igSeparator()
        ImGuiTextV("Plot scale")
        var fit = draft.standardScaleType == 0
        let fitEnabled = PlotSettingsValidator.isFitEnabled(plotType: draft.plotType)
        if !fitEnabled { ImGuiBeginDisabled(true) }
        if ImGuiCheckbox("Fit to paper", &fit) {
            if fit {
                draft.standardScaleType = 0
                draft.useStandardScale = false
            } else {
                draft.standardScaleType = 16
                draft.useStandardScale = true
            }
        }
        if !fitEnabled { ImGuiEndDisabled() }

        var scaleLabel = "Custom"
        if draft.useStandardScale,
           (0...32).contains(draft.standardScaleType),
           draft.standardScaleType != 0 {
            scaleLabel = PlotSettingsValidator.scaleLabel(for: draft.standardScaleType)
        } else if !draft.useStandardScale {
            let f = draft.customScaleDenominator != 0
                ? draft.customScaleNumerator / draft.customScaleDenominator : 0
            if let match = customScales.first(where: {
                abs($0 - f) <= max(1e-9, abs($0) * 1e-9)
            }) {
                scaleLabel = TabManager.customScaleLabel(for: match)
            }
        }
        if ImGuiBeginCombo("Scale", scaleLabel, 0) {
            if ImGuiSelectable("Custom", !draft.useStandardScale && customScales.isEmpty, 0, ImVec2(x: 0, y: 0)) {
                draft.useStandardScale = false
                if draft.standardScaleType == 0 { draft.standardScaleType = 16 }
            }
            for t in 1...32 {
                if ImGuiSelectable(PlotSettingsValidator.scaleLabel(for: t),
                                   draft.useStandardScale && draft.standardScaleType == t,
                                   0, ImVec2(x: 0, y: 0)) {
                    draft.standardScaleType = t
                    draft.useStandardScale = true
                }
            }
            for custom in customScales {
                let label = TabManager.customScaleLabel(for: custom)
                let selected = !draft.useStandardScale
                    && abs(draft.customScaleNumerator / max(draft.customScaleDenominator, 1e-12) - custom)
                        <= max(1e-9, abs(custom) * 1e-9)
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    draft.standardScaleType = 16
                    draft.useStandardScale = false
                    draft.customScaleNumerator = custom
                    draft.customScaleDenominator = 1
                    draft.standardScaleFactor = custom
                }
            }
            ImGuiEndCombo()
        }

        var paperUnits = Float(draft.customScaleNumerator)
        var drawingUnits = Float(draft.customScaleDenominator)
        if ImGuiDragFloat("Paper units", &paperUnits, 0.1, 0.0001, 1e6, "%.4f", ImGuiSliderFlags(0)) {
            draft.customScaleNumerator = Double(paperUnits)
            if !draft.useStandardScale { draft.standardScaleFactor = draft.effectiveScaleFactor }
        }
        if ImGuiDragFloat("Drawing units", &drawingUnits, 0.1, 0.0001, 1e6, "%.4f", ImGuiSliderFlags(0)) {
            draft.customScaleDenominator = Double(max(drawingUnits, 0.0001))
            if !draft.useStandardScale { draft.standardScaleFactor = draft.effectiveScaleFactor }
        }
        let unitLabels = ["inches", "mm", "pixels"]
        let unitLabel = (0..<3).contains(draft.plotPaperUnits) ? unitLabels[draft.plotPaperUnits] : "mm"
        if ImGuiBeginCombo("Units", unitLabel, 0) {
            for (index, label) in unitLabels.enumerated() {
                if ImGuiSelectable(label, index == draft.plotPaperUnits, 0, ImVec2(x: 0, y: 0)) {
                    draft.plotPaperUnits = index
                }
            }
            ImGuiEndCombo()
        }
        var scaleLW = draft.plotFlags & 64 != 0
        if ImGuiCheckbox("Scale lineweights", &scaleLW) {
            if scaleLW { draft.plotFlags |= 64 } else { draft.plotFlags &= ~64 }
        }
    }

    // MARK: - Group 7: Plot style table

    private static func renderStyleGroup() {
        igSeparator()
        ImGuiTextV("Plot style table (pen assignments)")
        let current = draft.styleSheet.isEmpty ? "None" : draft.styleSheet
        if ImGuiBeginCombo("Name", current, 0) {
            if ImGuiSelectable("None", draft.styleSheet.isEmpty, 0, ImVec2(x: 0, y: 0)) {
                draft.styleSheet = ""
            }
            for file in styleFiles where file.caseInsensitiveCompare(current) != .orderedSame {
                if ImGuiSelectable(file, false, 0, ImVec2(x: 0, y: 0)) {
                    draft.styleSheet = file
                }
            }
            if !draft.styleSheet.isEmpty,
               !styleFiles.contains(where: { $0.caseInsensitiveCompare(draft.styleSheet) == .orderedSame }) {
                if ImGuiSelectable(draft.styleSheet, true, 0, ImVec2(x: 0, y: 0)) {}
            }
            ImGuiEndCombo()
        }
        ImGuiSameLine(0, 8)
        ImGuiBeginDisabled(true)
        _ = igButton("Edit...", ImVec2(x: 70, y: 0))
        ImGuiEndDisabled()
        var show = draft.plotFlags & 2 != 0
        if ImGuiCheckbox("Display plot styles", &show) {
            if show { draft.plotFlags |= 2 } else { draft.plotFlags &= ~2 }
        }
    }

    // MARK: - Group 8: Shaded viewport options

    private static func renderShadeGroup(engine: PhrostEngine) {
        igSeparator()
        ImGuiTextV("Shaded viewport options")
        ImGuiTextV("Shade plot: As displayed (per-viewport on layouts)")
        let qualities = ["Draft", "Preview", "Normal", "Presentation", "Maximum", "Custom"]
        let q = (0..<6).contains(draft.shadePlotResolution) ? draft.shadePlotResolution : 2
        if ImGuiBeginCombo("Quality", qualities[q], 0) {
            for (index, label) in qualities.enumerated() {
                if ImGuiSelectable(label, index == q, 0, ImVec2(x: 0, y: 0)) {
                    draft.shadePlotResolution = index
                }
            }
            ImGuiEndCombo()
        }
        let device = PlotDeviceCatalog.device(named: draft.plotConfigName)
        let dpi = PlotSettingsValidator.effectiveDPI(
            quality: draft.shadePlotResolution,
            customDPI: draft.shadePlotCustomDPI,
            referenceDPI: device?.referenceDPI ?? 200)
        if PlotSettingsValidator.isDPIEditable(quality: draft.shadePlotResolution) {
            var custom = draft.shadePlotCustomDPI
            if dragInt("DPI", value: &custom, speed: 10, lo: 100, hi: 32767) {
                draft.shadePlotCustomDPI = custom
            }
        } else {
            ImGuiTextV("DPI: \(dpi)")
        }
        _ = engine
    }

    // MARK: - Group 9: Plot options

    private static func renderOptionsGroup() {
        igSeparator()
        ImGuiTextV("Plot options")
        checkboxFlag(label: "Plot object lineweights", bit: 128)
        checkboxTransparency()
        checkboxPlotStyles()
        checkboxFlag(label: "Plot paperspace last", bit: 512)
        checkboxFlag(label: "Hide paperspace objects", bit: 8)
    }

    private static func checkboxFlag(label: String, bit: Int) {
        var value = draft.plotFlags & bit != 0
        if ImGuiCheckbox(label, &value) {
            if value { draft.plotFlags |= bit } else { draft.plotFlags &= ~bit }
        }
    }

    private static func checkboxTransparency() {
        var value = draft.plotTransparency
        if ImGuiCheckbox("Plot transparency", &value) {
            draft.plotTransparency = value
        }
    }

    private static func checkboxPlotStyles() {
        var value = draft.plotFlags & 32 != 0
        if ImGuiCheckbox("Plot with plot styles", &value) {
            draft = PlotSettingsValidator.applyingPlotStylesToggled(settings: draft, on: value)
        }
    }

    // MARK: - Group 10: Drawing orientation

    private static func renderOrientationGroup() {
        igSeparator()
        ImGuiTextV("Drawing orientation   [A]")
        let landscape = draft.plotRotation == 1 || draft.plotRotation == 3
        var portrait = !landscape
        var land = landscape
        if ImGuiRadioButton("Portrait", portrait) {
            draft.plotRotation = draft.plotRotation >= 2 ? 2 : 0
            portrait = true
            land = false
        }
        ImGuiSameLine(0, 16)
        if ImGuiRadioButton("Landscape", land) {
            draft.plotRotation = draft.plotRotation >= 2 ? 3 : 1
        }
        var upside = draft.plotRotation >= 2
        if ImGuiCheckbox("Plot upside-down", &upside) {
            let isLand = draft.plotRotation == 1 || draft.plotRotation == 3
            draft.plotRotation = isLand ? (upside ? 3 : 1) : (upside ? 2 : 0)
        }
    }

    // MARK: - PDF Options sub-dialog

    private static func renderPDFOptions(engine: PhrostEngine, dw: Float, dh: Float) {
        let width: Float = 420
        let height: Float = 380
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))
        var opened = true
        guard igBegin("PDF Options##PageSetupPDF", &opened, Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            pdfOpen = false
            return
        }
        var vector = pdfDraft.vectorDPI
        if dragInt("Vector quality (DPI)", value: &vector, speed: 10, lo: 72, hi: 2400) {
            pdfDraft.vectorDPI = vector
        }
        var raster = pdfDraft.rasterDPI
        if dragInt("Raster image quality (DPI)", value: &raster, speed: 10, lo: 72, hi: 2400) {
            pdfDraft.rasterDPI = raster
        }
        let mergeLabels = ["Lines Overwrite", "Lines Merge"]
        let mergeLabel = pdfDraft.mergeControl == .mergeLines ? mergeLabels[1] : mergeLabels[0]
        if ImGuiBeginCombo("Merge control", mergeLabel, 0) {
            for (index, label) in mergeLabels.enumerated() {
                let selected = (index == 1) == (pdfDraft.mergeControl == .mergeLines)
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    pdfDraft.mergeControl = index == 1 ? .mergeLines : .overwriteLines
                }
            }
            ImGuiEndCombo()
        }
        var layers = pdfDraft.includeLayerInfo
        if ImGuiCheckbox("Include layer information", &layers) { pdfDraft.includeLayerInfo = layers }
        var links = pdfDraft.includeHyperlinks
        if ImGuiCheckbox("Include hyperlinks", &links) { pdfDraft.includeHyperlinks = links }
        var fonts = pdfDraft.captureFonts
        if ImGuiCheckbox("Capture fonts used in the drawing", &fonts) { pdfDraft.captureFonts = fonts }
        var geom = pdfDraft.convertTextToGeometry
        if ImGuiCheckbox("Convert all text to geometry", &geom) { pdfDraft.convertTextToGeometry = geom }
        if igButton("OK", ImVec2(x: 90, y: 0)) {
            draft.pdfOptions = pdfDraft
            pdfOpen = false
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 90, y: 0)) {
            pdfOpen = false
        }
        _ = engine
    }

    // MARK: - Style file discovery (cached per dialog open)

    private static func availableStyleFiles(pstyleMode: Int) -> [String] {
        let ext = pstyleMode == 0 ? "stb" : "ctb"
        let candidates = ["Plot Styles", "./Plot Styles", "Engine/EngineAsBuilt/Plot Styles"]
        for dir in candidates {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                let matches = items.filter {
                    $0.lowercased().hasSuffix(".\(ext)")
                }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                if !matches.isEmpty { return matches }
            }
        }
        return []
    }

    private static func inputText(_ label: String, value: inout String) {
        let capacity = 256
        var buffer = [CChar](repeating: 0, count: capacity)
        let bytes = value.utf8CString
        for index in 0..<min(bytes.count, capacity - 1) { buffer[index] = bytes[index] }
        ImGuiSetNextItemWidth(-1)
        let changed = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return igInputText(label, base, capacity, 0, { _ in 0 }, nil)
        }
        if changed {
            value = buffer.withUnsafeBufferPointer { pointer in
                String(cString: pointer.baseAddress!)
            }
        }
    }
}
