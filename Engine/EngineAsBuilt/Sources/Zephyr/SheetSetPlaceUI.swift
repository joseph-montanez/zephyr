import ZephyrCore
import Foundation
import ImGui

// MARK: - SheetSetPlaceUI
//
// "Place on Sheet" modal for one Sheet Views entry: picks scale and paper
// center, then runs the one-shot `placeSheetView` (attach + instance +
// viewport) onto the active sheet tab. The sheet must already be open and
// active; model file and view bounds come from the Sheet Views group row.

/// Mutable placement state, owned by the palette (`inout` each frame).
struct SheetSetPlaceState {
    var active = false
    var opened = false
    var modelPath = ""
    var viewName = ""
    var modelCenterX = 0.0
    var modelCenterY = 0.0
    var modelWidth = 0.0
    var modelHeight = 0.0
    var scaleText = "50"
    var centerXText = "0"
    var centerYText = "0"
    var error = ""

    mutating func begin(
        modelPath: String, view: SheetSetSheetViews.NamedView, paperCenterX: Double, paperCenterY: Double
    ) {
        active = true
        opened = false
        self.modelPath = modelPath
        viewName = view.name
        modelCenterX = view.targetX
        modelCenterY = view.targetY
        modelWidth = view.width
        modelHeight = view.height
        scaleText = "50"
        centerXText = formatNumber(paperCenterX)
        centerYText = formatNumber(paperCenterY)
        error = ""
    }

    mutating func reset() {
        active = false
        opened = false
        modelPath = ""
        viewName = ""
        error = ""
    }
}

private func formatNumber(_ value: Double) -> String {
    if value.truncatingRemainder(dividingBy: 1) == 0 {
        return String(Int(value))
    }
    return String(value)
}

@MainActor
enum SheetSetPlaceUI {
    static let popupID = "Place View on Sheet##SheetSetPlaceView"

    static func render(engine: PhrostEngine, state: inout SheetSetPlaceState) {
        guard state.active else { return }
        if !state.opened {
            state.opened = true
            ImGuiOpenPopup(popupID, Int32(ImGuiPopupFlags_None.rawValue))
        }
        var open = true
        let flags = Int32(ImGuiWindowFlags_NoCollapse.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        guard ImGuiBeginPopupModal(popupID, &open, flags) else { return }
        defer { ImGuiEndPopup() }
        if !open {
            state.reset()
            return
        }
        let fileName = URL(fileURLWithPath: state.modelPath).lastPathComponent
        ImGuiTextV("Model: \(fileName)")
        ImGuiTextV("View: \(state.viewName)")
        ImGuiTextV("Scale 1:")
        ImGuiSameLine(0, 6)
        state.scaleText = SheetSetManagerUI.inputText("##PlaceScale", value: state.scaleText)
        ImGuiSameLine(0, 6)
        for quick in ["10", "20", "50", "100"] {
            if igSmallButton(quick) {
                state.scaleText = quick
            }
            ImGuiSameLine(0, 4)
        }
        ImGuiTextV("")
        ImGuiTextV("Paper center X:")
        ImGuiSameLine(0, 6)
        state.centerXText = SheetSetManagerUI.inputText("##PlaceCX", value: state.centerXText)
        ImGuiTextV("Paper center Y:")
        ImGuiSameLine(0, 6)
        state.centerYText = SheetSetManagerUI.inputText("##PlaceCY", value: state.centerYText)
        if let scale = Double(state.scaleText.trimmingCharacters(in: .whitespacesAndNewlines)),
           scale > 0, state.modelWidth > 0, state.modelHeight > 0 {
            let frameW = state.modelWidth / scale
            let frameH = state.modelHeight / scale
            ImGuiTextV("Frame: \(formatNumber(frameW)) x \(formatNumber(frameH)) paper units at 1:\(state.scaleText).")
        } else {
            ImGuiTextV("Enter a positive scale denominator.")
        }
        if let tab = engine.tabManager.activeTab,
           tab.drawingViews.indices.contains(tab.activeViewIndex),
           tab.drawingViews[tab.activeViewIndex].kind == .sheet {
            ImGuiTextV("Sheet: \(tab.drawingViews[tab.activeViewIndex].name)")
        } else {
            ImGuiTextV("Activate a sheet (layout) tab to place onto.")
        }
        if !state.error.isEmpty {
            ImGuiTextV("Error: \(state.error)")
        }
        if igButton("Place", ImVec2(x: 0, y: 0)) {
            place(engine: engine, state: &state)
        }
        ImGuiSameLine(0, 6)
        if igButton("Pick point", ImVec2(x: 0, y: 0)) {
            pickPoint(engine: engine, state: &state)
        }
        ImGuiSameLine(0, 6)
        if igButton("Cancel", ImVec2(x: 0, y: 0)) {
            ImGuiCloseCurrentPopup()
            state.reset()
        }
    }

    /// Hands the pending placement to the PLACEVIEW command, which prompts
    /// for a canvas click. The modal closes; the command does the rest.
    private static func pickPoint(engine: PhrostEngine, state: inout SheetSetPlaceState) {
        guard let scale = Double(state.scaleText.trimmingCharacters(in: .whitespacesAndNewlines)),
              scale > 0
        else {
            state.error = "Scale must be a positive number."
            return
        }
        let viewName = state.viewName.replacingOccurrences(of: "\"", with: "")
        engine.commandProcessor.executeCommand(
            "PLACEVIEW \"\(state.modelPath)\" \"\(viewName)\" \(scale)")
        ImGuiCloseCurrentPopup()
        state.reset()
    }

    private static func place(engine: PhrostEngine, state: inout SheetSetPlaceState) {
        guard let tab = engine.tabManager.activeTab,
              tab.drawingViews.indices.contains(tab.activeViewIndex),
              tab.drawingViews[tab.activeViewIndex].kind == .sheet
        else {
            state.error = "Activate a sheet (layout) tab first."
            return
        }
        guard let scale = Double(state.scaleText.trimmingCharacters(in: .whitespacesAndNewlines)),
              scale > 0
        else {
            state.error = "Scale must be a positive number."
            return
        }
        guard let cx = Double(state.centerXText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let cy = Double(state.centerYText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            state.error = "Paper center must be two numbers."
            return
        }
        do {
            let placed = try engine.tabManager.placeSheetView(
                modelFileURL: URL(fileURLWithPath: state.modelPath),
                modelCenterX: state.modelCenterX, modelCenterY: state.modelCenterY,
                modelWidth: state.modelWidth, modelHeight: state.modelHeight,
                paperCenterXUp: cx, paperCenterYUp: cy,
                scaleDenominator: scale)
            print("[SheetSet] Placed '\(state.viewName)' as viewport \(placed.viewportID).")
            ImGuiCloseCurrentPopup()
            state.reset()
        } catch {
            state.error = error.localizedDescription
        }
    }
}
