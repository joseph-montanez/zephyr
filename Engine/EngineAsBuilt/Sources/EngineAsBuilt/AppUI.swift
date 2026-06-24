import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - AppUI
//
// The top-level UI rendering orchestrator. Called once per frame by the
// engine's ImGui frame callback. It lays out all visible panels, chrome,
// and dialogs in the correct order and handles the mini-toolbar fallback
// when the full toolbar is hidden.
//
// Rendering order matters for z-ordering and docking-like behavior:
//   1. Tab Bar (top)
//   2. Side panels: Layers, Draw Palette
//   3. Toolbar or mini-toolbar
//   4. File dialogs (modal overlays)
//   5. Properties panel
//   6. Block panel
//   7. Command Line (bottom, if active)
//   8. Layer Move dialog (modal, if active)
//   9. Status Bar (very bottom)
//  10. Block Editor Banner (if editing a block)

@MainActor
struct AppUI {
    /// Called once per frame by the engine to render the entire UI.
    /// Orders all panels, chrome, and dialogs in the correct z-order.
    /// - Parameters:
    ///   - engine: The PhrostEngine instance providing state and services.
    static func render(engine: PhrostEngine) {
        // Get the current display size from ImGui's IO context.
        let io = ImGuiGetIO()!
        let dw = io.pointee.DisplaySize.x
        let dh = io.pointee.DisplaySize.y

        // Create a dockspace covering the work area
        let topOffset = AppLayout.topChromeHeight + AppLayout.tabBarHeight
        let bottomOffset = AppLayout.statusBarHeight
        let workH = dh - topOffset - bottomOffset

        ImGuiSetNextWindowPos(ImVec2(x: 0, y: topOffset), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: dw, y: workH), Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), Float(0.0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), Float(0.0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 0, y: 0))

        let hostFlags: Int32 =
            Int32(ImGuiWindowFlags_NoTitleBar.rawValue) |
            Int32(ImGuiWindowFlags_NoCollapse.rawValue) |
            Int32(ImGuiWindowFlags_NoResize.rawValue) |
            Int32(ImGuiWindowFlags_NoMove.rawValue) |
            Int32(ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue) |
            Int32(ImGuiWindowFlags_NoNavFocus.rawValue) |
            Int32(ImGuiWindowFlags_NoBackground.rawValue)

        var open = true
        if igBegin("MainWorkspace", &open, hostFlags) {
            igDockSpace(igGetID_Str("MainDockSpace"), ImVec2(x: 0, y: 0), Int32(ImGuiDockNodeFlags_PassthruCentralNode.rawValue), nil)
        }
        igEnd()

        ImGuiPopStyleVar(3)

        // 0. Custom Top Chrome (window header)
        if AppLayout.topChromeHeight > 0 {
            TopChromeUI.render(engine: engine, dw: dw)
        }

        // 1. Tab bar at the very top.
        TabBarUI.render(engine: engine, dw: dw)

        // 2. Side panels — Layers on the left.
        if engine.ui.layersPanelVisible {
            LayerPanelUI.render(engine: engine)
        }

        // 3. Draw palette — optional side panel for drawing tools.
        if engine.ui.drawPaletteVisible {
            DrawPaletteUI.render(engine: engine)
        }

        // 4. Toolbar removed in redesign. Functionality moved to command line.

        // 5. File browser dialogs (native-style modal overlays).
        engine.fileBrowser.render()
        engine.saveFileBrowser.render()

        // 6. Properties panel — shows selected entity details.
        PropertiesPanelUI.render(engine: engine)

        // 7. Block management panel — list/create/edit blocks.
        if engine.ui.blockPanelVisible {
            BlockPanelUI.render(engine: engine)
        }

        // 8. Command line overlay at the bottom (when active via Space key).
        CommandLineUI.render(engine: engine, dw: dw, dh: dh)

        // 9. Layer-move modal dialog (when moving entities between layers).
        if engine.ui.layerMoveActive {
            LayerMoveUI.render(engine: engine, dw: dw, dh: dh)
        }

        // 9b. Text editor modal dialog (when creating/editing text).
        if engine.textManager.isEditorActive {
            let result = TextEditorUI.render(state: &engine.textManager.editorState, dw: dw, dh: dh)
            switch result {
            case .active:
                break // Still open
            case .confirmed:
                print("[AppUI] Text editor confirmed")
                engine.textManager.isEditorActive = false
                engine.textManager.editorResult = result
            case .cancelled:
                print("[AppUI] Text editor cancelled")
                engine.textManager.isEditorActive = false
                engine.textManager.editorResult = result
            }
        }

        // 10. Status bar at the very bottom — shows entity count, FPS, etc.
        StatusBarUI.render(engine: engine, io: io, dw: dw, dh: dh)

        // 11. Block editor banner — shown when editing a block in-place.
        if engine.tabManager.activeTab?.editingBlockID != nil {
            BlockEditorBannerUI.render(engine: engine, dw: dw)
        }

        // 12. Radial Navigation Tool (Artrage style)
        if engine.ui.radialNavVisible {
            RadialNavUI.render(engine: engine, dw: dw, dh: dh)
        }
    }

}
