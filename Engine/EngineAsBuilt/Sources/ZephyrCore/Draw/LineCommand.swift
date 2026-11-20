import Foundation
import CSDL3
import ImGui
import SwiftSDL
import SwiftSDL_image

// =========================================================================
// MARK: - LineCommand
// =========================================================================

/// Interactive multi-segment line drawing command with AutoCAD-style
/// direct distance entry and dynamic input.
///
/// Workflows:
///   - Click to place points (standard).
///   - Type a distance and press Enter — places the next point at that exact
///     distance from the last point in the current mouse direction.
///   - Tab to switch to angle mode, type an angle, Enter to lock it — then
///     type a distance to place the point at that angle.
///   - Press Enter with an empty buffer to finalize.
///   - Esc cancels the in-progress segments (the input layer intercepts
///     it before this command; `cancel` discards the pending points).
@MainActor
public final class LineCommand: FeatureCommand {

    private var points: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var input = DynamicNumericInput()

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        input.reset()
        processor.commandPrompt = "Specify first point (Esc/Enter to complete when done)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        input.reset()
    }

    public func getDrawingSnapPoints() -> [Vector3] { points }

    // MARK: - Mouse

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        points.append(Vector3(x: worldX, y: worldY, z: 0))
        input.reset()
        if points.count == 1 {
            processor.commandPrompt = "Specify next point or enter distance (Esc/Enter to finish)."
        } else {
            processor.commandPrompt = "\(points.count) points. Specify next or Esc/Enter to finish."
        }
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    // MARK: - Keyboard

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let dynResult = input.handleKey(scancode)
        switch dynResult {
        case .ignored:
            break // fall through to legacy handling below

        case .consumed:
            return .handled

        case .commitValue(let distance):
            return placePoint(atDistance: distance, engine: engine, processor: processor)

        case .commitAngle(let angleDeg):
            processor.commandPrompt = "Angle locked at \(String(format: "%.1f", angleDeg))°. Enter distance."
            return .handled

        case .cancel:
            // All buffers empty, Esc pressed — finalize if we have segments, otherwise cancel.
            return finishOrCancel(engine: engine, processor: processor)
        }

        // Legacy key paths (feature command returned .ignored or key not consumed above).
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            // Enter with empty buffer → finalize if we have enough points.
            return finishOrCancel(engine: engine, processor: processor)
        case SDL_SCANCODE_ESCAPE:
            return finishOrCancel(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    // MARK: - Command-line text

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let dynResult = input.handleText(text)
        switch dynResult {
        case .ignored:
            return .continue
        case .consumed:
            return .handled
        case .commitValue(let distance):
            return placePoint(atDistance: distance, engine: engine, processor: processor)
        case .commitAngle(let angleDeg):
            processor.commandPrompt = "Angle locked at \(String(format: "%.1f", angleDeg))°. Enter distance."
            return .handled
        case .cancel:
            return finishOrCancel(engine: engine, processor: processor)
        }
    }

    // MARK: - Point placement

    /// Place the next point at the given distance from the last placed point,
    /// using either the locked explicit angle or the current mouse direction.
    private func placePoint(
        atDistance distance: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let last = points.last else {
            processor.commandPrompt = "Click a start point first."
            return .handled
        }

        // Reject zero-length
        guard abs(distance) > 1e-9 else {
            processor.commandPrompt = "Distance must not be zero."
            return .handled
        }

        let direction: Vector3
        if let lockedAngle = input.lockedAngleRadians {
            direction = Vector3(x: cos(lockedAngle), y: sin(lockedAngle), z: 0)
        } else {
            let dx = currentMouseWorldX - last.x
            let dy = currentMouseWorldY - last.y
            let len = hypot(dx, dy)
            if len < 1e-9 {
                direction = Vector3(x: 1, y: 0, z: 0)
            } else {
                direction = Vector3(x: dx / len, y: dy / len, z: 0)
            }
        }

        let newPoint = Vector3(
            x: last.x + direction.x * distance,
            y: last.y + direction.y * distance,
            z: 0
        )
        points.append(newPoint)
        input.reset()

        processor.commandPrompt = "\(points.count) points. Specify next or Esc/Enter to finish."
        return .handled
    }

    // MARK: - Finalize / Cancel

    /// If we have ≥ 2 points, commit them as entities and finish.
    /// Otherwise cancel the command (return `.finished` to discard).
    private func finishOrCancel(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard points.count >= 2 else {
            processor.commandPrompt = "Command cancelled."
            return .finished
        }
        var entities: [CADEntity] = []
        let layerID = engine.document.activeLayerID ?? UUID()
        for i in 0..<(points.count - 1) {
            let entity = CADEntity(
                layerID: layerID,
                localGeometry: [.line(start: points[i], end: points[i + 1])])
            entities.append(entity)
        }
        // Floated MSPACE keeps paper-space preview points; commit maps them
        // into the model document through the viewport inverse transform.
        if engine.tabManager.isFloatingModelSpace,
           engine.tabManager.commitPaperEntitiesAsModel(entities) {
            engine.tabManager.markActiveDirty()
        } else {
            engine.document.addEntities(entities)
            engine.tabManager.markActiveDirty()
        }
        let segmentCount = points.count - 1
        processor.commandPrompt = "Line created with \(segmentCount) segment\(segmentCount == 1 ? "" : "s")."
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        // Draw confirmed segments
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let p1 = EngineCameraManager.worldToScreen(worldX: points[i].x, worldY: points[i].y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: points[i + 1].x, worldY: points[i + 1].y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)
            }
        }

        // Rubber-band from last point to current mouse
        if let last = points.last {
            let p1 = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                              makeCol32(0, 255, 128, 100), 1.0)

            // Show rubber-band distance label
            let dx = currentMouseWorldX - last.x
            let dy = currentMouseWorldY - last.y
            let dist = hypot(dx, dy)
            let angleDeg = atan2(dy, dx) * 180.0 / .pi
            let midX = (last.x + currentMouseWorldX) / 2.0
            let midY = (last.y + currentMouseWorldY) / 2.0
            let midScreen = EngineCameraManager.worldToScreen(worldX: midX, worldY: midY, cam: cam)
            let labelText = String(format: "%.2f  <%.1f°", dist, angleDeg)
            let textSize = ImGuiCalcTextSize(labelText, nil, false, -1.0)
            let textW = textSize.x
            let pad: Float = 4.0
            let fontSize = ImGuiGetFontSize()
            let bgMin = ImVec2(x: midScreen.x - textW / 2.0 - pad, y: midScreen.y - fontSize - pad * 2)
            let bgMax = ImVec2(x: midScreen.x + textW / 2.0 + pad, y: midScreen.y + pad)
            ImDrawListAddRectFilled(drawList, bgMin, bgMax,
                                    makeCol32(20, 20, 20, 180), 3.0, 0)
            ImDrawListAddText(drawList,
                              ImVec2(x: midScreen.x - textW / 2.0, y: midScreen.y - fontSize - pad),
                              makeCol32(200, 200, 200, 255), labelText, nil)
        }

        // Draw vertex dots
        let dotCol = makeCol32(0, 200, 100, 255)
        for pt in points {
            let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sp.x, y: sp.y), 3.0, dotCol, 0)
        }

        // Draw dynamic input pill near cursor when there are points
        if !points.isEmpty {
            input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
        }
    }
}
