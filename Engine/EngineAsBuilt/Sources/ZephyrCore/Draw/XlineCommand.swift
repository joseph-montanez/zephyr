import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - XlineCommand
// =========================================================================

/// Interactive construction line: through-point then direction, mirrored
/// from RayCommand. The line is infinite in both directions; the drag
/// preview extends both ways and there is no arrowhead. An angle typed
/// with Enter creates the line at that exact angle.
@MainActor
public final class XlineCommand: FeatureCommand {

    private enum State {
        case waitingForPoint
        case waitingForDirection(pointX: Double, pointY: Double)
    }

    private var state: State = .waitingForPoint
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var input = DynamicNumericInput()

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForPoint
        input.reset()
        input.tabCycle = [.angle]
        processor.commandPrompt = "Specify a through point or enter angle (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForPoint
        input.reset()
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .waitingForPoint:
            state = .waitingForDirection(pointX: worldX, pointY: worldY)
            input.reset()
            processor.commandPrompt = "Specify direction point or type angle + Enter (Esc to cancel)."
            return .continue

        case .waitingForDirection(let pointX, let pointY):
            let dx = worldX - pointX
            let dy = worldY - pointY
            return commitXLine(pointX: pointX, pointY: pointY, dx: dx, dy: dy,
                               engine: engine, processor: processor)
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let dynResult = input.handleKey(scancode)
        switch dynResult {
        case .ignored:
            break
        case .consumed:
            return .handled
        case .commitValue:
            return .handled  // value not used for xline
        case .commitAngle(let angleDeg):
            guard case .waitingForDirection(let px, let py) = state else {
                processor.commandPrompt = "Click a through point first."
                return .handled
            }
            let rad = angleDeg * .pi / 180.0
            return commitXLine(pointX: px, pointY: py,
                               dx: cos(rad), dy: sin(rad),
                               engine: engine, processor: processor)
        case .cancel:
            return .finished
        }

        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
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
        case .commitValue: return .handled
        case .commitAngle(let angleDeg):
            guard case .waitingForDirection(let px, let py) = state else {
                processor.commandPrompt = "Click a through point first."
                return .handled
            }
            let rad = angleDeg * .pi / 180.0
            return commitXLine(pointX: px, pointY: py,
                               dx: cos(rad), dy: sin(rad),
                               engine: engine, processor: processor)
        case .cancel: return .finished
        }
    }

    private func commitXLine(pointX: Double, pointY: Double,
                             dx: Double, dy: Double,
                             engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-9 else {
            processor.commandPrompt = "Direction too short. Try again."
            return .continue
        }
        let direction = Vector3(x: dx, y: dy, z: 0)
        let point = Vector3(x: pointX, y: pointY, z: 0)
        let prim: CADPrimitive = .xline(point: point, direction: direction)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [prim])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        let angleDeg = atan2(dy, dx) * 180.0 / .pi
        processor.commandPrompt = "Xline created at \(String(format: "%.1f", angleDeg))°."
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForDirection(let pointX, let pointY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        let dx = currentMouseWorldX - pointX
        let dy = currentMouseWorldY - pointY
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-9 else { return }
        let unitX = dx / dist
        let unitY = dy / dist

        let farDist = 25000.0
        let backX = pointX - unitX * farDist
        let backY = pointY - unitY * farDist
        let farX = pointX + unitX * farDist
        let farY = pointY + unitY * farDist

        let p1 = EngineCameraManager.worldToScreen(worldX: backX, worldY: backY, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(worldX: farX, worldY: farY, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)

        // Angle label
        let angleDeg = atan2(dy, dx) * 180.0 / .pi
        let midX = (pointX + currentMouseWorldX) / 2
        let midY = (pointY + currentMouseWorldY) / 2
        let midScreen = EngineCameraManager.worldToScreen(worldX: midX, worldY: midY, cam: cam)
        let label = String(format: "<%.1f°", angleDeg)
        ImDrawListAddText(drawList, ImVec2(x: midScreen.x, y: midScreen.y),
                          makeCol32(255, 255, 255, 200), label, nil)

        input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
    }
}
