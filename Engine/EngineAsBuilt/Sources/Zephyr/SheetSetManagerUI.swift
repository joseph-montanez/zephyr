import ZephyrCore
import Foundation
import ImGui

// MARK: - SheetSetManagerUI
//
// Sheet Set Manager palette, Sheet List tab (Step 8). Rows and details
// come from SheetSetManagerViewModel (pinned by SheetSetManagerTests);
// this file only renders them. Sheet Views / Model Views tabs arrive
// later. Actions reuse the command line (OPENSHEETSET dialog flow,
// -PUBLISHSET foreground publish) instead of duplicating their logic.

@MainActor
struct SheetSetManagerUI {
    static var _isDockedBySlot: [WindowSlotID: Bool] = [:]
    static var selectedSheetID: String? = nil

    static func render(engine: PhrostEngine) {
        let isDocked = _isDockedBySlot[engine.ui.frameSlot] ?? false
        var flags = Int32(0)
        if isDocked { flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue) }
        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Sheet Set Manager##SheetSetManager", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Sheet Set Manager##SheetSetManager", &opened, flags)
        }
        _isDockedBySlot[engine.ui.frameSlot] = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)
        guard entered else {
            ImGuiEnd(); ImGuiPopStyleVar(1); ImGuiPopStyleColor(1)
            return
        }
        defer { ImGuiEnd(); ImGuiPopStyleVar(1); ImGuiPopStyleColor(1) }
        if !isDocked && !opened {
            engine.ui.sheetSetManagerActive = false
            SheetSetSysvars.managerOpen = false
            return
        }

        let store = engine.commandProcessor.sheetSetStore
        guard let set = store.current else {
            ImGuiTextV("No sheet set open.")
            if igButton("Open…", ImVec2(x: 0, y: 0)) {
                engine.commandProcessor.executeCommand("OPENSHEETSET")
            }
            return
        }

        ImGuiTextV("Set: \(set.name)")
        ImGuiSameLine(0, 6)
        if igSmallButton("Open…") {
            engine.commandProcessor.executeCommand("OPENSHEETSET")
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("New…") {
            newWizardState.reset()
            newWizardState.requested = true
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("Close Set") {
            engine.commandProcessor.sheetSetStore.close(dstPath: set.dstPath)
            selectedSheetID = nil
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("Publish…") {
            engine.commandProcessor.executeCommand("-PUBLISHSET \"\(set.dstPath)\"")
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("Insert Sheet List") {
            engine.commandProcessor.executeCommand("SHEETLISTTABLE")
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("Import Layouts…") {
            let window = engine.dialogParentWindow
            NativeFileDialog.showOpenDialog(
                window: window,
                filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dwg", "dxf", "dwt"])],
                allowMultiple: true
            ) { urls in
                var added = 0
                let folder = URL(fileURLWithPath: set.dstPath).deletingLastPathComponent().path
                for url in urls {
                    guard let meta = try? PublishMetadataInspector.readFile(atPath: url.path) else {
                        print("[SheetSet] Import skipped (unreadable): \(url.path)")
                        continue
                    }
                    let sheets = SheetSetLayoutImport.sheets(from: meta, dstFolder: set.dstPath.isEmpty ? "" : folder)
                    if sheets.isEmpty { continue }
                    engine.commandProcessor.sheetSetStore.updateCurrent { $0.sheets.append(contentsOf: sheets) }
                    added += sheets.count
                }
                print("[SheetSet] Imported \(added) sheet(s) from \(urls.count) file(s).")
            }
        }
        igSeparator()

        let rows = SheetSetManagerViewModel.rows(for: set)
        var skipDepth: Int? = nil
        for (index, row) in rows.enumerated() {
            if let skip = skipDepth {
                if row.depth > skip { continue }
                skipDepth = nil
            }
            switch row.kind {
            case .subset:
                if !ImGuiCollapsingHeader(
                    "\(row.title)##subset\(index)",
                    Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
                    skipDepth = row.depth
                }
            case .sheet:
                let selected = row.sheetID == selectedSheetID
                if ImGuiSelectable(
                    "\(row.title)##\(row.sheetID ?? "sheet\(index)")",
                    selected, 0, ImVec2(x: 0, y: 0)) {
                    selectedSheetID = row.sheetID
                }
            }
        }
        igSeparator()

        let locked = store.lockStatus(dstPath: set.dstPath).locked
        for line in SheetSetManagerViewModel.details(
            for: set, sheetID: selectedSheetID, locked: locked) {
            ImGuiTextV(line)
        }

        if let id = selectedSheetID,
           let sheet = set.sheet(id: id),
           !sheet.absoluteFile.isEmpty {
            if igButton("Open Drawing", ImVec2(x: 0, y: 0)) {
                do {
                    try engine.tabManager.openTab(url: URL(fileURLWithPath: sheet.absoluteFile))
                    engine.frameInitialView()
                } catch {
                    print("[SheetSet] Open drawing failed: \(error.localizedDescription)")
                }
            }
        }
        igSeparator()
        ImGuiTextV("Edit")
        if let id = selectedSheetID, let sheet = set.sheet(id: id) {
            if renameForID != id {
                renameForID = id
                renameNumber = sheet.number
                renameTitle = sheet.title
            }
            renameNumber = inputText("##RenameNumber", value: renameNumber)
            ImGuiSameLine(0, 6)
            renameTitle = inputText("##RenameTitle", value: renameTitle)
            ImGuiSameLine(0, 6)
            if igSmallButton("Apply") {
                engine.commandProcessor.sheetSetStore.updateCurrent {
                    $0.renameSheet(id: id, number: renameNumber, title: renameTitle)
                }
            }
            ImGuiSameLine(0, 6)
            if igSmallButton("Remove Sheet") {
                engine.commandProcessor.sheetSetStore.updateCurrent { _ = $0.removeSheet(id: id) }
                selectedSheetID = nil
                renameForID = nil
            }
        } else {
            renameForID = nil
            newSubsetName = inputText("##NewSubset", value: newSubsetName)
            ImGuiSameLine(0, 6)
            if igSmallButton("Add Subset") {
                let name = newSubsetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    engine.commandProcessor.sheetSetStore.updateCurrent {
                        $0.subsets.append(SheetSetSubset(name: name))
                    }
                    newSubsetName = ""
                }
            }
        }
        if !set.dstPath.isEmpty {
            if igButton("Save Set", ImVec2(x: 0, y: 0)) {
                do {
                    let path = try engine.commandProcessor.sheetSetStore.saveCurrent()
                    print("[SheetSet] Saved \(path).")
                } catch {
                    print("[SheetSet] Save failed: \(error.localizedDescription)")
                }
            }
        }
        igSeparator()
        if ImGuiCollapsingHeader("Sheet Views", 0) {
            // Read-only named views per member drawing (place-on-sheet
            // stays gated). Parsed results cache on file mtime so the
            // per-frame render is a stat call in the common case.
            let groups = sheetViewGroups(for: set)
            if groups.isEmpty {
                ImGuiTextV("No named views in member drawings.")
            } else {
                for (index, group) in groups.enumerated() {
                    if ImGuiCollapsingHeader("\(group.title)##svgroup\(index)", 0) {
                        for view in group.views {
                            ImGuiTextV("\(view.name)  (\(view.handle))")
                            ImGuiSameLine(0, 6)
                            if igSmallButton("Place...##svplace\(group.title)|\(view.handle)") {
                                placeState.begin(
                                    modelPath: group.path, view: view,
                                    paperCenterX: 0, paperCenterY: 0)
                            }
                        }
                }
            }
        }
        }
        if ImGuiCollapsingHeader("Model Views", 0) {
            let folders = SheetSetManagerViewModel.modelViewFolders(for: set)
            if folders.isEmpty {
                ImGuiTextV("No drawing folders.")
            } else {
                for (index, folder) in folders.enumerated() {
                    if ImGuiCollapsingHeader("\(folder)##mvfolder\(index)", 0) {
                        for file in SheetSetManagerViewModel.modelViewFileRows(files: drawingFiles(in: folder)) {
                            let selected = file.path == selectedModelFile
                            if ImGuiSelectable("\(file.title)##mvfile\(index)", selected, 0, ImVec2(x: 0, y: 0)) {
                                selectedModelFile = file.path
                            }
                        }
                    }
                }
                if let path = selectedModelFile {
                    if igButton("Open Drawing", ImVec2(x: 0, y: 0)) {
                        do {
                            try engine.tabManager.openTab(url: URL(fileURLWithPath: path))
                            engine.frameInitialView()
                            selectedModelFile = nil
                        } catch {
                            print("[SheetSet] Open drawing failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        SheetSetNewWizard.render(engine: engine, state: &newWizardState)
        SheetSetPlaceUI.render(engine: engine, state: &placeState)

    }

    private static var newWizardState = SheetSetNewWizardState()
    private static var placeState = SheetSetPlaceState()
    private static var selectedModelFile: String? = nil
    private static var modelFileCache: [String: (stamp: TimeInterval, files: [String])] = [:]
    private static var sheetViewCache: [String: (stamp: TimeInterval, views: [SheetSetSheetViews.NamedView])] = [:]

    /// Sheet Views groups for the palette: distinct member drawings with
    /// their named views, cached on file mtime like the Model Views rows.
    private static func sheetViewGroups(for set: SheetSet) -> [SheetSetSheetViews.DrawingViews] {
        var seen = Set<String>()
        var out: [SheetSetSheetViews.DrawingViews] = []
        for sheet in set.allSheetsInOrder {
            let path = sheet.absoluteFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
            guard seen.insert(key).inserted else { continue }
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if let cached = sheetViewCache[path], cached.stamp == stamp {
                if !cached.views.isEmpty {
                    out.append(SheetSetSheetViews.DrawingViews(
                        path: path,
                        title: URL(fileURLWithPath: path).lastPathComponent,
                        views: cached.views))
                }
                continue
            }
            let views = SheetSetSheetViews.readViews(atPath: path) ?? []
            sheetViewCache[path] = (stamp, views)
            if !views.isEmpty {
                out.append(SheetSetSheetViews.DrawingViews(
                    path: path,
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    views: views))
            }
        }
        return out.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// `.dwg`/`.dxf`/`.dwt` files in one folder, cached on folder mtime
    /// so the per-frame render stays a stat call in the common case.
    private static func drawingFiles(in folder: String) -> [String] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let cached = modelFileCache[folder], cached.stamp == stamp {
            return cached.files
        }
        let files: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder))?
            .filter {
                let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
                return ext == "dwg" || ext == "dxf" || ext == "dwt"
            }
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0).path } ?? []
        modelFileCache[folder] = (stamp, files)
        return files
    }

    private static var renameNumber = ""
    private static var renameTitle = ""
    private static var renameForID: String? = nil
    private static var newSubsetName = ""

    static func inputText(_ id: String, value: String) -> String {
        var buffer = DataTableEditor.makeCellEditBuffer(from: value, capacity: 256)
        let capacity = buffer.count
        buffer.withUnsafeMutableBufferPointer { pointer in
            if let base = pointer.baseAddress {
                _ = igInputText(id, base, capacity, 0, nil, nil)
            }
        }
        return DataTableEditor.readCellEditBuffer(buffer)
    }
}




