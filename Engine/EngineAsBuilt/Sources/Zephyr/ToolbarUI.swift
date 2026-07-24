import ZephyrCore
import Foundation
import ImGui

// MARK: - ToolbarUI
//
// Renders the main toolbar just below the tab bar.
// Provides quick-access buttons for common operations:
//   - File: Open, Save, Save As
//   - Tool modes: Select, Move, Rotate, Scale, Pan, Zoom
//   - Anti-aliasing toggle (AA button)
//   - Edit Block button (when a block reference is selected)
//   - View rotation slider with reset button
//   - Dark/Light theme toggle
//   - Hide toolbar button (shows the mini-toolbar instead)
//
// The toolbar also displays the current command status — either the active
// command's prompt, selected entity info, selection count, or "No selection".
//
// When hidden (via "_" button), a compact mini-toolbar with a "+" button
// is shown instead (rendered by AppUI.renderMiniToolbar).

@MainActor
struct ToolbarUI {
    /// Renders the main toolbar below the tab bar.
    /// - Parameters:
    ///   - engine: The engine instance.
    ///   - dw: Display width for full-width positioning.
    static func render(engine: PhrostEngine, dw: Float) {
        ImGuiSetNextWindowPos(
            ImVec2(x: 0, y: 0),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: dw, y: AppLayout.toolbarHeight),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 8)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 4)

        var opened = true
        // Window flags: NoTitleBar | NoResize | NoMove | NoScrollbar | NoSavedSettings
        let toolbarFlags: Int32 = 1 | 2 | 4 | 8 | 256

        if igBegin("##Toolbar", &opened, toolbarFlags) {

            // File operations: Open, Save, Save As
            if igSmallButton("Open..") {
                NativeFileDialog.showOpenDialog(
                    window: engine.window,
                    filters: [
                        NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg", "eab"]),
                        NativeFileDialog.Filter(label: "All Files", extensions: ["*"])
                    ],
                    allowMultiple: true
                ) { [weak engine] urls in
                    guard let engine else { return }
                    for url in urls {
                        do {
                            try engine.tabManager.openTab(url: url)
                        } catch {
                            print("Failed to open \(url.lastPathComponent): \(error)")
                        }
                    }
                    if !urls.isEmpty {
                        engine.zoomExtents()
                    }
                }
            }
            ImGuiSameLine(0, 4)
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
#if os(macOS)
                ImGuiTextV("Cmd+O to open a DXF/DWG file in a new tab")
#else
                ImGuiTextV("Ctrl+O to open a DXF/DWG file in a new tab")
#endif
                ImGuiEndTooltip()
            }

            ImGuiSameLine(0, 4)

            if igSmallButton("Save") {
                // Use async save; fall back to native save dialog if no file URL
                engine.tabManager.startSaveActiveTab()
                if engine.tabManager.activeFileURL == nil {
                    showNativeSaveDialog(engine: engine)
                }
            }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
#if os(macOS)
                ImGuiTextV("Cmd+S to save")
#else
                ImGuiTextV("Ctrl+S to save")
#endif
                ImGuiEndTooltip()
            }

            ImGuiSameLine(0, 4)

            if igSmallButton("Save As..") {
                showNativeSaveDialog(engine: engine)
            }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
#if os(macOS)
                ImGuiTextV("Cmd+Shift+S to save as a new file")
#else
                ImGuiTextV("Ctrl+Shift+S to save as a new file")
#endif
                ImGuiEndTooltip()
            }

            ImGuiSameLine(0, 4)

            if igSmallButton("Import PDF") {
                engine.commandProcessor.executeCommand("PDFIMPORT")
            }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
#if os(macOS)
                ImGuiTextV("Cmd+Shift+P to import a PDF page as an underlay")
#else
                ImGuiTextV("Ctrl+Shift+P to import a PDF page as an underlay")
#endif
                ImGuiEndTooltip()
            }

            ImGuiSameLine(0, 4)
            igSeparator()
            ImGuiSameLine(0, 4)

            // Tool mode buttons: Select, Move, Rotate, Scale, Pan, Zoom
            for tool in ToolMode.allCases {
                let isActive = (engine.currentTool == tool)
                let label = isActive ? "[\(tool.label)]" : " \(tool.label) "
                if igSmallButton(label) {
                    engine.commandProcessor.executeCommand(tool.label.uppercased())
                }
                ImGuiSameLine(0, 4)
            }

            ImGuiSameLine(0, 16)

            // Anti-aliasing toggle button.
            let aaLabel = engine.renderer.antiAliasLines ? "[AA]" : " AA "
            if igSmallButton(aaLabel) {
                engine.commandProcessor.executeCommand("AALINES")
            }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
                ImGuiTextV("Toggle anti-aliased line rendering")
                ImGuiEndTooltip()
            }

            ImGuiSameLine(0, 16)

            // Radial Navigation toggle button.
            let navLabel = engine.ui.radialNavVisible ? "[Nav]" : " Nav "
            if igSmallButton(navLabel) {
                engine.ui.radialNavVisible.toggle()
            }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
                ImGuiTextV("Toggle Radial Navigation Tool (Artrage style)")
                ImGuiEndTooltip()
            }
            ImGuiSameLine(0, 8)

            // "Edit Block" button — only shown when exactly one block reference is selected.
            let selCount = engine.cadSelection.selectedCount
            if selCount == 1,
               let handle = engine.cadSelection.selectedHandles.first,
               let entity = engine.document.entity(for: handle),
               entity.blockID != nil {
                if igSmallButton("Edit Block") {
                    engine.commandProcessor.executeCommand("BEDIT")
                }
                ImGuiSameLine(0, 8)
            }

            // Status text: shows active command prompt, selected entity info, or "No selection".
            if let cmd = engine.commandProcessor.activeCommand {
                let prompt = engine.commandProcessor.commandPrompt ?? cmd
                ImGuiTextV("\(cmd): \(prompt)  (Esc to cancel)")
            } else {
                let selCount = engine.cadSelection.selectedCount
                if selCount == 1 {
                    let handle = engine.cadSelection.selectedHandles.first!
                    if let entity = engine.document.entity(for: handle) {
                        let pos = entity.transform.position
                        if let bid = entity.blockID, let block = engine.document.block(for: bid) {
                            ImGuiTextV(
                                "\(block.name) | Pos:(%.0f,%.0f) | Rot:%.1f\u{00B0}",
                                pos.x, pos.y, entity.transform.rotation * 180 / .pi)
                        } else {
                            ImGuiTextV("Entity | Pos:(%.0f,%.0f)", pos.x, pos.y)
                        }
                    }
                } else if selCount > 1 {
                    if selCount > engine.gripObjectMax {
                        ImGuiTextV(
                            "%d entities selected  |  Grips hidden (>%d) |  Drag to move", selCount, engine.gripObjectMax)
                    } else {
                        ImGuiTextV(
                            "%d entities selected  |  Drag to move  |  Grips to scale/rotate", selCount)
                    }
                } else {
                    ImGuiTextV("No selection  |  Click/drag to select  |  Space for commands")
                }
            }

            // Right-aligned controls: view rotation slider and theme toggle.
            let hideBtnWidth: Float = 28
            let rightX = dw - hideBtnWidth - 8

            let sliderWidth: Float = 130
            let sliderX = rightX - sliderWidth - 20
            if sliderX > 420 {
                // View rotation angle slider.
                ImGuiSetCursorPosX(sliderX)
                var rotRad = Float(engine.camera.rotation)
                ImGuiSetNextItemWidth(sliderWidth - 26)
                if ImGuiSliderAngle("##ViewRot", &rotRad, -180, 180, "%.0f", ImGuiSliderFlags(0)) {
                    engine.camera.rotation = Double(rotRad)
                }
                ImGuiSameLine(0, 2)
                if igSmallButton("0") { engine.camera.rotation = 0 }
                if ImGuiIsItemHovered(0) {
                    ImGuiBeginTooltip()
                    ImGuiTextV("Reset view rotation")
                    ImGuiEndTooltip()
                }

                let curX = ImGuiGetCursorPosX()
                if curX < rightX { ImGuiSameLine(0, rightX - curX) }
            } else {
                ImGuiSetCursorPosX(rightX)
            }

            // Dark/Light theme toggle button.
            let themeLabel = engine.ui.isDarkTheme ? "Light Mode" : "Dark Mode"
            if igSmallButton(themeLabel) {
                engine.ui.toggleTheme()
            }
            ImGuiSameLine(0, 8)

            if igSmallButton("_") { engine.ui.toolbarVisible = false }
            if ImGuiIsItemHovered(0) {
                ImGuiBeginTooltip()
                ImGuiTextV("Hide toolbar")
                ImGuiEndTooltip()
            }
        }
        ImGuiEnd()

        ImGuiPopStyleVar(2)
    }

    /// Show the native file-save dialog and, on confirmation, save the active tab.
    private static func showNativeSaveDialog(engine: PhrostEngine) {
        let defaultName = engine.tabManager.activeTab?.displayName ?? "untitled"
        let dxfVersion = engine.tabManager.activeTab?.dxfVersion ?? .r2018
        NativeFileDialog.showSaveDialog(
            window: engine.window,
            filters: [
                NativeFileDialog.Filter(label: "DXF Drawing", extensions: ["dxf"]),
                NativeFileDialog.Filter(label: "Zephyr Drawing", extensions: ["eab"]),
                NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"]),
                NativeFileDialog.Filter(label: "All Files", extensions: ["*"])
            ],
            defaultName: defaultName
        ) { [weak engine] url in
            guard let engine, let url else { return }
            engine.tabManager.startSaveActiveTabAs(url: url, dxfVersion: dxfVersion)
        }
    }

}
