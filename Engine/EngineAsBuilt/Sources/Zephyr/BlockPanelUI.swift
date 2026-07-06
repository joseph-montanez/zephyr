import ZephyrCore
import Foundation
import ImGui

// MARK: - BlockPanelUI
//
// Renders the Blocks management panel as a floating ImGui window.
// Lists all block definitions in the current document with instance counts,
// lets users create new blocks from selected entities, and enter block-editing
// mode to modify block geometry in-place.
//
// Block editing workflow:
//   1. Select entities on the canvas
//   2. Click "Create Block" or run the BLOCK command
//   3. Blocks appear in this panel with instance counts
//   4. Click "Edit" to enter block editor (isolated view of the block definition)

@MainActor
struct BlockPanelUI {
    /// Track docking state of this window.
    static var _isDocked: Bool = false
    /// Renders the block panel window.
    /// - Parameter engine: The engine instance for document access and command execution.
    static func render(engine: PhrostEngine) {
        let doc = engine.document
        let blocks = doc.allBlocks

        // Size the window based on font size for proportional scaling.
        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 22, y: ImGuiGetFontSize() * 30),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDocked
        var flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Blocks##BlockPanel", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Blocks##BlockPanel", &opened, flags)
        }

        guard entered else {
            _isDocked = ImGuiIsWindowDocked()
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        _isDocked = ImGuiIsWindowDocked()
        defer { 
            ImGuiEnd() 
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.blockPanelVisible = false
            return
        }

        ImGuiTextV("Blocks")
        ImGuiSameLine(0, 8)

        // "Create Block" button — only enabled when entities are selected.
        // A block cannot be created from an empty selection.
        let hasSelection = engine.cadSelection.hasSelection
        if !hasSelection {
            ImGuiBeginDisabled(true)
        }
        if igButton("Create Block", ImVec2(x: 0, y: 0)) {
            engine.commandProcessor.executeCommand("BLOCK")
        }
        if !hasSelection {
            ImGuiEndDisabled()
        }

        igSeparator()

        if blocks.isEmpty {
            ImGuiTextV("No blocks in this document.")
        } else {
            var blockIdx: Int32 = 0
            for block in blocks where !block.isInternalTableDisplayBlock {
                blockIdx &+= 1

                // Count how many block references (INSERT entities) point to this block definition.
                let instanceCount = doc.entitiesView.filter { $0.blockID == block.handle }.count

                ImGuiTextV("\u{2022}")
                ImGuiSameLine(0, 4)
                ImGuiTextV("\(block.name)")

                ImGuiSameLine(0, 8)
                let countStr = "(\(instanceCount) instances)"
                ImGuiTextV(countStr)

                ImGuiSameLine(0, 8)
                ImGuiPushID(blockIdx)
                // Enter block editor — isolates this block's geometry for in-place editing.
                if igSmallButton("Edit") {
                    engine.tabManager.enterBlockEditor(blockID: block.handle)
                    engine.cadSelection.clearSelection()
                }
                ImGuiPopID()
            }
        }
    }

}
