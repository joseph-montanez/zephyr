import ZephyrCore
import Foundation
import ImGui

/// `PUBLISH` dialog (Phase 5): batch sheet list over open drawings and
/// drawing files on disk, with Master-DWG setup sharing, `.dsd` save/load,
/// and background execution through `PublishRunner`.
///
/// Boundaries (mirroring `PublishExecution`):
/// - Open drawings are never mutated: rows publish from `openSnapshots`
///   (per-tab snapshots keyed by drawing id); file-only rows publish
///   through the runner's once-per-job disk cache.
/// - Preview jumps to the open tab for sheets whose drawing is open.
///   File-only sheets cannot preview without a full geometry load, so the
///   button reports that limitation explicitly instead of guessing.
@MainActor
struct PublishDialogUI {
    // MARK: - Session state (rebuilt every time the dialog opens)

    private static var initialized = false
    private static var store = PublishSheetStore()
    private static var openSnapshots: [UUID: [String: CADDocumentSnapshot]] = [:]
    private static var selection = Set<UUID>()
    private static var anchor: Int? = nil
    // Job options (mirror `PublishJobSpec`).
    private static var publishToChoice = 0 // 0 plotter-named, 1 PDF
    private static var fileTypeChoice = 0 // 0 multi-sheet, 1 single-sheet
    private static var namingChoice = 0 // 0 prompt, 1 auto
    private static var outputDir = ""
    private static var targetName = ""
    private static var openViewer = false
    private static var includeModel = true
    private static var appendOnLoad = false
    // Inline rename (single selection).
    private static var renamingID: UUID? = nil
    private static var renameBuffer = ""
    // Page-setup assignment combo.
    private static var assignChoice = 0
    // Import setups from another drawing.
    private static var showImport = false
    private static var importSourcePath = ""
    private static var importSourceLabel = ""
    private static var importSetups: [CADNamedPageSetup] = []
    private static var importPicked: String? = nil
    private static var importError = ""
    // Background run.
    private static var jobTask: Task<Void, Never>? = nil
    private static var running = false
    private static var progressBox: ProgressBox? = nil
    private static var jobReport: PublishJobReport? = nil
    private static var jobError: String? = nil
    private static var message = ""

    /// Lock-guarded `(done, total)` written by the runner's Sendable
    /// progress closure and read on the render thread.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        private var total = 0

        func set(done: Int, total: Int) {
            lock.lock()
            self.done = done
            self.total = total
            lock.unlock()
        }

        func read() -> (Int, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (done, total)
        }
    }

    // MARK: - Frame

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        if !initialized {
            initialized = true
            resetSession(engine: engine)
        }

        let width: Float = min(880, dw - 40)
        let height: Float = min(740, dh - 40)
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin("Publish##PublishDialog", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            closeDialog(engine: engine)
            return
        }

        renderSheetList()
        renderRowBar(engine: engine)
        renderRenameRow()
        renderAssignRow(engine: engine)
        igSeparator()
        renderDetails()
        igSeparator()
        renderOptions()
        igSeparator()
        renderPublishRow(engine: engine)

        if !message.isEmpty {
            ImGuiTextWrappedV(message)
        }
        if let jobError {
            ImGuiTextWrappedV("Publish failed: \(jobError)")
        }

        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            if showImport {
                showImport = false
            } else if !running {
                closeDialog(engine: engine)
            }
        }
        if showImport {
            renderImport(engine: engine, dw: dw, dh: dh)
        }
    }

    private static func closeDialog(engine: PhrostEngine) {
        jobTask?.cancel()
        jobTask = nil
        running = false
        progressBox = nil
        showImport = false
        engine.ui.publishDialogActive = false
        initialized = false
    }

    private static func resetSession(engine: PhrostEngine) {
        store = PublishSheetStore()
        openSnapshots = [:]
        selection = []
        anchor = nil
        publishToChoice = 0
        fileTypeChoice = 0
        namingChoice = 0
        outputDir = ""
        targetName = ""
        openViewer = false
        includeModel = true
        appendOnLoad = false
        renamingID = nil
        renameBuffer = ""
        assignChoice = 0
        showImport = false
        importPicked = nil
        importError = ""
        jobTask = nil
        running = false
        progressBox = nil
        jobReport = nil
        jobError = nil
        message = ""
        loadOpenDrawings(engine: engine)
    }

    // MARK: - Sheet list

    private static func setupColumn(_ entry: PublishSheetEntry) -> String {
        if entry.assignment.mode == .default {
            return entry.defaultSetupName.isEmpty
                ? "<Default: None>" : "<Default: \(entry.defaultSetupName)>"
        }
        return entry.assignment.setupName
    }

    private static func statusColumn(_ entry: PublishSheetEntry) -> String {
        switch entry.status {
        case .ready: return "Ready"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    private static func renderSheetList() {
        ImGuiTextV("Sheets (\(store.sheets.count)) — Ctrl+click toggles, Shift+click extends")
        if igBeginChild_Str("##PublishSheets", ImVec2(x: -1, y: 190), 1, 0) {
            for (index, entry) in store.sheets.enumerated() {
                let selected = selection.contains(entry.id)
                let label = "\(entry.sheetName)  |  \(setupColumn(entry))  |  "
                    + "\(statusColumn(entry))##\(entry.id.uuidString)"
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    handleRowClick(index: index, id: entry.id)
                }
                if entry.status != .ready, ImGuiIsItemHovered(0) {
                    ImGuiBeginTooltip()
                    ImGuiTextV(entry.statusMessage)
                    ImGuiEndTooltip()
                }
            }
        }
        igEndChild()
    }

    private static func handleRowClick(index: Int, id: UUID) {
        let ctrl = ImGuiGetIO()?.pointee.KeyCtrl ?? false
        let shift = ImGuiGetIO()?.pointee.KeyShift ?? false
        if shift, let anchor {
            let lo = min(anchor, index)
            let hi = max(anchor, index)
            selection = Set(store.sheets.indices[lo...hi].map { store.sheets[$0].id })
        } else if ctrl {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            anchor = index
        } else {
            selection = [id]
            anchor = index
        }
        renamingID = nil
        assignChoice = 0
    }

    private static func selectedIndices() -> [Int] {
        store.sheets.indices.filter { selection.contains(store.sheets[$0].id) }.sorted()
    }

    private static func renderRowBar(engine: PhrostEngine) {
        if igButton("Add Sheets...", ImVec2(x: 100, y: 0)) {
            addSheets(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Remove", ImVec2(x: 80, y: 0)) {
            removeSelected()
        }
        ImGuiSameLine(0, 8)
        if igButton("Up", ImVec2(x: 60, y: 0)) {
            moveSelected(up: true)
        }
        ImGuiSameLine(0, 8)
        if igButton("Down", ImVec2(x: 60, y: 0)) {
            moveSelected(up: false)
        }
        ImGuiSameLine(0, 8)
        if igButton("Preview", ImVec2(x: 80, y: 0)) {
            previewSelected(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Load...", ImVec2(x: 80, y: 0)) {
            loadDSD(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Save...", ImVec2(x: 80, y: 0)) {
            saveDSD(engine: engine)
        }
        if igButton("Model", ImVec2(x: 70, y: 0)) {
            selection = Set(store.sheets.filter { $0.space == .model }.map(\.id))
            anchor = nil
            assignChoice = 0
        }
        ImGuiSameLine(0, 8)
        if igButton("Layouts", ImVec2(x: 70, y: 0)) {
            selection = Set(store.sheets.filter { $0.space == .layout }.map(\.id))
            anchor = nil
            assignChoice = 0
        }
        ImGuiSameLine(0, 8)
        if igButton("None", ImVec2(x: 60, y: 0)) {
            selection = []
            anchor = nil
            assignChoice = 0
        }
        var append = appendOnLoad
        if ImGuiCheckbox("Append on load", &append) {
            appendOnLoad = append
        }
    }

    private static func removeSelected() {
        let idxs = selectedIndices()
        guard !idxs.isEmpty else {
            message = "Select sheets to remove first."
            return
        }
        store.removeSheets(at: idxs)
        selection = []
        anchor = nil
        renamingID = nil
        message = "Removed \(idxs.count) sheet\(idxs.count == 1 ? "" : "s")."
    }

    private static func moveSelected(up: Bool) {
        var idxs = selectedIndices()
        guard !idxs.isEmpty else {
            message = "Select sheets to move first."
            return
        }
        if up {
            guard idxs.first! > 0 else { return }
            for i in idxs {
                _ = store.moveSheet(from: i, to: i - 1)
            }
        } else {
            guard idxs.last! < store.sheets.count - 1 else { return }
            for i in idxs.reversed() {
                _ = store.moveSheet(from: i, to: i + 1)
            }
        }
        idxs = selectedIndices()
        anchor = idxs.first
    }

    // MARK: - Rename

    private static func renderRenameRow() {
        guard selection.count == 1,
              let id = selection.first,
              let entry = store.sheets.first(where: { $0.id == id })
        else { return }
        if renamingID != id {
            ImGuiTextV("Sheet: \(entry.sheetName)")
            ImGuiSameLine(0, 8)
            if igButton("Rename...", ImVec2(x: 90, y: 0)) {
                renamingID = id
                renameBuffer = entry.sheetName
            }
            return
        }
        ImGuiTextV("Rename to:")
        inputText("##PublishRename", value: &renameBuffer)
        ImGuiSameLine(0, 8)
        if igButton("OK", ImVec2(x: 70, y: 0)) {
            applyRename(id: id)
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 70, y: 0)) {
            renamingID = nil
        }
    }

    private static func applyRename(id: UUID) {
        guard let idx = store.sheets.firstIndex(where: { $0.id == id }) else {
            renamingID = nil
            return
        }
        let proposal = renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposal.isEmpty else {
            message = "Sheet name cannot be empty."
            return
        }
        store.sheets[idx].sheetName = store.uniqueSheetName(
            proposing: proposal, excluding: id)
        renamingID = nil
        message = ""
    }

    // MARK: - Page-setup assignment (selection-wide, Master flow + Import)

    private struct AssignOption {
        var title: String
        var setupName: String
        var origin: String?
        var isDefault: Bool
        var isImport: Bool
    }

    /// Assignment options for the current selection: `<Default>` reset,
    /// then space-tagged named setups (own drawing first per row, then
    /// every other loaded drawing — the Master DWG flow), then `Import...`.
    /// A chosen setup applies only to selected rows whose space matches
    /// (`PublishSheetStore.assign` resolves per row).
    private static func assignOptions() -> [AssignOption] {
        var options = [AssignOption(
            title: "<Default (each row's own)>",
            setupName: "", origin: nil, isDefault: true, isImport: false)]
        guard !selection.isEmpty else { return options }
        var seen = Set<String>()
        for id in selection.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = store.sheets.first(where: { $0.id == id }) else { continue }
            for candidate in store.candidateSetups(for: entry) {
                let key = "\(candidate.setup.name.uppercased())|\(candidate.originPath.uppercased())"
                guard seen.insert(key).inserted else { continue }
                let tag = candidate.setup.isModelType ? "Model" : "Layout"
                let origin = candidate.isOwnDrawing
                    ? "this drawing" : URL(fileURLWithPath: candidate.originPath).lastPathComponent
                options.append(AssignOption(
                    title: "[\(tag)] \(candidate.setup.name) (\(origin))",
                    setupName: candidate.setup.name,
                    origin: candidate.isOwnDrawing ? nil : candidate.originPath,
                    isDefault: false, isImport: false))
            }
        }
        options.append(AssignOption(
            title: "Import...", setupName: "",
            origin: nil, isDefault: false, isImport: true))
        return options
    }

    private static func renderAssignRow(engine: PhrostEngine) {
        ImGuiTextV("Page setup for selection")
        let options = assignOptions()
        assignChoice = min(max(assignChoice, 0), options.count - 1)
        if ImGuiBeginCombo("##PublishAssign", options[assignChoice].title, 0) {
            for (index, option) in options.enumerated() {
                let selected = index == assignChoice
                if ImGuiSelectable(option.title, selected, 0, ImVec2(x: 0, y: 0)) {
                    assignChoice = index
                    applyAssignChoice(option: option, engine: engine)
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
    }

    private static func applyAssignChoice(option: AssignOption, engine: PhrostEngine) {
        if option.isImport {
            requestImportFile(engine: engine)
            return
        }
        guard !selection.isEmpty else {
            message = "Select sheets first."
            return
        }
        if option.isDefault {
            store.assignDefault(to: selection)
            store.refreshPreflight(publishTo: currentPublishTo())
            message = "Reset \(selection.count) row\(selection.count == 1 ? "" : "s") to <Default>."
            return
        }
        let changed = store.assign(
            setupName: option.setupName, from: option.origin, to: selection)
        store.refreshPreflight(publishTo: currentPublishTo())
        message = changed == 0
            ? "'\(option.setupName)' matches no selected row's space."
            : "Applied '\(option.setupName)' to \(changed) row\(changed == 1 ? "" : "s")."
    }

    // MARK: - Import setups from another drawing

    private static func requestImportFile(engine: PhrostEngine) {
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(
                label: "Drawings", extensions: ["dxf", "dwg", "dwt", "eab"])]) { urls in
            guard let url = urls.first else { return }
            do {
                let meta = try PublishMetadataInspector.readFile(atPath: url.path)
                let spaces = Set(self.selection.compactMap { id in
                    self.store.sheets.first(where: { $0.id == id })?.space
                })
                let filtered = meta.namedSetups.filter { setup in
                    spaces.isEmpty || spaces.contains(setup.isModelType ? .model : .layout)
                }
                self.importSourcePath = url.path
                self.importSourceLabel = url.lastPathComponent
                self.importSetups = filtered
                self.importPicked = filtered.first?.name
                self.importError = filtered.isEmpty
                    ? "No named page setups for the selected rows' space in that file." : ""
                self.showImport = true
            } catch {
                self.message = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private static func renderImport(engine: PhrostEngine, dw: Float, dh: Float) {
        let width: Float = 480
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
        guard igBegin("Import Page Setups##PublishImport", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            showImport = false
            return
        }

        ImGuiTextV("From: \(importSourceLabel)")
        ImGuiTextV("Pick one setup — it applies to every selected row of its space.")
        if igBeginChild_Str("##PublishImportList", ImVec2(x: -1, y: -90), 1, 0) {
            for setup in importSetups {
                let tag = setup.isModelType ? "Model" : "Layout"
                if ImGuiSelectable(
                    "[\(tag)] \(setup.name)", importPicked == setup.name,
                    0, ImVec2(x: 0, y: 0))
                {
                    importPicked = setup.name
                }
            }
        }
        igEndChild()

        if !importError.isEmpty {
            ImGuiTextWrappedV(importError)
        }
        if igButton("Apply to Selection", ImVec2(x: 140, y: 0)) {
            applyImport(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Cancel", ImVec2(x: 90, y: 0)) {
            showImport = false
        }
    }

    private static func applyImport(engine: PhrostEngine) {
        guard let picked = importPicked,
              importSetups.contains(where: { $0.name == picked })
        else {
            importError = "Pick a setup first."
            return
        }
        guard !selection.isEmpty else {
            importError = "Select sheets first."
            return
        }
        // Keep the source drawing metadata around (no new sheet rows) so
        // the borrowed setup stays listed for later assignment.
        do {
            let meta = try PublishMetadataInspector.readFile(atPath: importSourcePath)
            if !store.drawings.contains(where: { $0.id == meta.id }) {
                store.drawings.append(meta)
            }
        } catch {
            importError = "Re-read failed: \(error.localizedDescription)"
            return
        }
        let changed = store.assign(
            setupName: picked, from: importSourcePath, to: selection)
        store.refreshPreflight(publishTo: currentPublishTo())
        showImport = false
        message = changed == 0
            ? "'\(picked)' matches no selected row's space."
            : "Imported '\(picked)' onto \(changed) row\(changed == 1 ? "" : "s")."
    }

    // MARK: - Selected-sheet details

    private static func renderDetails() {
        guard selection.count == 1,
              let id = selection.first,
              let entry = store.sheets.first(where: { $0.id == id })
        else {
            ImGuiTextV(selection.isEmpty
                ? "Select a sheet to inspect it."
                : "\(selection.count) sheets selected.")
            return
        }
        ImGuiTextV("Selected sheet details")
        igSeparator()
        let drawing = store.drawing(for: entry)
        ImGuiTextV("Sheet: \(entry.sheetName)")
        let sourceLabel = entry.sourceDwgPath.isEmpty
            ? (drawing?.displayName ?? "(unsaved)") : entry.sourceDwgPath
        ImGuiTextV("Source: \(sourceLabel)")
        ImGuiTextV("Layout: \(entry.tabName) (\(entry.space == .model ? "Model" : "Layout"))")
        switch entry.assignment.mode {
        case .default:
            ImGuiTextV("Setup: \(setupColumn(entry))")
        case .namedLocal:
            ImGuiTextV("Setup: \(entry.assignment.setupName) (this drawing)")
        case .importedMaster:
            let base = entry.assignment.masterDwgPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? "?"
            ImGuiTextV("Setup: \(entry.assignment.setupName) (from \(base))")
        }
        if let settings = entry.resolvedSetup ?? entry.defaultSetup {
            let deviceName = settings.plotConfigName.isEmpty ? "None" : settings.plotConfigName
            let device = PlotDeviceCatalog.device(named: settings.plotConfigName)
            let sizeName = settings.canonicalMediaName.isEmpty
                ? "--" : PlotDeviceCatalog.displayName(forCanonical: settings.canonicalMediaName)
            ImGuiTextV("Device: \(deviceName)")
            ImGuiTextV("Paper: \(sizeName) "
                + "(\(String(format: "%.2f", settings.paperWidthMM)) x "
                + "\(String(format: "%.2f", settings.paperHeightMM)) "
                + "\(settings.plotPaperUnits == 0 ? "inches" : "mm"))")
            if let device {
                ImGuiTextV("Where: \(device.whereText)")
            }
        } else {
            ImGuiTextV("Setup: <none assigned>")
        }
        ImGuiTextV("Status: \(statusColumn(entry)) — \(entry.statusMessage)")
    }

    // MARK: - Output options

    private static func currentPublishTo() -> PublishDestination {
        publishToChoice == 1 ? .pdf : .plotterNamedInPageSetup
    }

    private static func renderOptions() {
        ImGuiTextV("Publish to:")
        let toOptions = ["Plotter named in page setup", "PDF"]
        publishToChoice = min(max(publishToChoice, 0), toOptions.count - 1)
        if ImGuiBeginCombo("##PublishTo", toOptions[publishToChoice], 0) {
            for (index, option) in toOptions.enumerated() {
                let selected = index == publishToChoice
                if ImGuiSelectable(option, selected, 0, ImVec2(x: 0, y: 0)) {
                    publishToChoice = index
                    store.refreshPreflight(publishTo: currentPublishTo())
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
        ImGuiTextV("File type:")
        let typeOptions = ["Multi-sheet file", "Single-sheet files"]
        fileTypeChoice = min(max(fileTypeChoice, 0), typeOptions.count - 1)
        if ImGuiBeginCombo("##PublishFileType", typeOptions[fileTypeChoice], 0) {
            for (index, option) in typeOptions.enumerated() {
                let selected = index == fileTypeChoice
                if ImGuiSelectable(option, selected, 0, ImVec2(x: 0, y: 0)) {
                    fileTypeChoice = index
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }
        ImGuiTextV("Naming:")
        let namingOptions = ["Prompt for name", "Auto"]
        namingChoice = min(max(namingChoice, 0), namingOptions.count - 1)
        if ImGuiBeginCombo("##PublishNaming", namingOptions[namingChoice], 0) {
            for (index, option) in namingOptions.enumerated() {
                let selected = index == namingChoice
                if ImGuiSelectable(option, selected, 0, ImVec2(x: 0, y: 0)) {
                    namingChoice = index
                }
                if selected { ImGuiSetItemDefaultFocus() }
            }
            ImGuiEndCombo()
        }

        ImGuiTextV("Output folder (empty = first sheet's folder):")
        inputText("##PublishOutputDir", value: &outputDir)
        ImGuiTextV("File name (multi-sheet; empty = prompt / first drawing base):")
        inputText("##PublishTargetName", value: &targetName)
        var viewer = openViewer
        if ImGuiCheckbox("Open in viewer when done", &viewer) {
            openViewer = viewer
        }
        ImGuiSameLine(0, 8)
        var model = includeModel
        if ImGuiCheckbox("Include Model tabs when adding sheets", &model) {
            includeModel = model
        }
        if fileTypeChoice == 1 {
            ImGuiTextV("Single-sheet files are named <SheetName>.pdf in the output folder.")
        }
    }

    private static func currentSpec() -> PublishJobSpec {
        let dir = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PublishJobSpec(
            publishTo: currentPublishTo(),
            outputDirectory: dir,
            fileType: fileTypeChoice == 1 ? .singleSheetFiles : .multiSheetFile,
            namingPolicy: namingChoice == 1 ? .autoName : .promptForName,
            targetFileName: name.isEmpty ? nil : name,
            openInViewerWhenDone: openViewer,
            sheets: store.sheets)
    }

    // MARK: - Publish run (background; open drawings never touched)

    private static func renderPublishRow(engine: PhrostEngine) {
        if running, let box = progressBox {
            let (done, total) = box.read()
            ImGuiTextV("Publishing... \(done)/\(total)")
            if igButton("Cancel", ImVec2(x: 90, y: 0)) {
                jobTask?.cancel()
            }
            return
        }
        if igButton("Publish", ImVec2(x: 90, y: 0)) {
            startPublish(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igButton("Close", ImVec2(x: 90, y: 0)) {
            closeDialog(engine: engine)
        }
        if let report = jobReport {
            let ok = report.sheets.filter { $0.status == .ready }.count
            ImGuiTextV("Last job: \(ok)/\(report.sheets.count) sheets ready"
                + (report.warnings.isEmpty ? "" : ", \(report.warnings.count) warning(s)") + ".")
            for output in report.outputURLs {
                ImGuiTextV("Wrote \(output.path)")
            }
        }
    }

    private static func startPublish(engine: PhrostEngine) {
        guard !running else { return }
        jobReport = nil
        jobError = nil
        let spec = currentSpec()
        guard !spec.sheets.isEmpty else {
            message = "Nothing to publish: add sheets first."
            return
        }
        if spec.fileType == .multiSheetFile,
           spec.namingPolicy == .promptForName,
           (spec.targetFileName ?? "").isEmpty {
            NativeFileDialog.showSaveDialog(
                window: engine.dialogParentWindow,
                filters: [NativeFileDialog.Filter(
                    label: "PDF Document", extensions: ["pdf"])],
                defaultName: "Publish.pdf") { url, _ in
                guard let url else { return }
                self.targetName = url.path
                self.runJob(engine: engine)
            }
            return
        }
        runJob(engine: engine)
    }

    private static func runJob(engine: PhrostEngine) {
        let spec = currentSpec()
        guard !spec.sheets.isEmpty else {
            message = "Nothing to publish: add sheets first."
            return
        }
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
        let snaps = openSnapshots
        let box = ProgressBox()
        progressBox = box
        running = true
        message = ""
        jobTask = Task {
            do {
                let report = try await PublishRunner.run(
                    spec: spec, openDrawings: snaps,
                    plotContext: context,
                    progress: { done, total in box.set(done: done, total: total) })
                await MainActor.run { Self.finishPublish(report: report) }
            } catch is CancellationError {
                await MainActor.run { Self.finishPublishCancelled() }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { Self.finishPublishErrorMessage(message) }
            }
        }
    }

    private static func finishPublish(report: PublishJobReport) {
        running = false
        jobTask = nil
        progressBox = nil
        jobReport = report
        for sheetReport in report.sheets {
            if let idx = store.sheets.firstIndex(where: { $0.id == sheetReport.id }) {
                store.sheets[idx].status = sheetReport.status
                store.sheets[idx].statusMessage = sheetReport.message
            }
        }
        let ok = report.sheets.filter { $0.status == .ready }.count
        if let first = report.outputURLs.first {
            message = report.sheets.count == 1 || report.outputURLs.count == 1
                ? "Published \(ok)/\(report.sheets.count) sheets to \(first.lastPathComponent)."
                : "Published \(ok)/\(report.sheets.count) sheets to \(report.outputURLs.count) files."
        } else {
            message = "No files written: every sheet failed (see Status column)."
        }
        if openViewer {
            for url in report.outputURLs {
                NativeFileDialog.openInSystemViewer(url: url)
            }
        }
    }

    private static func finishPublishCancelled() {
        running = false
        jobTask = nil
        progressBox = nil
        message = "Publish cancelled."
    }

    private static func finishPublishErrorMessage(_ message: String) {
        running = false
        jobTask = nil
        progressBox = nil
        jobError = message
    }

    // MARK: - Add / Preview

    private static func loadOpenDrawings(engine: PhrostEngine) {
        let metas = PublishMetadataInspector.readOpenTabs(from: engine.tabManager)
        for (index, meta) in metas.enumerated() {
            store.addDrawing(
                meta, includeModel: includeModel,
                publishTo: currentPublishTo())
            if index < engine.tabManager.tabs.count {
                openSnapshots[meta.id] = PublishRunner.snapshotsByTabName(
                    engine.tabManager.tabs[index].drawingViews)
            }
        }
        if !store.sheets.isEmpty {
            message = "Loaded \(store.sheets.count) sheets from open drawings."
        }
        // `+PUBLISH <file.dsd>` preloading (replace mode).
        if let pending = PublishDialogPreload.pendingDSDPath {
            PublishDialogPreload.pendingDSDPath = nil
            do {
                let text = try String(contentsOfFile: pending, encoding: .utf8)
                let dsd = try PublishDSD.parse(text)
                applyDSD(
                    engine: engine, dsd: dsd,
                    fileName: URL(fileURLWithPath: pending).lastPathComponent,
                    mode: .replace)
            } catch {
                message = "Preload failed: \(error.localizedDescription)"
            }
        }
    }

    private static func addSheets(engine: PhrostEngine) {
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(
                label: "Drawings", extensions: ["dxf", "dwg", "dwt", "eab"])],
            allowMultiple: true) { urls in
            guard !urls.isEmpty else { return }
            var added = 0
            var skipped = 0
            var errors: [String] = []
            for url in urls {
                if self.store.drawings.contains(where: {
                    $0.sourcePath.caseInsensitiveCompare(url.path) == .orderedSame
                }) {
                    skipped += 1
                    continue
                }
                do {
                    let meta = try PublishMetadataInspector.readFile(atPath: url.path)
                    added += self.store.addDrawing(
                        meta, includeModel: self.includeModel,
                        publishTo: self.currentPublishTo()).count
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            var parts: [String] = []
            if added > 0 { parts.append("Added \(added) sheets.") }
            if skipped > 0 { parts.append("\(skipped) already listed.") }
            parts += errors
            self.message = parts.isEmpty ? "Nothing added." : parts.joined(separator: " ")
        }
    }

    private static func tabMatchesDrawing(_ tab: DocumentTab, drawing: PublishDrawingMetadata) -> Bool {
        let src = drawing.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !src.isEmpty {
            guard let url = tab.fileURL else { return false }
            return url.standardizedFileURL.path.lowercased()
                == URL(fileURLWithPath: src).standardizedFileURL.path.lowercased()
        }
        return drawing.displayName == tab.displayName
    }

    private static func previewSelected(engine: PhrostEngine) {
        guard selection.count == 1,
              let id = selection.first,
              let entry = store.sheets.first(where: { $0.id == id })
        else {
            message = "Select exactly one sheet to preview."
            return
        }
        guard let drawing = store.drawing(for: entry),
              let tabIndex = engine.tabManager.tabs.firstIndex(where: {
                  tabMatchesDrawing($0, drawing: drawing)
              })
        else {
            message = "Preview is unavailable: '\(entry.sheetName)' is file-only — "
                + "open its drawing in a tab first (sheets render from open "
                + "tabs, or from the file itself at Publish time)."
            return
        }
        engine.activateDockedTab(at: tabIndex)
        guard engine.tabManager.switchToView(named: entry.tabName) else {
            message = "Preview is unavailable: layout '\(entry.tabName)' is not in the open drawing."
            return
        }
        if let setup = entry.resolvedSetup {
            engine.ui.previewSettings = setup
        } else if let view = engine.tabManager.activeTab?.drawingViews.first(where: {
            $0.name.caseInsensitiveCompare(entry.tabName) == .orderedSame
        }) {
            engine.ui.previewSettings = view.document.plotSettings
        }
        engine.ui.previewActive = true
        message = ""
    }

    // MARK: - Sheet-list persistence (`.dsd`)

    private static func saveDSD(engine: PhrostEngine) {
        let spec = currentSpec()
        guard !spec.sheets.isEmpty else {
            message = "Nothing to save: the sheet list is empty."
            return
        }
        NativeFileDialog.showSaveDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(
                label: "Drawing Set Description", extensions: ["dsd"])],
            defaultName: "Sheets.dsd") { url, _ in
            guard let url else { return }
            do {
                try PublishDSD.serialize(spec: spec).write(
                    to: url, atomically: true, encoding: .utf8)
                self.message = "Saved \(spec.sheets.count) sheets to \(url.lastPathComponent)."
            } catch {
                self.message = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private static func loadDSD(engine: PhrostEngine) {
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(
                label: "Drawing Set Description", extensions: ["dsd"])]) { urls in
            guard let url = urls.first else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let dsd = try PublishDSD.parse(text)
                self.applyDSD(
                    engine: engine, dsd: dsd, fileName: url.lastPathComponent,
                    mode: self.appendOnLoad ? .append : .replace)
            } catch {
                self.message = "Load failed: \(error.localizedDescription)"
            }
        }
    }

    /// Merge a `.dsd` job into the sheet list (replace or append — see the
    /// "Append on load" checkbox): shared `applyDSDJob` re-reads drawings
    /// from disk when present (names re-resolve to live setups, including
    /// Master imports), otherwise stubs records so rows still list with
    /// an honest preflight status.
    private static func applyDSD(
        engine: PhrostEngine, dsd: PublishDSDJob, fileName: String,
        mode: PublishDSDLoadMode
    ) {
        let unresolved = store.applyDSDJob(dsd, mode: mode) { path in
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return try? PublishMetadataInspector.readFile(atPath: path)
        }
        publishToChoice = dsd.publishTo == .pdf ? 1 : 0
        fileTypeChoice = dsd.fileType == .singleSheetFiles ? 1 : 0
        namingChoice = dsd.namingPolicy == .autoName ? 1 : 0
        outputDir = dsd.outputDirectory
        targetName = dsd.targetFileName ?? ""
        openViewer = dsd.openInViewerWhenDone
        selection = []
        anchor = nil
        renamingID = nil
        assignChoice = 0
        jobReport = nil
        jobError = nil
        openSnapshots = [:]
        for drawing in store.drawings {
            if let index = engine.tabManager.tabs.firstIndex(where: {
                tabMatchesDrawing($0, drawing: drawing)
            }) {
                openSnapshots[drawing.id] = PublishRunner.snapshotsByTabName(
                    engine.tabManager.tabs[index].drawingViews)
            }
        }
        let verb = mode == .append ? "Appended" : "Loaded"
        message = "\(verb) \(dsd.sheets.count) sheets from \(fileName) (\(store.sheets.count) total)"
            + (unresolved == 0 ? "." : " (\(unresolved) assignment(s) no longer resolve).")
    }

    // MARK: - ImGui helper

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
