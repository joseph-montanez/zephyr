import ZephyrCore
import Foundation
import ImGui

/// PLOT / PRINT dialog (step 22): reuses the Page Setup body
/// (`PageSetupDialogUI.renderGroups`) with a Page setup dropdown + `Add...`
/// on top and destination + `Apply to Layout` at the bottom.
/// `-PLOT` stays command-line (Phase 4 step 25).
@MainActor
struct PlotDialogUI {
    private static var tabID: UUID?
    private static var setupChoice = 0
    private static var destination = ""
    private static var newSetupName = ""
    private static var message = ""

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        guard let tab = engine.tabManager.activeTab else {
            engine.ui.plotDialogActive = false
            return
        }
        if tabID != tab.id {
            tabID = tab.id
            setupChoice = 0
            destination = ""
            newSetupName = ""
            message = ""
            pointDraftAtCurrent(engine: engine)
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
        guard igBegin("Plot - \(tab.drawingViews[tab.activeViewIndex].name)##PlotDialog", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            engine.ui.plotDialogActive = false
            return
        }

        renderSetupRow(engine: engine)
        igSeparator()
        PageSetupDialogUI.renderGroups(engine: engine, dw: dw, dh: dh)
        if !PageSetupDialogUI.currentMessage.isEmpty {
            ImGuiTextWrappedV(PageSetupDialogUI.currentMessage)
        }

        igSeparator()
        ImGuiTextV("Destination")
        ImGuiTextV(destination.isEmpty ? "No file selected." : destination)
        ImGuiSameLine(0, 8)
        if igButton("Browse...", ImVec2(x: 90, y: 0)) {
            let layoutName = tab.drawingViews[tab.activeViewIndex].name
            NativeFileDialog.showSaveDialog(
                window: engine.dialogParentWindow,
                filters: [NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"])],
                defaultName: "\(layoutName).pdf") { url in
                if let url { destination = url.path }
            }
        }

        if igButton("Add...", ImVec2(x: 90, y: 0)) {
            addCurrentAsSetup(engine: engine)
        }
        ImGuiSameLine(0, 8)
        inputText("##PlotNewSetupName", value: &newSetupName)
        ImGuiSameLine(0, 8)
        if igButton("Apply to Layout", ImVec2(x: 110, y: 0)) {
            if PageSetupDialogUI.commitDraft(engine: engine) {
                message = "Applied to layout."
            } else {
                message = PageSetupDialogUI.currentMessage
            }
        }
        ImGuiSameLine(0, 8)
        if igButton("Plot", ImVec2(x: 90, y: 0)) {
            plot(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Close", ImVec2(x: 90, y: 0)) {
            engine.ui.plotDialogActive = false
        }
        if !message.isEmpty {
            ImGuiTextWrappedV(message)
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.plotDialogActive = false
        }
    }

    // MARK: - Page setup row

    private static func setupOptions(engine: PhrostEngine) -> [String] {
        guard let tab = engine.tabManager.activeTab else { return ["<None>"] }
        let isModel = tab.drawingViews[tab.activeViewIndex].kind == .model
        var options = ["<Current layout settings>", "<None>", "<Previous plot>"]
        options += tab.namedPageSetups.filter { $0.isModelType == isModel }.map { $0.name }
        return options
    }

    private static func pointDraftAtCurrent(engine: PhrostEngine) {
        guard let tab = engine.tabManager.activeTab else { return }
        let view = tab.drawingViews[tab.activeViewIndex]
        engine.ui.pageSetupEditName = view.name
        engine.ui.pageSetupEditIsSetup = false
        PageSetupDialogUI.ensureDraft(engine: engine)
    }

    private static func renderSetupRow(engine: PhrostEngine) {
        ImGuiTextV("Page setup")
        let options = setupOptions(engine: engine)
        setupChoice = min(max(setupChoice, 0), options.count - 1)
        if ImGuiBeginCombo("##PlotSetupChoice", options[setupChoice], 0) {
            for (index, option) in options.enumerated() {
                let selected = index == setupChoice
                if ImGuiSelectable(option, selected, 0, ImVec2(x: 0, y: 0)) {
                    setupChoice = index
                    applySetupChoice(engine: engine, index: index)
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
    }

    private static func applySetupChoice(engine: PhrostEngine, index: Int) {
        let options = setupOptions(engine: engine)
        guard options.indices.contains(index) else { return }
        switch index {
        case 0:
            pointDraftAtCurrent(engine: engine)
        case 1: // <None>: current settings with no named association.
            pointDraftAtCurrent(engine: engine)
            var detached = PageSetupDialogUI.currentDraft
            detached.pageSetupName = ""
            PageSetupDialogUI.currentDraft = detached
        case 2: // <Previous plot>: last plot settings as the working draft.
            if let prev = engine.tabManager.activeTab?.lastPlotSettings {
                pointDraftAtCurrent(engine: engine)
                PageSetupDialogUI.currentDraft = prev
                PageSetupDialogUI.currentMessage = ""
            } else {
                pointDraftAtCurrent(engine: engine)
                PageSetupDialogUI.currentMessage = "No previous plot in this drawing yet."
            }
        default:
            if let setup = engine.tabManager.activeTab?.namedPageSetups.first(where: {
                $0.name.caseInsensitiveCompare(options[index]) == .orderedSame
            }) {
                engine.ui.pageSetupEditName = setup.name
                engine.ui.pageSetupEditIsSetup = true
                PageSetupDialogUI.ensureDraft(engine: engine)
            }
        }
    }

    private static func addCurrentAsSetup(engine: PhrostEngine) {
        let manager = engine.tabManager
        let trimmed = newSetupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = manager.validatePageSetupName(trimmed) {
            message = error
            return
        }
        var draft = PageSetupDialogUI.currentDraft
        draft.pageSetupName = trimmed
        let isModel = manager.activeTab.map { $0.drawingViews[$0.activeViewIndex].kind == .model } ?? false
        if manager.createNamedSetup(name: trimmed, from: draft, isModelType: isModel) {
            message = "Saved page setup '\(trimmed)'."
            newSetupName = ""
        } else {
            message = "Could not save '\(trimmed)'."
        }
    }

    // MARK: - Plot

    private static func plot(engine: PhrostEngine) {
        guard let tab = engine.tabManager.activeTab else { return }
        guard !destination.isEmpty else {
            message = "Choose a destination file first (Browse...)."
            return
        }
        guard tab.drawingViews.indices.contains(tab.activeViewIndex) else {
            message = "PLOT needs an active view."
            return
        }
        // Apply dialog settings to the view first (one undoable step).
        guard PageSetupDialogUI.commitDraft(engine: engine) else {
            message = PageSetupDialogUI.currentMessage
            return
        }
        let doc = tab.drawingViews[tab.activeViewIndex].document
        var transparency = 1
        var plotOffset = 0
        if case .int(let v) = engine.commandProcessor.systemVariable("PLOTTRANSPARENCYOVERRIDE") {
            transparency = v
        }
        if case .int(let v) = engine.commandProcessor.systemVariable("PLOTOFFSET") {
            plotOffset = v
        }
        let context = PDFExporter.PlotContext(
            transparencyOverride: transparency,
            plotOffset: plotOffset,
            plotTableLoader: PDFExporter.defaultPlotTableLoader)
        do {
            try PDFExporter.export(
                document: doc, to: URL(fileURLWithPath: destination),
                backgroundColor: .white, plotContext: context,
                options: PDFExporter.PDFExportOptions.loadPersisted())
            message = "Plotted to \(destination)."
        } catch {
            message = "Plot failed: \(error)."
        }
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
