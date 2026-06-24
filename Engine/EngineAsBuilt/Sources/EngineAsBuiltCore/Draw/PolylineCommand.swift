import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PolylineCommand
// =========================================================================

/// Interactive multi-point polyline drawing command.
/// Click to add vertices, double-click or Enter to finish.
@MainActor
public final class PolylineCommand: FeatureCommand {

    private var points: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        processor.commandPrompt = "Specify first point (Enter/Esc to finish, C to close)."
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
            processor.commandPrompt = "Specify next point (double-click or Enter/Esc to finish, C to close)."
        } else {
            processor.commandPrompt = "\(points.count) points. Specify next or double-click/Enter to finish."
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
        case SDL_SCANCODE_C:
            return finalize(engine: engine, processor: processor, closeShape: true)
        default:
            return .continue
        }
    }

    private func finalize(engine: PhrostEngine, processor: CADCommandProcessor, closeShape: Bool = false) -> CommandResult {
        guard points.count >= (closeShape ? 3 : 2) else {
            processor.commandPrompt = closeShape
                ? "Need at least 3 points to close a polyline."
                : "Need at least 2 points for a polyline."
            return .continue
        }

        let primitives: [CADPrimitive]
        if closeShape {
            // Closed polyline — polygon primitive renders with the closing edge.
            primitives = [.polygon(points: points)]
        } else {
            // Open polyline — single polyline primitive with shared vertices.
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

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
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
