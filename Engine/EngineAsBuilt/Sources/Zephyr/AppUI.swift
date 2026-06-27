import ZephyrCore
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

        // 6b. Hatch editing ribbon — appears when a hatch entity is selected
        //     and no hatch creation command is active.
        if engine.commandProcessor.activeFeatureCommand == nil,
           engine.cadSelection.selectedCount == 1,
           let handle = engine.cadSelection.lastSelectedHandle,
           let entity = engine.document.entity(for: handle),
           let localGeom = entity.localGeometry,
           let firstPrim = localGeom.first {
            renderHatchEditingRibbonIfNeeded(firstPrim: firstPrim, entity: entity, engine: engine)
        }

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

        // 11. (Removed: Block editor banner now fully integrated into titlebar)

        // 11b. Block editor close-confirmation popup (Save / Discard / Cancel).
        //      Triggered by the titlebar "Save & Close" button or BCLOSE command.
        if engine.ui.blockClosePending {
            let blockName: String
            if let blockID = engine.tabManager.activeTab?.editingBlockID {
                if let block = engine.tabManager.activeTab?.document.block(for: blockID) {
                    blockName = block.name
                } else if let block = engine.tabManager.activeTab?.parentDocument?.block(for: blockID) {
                    blockName = block.name
                } else {
                    blockName = "Unknown Block"
                }
            } else {
                blockName = "Unknown Block"
            }

            ImGuiOpenPopup("Close Block Editor##BlockClose", Int32(ImGuiPopupFlags_None.rawValue))

            let popupW: Float = 360
            let popupH: Float = 100
            ImGuiSetNextWindowPos(
                ImVec2(x: (dw - popupW) * 0.5, y: 150),
                Int32(ImGuiCond_Appearing.rawValue),
                ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Appearing.rawValue))

            var popupOpen = true
            if ImGuiBeginPopupModal("Close Block Editor##BlockClose", &popupOpen,
                                    Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)) {
                defer { ImGuiEndPopup() }

                if !popupOpen {
                    engine.ui.blockClosePending = false
                } else {
                    ImGuiTextV("Save changes to block \"\(blockName)\" before closing?")

                    igSeparator()

                    if igSmallButton("Save") {
                        engine.tabManager.exitBlockEditor(saveChanges: true)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, 8)
                    if igSmallButton("Discard") {
                        engine.tabManager.exitBlockEditor(saveChanges: false)
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                    ImGuiSameLine(0, 8)
                    if igSmallButton("Cancel") {
                        engine.ui.blockClosePending = false
                        ImGuiCloseCurrentPopup()
                    }
                }
            }
        }

        // 12. Radial Navigation Tool (Artrage style)
        if engine.ui.radialNavVisible {
            RadialNavUI.render(engine: engine, dw: dw, dh: dh)
        }
    }

    // MARK: - Hatch editing ribbon

    /// When a single hatch entity is selected, show the same floating ribbon
    /// used during creation so the user can edit properties inline.
    private static func renderHatchEditingRibbonIfNeeded(
        firstPrim: CADPrimitive, entity: CADEntity, engine: PhrostEngine
    ) {
        let pattern: String
        let scale: Double
        let angle: Double
        let color: ColorRGBA?
        let backgroundColor: ColorRGBA?
        let gradientColor2: ColorRGBA?
        let outerBoundary: [Vector3]
        let holes: [[Vector3]]

        switch firstPrim {
        case .hatch(let b, let p, let s, let a, let c, let bg):
            outerBoundary = b
            holes = []
            pattern = p
            scale = s
            angle = a
            color = c
            backgroundColor = bg
            gradientColor2 = nil
        case .gradient(let outer, let h, _, let a, let c1, let c2):
            outerBoundary = outer
            holes = h
            pattern = "GRADIENT"
            scale = 1.0
            angle = a
            color = c1
            backgroundColor = nil
            gradientColor2 = c2
        default:
            return
        }

        var settings = HatchRibbonUI.Settings(
            fillType: {
                if case .gradient = firstPrim { return 2 }
                let p = pattern.uppercased()
                if p == "USER" { return 3 }
                if p == "SOLID" || p.isEmpty { return 1 }
                return 0
            }(),
            patternName: {
                if let xdataPat = entity.xdata["dxf.hatchPatternName"], case .string(let s) = xdataPat, !s.isEmpty, s != "SOLID", s != "GRADIENT", s != "USER" {
                    return s
                }
                return "ANSI31"
            }(),
            gradientName: {
                if case .gradient(_, _, let gName, _, _, _) = firstPrim {
                    return gName
                }
                return "LINEAR"
            }(),
            scale: Float(scale),
            angle: Float(angle), // angle is already radians
            primaryColor: color,
            backgroundColor: backgroundColor,
            secondaryColor: gradientColor2,
            selectionMode: 0,
            showModeSection: false  // hide Pick Points / Select Boundary
        )
        let oldSettings = settings
        HatchRibbonUI.render(&settings, engine: engine)
        
        // Commit changes back to the entity
        let newScale = Double(settings.scale)
        let newAngle = Double(settings.angle) // angle from ImGuiSliderAngle is radians
        
        let newPattern: String
        switch settings.fillType {
        case 1: newPattern = "SOLID"
        case 2: newPattern = "GRADIENT"
        case 3: newPattern = "USER"
        default: newPattern = settings.patternName.uppercased()
        }
        
        let newPrim: CADPrimitive
        if settings.fillType == 2 {
            let gName = settings.gradientName
            newPrim = .gradient(
                outer: outerBoundary,
                holes: holes,
                gradientName: gName,
                angle: Double(settings.angle),
                color1: settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255),
                color2: settings.secondaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            )
        } else {
            newPrim = .hatch(
                boundary: outerBoundary,
                pattern: newPattern,
                scale: newScale,
                angle: newAngle,
                color: settings.primaryColor,
                backgroundColor: settings.backgroundColor
            )
        }
            
        if settings.closeRequested {
            if settings != oldSettings {
                var newEntity = entity
                newEntity.xdata["dxf.hatchPatternName"] = .string(newPattern)
                newEntity.localGeometry = [newPrim]
                engine.document.updateEntity(newEntity)
            }
            engine.cadSelection.clearSelection()
        } else {
            if settings != oldSettings {
                var newEntity = entity
                newEntity.xdata["dxf.hatchPatternName"] = .string(newPattern)
                newEntity.localGeometry = [newPrim]
                engine.document.updateEntityLive(newEntity)
                engine.tabManager.markActiveDirty()
            }
        }
    }

}
