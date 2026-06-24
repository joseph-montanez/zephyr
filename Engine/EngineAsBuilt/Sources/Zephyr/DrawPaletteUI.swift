import ZephyrCore
import Foundation
import ImGui

// MARK: - DrawPaletteUI
//
// Renders a floating palette of drawing tool buttons in a 2-column grid.
// Each button executes the corresponding drawing command (LINE, CIRCLE, etc.).
// The currently active drawing command is highlighted with a distinct color
// to indicate which tool is armed and awaiting input.
//
// Tools listed: Line, Polyline, Circle, Arc, Rectangle, Ellipse, Hatch, Spline, Ray

@MainActor
struct DrawPaletteUI {
    /// Track docking state of this window.
    static var _isDocked: Bool = false
    static func render(engine: PhrostEngine) {
        // Tool definitions: (display label, canonical command name)
        let tools: [(String, String)] = [
            ("Line", "LINE"),
            ("Polyline", "POLYLINE"),
            ("Circle", "CIRCLE"),
            ("Arc", "ARC"),
            ("Rectangle", "RECTANGLE"),
            ("Ellipse", "ELLIPSE"),
            ("Hatch", "HATCH"),
            ("Spline", "SPLINE"),
            ("Ray", "RAY"),
            ("Text", "TEXT"),
            ("Image", "IMAGE"),
        ]

        // Calculate the widest button needed for consistent sizing.
        var btnW: Float = 60
        for (label, _) in tools {
            let sz = ImGuiCalcTextSize(label, nil, false, -1)
            if sz.x > btnW { btnW = sz.x }
        }
        let framePadX = ImGuiGetStyle()!.pointee.FramePadding.x * 2
        btnW += framePadX + 10

        let cols: Float = 2
        let panelW = btnW * cols + 24
        let rowH = ImGuiGetFrameHeight() + 2
        let panelH = Float(tools.count) / cols * rowH + 40

        ImGuiSetNextWindowPos(
            ImVec2(x: 4 + panelW + 8, y: AppLayout.belowToolbarY + 4),
            Int32(ImGuiCond_FirstUseEver.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: panelW, y: panelH),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDocked
        var flags: Int32 = 0
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Draw Tools##DrawPalette", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Draw Tools##DrawPalette", &opened, flags)
        }

        if entered {
            _isDocked = ImGuiIsWindowDocked()
            defer { 
                ImGuiEnd() 
                ImGuiPopStyleVar(1)
                ImGuiPopStyleColor(1)
            }
            if !isDocked && !opened { engine.ui.drawPaletteVisible = false; return }

            ImGuiTextV("Draw Tools")
            igSeparator()

            let isDrawingActive = engine.commandProcessor.activeFeatureCommand != nil

            var col = 0
            for (label, cmdName) in tools {
                if col > 0 { ImGuiSameLine(0, 4) }

                let isActive = isDrawingActive && isCurrentDrawCommand(engine, cmdName)

                // Highlight the button for the currently active drawing command.
                if isActive {
                    ImGuiPushStyleColor(
                        Int32(ImGuiCol_Button.rawValue),
                        engine.ui.theme.activeBg)
                }

                if igButton(label, ImVec2(x: btnW, y: 0)) {
                    engine.commandProcessor.executeCommand(cmdName)
                }

                if isActive {
                    ImGuiPopStyleColor(1)
                }

                col += 1
                if col >= Int(cols) { col = 0 }
            }
        }
    }

    /// Checks whether the given command name matches the currently active feature command.
    /// Used to highlight the active tool button in the draw palette.
    private static func isCurrentDrawCommand(_ engine: PhrostEngine, _ cmdName: String) -> Bool {

        guard let cmd = engine.commandProcessor.activeFeatureCommand else { return false }
        switch cmdName {
        case "LINE": return cmd is LineCommand
        case "POLYLINE": return cmd is PolylineCommand
        case "CIRCLE": return cmd is CircleCommand
        case "ARC": return cmd is ArcCommand
        case "RECTANGLE": return cmd is RectangleCommand
        case "ELLIPSE": return cmd is EllipseCommand
        case "HATCH": return cmd is HatchCommand
        case "SPLINE": return cmd is SplineCommand
        case "RAY": return cmd is RayCommand
        case "TEXT": return cmd is TextCommand
        case "IMAGE": return cmd is ImageCommand
        default: return false
        }
    }

}
