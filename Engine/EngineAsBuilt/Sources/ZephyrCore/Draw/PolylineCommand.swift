import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PolylineCommand
// =========================================================================

/// Interactive multi-point polyline drawing command with direct distance/angle entry.
/// Click to add vertices, type distance + Enter to place a vertex at exact distance,
/// Tab to switch to angle mode, C to close the shape.
@MainActor
public final class PolylineCommand: FeatureCommand {

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
        processor.commandPrompt = "Specify first point (Enter/Esc to finish, C to close)."
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
            processor.commandPrompt = "Specify next point or enter distance (Enter/Esc to finish, C to close)."
        } else {
            processor.commandPrompt = "\(points.count) points. Specify next or Enter/Esc to finish."
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
            break
        case .consumed:
            return .handled
        case .commitValue(let distance):
            return placePoint(atDistance: distance, processor: processor)
        case .commitAngle(let angleDeg):
            processor.commandPrompt = "Angle locked at \(String(format: "%.1f", angleDeg))°. Enter distance."
            return .handled
        case .cancel:
            return finishOrCancel(engine: engine, processor: processor)
        }

        // Non-input keys
        switch scancode {
        case SDL_SCANCODE_C:
            return finalize(engine: engine, processor: processor, closeShape: true)
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return finishOrCancel(engine: engine, processor: processor)
        case SDL_SCANCODE_ESCAPE:
            return finishOrCancel(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let dynResult = input.handleText(text)
        switch dynResult {
        case .ignored:  return .continue
        case .consumed: return .handled
        case .commitValue(let d): return placePoint(atDistance: d, processor: processor)
        case .commitAngle(let a):
            processor.commandPrompt = "Angle locked at \(String(format: "%.1f", a))°. Enter distance."
            return .handled
        case .cancel: return finishOrCancel(engine: engine, processor: processor)
        }
    }

    // MARK: - Point placement

    private func placePoint(atDistance distance: Double, processor: CADCommandProcessor) -> CommandResult {
        guard let last = points.last else {
            processor.commandPrompt = "Click a start point first."
            return .handled
        }
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
            direction = len < 1e-9 ? Vector3(x: 1, y: 0, z: 0) : Vector3(x: dx / len, y: dy / len, z: 0)
        }
        points.append(Vector3(x: last.x + direction.x * distance,
                              y: last.y + direction.y * distance, z: 0))
        input.reset()
        processor.commandPrompt = "\(points.count) points. Specify next or Enter/Esc to finish."
        return .handled
    }

    // MARK: - Finalize

    private func finishOrCancel(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        return finalize(engine: engine, processor: processor)
    }

    private func finalize(engine: PhrostEngine, processor: CADCommandProcessor,
                          closeShape: Bool = false) -> CommandResult {
        guard points.count >= (closeShape ? 3 : 2) else {
            processor.commandPrompt = "Command cancelled."
            return .finished
        }

        let primitives: [CADPrimitive]
        if closeShape {
            primitives = [.polygon(points: points)]
        } else {
            primitives = [.polyline(points: points)]
        }

        var entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: primitives)

        if closeShape {
            entity.xdata["dxf.closed"] = .bool(true)
            processor.commandPrompt = "Closed polyline created with \(points.count) points."
        } else {
            processor.commandPrompt = "Polyline created with \(points.count) points."
        }

        if engine.tabManager.isFloatingModelSpace,
           engine.tabManager.commitPaperEntitiesAsModel([entity]) {
            engine.tabManager.markActiveDirty()
        } else {
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
        }
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let p1 = EngineCameraManager.worldToScreen(worldX: points[i].x, worldY: points[i].y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: points[i + 1].x, worldY: points[i + 1].y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)
            }
        }

        if let last = points.last {
            let p1 = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                              makeCol32(0, 255, 128, 100), 1.0)

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
            ImDrawListAddRectFilled(drawList, bgMin, bgMax, makeCol32(20, 20, 20, 180), 3.0, 0)
            ImDrawListAddText(drawList,
                              ImVec2(x: midScreen.x - textW / 2.0, y: midScreen.y - fontSize - pad),
                              makeCol32(200, 200, 200, 255), labelText, nil)
        }

        let dotCol = makeCol32(0, 200, 100, 255)
        for pt in points {
            let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sp.x, y: sp.y), 3.0, dotCol, 0)
        }

        if !points.isEmpty {
            input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
        }
    }
}
