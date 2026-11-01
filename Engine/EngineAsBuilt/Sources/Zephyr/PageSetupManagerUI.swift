import ZephyrCore
import Foundation
import ImGui

/// Page Setup Manager (`PAGESETUP`): layouts + named setups list,
/// Set Current / New / Modify / Import / Close, details group,
/// Rename/Delete context actions, and the New Page Setup mini-dialog.
/// The ten-group Page Setup dialog itself lives in `PageSetupDialogUI`.
@MainActor
struct PageSetupManagerUI {
    private static var tabID: UUID?
    private static var selection: String? = nil // "layout:<name>" / "setup:<name>"
    private static var message = ""
    private static var renamingName: String? = nil
    private static var renameBuffer = ""
    private static var showNewDialog = false
    private static var newName = ""
    private static var newStartWith = 0
    private static var newError = ""
    private static var showImportDialog = false
    private static var importSource = ""
    private static var importSetups: [CADNamedPageSetup] = []
    private static var importSelected: Set<String> = []
    private static var importRedefine = false
    private static var importError = ""

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        guard let tab = engine.tabManager.activeTab else {
            engine.ui.pageSetupManagerActive = false
            return
        }
        if tabID != tab.id {
            tabID = tab.id
            selection = nil
            message = ""
            renamingName = nil
            showNewDialog = false
            newName = ""
            newStartWith = 0
            newError = ""
        }

        let width: Float = 640
        let height: Float = 520
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        if engine.ui.pageSetupAutoImport {
            engine.ui.pageSetupAutoImport = false
            requestImportFile(engine: engine)
        }
        guard igBegin("Page Setup Manager##PageSetupManager", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }

        if !opened {
            engine.ui.pageSetupManagerActive = false
            return
        }

        let manager = engine.tabManager
        let currentLayout = manager.activeViewName ?? "Model"
        let currentDoc = tab.drawingViews[tab.activeViewIndex].document
        let currentSetup = currentDoc.plotSettings?.pageSetupName ?? ""
        ImGuiTextV("Current layout: \(currentLayout)")
        ImGuiTextV("Current page setup: \(currentSetup.isEmpty ? "<None>" : currentSetup)")
        igSeparator()

        // ---- List: layouts then named setups ----
        if igBeginChild_Str("##PageSetupList", ImVec2(x: -1, y: 220), 1, 0) {
            ImGuiTextV("Page setups")
            for view in tab.drawingViews where view.kind == .sheet {
                let bound = view.document.plotSettings?.pageSetupName ?? ""
                let title = bound.isEmpty
                    ? view.name
                    : "*\(view.name) (\(bound))"
                let key = "layout:\(view.name)"
                let selected = selection == key
                if ImGuiSelectable(title, selected, 0, ImVec2(x: 0, y: 0)) {
                    selection = key
                }
            }
            for setup in tab.namedPageSetups {
                let key = "setup:\(setup.name)"
                let selected = selection == key
                if ImGuiSelectable("   \(setup.name)", selected, 0, ImVec2(x: 0, y: 0)) {
                    selection = key
                }
                if igBeginPopupContextItem(
                    "##PageSetupCtx\(setup.name)",
                    Int32(ImGuiPopupFlags_MouseButtonRight.rawValue))
                {
                    if igMenuItem_Bool("Rename", nil, false, true) {
                        renamingName = setup.name
                        renameBuffer = setup.name
                    }
                    let bound = manager.layoutsBound(to: setup.name)
                    if igMenuItem_Bool("Delete", nil, false, bound.isEmpty) {
                        if manager.deleteNamedSetup(named: setup.name) {
                            message = "Deleted '\(setup.name)'."
                            if selection == key { selection = nil }
                        }
                    }
                    if !bound.isEmpty {
                        ImGuiTextV("In use by: \(bound.joined(separator: ", "))")
                    }
                    ImGuiEndPopup()
                }
            }
        }
        igEndChild()

        // ---- Inline rename row ----
        if let target = renamingName {
            igSpacing()
            ImGuiTextV("Rename '\(target)' to:")
            inputText("##PageSetupRename", value: &renameBuffer)
            ImGuiSameLine(0, 8)
            if igButton("OK", ImVec2(x: 80, y: 0)) {
                if manager.renameNamedSetup(from: target, to: renameBuffer) {
                    message = "Renamed to '\(renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines))'."
                    selection = "setup:\(renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines))"
                    renamingName = nil
                } else {
                    message = manager.validatePageSetupName(renameBuffer, ignoring: target)
                        ?? "Rename failed."
                }
            }
            ImGuiSameLine(0, 8)
            if igButton("Cancel", ImVec2(x: 80, y: 0)) {
                renamingName = nil
            }
        }

        // ---- Selected setup details ----
        igSpacing()
        if igBeginChild_Str("##PageSetupDetails", ImVec2(x: -1, y: 110), 1, 0) {
            ImGuiTextV("Selected page setup details")
            igSeparator()
            if let details = selectedDetails(engine: engine) {
                ImGuiTextV("Device name: \(details.device)")
                ImGuiTextV("Plotter: \(details.plotter)")
                ImGuiTextV("Plot size: \(details.size)")
                ImGuiTextV("Where: \(details.whereText)")
                ImGuiTextV("Description: \(details.description)")
            } else {
                ImGuiTextV("Select a layout or named setup above.")
            }
        }
        igEndChild()

        // ---- Action bar ----
        let sheetActive = tab.drawingViews[tab.activeViewIndex].kind == .sheet
        if igButton("Set Current", ImVec2(x: 100, y: 0)) {
            setCurrent(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("New...", ImVec2(x: 80, y: 0)) {
            showNewDialog = true
            newName = ""
            newStartWith = 0
            newError = ""
        }
        ImGuiSameLine(0, 8)
        if !sheetActive { ImGuiBeginDisabled(true) }
        if igButton("Modify...", ImVec2(x: 80, y: 0)) {
            openModify(engine: engine)
        }
        if !sheetActive { ImGuiEndDisabled() }
        ImGuiSameLine(0, 8)
        if igButton("Import...", ImVec2(x: 80, y: 0)) {
            requestImportFile(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Close", ImVec2(x: 80, y: 0)) {
            engine.ui.pageSetupManagerActive = false
        }

        // ---- Display-on-new-layout checkbox ----
        var displayOnNew = engine.tabManager.autoOpenPageSetupForNewLayouts
        if ImGuiCheckbox("Display when creating a new layout", &displayOnNew) {
            engine.tabManager.autoOpenPageSetupForNewLayouts = displayOnNew
            var settings = UserSettings.load()
            settings.displayPageSetupForNewLayouts = displayOnNew
            settings.save()
        }

        if !message.isEmpty {
            igSpacing()
            ImGuiTextWrappedV(message)
        }

        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.pageSetupManagerActive = false
        }

        if showNewDialog {
            renderNewDialog(engine: engine, dw: dw, dh: dh)
        }
        if showImportDialog {
            renderImportDialog(engine: engine, dw: dw, dh: dh)
        }
    }

    // MARK: - Selection helpers

    private static func selectedDetails(engine: PhrostEngine)
        -> (device: String, plotter: String, size: String, whereText: String, description: String)?
    {
        guard let tab = engine.tabManager.activeTab,
              let sel = selection else { return nil }
        let settings: CADPlotSettings?
        if sel.hasPrefix("layout:") {
            let name = String(sel.dropFirst("layout:".count))
            settings = tab.drawingViews.first {
                $0.kind == .sheet && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }?.document.plotSettings
        } else if sel.hasPrefix("setup:") {
            let name = String(sel.dropFirst("setup:".count))
            settings = tab.namedPageSetups.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }?.settings
        } else {
            settings = nil
        }
        guard let settings else { return nil }
        let deviceName = settings.plotConfigName.isEmpty ? "None" : settings.plotConfigName
        let device = PlotDeviceCatalog.device(named: settings.plotConfigName)
        let sizeName = settings.canonicalMediaName.isEmpty
            ? "—" : PlotDeviceCatalog.displayName(forCanonical: settings.canonicalMediaName)
        let size = "\(sizeName) (\(String(format: "%.2f", settings.paperWidthMM)) x " +
            "\(String(format: "%.2f", settings.paperHeightMM)) " +
            "\(settings.plotPaperUnits == 0 ? "inches" : "mm"))"
        return (deviceName,
                device?.plotterDescription ?? "Unknown device (kept from file)",
                size,
                device?.whereText ?? "",
                device?.plotterDescription ?? "")
    }

    private static func setCurrent(engine: PhrostEngine) {
        guard let tab = engine.tabManager.activeTab,
              let sel = selection else {
            message = "Select a layout or named setup first."
            return
        }
        if sel.hasPrefix("layout:") {
            let name = String(sel.dropFirst("layout:".count))
            if engine.tabManager.switchToView(named: name) {
                message = "Current layout: \(name)."
            } else {
                message = "Cannot switch to '\(name)'."
            }
        } else if sel.hasPrefix("setup:") {
            let name = String(sel.dropFirst("setup:".count))
            let layout = engine.tabManager.activeViewName ?? ""
            if engine.tabManager.applyNamedSetupToLayout(name, layoutName: layout) {
                message = "Applied '\(name)' to \(layout)."
            } else {
                message = "Select a sheet layout first, then Set Current."
            }
        }
    }

    private static func openModify(engine: PhrostEngine) {
        guard let tab = engine.tabManager.activeTab,
              let sel = selection else {
            message = "Select a layout or named setup to modify."
            return
        }
        if sel.hasPrefix("layout:") {
            engine.ui.pageSetupEditName = String(sel.dropFirst("layout:".count))
            engine.ui.pageSetupEditIsSetup = false
            engine.ui.pageSetupDialogActive = true
        } else if sel.hasPrefix("setup:") {
            engine.ui.pageSetupEditName = String(sel.dropFirst("setup:".count))
            engine.ui.pageSetupEditIsSetup = true
            engine.ui.pageSetupDialogActive = true
        }
        _ = tab
    }

    // MARK: - New Page Setup dialog (step 14)

    private static func startWithOptions(engine: PhrostEngine) -> [String] {
        var options = ["<None>", "<Default output device>", "<Previous plot>"]
        guard let tab = engine.tabManager.activeTab else { return options }
        options += tab.drawingViews.filter { $0.kind == .sheet }.map { $0.name }
        options += tab.namedPageSetups.map { $0.name }
        return options
    }

    private static func renderNewDialog(engine: PhrostEngine, dw: Float, dh: Float) {
        let width: Float = 420
        let height: Float = 300
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin("New Page Setup##PageSetupNew", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            showNewDialog = false
            return
        }

        ImGuiTextV("New page setup name:")
        inputText("##PageSetupNewName", value: &newName)
        igSpacing()
        ImGuiTextV("Start with:")
        let options = startWithOptions(engine: engine)
        newStartWith = min(max(newStartWith, 0), options.count - 1)
        if igBeginChild_Str("##PageSetupStartWith", ImVec2(x: -1, y: 120), 1, 0) {
            for (index, option) in options.enumerated() {
                if ImGuiSelectable(option, index == newStartWith, 0, ImVec2(x: 0, y: 0)) {
                    newStartWith = index
                }
            }
        }
        igEndChild()

        if !newError.isEmpty {
            ImGuiTextWrappedV(newError)
        }

        if igButton("OK", ImVec2(x: 90, y: 0)) {
            createFromDialog(engine: engine, options: options)
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 90, y: 0)) {
            showNewDialog = false
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            showNewDialog = false
        }
    }

    private static func createFromDialog(engine: PhrostEngine, options: [String]) {
        let manager = engine.tabManager
        if let error = manager.validatePageSetupName(newName) {
            newError = error
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = options[newStartWith]
        let settings: CADPlotSettings
        let isModel = false
        switch choice {
        case "<None>":
            settings = CADPlotSettings(
                paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
        case "<Default output device>":
            let device = PlotDeviceCatalog.dwgToPDF
            let media = device.defaultMedium
            var ps = CADPlotSettings()
            if let media {
                ps = PlotSettingsValidator.applyPaperSize(settings: ps, media: media)
            }
            ps.plotConfigName = device.name
            settings = ps
        case "<Previous plot>":
            guard let tab = manager.activeTab,
                  let prev = tab.lastPlotSettings else {
                newError = "No previous plot in this drawing yet."
                return
            }
            settings = prev
        default:
            if let tab = manager.activeTab,
               let view = tab.drawingViews.first(where: {
                   $0.kind == .sheet && $0.name.caseInsensitiveCompare(choice) == .orderedSame
               }) {
                settings = view.document.plotSettings ?? CADPlotSettings(
                    paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
            } else if let tab = manager.activeTab,
                      let setup = tab.namedPageSetups.first(where: {
                          $0.name.caseInsensitiveCompare(choice) == .orderedSame
                      }) {
                settings = setup.settings
            } else {
                newError = "Unknown template '\(choice)'."
                return
            }
        }
        if manager.createNamedSetup(name: trimmed, from: settings, isModelType: isModel) {
            showNewDialog = false
            selection = "setup:\(trimmed)"
            message = "Created '\(trimmed)'."
            engine.ui.pageSetupEditName = trimmed
            engine.ui.pageSetupEditIsSetup = true
            engine.ui.pageSetupDialogActive = true
        } else {
            newError = "Could not create '\(trimmed)'."
        }
    }

    // MARK: - Import Page Setups dialog (step 26)

    private static func requestImportFile(engine: PhrostEngine) {
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg", "dwt"])]) { urls in
            guard let url = urls.first else { return }
            do {
                importSetups = try DXFPlotSettingsImport.readNamedSetups(filePath: url.path)
                importSource = url.lastPathComponent
                importSelected = Set(importSetups.map(\.name))
                importError = importSetups.isEmpty ? "No named page setups in that file." : ""
                showImportDialog = true
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private static func renderImportDialog(engine: PhrostEngine, dw: Float, dh: Float) {
        let width: Float = 460
        let height: Float = 420
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin("Import Page Setups##PageSetupImport", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            showImportDialog = false
            return
        }

        ImGuiTextV("From: \(importSource)")
        if igBeginChild_Str("##ImportChecklist", ImVec2(x: -1, y: -90), 1, 0) {
            let existing = Set((engine.tabManager.activeTab?.namedPageSetups ?? []).map { $0.name.uppercased() })
            for setup in importSetups {
                var checked = importSelected.contains(setup.name)
                let label = existing.contains(setup.name.uppercased())
                    ? "\(setup.name) (exists — skipped unless Redefine is on)"
                    : setup.name
                if ImGuiCheckbox(label, &checked) {
                    if checked { importSelected.insert(setup.name) }
                    else { importSelected.remove(setup.name) }
                }
            }
        }
        igEndChild()

        var redefine = importRedefine
        if ImGuiCheckbox("Redefine existing setups", &redefine) {
            importRedefine = redefine
        }
        if !importError.isEmpty {
            ImGuiTextWrappedV(importError)
        }
        if igButton("Import", ImVec2(x: 90, y: 0)) {
            importSelectedChecked(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 90, y: 0)) {
            showImportDialog = false
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            showImportDialog = false
        }
    }

    private static func importSelectedChecked(engine: PhrostEngine) {
        let manager = engine.tabManager
        var imported = 0
        var skipped: [String] = []
        for setup in importSetups where importSelected.contains(setup.name) {
            let exists = manager.activeTab?.namedPageSetups.contains(where: {
                $0.name.caseInsensitiveCompare(setup.name) == .orderedSame
            }) ?? false
            if exists {
                if importRedefine {
                    manager.updateNamedSetup(name: setup.name, with: setup.settings)
                    imported += 1
                } else {
                    skipped.append(setup.name)
                }
                continue
            }
            if manager.createNamedSetup(
                name: setup.name, from: setup.settings, isModelType: setup.isModelType) {
                imported += 1
            } else {
                skipped.append(setup.name)
            }
        }
        showImportDialog = false
        var parts: [String] = []
        if imported > 0 { parts.append("Imported \(imported).") }
        if !skipped.isEmpty { parts.append("Skipped: \(skipped.joined(separator: ", ")).") }
        message = parts.isEmpty ? "Nothing imported." : parts.joined(separator: " ")
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
