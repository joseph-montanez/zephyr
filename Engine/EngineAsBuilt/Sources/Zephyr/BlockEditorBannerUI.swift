import ZephyrCore
import Foundation
import ImGui

// MARK: - BlockEditorBannerUI
//
// Renders an inline banner at the top of the canvas when the user is
// editing a block in-place (entered via "Edit Block" button or BEDIT command).
// The banner displays the block name as a visual cue. The "Save & Close"
// button lives in the titlebar (TopChromeUI); the confirmation popup is
// rendered by AppUI when engine.ui.blockClosePending is true.
//
// The banner is styled with a green-tinted background to visually
// distinguish block-editing mode from normal document editing.

@MainActor
struct BlockEditorBannerUI {
    /// Renders the block editor banner if the active tab is currently
    /// editing a block. Otherwise, this is a no-op.
    /// - Parameters:
    ///   - engine: The engine instance for state and command execution.
    ///   - dw: Display width for centering the banner horizontally.
    static func render(engine: PhrostEngine, dw: Float) {
        // Only show when a block is being edited in the active tab.
        guard let blockID = engine.tabManager.activeTab?.editingBlockID else { return }

        // Resolve block name from the current document or parent document.
        let blockName: String

        if let block = engine.tabManager.activeTab?.document.block(for: blockID) {
            blockName = block.name
        } else if let block = engine.tabManager.activeTab?.parentDocument?.block(for: blockID) {
            blockName = block.name
        } else {
            blockName = "Unknown Block"
        }

        let bannerY = AppLayout.belowToolbarY + 2

        // Center the banner horizontally, just below the toolbar.
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - 300) * 0.5, y: bannerY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0.5, y: 0))

        var opened = true

        // Window flags: NoTitleBar | NoResize | NoMove | NoScrollbar | NoSavedSettings
        let flags: Int32 = 1 | 4 | 8 | 64 | 256

        // Style the banner with extra padding and a green-tinted background
        // to indicate that the user is in block-editing mode.
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 8)
        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_ItemSpacing.rawValue), 12)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), ImVec4(x: 0.2, y: 0.6, z: 0.3, w: 0.85))

        if igBegin("##BlockEditorBanner", &opened, flags) {
            ImGuiTextV("Block Editor:")
            ImGuiSameLine(0, 8)
            ImGuiTextV(blockName)
            ImGuiEnd()
        }

        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(2)
    }

}
