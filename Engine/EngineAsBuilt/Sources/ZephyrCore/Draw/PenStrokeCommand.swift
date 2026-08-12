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
/// **Stabilization:** A user-controlled amount drives screen-space sampling,
/// exponential smoothing, and the final rational-spline simplification pass.
@MainActor
public final class PenStrokeCommand: FeatureCommand {

    private static var rememberedBrushSettings: PenStrokeBrushSettings?
    private static var rememberedStabilizationSettings: PenStrokeStabilizationSettings?
    private static var rememberedEraserDiameterPixels: Double = 36.0
    private var brushSettings = PenStrokeBrushSettings.defaults(baseLineWeight: 0.25)
    private var stabilizationSettings = PenStrokeStabilizationSettings.defaults
    private var thresholdPixelsOverride: Double?

    // MARK: - Eraser State

    private var eraseMode = false
    private var eraserDiameterPixels: Double = 36.0
    private var isErasingDrag = false
    private var eraseUndoSnapshot: CADDocumentSnapshot?
    private var eraseDidModify = false
    private var lastEraseWorld: Vector3?
    private var eraserCursorWorld: Vector3?

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
        stabilizationSettings = Self.rememberedStabilizationSettings
            ?? PenStrokeStabilizationSettings.defaults
        thresholdPixelsOverride = nil
        eraseMode = false
        eraserDiameterPixels = Self.rememberedEraserDiameterPixels
        isErasingDrag = false
        eraseUndoSnapshot = nil
        eraseDidModify = false
        lastEraseWorld = nil
        eraserCursorWorld = nil
        processor.commandPrompt = "PenStroke: draw with pen. E toggles vector eraser; Enter/Esc ends the command."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finishEraseSession(engine: engine)
        vertices.removeAll()
        isDrawingDrag = false
        isErasingDrag = false
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
        eraserCursorWorld = Vector3(x: worldX, y: worldY, z: 0)
        if eraseMode && !(engine.interaction.penState.penActive && engine.interaction.penState.penDrawing) {
            resetCurrentStroke()
            usingPenHardware = false
            isErasingDrag = true
            beginEraseSession(engine: engine)
            eraseAlongSweep(to: Vector3(x: worldX, y: worldY, z: 0), engine: engine)
            processor.commandPrompt = "PenStroke Erase: drag across vectors. Release pauses; E returns to Draw."
            return .handled
        }

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
        eraserCursorWorld = Vector3(x: worldX, y: worldY, z: 0)

        if eraseMode && isErasingDrag && !usingPenHardware {
            eraseAlongSweep(to: Vector3(x: worldX, y: worldY, z: 0), engine: engine)
            return
        }

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
        case SDL_SCANCODE_E:
            finishEraseSession(engine: engine)
            resetCurrentStroke()
            eraseMode.toggle()
            processor.commandPrompt = eraseMode
                ? "PenStroke Erase: drag the eraser circle across vectors. E returns to Draw."
                : "PenStroke Draw: draw with pen. E toggles vector eraser; Enter/Esc ends command."
            return .handled
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            finishEraseSession(engine: engine)
            if vertices.count >= 2 {
                _ = commitCurrentStroke(engine: engine, processor: processor)
            }
            processor.commandPrompt = "PenStroke finished."
            return .finished
        case SDL_SCANCODE_ESCAPE:
            finishEraseSession(engine: engine)
            resetCurrentStroke()
            processor.commandPrompt = "PenStroke cancelled."
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if let pixels = Double(text), pixels > 0 {
            thresholdPixelsOverride = pixels
            processor.commandPrompt = "PenStroke: sampling threshold override set to \(String(format: "%.1f", pixels)) px."
            return .continue
        }
        return .continue
    }

    // MARK: - Per-Frame Pen Polling

    /// Called every frame from the render loop so the command can read
    /// the latest pen state and accumulate vertices during an active drag.
    public func pollPenState(engine: PhrostEngine) {
        let pen = engine.interaction.penState
        if pen.penActive {
            eraserCursorWorld = Vector3(x: pen.worldX, y: pen.worldY, z: 0)
        }

        let wantsErase = eraseMode || pen.isEraser
        if pen.penActive && pen.penDrawing && wantsErase {
            if !isErasingDrag {
                resetCurrentStroke()
                isErasingDrag = true
                lastEraseWorld = nil
                beginEraseSession(engine: engine)
            }
            usingPenHardware = true
            isEraser = true
            eraseAlongSweep(
                to: Vector3(x: pen.worldX, y: pen.worldY, z: 0),
                engine: engine)
            engine.commandProcessor.commandPrompt = "PenStroke Erase: release pauses; continue erasing or press E/Enter/Esc."
            return
        }

        if !pen.penDrawing && isErasingDrag && usingPenHardware {
            finishEraseSession(engine: engine)
            usingPenHardware = false
            isEraser = false
            engine.commandProcessor.commandPrompt = "PenStroke: erase pass complete. Erase again, press E to draw, or Enter/Esc to finish."
            return
        }

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

            engine.commandProcessor.commandPrompt = "PenStroke: drawing with pen. Release creates stroke; Enter/Esc ends command."
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

            if commitCurrentStroke(engine: engine, processor: engine.commandProcessor) {
                engine.commandProcessor.commandPrompt = "PenStroke: stroke created. Draw another or press Enter/Esc to finish."
            } else {
                resetCurrentStroke()
                engine.commandProcessor.commandPrompt = "PenStroke: draw another stroke or press Enter/Esc to finish."
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

        let alpha = stabilizationSettings.inputAlpha

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
        let thresholdPixels = thresholdPixelsOverride ?? stabilizationSettings.inputThresholdPixels
        let thresholdWorld = thresholdPixels / max(engine.camera.zoom, 0.001)

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

    // MARK: - Vector Eraser

    private func beginEraseSession(engine: PhrostEngine) {
        guard eraseUndoSnapshot == nil else { return }
        eraseUndoSnapshot = engine.document.snapshot()
        eraseDidModify = false
        lastEraseWorld = nil
        if !engine.document.entityGridBuilt {
            engine.document.rebuildEntityGrid()
        }
    }

    private func eraseAlongSweep(to worldPoint: Vector3, engine: PhrostEngine) {
        beginEraseSession(engine: engine)
        eraserCursorWorld = worldPoint

        let radiusWorld = max(1e-9, (eraserDiameterPixels * 0.5) / max(engine.camera.zoom, 0.001))
        let start = lastEraseWorld ?? worldPoint
        let modified = PenVectorEraser.eraseSweep(
            from: start,
            to: worldPoint,
            radius: radiusWorld,
            document: engine.document)

        lastEraseWorld = worldPoint
        if modified {
            eraseDidModify = true
            engine.cadSelection.clearSelection()
            engine.tabManager.markActiveDirty()
        }
    }

    private func finishEraseSession(engine: PhrostEngine) {
        if eraseDidModify, let snapshot = eraseUndoSnapshot {
            engine.document.pushUndo(snapshot)
            engine.document.invalidateEntityGrid()
            engine.tabManager.markActiveDirty()
        }
        eraseUndoSnapshot = nil
        eraseDidModify = false
        lastEraseWorld = nil
        isErasingDrag = false
    }

    // MARK: - Finalize

    private func resetCurrentStroke() {
        vertices.removeAll(keepingCapacity: true)
        isDrawingDrag = false
        usingPenHardware = false
        isEraser = false
        hasFirstVertex = false
        lastEmitted = .zero
        smoothedPressure = 1.0
        smoothedXtilt = 0.0
        smoothedYtilt = 0.0
    }

    @discardableResult
    private func commitCurrentStroke(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        guard vertices.count >= 2 else {
            resetCurrentStroke()
            return false
        }

        let layerID = engine.document.activeLayerID ?? UUID()
        let layer = engine.document.layer(for: layerID)
        let baseLineWeight = layer?.lineWeight ?? 0.25

        // Store the simplified fit points, not the dense tablet samples. The
        // spline renderer solves its own NURBS control polygon from these points,
        // so selection grips reflect the actual stabilization level as well.
        let storedVertices: [PenStrokeVertex]
        if stabilizationSettings.useSpline,
           let fit = PenStrokeSplineFitter.fit(
            vertices: vertices,
            settings: stabilizationSettings,
            simplifyInput: true) {
            storedVertices = fit.fitVertices
        } else {
            storedVertices = vertices
        }

        let prim: CADPrimitive = .penStroke(
            vertices: storedVertices,
            baseLineWeight: baseLineWeight,
            color: nil)
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [prim])
        brushSettings.apply(to: &entity)
        var storedStabilization = stabilizationSettings
        storedStabilization.fitPointsStored = stabilizationSettings.useSpline
        storedStabilization.apply(to: &entity)
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        resetCurrentStroke()
        return true
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let strokeCol = makeCol32(0, 200, 255, 220)

        let pen = engine.interaction.penState
        let showingEraser = eraseMode || (pen.penActive && pen.isEraser)
        if showingEraser, let cursor = eraserCursorWorld {
            let screen = EngineCameraManager.worldToScreen(
                worldX: cursor.x, worldY: cursor.y, cam: cam)
            let eraseColor = makeCol32(255, 120, 80, 235)
            ImDrawListAddCircle(
                drawList,
                ImVec2(x: screen.x, y: screen.y),
                Float(eraserDiameterPixels * 0.5),
                eraseColor,
                48,
                2.0)
            return
        }

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
        if isErasingDrag && !usingPenHardware,
           let io = ImGuiGetIO(), !io.pointee.MouseDown.0 {
            finishEraseSession(engine: engine)
            engine.commandProcessor.commandPrompt = "PenStroke: erase pass complete. Erase again, press E to draw, or Enter/Esc to finish."
        }
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
        var stabilizationPercent = Float(stabilizationSettings.amount * 100.0)
        var splineFinal = stabilizationSettings.useSpline
        var eraseEnabled = eraseMode
        var eraserSize = Float(eraserDiameterPixels)
        var changed = false
        var stabilizationChanged = false
        var eraserChanged = false

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

        ImGuiTextV("Stabilize")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(180.0 * scale)
        if ImGuiSliderFloat("##PenStabilization", &stabilizationPercent, 0.0, 100.0, "%.0f%%", 0) {
            stabilizationChanged = true
        }
        ImGuiPopItemWidth()
        ImGuiSameLine(0, 16.0 * scale)
        if ImGuiCheckbox("Spline final", &splineFinal) {
            stabilizationChanged = true
        }
        ImGuiSameLine(0, 12.0 * scale)
        ImGuiTextV("Live: lines  Final: simplified rational spline")

        if ImGuiCheckbox("Erase (E)", &eraseEnabled) {
            eraserChanged = true
        }
        ImGuiSameLine(0, 12.0 * scale)
        ImGuiTextV("Size")
        ImGuiSameLine(0, 4.0 * scale)
        ImGuiPushItemWidth(120.0 * scale)
        if ImGuiSliderFloat("##PenEraserSize", &eraserSize, 6.0, 192.0, "%.0f px", 0) {
            eraserChanged = true
        }
        ImGuiPopItemWidth()
        ImGuiSameLine(0, 12.0 * scale)
        ImGuiTextV("Vector eraser splits lines, paths, pen strokes, and native splines")

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

        if stabilizationChanged {
            stabilizationSettings = PenStrokeStabilizationSettings(
                amount: Double(stabilizationPercent) / 100.0,
                useSpline: splineFinal)
            thresholdPixelsOverride = nil
            Self.rememberedStabilizationSettings = stabilizationSettings
        }

        if eraserChanged {
            if eraseEnabled != eraseMode {
                finishEraseSession(engine: engine)
                resetCurrentStroke()
                eraseMode = eraseEnabled
                engine.commandProcessor.commandPrompt = eraseMode
                    ? "PenStroke Erase: drag the eraser circle across vectors. E returns to Draw."
                    : "PenStroke Draw: draw with pen. E toggles vector eraser; Enter/Esc ends command."
            }
            eraserDiameterPixels = max(6.0, min(192.0, Double(eraserSize)))
            Self.rememberedEraserDiameterPixels = eraserDiameterPixels
        }
    }
}
