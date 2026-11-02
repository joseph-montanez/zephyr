import Foundation
import ImGui
import ZephyrCore

// Sources/Zephyr/ExportPDFDialogUI.swift
/// `EXPORTPDF` options popup: a standalone modal that mirrors the font-handling
/// half of AutoCAD's PDF export UI, then hands off to the system save window.
///
/// Flow (never inside the file-export window):
/// `EXPORTPDF` -> popup -> Export... -> system save window -> background
/// export via `TabManager.startExportPDFActiveTab`, which leaves the tab's
/// file association untouched. Cancelling the save window keeps the popup
/// open with settings intact. "Open in viewer when done" fires once the
/// background export's save state clears (success clears it; failure keeps a
/// `.failed` state, so a partial file is never opened).
@MainActor
enum ExportPDFDialogUI {

    // MARK: - Ephemeral state (per popup open)

    private static var loadedTabID: UUID? = nil
    private static var captureFonts = true
    private static var convertAllText = false
    private static var hiddenSHXText = true
    private static var openInViewer = false
    private static var fontWarnings: [String] = []

    // MARK: - Pending "open when done"

    private static var pendingTabID: UUID? = nil
    private static var pendingSaveID: UUID? = nil
    private static var pendingURL: URL? = nil

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        pollPendingOpen(engine: engine)
        guard engine.ui.exportPDFDialogActive else { return }
        guard let tab = engine.tabManager.activeTab else {
            engine.ui.exportPDFDialogActive = false
            return
        }
        if loadedTabID != tab.id {
            loadedTabID = tab.id
            let persisted = PDFExporter.PDFExportOptions.loadPersisted()
            captureFonts = persisted.captureFonts
            convertAllText = persisted.convertAllTextToGeometry
            hiddenSHXText = persisted.includeHiddenTextForSHX
            openInViewer = PDFExporter.PDFExportOptions.loadPersistedOpenInViewer()
            fontWarnings = Self.fontWarnings(for: engine.tabManager.activeDocument)
        }

        let width: Float = 460
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - 320) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: 0), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin(
            "Export to PDF - \(tab.displayName)##ExportPDFDialog", &opened, flags)
        else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            engine.ui.exportPDFDialogActive = false
            return
        }

        ImGuiTextV("Export:  Current layout")
        ImGuiTextV("Page setup:  Current")

        igSeparator()
        ImGuiTextV("Font handling:")
        if convertAllText {
            ImGuiBeginDisabled(true)
            var capture = captureFonts
            ImGuiCheckbox("Capture fonts used in the drawing", &capture)
            ImGuiEndDisabled()
        } else {
            ImGuiCheckbox("Capture fonts used in the drawing", &captureFonts)
        }
        ImGuiCheckbox("Convert all text to geometry", &convertAllText)
        ImGuiCheckbox("Hidden text for SHX (searchable)", &hiddenSHXText)
        for warning in fontWarnings {
            // TextV takes a printf format: escape user-controlled names.
            ImGuiTextV(warning.replacingOccurrences(of: "%", with: "%%"))
        }

        igSeparator()
        ImGuiCheckbox("Open in viewer when done", &openInViewer)

        if pendingSaveID != nil {
            igSeparator()
            ImGuiTextV("Exporting...")
        } else {
            if igButton("Export...", ImVec2(x: 110, y: 0)) {
                startExportFlow(engine: engine, tabID: tab.id)
            }
            igSameLine(0, 8)
            if igButton("Cancel", ImVec2(x: 90, y: 0)) {
                persistSettings()
                engine.ui.exportPDFDialogActive = false
            }
        }
    }

    // MARK: - Export flow

    private static func startExportFlow(engine: PhrostEngine, tabID: UUID) {
        let options = PDFExporter.PDFExportOptions(
            captureFonts: convertAllText ? false : captureFonts,
            convertAllTextToGeometry: convertAllText,
            includeHiddenTextForSHX: hiddenSHXText)
        options.persist()
        PDFExporter.PDFExportOptions.persistOpenInViewer(openInViewer)
        let wantViewer = openInViewer
        let displayName = engine.tabManager.activeTab?.displayName
        NativeFileDialog.showSaveDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"])],
            defaultName: CADCommandProcessor.pdfExportDefaultName(for: displayName)
        ) { [weak engine] url in
            guard let engine, let url else { return } // cancel: popup stays open
            engine.ui.exportPDFDialogActive = false
            let target = CADCommandProcessor.pdfExportTargetURL(from: url)
            engine.tabManager.startExportPDFActiveTab(url: target, options: options)
            if wantViewer {
                pendingTabID = tabID
                pendingSaveID = engine.tabManager.activeSaveState?.saveID
                pendingURL = target
            }
        }
    }

    private static func persistSettings() {
        PDFExporter.PDFExportOptions(
            captureFonts: captureFonts,
            convertAllTextToGeometry: convertAllText,
            includeHiddenTextForSHX: hiddenSHXText
        ).persist()
        PDFExporter.PDFExportOptions.persistOpenInViewer(openInViewer)
    }

    /// Fires the pending viewer-open once the export's save state clears.
    /// Success removes the state; failure leaves `.failed`, so a partial
    /// file is never opened. A closed tab drops the pending open.
    private static func pollPendingOpen(engine: PhrostEngine) {
        guard let url = pendingURL, let tabID = pendingTabID else { return }
        guard engine.tabManager.tabs.contains(where: { $0.id == tabID }) else {
            clearPending()
            return
        }
        guard let state = engine.tabManager.activeSaveState else {
            NativeFileDialog.openInSystemViewer(url: url)
            clearPending()
            return
        }
        if state.saveID != pendingSaveID {
            // Superseded by a newer save: keep waiting only while that
            // save is in flight; otherwise the export already settled.
            if state.status != .saving, state.status != .autosaving,
               state.status != .committing {
                clearPending()
            }
        }
    }

    private static func clearPending() {
        pendingTabID = nil
        pendingSaveID = nil
        pendingURL = nil
    }

    // MARK: - Font warnings

    /// Styles referenced by the drawing's text that will not embed as
    /// requested (substituted or missing faces). Computed once per tab.
    private static func fontWarnings(for document: CADDocument) -> [String] {
        var styleNames = Set<String>()
        for entity in document.entitiesView {
            if let value = entity.xdata["dxf.textStyle"], case .string(let name) = value,
               !name.isEmpty {
                styleNames.insert(name)
            }
            guard let geometry = entity.resolvedGeometry(in: document) else { continue }
            for prim in geometry {
                if case .text(_, _, _, _, let style, _, _, _, _) = prim,
                   let style, !style.isEmpty {
                    // Block-scoped "BLOCK$0$STYLE" names resolve against the
                    // bare style for warning purposes.
                    let bare = style.components(separatedBy: "$").last ?? style
                    styleNames.insert(bare)
                }
            }
        }
        var warnings: [String] = []
        for name in styleNames.sorted().prefix(8) {
            let filename = CADFontManager.resolveTextStyleFont(
                styleName: name, textStyleFonts: document.textStyleFonts)
            guard CADFontManager.getTTFEquivalent(filename: filename) == nil else {
                continue
            }
            if CADFontManager.getOrLoadSHXFont(filename: filename) != nil { continue }
            warnings.append("Font unavailable, will reference by name: \(name)")
        }
        return warnings
    }
}
