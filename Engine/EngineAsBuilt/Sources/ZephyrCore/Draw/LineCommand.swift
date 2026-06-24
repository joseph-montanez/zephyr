import Foundation
import CSDL3
import ImGui
import SwiftSDL
import SwiftSDL_image

// =========================================================================
// MARK: - LineCommand
// =========================================================================

/// Interactive multi-segment line drawing command.
/// Each click adds a connected segment from the previous endpoint.
/// Press Enter or Escape to finish and create a polyline entity.
@MainActor
public final class LineCommand: FeatureCommand {

    private var points: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        processor.commandPrompt = "Specify first point (Esc/Enter to complete when done)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
    }

    public func getDrawingSnapPoints() -> [Vector3] { points }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        points.append(Vector3(x: worldX, y: worldY, z: 0))
        if points.count == 1 {
            processor.commandPrompt = "Specify next point (Esc/Enter to finish)."
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

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_ESCAPE:
            return finalize(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    private func finalize(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard points.count >= 2 else {
            processor.commandPrompt = "Need at least 2 points for a line."
            return .continue
        }
        // Create one CADEntity per segment — each line is independently selectable.
        for i in 0..<(points.count - 1) {
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [.line(start: points[i], end: points[i + 1])])
            engine.document.addEntity(entity)
        }
        engine.tabManager.markActiveDirty()
        let segmentCount = points.count - 1
        processor.commandPrompt = "Line created with \(segmentCount) segment\(segmentCount == 1 ? "" : "s")."
        return .finished
    }

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
        }

        // Draw vertex dots
        let dotCol = makeCol32(0, 200, 100, 255)
        for pt in points {
            let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sp.x, y: sp.y), 3.0, dotCol, 0)
        }
    }
}
