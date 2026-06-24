import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - SplineEditCommand
// =========================================================================

/// Interactive command to edit splines (Convert to Polyline, Close, Reverse, etc.).
@MainActor
public final class SplineEditCommand: FeatureCommand {

    private enum State {
        case selecting
        case menuOpen
        case promptingPrecision
        case finished
    }

    private var state: State = .selecting
    private var targetHandle: UUID?

    // UI state
    private var openMenuNextFrame = false
    private var openPromptNextFrame = false
    private var precisionSegments: Int32 = 12
    private var popupScreenX: Float = 0
    private var popupScreenY: Float = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[SplineEditCommand] start called")
        state = .selecting
        targetHandle = nil
        processor.commandPrompt = "Select a spline to edit (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[SplineEditCommand] cancel called")
        state = .finished
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }
    public var isSnappingEnabled: Bool { return state == .selecting }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if state == .selecting {
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom
            )
            
            if let handle = hitHandle,
               let entity = engine.document.entity(for: handle) {
                // Check if it has a spline primitive
                let hasSpline = entity.localGeometry?.contains { prim in
                    if case .spline = prim { return true }
                    return false
                } ?? false
                
                if hasSpline {
                    targetHandle = handle
                    state = .menuOpen
                    openMenuNextFrame = true
                    
                    let screenPos = EngineCameraManager.worldToScreen(worldX: worldX, worldY: worldY, cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                    popupScreenX = Float(screenPos.x)
                    popupScreenY = Float(screenPos.y)
                    
                    processor.commandPrompt = "Spline selected. Choose an option."
                    return .continue
                }
            }
        }
        
        if state == .finished {
            return .finished
        }
        
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            state = .finished
            return .finished
        }
        return state == .finished ? .finished : .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        if state == .finished { return }

        if openMenuNextFrame {
            ImGuiSetNextWindowPos(ImVec2(x: popupScreenX, y: popupScreenY), Int32(ImGuiCond_Appearing.rawValue), ImVec2(x: 0, y: 0))
            ImGuiOpenPopup("SplineEditMenu", Int32(ImGuiPopupFlags_None.rawValue))
            openMenuNextFrame = false
        }

        if ImGuiBeginPopup("SplineEditMenu", Int32(ImGuiPopupFlags_None.rawValue)) {
            ImGuiTextV("SplineEdit Options")
            ImGuiSeparator()
            
            if ImGuiButton("Close/Open", ImVec2(x: 150, y: 0)) {
                // Stub for now
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            if ImGuiButton("Join (Stub)", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            if ImGuiButton("Fit Data (Stub)", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            if ImGuiButton("Edit Vertex (Stub)", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            if ImGuiButton("Convert to Polyline", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .promptingPrecision
                openPromptNextFrame = true
            }
            if ImGuiButton("Reverse", ImVec2(x: 150, y: 0)) {
                applyReverse(engine: engine)
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            ImGuiSeparator()
            if ImGuiButton("Exit", ImVec2(x: 150, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            ImGuiEndPopup()
        }

        if openPromptNextFrame {
            ImGuiOpenPopup("Convert Spline", Int32(ImGuiPopupFlags_None.rawValue))
            openPromptNextFrame = false
        }

        var p_open = true
        let flags = Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)
        if ImGuiBeginPopupModal("Convert Spline", &p_open, flags) {
            ImGuiTextV("Enter precision (number of segments per span):")
            
            ImGuiInputInt("##segments", &precisionSegments, 1, 10, 0)
            if precisionSegments < 1 { precisionSegments = 1 }
            
            if ImGuiButton("Convert", ImVec2(x: 120, y: 0)) {
                applyConvert(engine: engine)
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            ImGuiSameLine(0, -1)
            if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
                ImGuiCloseCurrentPopup()
                state = .finished
            }
            ImGuiEndPopup()
        }
        
        if state == .finished {
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }

    // MARK: - Actions

    private func applyReverse(engine: PhrostEngine) {
        guard let handle = targetHandle,
              let entity = engine.document.entity(for: handle) else { return }

        var newGeom = entity.localGeometry ?? []
        for i in 0..<newGeom.count {
            if case let .spline(cps, knots, degree, weights, color) = newGeom[i] {
                // Reverse control points and weights
                let revCPs = Array(cps.reversed())
                let revW = weights.map { Array($0.reversed()) }
                
                // Reverse knots: t_new[i] = max_knot - t[n - i]
                let maxKnot = knots.last ?? 1.0
                let minKnot = knots.first ?? 0.0
                let revKnots = knots.reversed().map { maxKnot - ($0 - minKnot) }
                
                newGeom[i] = .spline(controlPoints: revCPs, knots: revKnots, degree: degree, weights: revW, color: color)
            }
        }
        
        engine.document.updateEntityGeometry(for: handle, geometry: newGeom)
        engine.tabManager.markActiveDirty()
        engine.commandProcessor.commandPrompt = "Spline reversed."
    }

    private func applyConvert(engine: PhrostEngine) {
        guard let handle = targetHandle,
              let entity = engine.document.entity(for: handle) else { return }

        var newGeom = entity.localGeometry ?? []
        var convertedAny = false
        
        for i in 0..<newGeom.count {
            if case let .spline(cps, knots, degree, weights, color) = newGeom[i] {
                let pts = NURBSEvaluator.evaluate(
                    degree: degree,
                    knots: knots,
                    controlPoints: cps,
                    weights: weights,
                    segments: Int(precisionSegments)
                )
                
                if pts.count >= 2 {
                    // Replace with line segments
                    var lines: [CADPrimitive] = []
                    for j in 0..<(pts.count - 1) {
                        lines.append(.line(start: pts[j], end: pts[j+1], color: color))
                    }
                    newGeom.remove(at: i)
                    newGeom.insert(contentsOf: lines, at: i)
                    convertedAny = true
                    break // Assumes only 1 spline to convert for simplicity
                }
            }
        }
        
        if convertedAny {
            engine.document.updateEntityGeometry(for: handle, geometry: newGeom)
            engine.tabManager.markActiveDirty()
            engine.commandProcessor.commandPrompt = "Spline converted to polyline."
        }
    }
}
