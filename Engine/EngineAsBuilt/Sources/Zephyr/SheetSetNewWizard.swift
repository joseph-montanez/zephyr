import ZephyrCore
import Foundation
import ImGui

// MARK: - SheetSetNewWizard
//
// "New Sheet Set" creation wizard, Existing-Drawings flow only (Step 5).
// The Example-Sheet-Set path needs LT's installed templates, which are
// not available here. Pure grouping logic lives in
// `SheetSetLayoutImport.buildSet`; this file owns the modal steps and
// the file enumeration.

/// Mutable wizard state, owned by the palette (`inout` each frame).
struct SheetSetNewWizardState {
    var requested = false
    var step = 0
    var files: [String] = []
    var prefixTitle = false
    var nestSubsets = true
    var name = ""
    var desc = ""
    var dstPath = ""

    mutating func reset() {
        requested = false
        step = 0
        files = []
        prefixTitle = false
        nestSubsets = true
        name = ""
        desc = ""
        dstPath = ""
    }
}

@MainActor
enum SheetSetNewWizard {
    static let popupID = "New Sheet Set##NewSheetSetWizard"

    static func render(engine: PhrostEngine, state: inout SheetSetNewWizardState) {
        if state.requested {
            state.requested = false
            state.step = 0
            ImGuiOpenPopup(popupID, Int32(ImGuiPopupFlags_None.rawValue))
        }
        drainPending(into: &state)
        var open = true
        let flags = Int32(ImGuiWindowFlags_NoCollapse.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        guard ImGuiBeginPopupModal(popupID, &open, flags) else { return }
        defer { ImGuiEndPopup() }
        if !open {
            state.reset()
            return
        }
        if state.step == 0 {
            renderFilesStep(engine: engine, state: &state)
        } else {
            renderDetailsStep(engine: engine, state: &state)
        }
    }

    // MARK: - Steps

    private static func renderFilesStep(engine: PhrostEngine, state: inout SheetSetNewWizardState) {
        ImGuiTextV("Step 1 of 2: drawings")
        if state.files.isEmpty {
            ImGuiTextV("(no drawings yet)")
        }
        for file in state.files {
            ImGuiTextV(URL(fileURLWithPath: file).lastPathComponent)
        }
        if igSmallButton("Add…") {
            let window = engine.dialogParentWindow
            NativeFileDialog.showOpenDialog(
                window: window,
                filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dwg", "dxf", "dwt"])],
                allowMultiple: true
            ) { urls in
                // NOTE: `state` is a copy here; the dialog applies on the
                // next frame through the pending-adds queue.
                pendingAdds.append(contentsOf: urls.map(\.path))
            }
        }
        ImGuiSameLine(0, 6)
        if igSmallButton("Clear") {
            state.files = []
        }
        _ = ImGuiCheckbox("Prefix sheet title with file name", &state.prefixTitle)
        _ = ImGuiCheckbox("Create subsets from folders", &state.nestSubsets)
        if igButton("Next", ImVec2(x: 0, y: 0)), !state.files.isEmpty {
            if state.dstPath.isEmpty {
                let dir = URL(fileURLWithPath: state.files[0]).deletingLastPathComponent().path
                let base = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
                state.dstPath = URL(fileURLWithPath: dir)
                    .appendingPathComponent((base.isEmpty ? "Sheets" : base) + ".dst").path
            }
            state.step = 1
        }
        ImGuiSameLine(0, 6)
        if igButton("Cancel", ImVec2(x: 0, y: 0)) {
            ImGuiCloseCurrentPopup()
            state.reset()
        }
        if state.files.isEmpty {
            ImGuiTextV("Add at least one drawing to continue.")
        }
    }

    private static func renderDetailsStep(engine: PhrostEngine, state: inout SheetSetNewWizardState) {
        ImGuiTextV("Step 2 of 2: details")
        state.name = SheetSetManagerUI.inputText("##NewSetName", value: state.name)
        ImGuiSameLine(0, 6)
        ImGuiTextV("Name")
        state.desc = SheetSetManagerUI.inputText("##NewSetDesc", value: state.desc)
        ImGuiSameLine(0, 6)
        ImGuiTextV("Description")
        state.dstPath = SheetSetManagerUI.inputText("##NewSetDst", value: state.dstPath)
        ImGuiSameLine(0, 6)
        ImGuiTextV("Sheet set file (.dst)")
        if igButton("Back", ImVec2(x: 0, y: 0)) {
            state.step = 0
        }
        ImGuiSameLine(0, 6)
        if igButton("Create", ImVec2(x: 0, y: 0)) {
            create(engine: engine, state: &state)
        }
    }

    // MARK: - Creation

    /// File paths picked while the modal was open; applied next frame
    /// because the dialog completion cannot mutate the in-flight state.
    private static var pendingAdds: [String] = []

    private static func drainPending(into state: inout SheetSetNewWizardState) {
        guard !pendingAdds.isEmpty else { return }
        for path in pendingAdds where !state.files.contains(path) {
            state.files.append(path)
        }
        pendingAdds = []
        if state.dstPath.isEmpty, let first = state.files.first {
            let dir = URL(fileURLWithPath: first).deletingLastPathComponent().path
            let base = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            state.dstPath = URL(fileURLWithPath: dir)
                .appendingPathComponent((base.isEmpty ? "Sheets" : base) + ".dst").path
        }
    }

    private static func create(engine: PhrostEngine, state: inout SheetSetNewWizardState) {
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = state.dstPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !dst.isEmpty else { return }
        if FileManager.default.fileExists(atPath: dst) {
            print("[SheetSet] '\(dst)' already exists; use OPENSHEETSET for it instead. Nothing created.")
            return
        }
        var files: [SheetSetLayoutImport.ImportFile] = []
        var skipped: [String] = []
        for path in state.files {
            guard let meta = try? PublishMetadataInspector.readFile(atPath: path) else {
                skipped.append(URL(fileURLWithPath: path).lastPathComponent)
                continue
            }
            let layouts = meta.tabs.filter { $0.space == .layout }.map(\.name)
            if layouts.isEmpty {
                skipped.append(URL(fileURLWithPath: path).lastPathComponent + " (no layouts)")
                continue
            }
            files.append(SheetSetLayoutImport.ImportFile(path: path, layouts: layouts))
        }
        guard !files.isEmpty else {
            print("[SheetSet] Nothing importable; set not created.")
            return
        }
        if !skipped.isEmpty {
            print("[SheetSet] Skipped: \(skipped.joined(separator: ", ")).")
        }
        let set = SheetSetLayoutImport.buildSet(
            name: name,
            description: state.desc,
            dstPath: dst,
            files: files,
            nestSubsets: state.nestSubsets,
            prefixTitleWithFile: state.prefixTitle)
        engine.commandProcessor.sheetSetStore.register(set)
        do {
            try engine.commandProcessor.sheetSetStore.saveCurrent()
            print("[SheetSet] Created set '\(name)' → \(dst).")
        } catch {
            print("[SheetSet] Created in memory; save failed: \(error.localizedDescription)")
        }
        ImGuiCloseCurrentPopup()
        state.reset()
    }
}
