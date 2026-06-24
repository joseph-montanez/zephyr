import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - RayCommand
// =========================================================================

/// Interactive ray: start point then direction point.
/// Creates a `.ray` CADPrimitive. The ray renders as a line extending
/// 100,000 units in the specified direction.
@MainActor
public final class RayCommand: FeatureCommand {

    private enum State {
        case waitingForStart
        case waitingForDirection(startX: Double, startY: Double)
    }

    private var state: State = .waitingForStart
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForStart
        processor.commandPrompt = "Specify start point (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForStart
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .waitingForStart:
            state = .waitingForDirection(startX: worldX, startY: worldY)
            processor.commandPrompt = "Specify direction point (Esc to cancel)."
            return .continue

        case .waitingForDirection(let startX, let startY):
            let dx = worldX - startX
            let dy = worldY - startY
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 1e-9 else {
                processor.commandPrompt = "Direction too short. Pick a point farther from start."
                return .continue
            }
            let direction = Vector3(x: dx, y: dy, z: 0)
            let start = Vector3(x: startX, y: startY, z: 0)
            let prim: CADPrimitive = .ray(start: start, direction: direction)
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [prim])
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Ray created."
            return .finished
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
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForDirection(let startX, let startY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        // Direction from start through cursor
        let dx = currentMouseWorldX - startX
        let dy = currentMouseWorldY - startY
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-9 else { return }
        let unitX = dx / dist
        let unitY = dy / dist

        // Extend to viewport edge
        let farDist = 25000.0  // large distance so it extends past viewport
        let farX = startX + unitX * farDist
        let farY = startY + unitY * farDist

        let p1 = EngineCameraManager.worldToScreen(worldX: startX, worldY: startY, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(worldX: farX, worldY: farY, cam: cam)

        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)

        // Arrowhead at cursor position
        let mp = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let arrowSize: Float = 8.0
        let perpX = -Float(unitY) * arrowSize * 0.5
        let perpY = Float(unitX) * arrowSize * 0.5
        ImDrawListAddLine(drawList,
                          ImVec2(x: mp.x - Float(unitX) * arrowSize + perpX,
                                 y: mp.y - Float(unitY) * arrowSize + perpY),
                          ImVec2(x: mp.x, y: mp.y), col, 2.0)
        ImDrawListAddLine(drawList,
                          ImVec2(x: mp.x - Float(unitX) * arrowSize - perpX,
                                 y: mp.y - Float(unitY) * arrowSize - perpY),
                          ImVec2(x: mp.x, y: mp.y), col, 2.0)
    }
}
