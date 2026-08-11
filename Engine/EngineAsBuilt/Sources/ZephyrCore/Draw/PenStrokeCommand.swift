import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PenStrokeCommand
// =========================================================================

/// Interactive pen-stroke drawing command that captures tablet pen data
/// (pressure, tilt, rotation) per vertex. Supports drawing with a pen/tablet
/// via SDL3 `CategoryPen` events, with automatic fallback to mouse input
/// using dummy pen values.
///
/// **Stabilization:** Screen-space distance threshold (4 pixels default)
/// combined with exponential moving average smoothing on position, pressure,
/// and tilt, prevents high-frequency jitter and vertex flooding.
@MainActor
public final class PenStrokeCommand: FeatureCommand {

    private static var rememberedBrushSettings: PenStrokeBrushSettings?
    private var brushSettings = PenStrokeBrushSettings.defaults(baseLineWeight: 0.25)

    // MARK: - Drawing State

    /// Accumulated vertices (smoothed, distance-filtered).
    private var vertices: [PenStrokeVertex] = []

    /// Raw mouse/pen position (screen coordinates) for the current frame.
    private var currentMouseScreenX: Float = 0
    private var currentMouseScreenY: Float = 0

    /// Whether a drawing drag is in progress (pen down or mouse left held).
    private var isDrawingDrag: Bool = false

    /// Whether the current stroke is using real pen hardware (vs mouse fallback).
    private var usingPenHardware: Bool = false

    /// Whether the eraser tip was detected on PEN_DOWN (stored for future use).
    private var isEraser: Bool = false

    // MARK: - Stabilization State

    /// Last emitted vertex position (world space), used for distance threshold.
    private var lastEmitted: Vector3 = .zero

    /// Smoothed values (EMA state).
    private var smoothedX: Double = 0
    private var smoothedY: Double = 0
    private var smoothedPressure: Double = 1.0
    private var smoothedXtilt: Double = 0.0
    private var smoothedYtilt: Double = 0.0

    /// Whether we have seeded the first vertex for this stroke.
    private var hasFirstVertex: Bool = false

    /// EMA smoothing factor (0.0 = no smoothing, 1.0 = no response).
    private let alpha: Double = 0.4

    /// Screen-space distance threshold in pixels before a new vertex is emitted.
    private var thresholdPixels: Double = 4.0

    // MARK: - Initialization

    public init() {}

    // MARK: - FeatureCommand Conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        vertices.removeAll()
        isDrawingDrag = false
        usingPenHardware = false
        isEraser = false
        hasFirstVertex = false
        lastEmitted = .zero
        smoothedX = 0
        smoothedY = 0
        smoothedPressure = 1.0
        smoothedXtilt = 0.0
        smoothedYtilt = 0.0
        currentMouseScreenX = 0
        currentMouseScreenY = 0
        let baseLineWeight = engine.document.activeLayerID
            .flatMap { engine.document.layer(for: $0)?.lineWeight } ?? 0.25
        brushSettings = Self.rememberedBrushSettings
            ?? PenStrokeBrushSettings.defaults(baseLineWeight: baseLineWeight)
        processor.commandPrompt = "PenStroke: draw with pen and release to create. Mouse: drag, then Enter to finish."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        vertices.removeAll()
        isDrawingDrag = false
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        vertices.map { $0.position }
    }

    public var isSnappingEnabled: Bool { return false }

    // MARK: - Mouse (fallback for non-pen input)

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Only process mouse clicks if pen hardware is NOT active.
        // If the pen is in proximity, pen events take precedence.
        if engine.interaction.penState.penActive && engine.interaction.penState.penDrawing {
            return .continue
        }

        // Mouse/trackpad fallback: begin drawing drag.
        isDrawingDrag = true
        usingPenHardware = false
        hasFirstVertex = false

        // Seed the initial smoothed position.
        smoothedX = worldX
        smoothedY = worldY
        smoothedPressure = 1.0
        smoothedXtilt = 0.0
        smoothedYtilt = 0.0

        let firstVertex = PenStrokeVertex.mouseFallback(at: Vector3(x: smoothedX, y: smoothedY, z: 0))
        vertices.append(firstVertex)
        lastEmitted = firstVertex.position
        hasFirstVertex = true

        processor.commandPrompt = "PenStroke: drawing with mouse. Release to pause, Enter to finish."
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseScreenX = Float(worldX)
        currentMouseScreenY = Float(worldY)

        // If pen hardware is active, ignore standard mouse motion
        // (pen axis/motion events are handled via the pen state path below).
        if engine.interaction.penState.penActive && engine.interaction.penState.penDrawing {
            return
        }

        // Mouse fallback: accumulate if dragging.
        guard isDrawingDrag else { return }
        accumulatePoint(worldX: worldX, worldY: worldY, engine: engine)
    }

    // MARK: - Keyboard

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_SPACE:
            return finalize(engine: engine, processor: processor)
        case SDL_SCANCODE_ESCAPE:
            if vertices.count >= 2 {
                return finalize(engine: engine, processor: processor)
            }
            processor.commandPrompt = "PenStroke cancelled."
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Allow the user to type a pixel threshold override.
        if let pixels = Double(text), pixels > 0 {
            thresholdPixels = pixels
            processor.commandPrompt = "PenStroke: threshold set to \(Int(pixels)) px. Draw or Enter to finish."
            return .continue
        }
        return .continue
    }

    // MARK: - Per-Frame Pen Polling

    /// Called every frame from the render loop so the command can read
    /// the latest pen state and accumulate vertices during an active drag.
    public func pollPenState(engine: PhrostEngine) {
        let pen = engine.interaction.penState

        // Detect pen-based draw start. If a synthetic mouse event reached us first,
        // promote that fallback drag to a real pen drag instead of locking pressure at 1.0.
        if pen.penActive && pen.penDrawing && (!isDrawingDrag || !usingPenHardware) {
            let replacingMouseFallback = isDrawingDrag && !usingPenHardware && !vertices.isEmpty
            isDrawingDrag = true
            usingPenHardware = true
            isEraser = pen.isEraser
            hasFirstVertex = false

            // Seed the initial smoothed position from world-space pen coords.
            smoothedX = pen.worldX
            smoothedY = pen.worldY
            smoothedPressure = max(0.0, min(1.0, pen.pressure))
            smoothedXtilt = pen.xtilt
            smoothedYtilt = pen.ytilt

            let firstVertex = PenStrokeVertex(
                position: Vector3(x: smoothedX, y: smoothedY, z: 0),
                pressure: smoothedPressure,
                xtilt: smoothedXtilt,
                ytilt: smoothedYtilt,
                rotation: pen.rotation)
            if replacingMouseFallback {
                vertices[vertices.count - 1] = firstVertex
            } else {
                vertices.append(firstVertex)
            }
            lastEmitted = firstVertex.position
            hasFirstVertex = true

            engine.commandProcessor.commandPrompt = "PenStroke: drawing with pen. Release to create stroke."
            return
        }

        // Detect pen-based drag end.
        if !pen.penDrawing && isDrawingDrag && usingPenHardware {
            // Emit the final vertex on pen up (unconditionally, to capture the endpoint).
            if let lastV = vertices.last {
                let finalPos = Vector3(x: smoothedX, y: smoothedY, z: 0)
                if finalPos.distance(to: lastV.position) > 0.001 {
                    vertices.append(PenStrokeVertex(
                        position: finalPos,
                        pressure: smoothedPressure,
                        xtilt: smoothedXtilt,
                        ytilt: smoothedYtilt,
                        rotation: pen.rotation))
                }
            }
            isDrawingDrag = false

            if vertices.count >= 2 {
                let result = finalize(engine: engine, processor: engine.commandProcessor)
                if result == .finished {
                    engine.commandProcessor.finishFeatureCommand(engine: engine)
                }
            }
            return
        }

        // During an active pen drag, accumulate stabilized vertices.
        if pen.penActive && pen.penDrawing && isDrawingDrag && usingPenHardware {
            accumulatePoint(worldX: pen.worldX, worldY: pen.worldY, engine: engine)
        }
    }

    // MARK: - Stabilization

    /// Apply EMA smoothing and distance filtering, then conditionally emit a vertex.
    private func accumulatePoint(worldX: Double, worldY: Double, engine: PhrostEngine) {
        let pen = engine.interaction.penState

        // EMA smoothing on position.
        if hasFirstVertex {
            smoothedX = alpha * worldX + (1.0 - alpha) * smoothedX
            smoothedY = alpha * worldY + (1.0 - alpha) * smoothedY
        } else {
            smoothedX = worldX
            smoothedY = worldY
        }

        // EMA smoothing on pressure/tilt (use pen values if available, else defaults).
        if usingPenHardware {
            let pressure = max(0.0, min(1.0, pen.pressure))
            smoothedPressure = alpha * pressure + (1.0 - alpha) * smoothedPressure
            smoothedXtilt = alpha * pen.xtilt + (1.0 - alpha) * smoothedXtilt
            smoothedYtilt = alpha * pen.ytilt + (1.0 - alpha) * smoothedYtilt
        } else {
            smoothedPressure = 1.0
            smoothedXtilt = 0.0
            smoothedYtilt = 0.0
        }

        let candidate = Vector3(x: smoothedX, y: smoothedY, z: 0)

        // Screen-space distance threshold → world-space.
        let thresholdWorld = thresholdPixels / engine.camera.zoom

        // Only emit if distance > threshold.
        if candidate.distance(to: lastEmitted) > thresholdWorld {
            let vertex = PenStrokeVertex(
                position: candidate,
                pressure: smoothedPressure,
                xtilt: smoothedXtilt,
                ytilt: smoothedYtilt,
                rotation: usingPenHardware ? pen.rotation : 0.0)
            vertices.append(vertex)
            lastEmitted = candidate
        }
    }

    // MARK: - Finalize

    private func finalize(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard vertices.count >= 2 else {
            processor.commandPrompt = "PenStroke: need at least 2 vertices to create a stroke."
            return .continue
        }

        let layerID = engine.document.activeLayerID ?? UUID()
        let layer = engine.document.layer(for: layerID)
        let baseLineWeight = layer?.lineWeight ?? 0.25

        let prim: CADPrimitive = .penStroke(
            vertices: vertices,
            baseLineWeight: baseLineWeight,
            color: nil)
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [prim])
        brushSettings.apply(to: &entity)
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()

        let mode = usingPenHardware ? "pen" : "mouse"
        processor.commandPrompt = "PenStroke created (\(vertices.count) vertices, \(mode) input)."
        return .finished
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let strokeCol = makeCol32(0, 200, 255, 220)

        if vertices.count >= 2 {
            for i in 0..<(vertices.count - 1) {
                let first = vertices[i]
                let second = vertices[i + 1]
                let p1 = EngineCameraManager.worldToScreen(
                    worldX: first.position.x, worldY: first.position.y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(
                    worldX: second.position.x, worldY: second.position.y, cam: cam)
                let segmentAngle = atan2(
                    second.position.y - first.position.y,
                    second.position.x - first.position.x)
                let thickness = brushSettings.pixelWidth(
                    from: first,
                    to: second,
                    segmentAngle: segmentAngle)
                ImDrawListAddLine(
                    drawList,
                    ImVec2(x: p1.x, y: p1.y),
                    ImVec2(x: p2.x, y: p2.y),
                    strokeCol,
                    thickness)
            }
        }

        // Draw rubber-band line from last vertex to current mouse position.
        if let lastV = vertices.last, isDrawingDrag {
            let lp = EngineCameraManager.worldToScreen(
                worldX: lastV.position.x, worldY: lastV.position.y, cam: cam)
            let cp = EngineCameraManager.worldToScreen(
                worldX: smoothedX, worldY: smoothedY, cam: cam)
            let current = PenStrokeVertex(
                position: Vector3(x: smoothedX, y: smoothedY, z: 0),
                pressure: smoothedPressure,
                xtilt: smoothedXtilt,
                ytilt: smoothedYtilt,
                rotation: engine.interaction.penState.rotation)
            let segmentAngle = atan2(
                current.position.y - lastV.position.y,
                current.position.x - lastV.position.x)
            let thickness = brushSettings.pixelWidth(
                from: lastV,
                to: current,
                segmentAngle: segmentAngle)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: lp.x, y: lp.y),
                ImVec2(x: cp.x, y: cp.y),
                strokeCol,
                thickness)
        }
    }

    public func renderImGui(engine: PhrostEngine) {
        pollPenState(engine: engine)
        guard engine.commandProcessor.activeFeatureCommand === self else { return }
        renderBrushSettings(engine: engine)
    }

    private func renderBrushSettings(engine: PhrostEngine) {
        let io = ImGuiGetIO()!.pointee
        let scale = max(0.75, engine.effectiveUiScale)
        let width = min(max(460.0 * scale, io.DisplaySize.x * 0.52), io.DisplaySize.x - 32.0 * scale)
        let viewportTop = engine.ui.drawingViewportRect?.y ?? 80.0
        let y = viewportTop + 54.0 * scale

        ImGuiSetNextWindowPos(
            ImVec2(x: io.DisplaySize.x * 0.5, y: y),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0.5, y: 0.0))
        ImGuiSetNextWindowSize(
            ImVec2(x: width, y: 0),
            Int32(ImGuiCond_Always.rawValue))

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)
            | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 12.0 * scale)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 8.0 * scale)
        defer { ImGuiPopStyleVar(2) }

        var opened = true
        guard igBegin("##PenStrokeBrush", &opened, flags) else {
            igEnd()
            return
        }
        defer { igEnd() }

        var minWidth = Float(brushSettings.minLineWeight)
        var maxWidth = Float(brushSettings.maxLineWeight)
        var tiltPercent = Float(brushSettings.tiltInfluence * 100.0)
        var rotationPercent = Float(brushSettings.rotationInfluence * 100.0)
        var changed = false

        ImGuiTextV("Pen Brush")
        ImGuiSameLine(0, 16.0 * scale)
        ImGuiTextV("Min")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(96.0 * scale)
        if ImGuiDragFloat("##PenMinWidth", &minWidth, 0.01, 0.01, 5.0, "%.2f mm", 0) { changed = true }
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 12.0 * scale)
        ImGuiTextV("Max")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(96.0 * scale)
        if ImGuiDragFloat("##PenMaxWidth", &maxWidth, 0.01, 0.01, 10.0, "%.2f mm", 0) { changed = true }
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 16.0 * scale)
        ImGuiTextV("Pressure maps Min → Max")

        ImGuiTextV("Tilt")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(180.0 * scale)
        if ImGuiSliderFloat("##PenTiltInfluence", &tiltPercent, 0.0, 100.0, "%.0f%%", 0) { changed = true }
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 16.0 * scale)
        ImGuiTextV("Rotation")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(180.0 * scale)
        if ImGuiSliderFloat("##PenRotationInfluence", &rotationPercent, 0.0, 100.0, "%.0f%%", 0) { changed = true }
        ImGuiPopItemWidth()

        if engine.interaction.penState.penActive {
            let pen = engine.interaction.penState
            ImGuiSameLine(0, 16.0 * scale)
            ImGuiTextV(String(format: "P %.2f  Tilt %.0f°/%.0f°  Rot %.0f°",
                              pen.pressure, pen.xtilt, pen.ytilt, pen.rotation))
        }

        if changed {
            let minValue = max(0.01, Double(minWidth))
            let maxValue = max(minValue, Double(maxWidth))
            brushSettings = PenStrokeBrushSettings(
                minLineWeight: minValue,
                maxLineWeight: maxValue,
                tiltInfluence: Double(tiltPercent) / 100.0,
                rotationInfluence: Double(rotationPercent) / 100.0)
            Self.rememberedBrushSettings = brushSettings
        }
    }
}
