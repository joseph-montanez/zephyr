import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - RectangleCommand
// =========================================================================

/// Interactive 2-corner rectangle drawing.
@MainActor
public final class RectangleCommand: FeatureCommand {

    private enum State {
        case waitingForFirstCorner
        case waitingForSecondCorner(firstX: Double, firstY: Double)
    }

    private var state: State = .waitingForFirstCorner
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirstCorner
        processor.commandPrompt = "Specify first corner (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirstCorner
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .waitingForFirstCorner:
            state = .waitingForSecondCorner(firstX: worldX, firstY: worldY)
            processor.commandPrompt = "Specify opposite corner (Esc to cancel)."
            return .continue

        case .waitingForSecondCorner(let firstX, let firstY):
            let originX = min(firstX, worldX)
            let originY = min(firstY, worldY)
            let sizeX = abs(worldX - firstX)
            let sizeY = abs(worldY - firstY)
            guard sizeX > 1e-9, sizeY > 1e-9 else {
                processor.commandPrompt = "Rectangle too small. Try again."
                return .continue
            }
            let prim: CADPrimitive = .rect(
                origin: Vector3(x: originX, y: originY, z: 0),
                size: Vector3(x: sizeX, y: sizeY, z: 0))
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [prim])
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Rectangle created."
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
        guard case .waitingForSecondCorner(let firstX, let firstY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let p4 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: currentMouseWorldY, cam: cam)

        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p3.x, y: p3.y), ImVec2(x: p4.x, y: p4.y), col, 1.5)
        ImDrawListAddLine(drawList, ImVec2(x: p4.x, y: p4.y), ImVec2(x: p1.x, y: p1.y), col, 1.5)

        // Semi-transparent fill
        let fillCol = makeCol32(0, 255, 128, 30)
        ImDrawListAddRectFilled(drawList,
                                ImVec2(x: min(p1.x, p3.x), y: min(p1.y, p3.y)),
                                ImVec2(x: max(p1.x, p3.x), y: max(p1.y, p3.y)),
                                fillCol, 0.0, 0)

        // Dimension labels
        let w = abs(currentMouseWorldX - firstX)
        let h = abs(currentMouseWorldY - firstY)
        if w > 1e-6 && h > 1e-6 {
            let labelW = String(format: "%.1f", w)
            let labelH = String(format: "%.1f", h)
            let midX = (firstX + currentMouseWorldX) / 2
            let midY = (firstY + currentMouseWorldY) / 2
            let sp = EngineCameraManager.worldToScreen(worldX: midX, worldY: midY, cam: cam)
            let label = "\(labelW) x \(labelH)"
            ImDrawListAddText(drawList, ImVec2(x: sp.x - 25, y: sp.y - 10),
                              makeCol32(255, 255, 255, 200), label, nil)
        }
    }
}
