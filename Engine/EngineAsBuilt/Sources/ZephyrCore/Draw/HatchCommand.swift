import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - HatchCommand
// =========================================================================

/// Interactive hatch: pick boundary points, double-click or Enter to fill.
/// Creates a `.hatch` CADPrimitive with a closed boundary and solid fill.
@MainActor
public final class HatchCommand: FeatureCommand {

    private var boundaryPoints: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        boundaryPoints.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        processor.commandPrompt = "Specify boundary point (Enter/Esc to fill when done)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        boundaryPoints.removeAll()
    }

    public func getDrawingSnapPoints() -> [Vector3] { boundaryPoints }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        boundaryPoints.append(Vector3(x: worldX, y: worldY, z: 0))
        if boundaryPoints.count == 1 {
            processor.commandPrompt = "Specify next boundary point (double-click or Enter/Esc to fill)."
        } else {
            processor.commandPrompt = "\(boundaryPoints.count) boundary points. Next point or double-click/Enter to fill."
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
        guard boundaryPoints.count >= 3 else {
            processor.commandPrompt = "Need at least 3 boundary points."
            return .continue
        }
        // Close the boundary
        var closed = boundaryPoints
        if closed.first != closed.last {
            closed.append(closed[0])
        }
        let prim: CADPrimitive = .hatch(boundary: closed,
                                         pattern: "SOLID",
                                         scale: 1.0,
                                         angle: 0.0,
                                         color: ColorRGBA(r: 128, g: 128, b: 128, a: 180))
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [prim])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Hatch created with \(boundaryPoints.count) boundary points."
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let edgeCol = makeCol32(0, 255, 128, 200)
        let fillCol = makeCol32(0, 255, 128, 40)

        // Draw confirmed boundary edges
        if boundaryPoints.count >= 2 {
            for i in 0..<(boundaryPoints.count - 1) {
                let p1 = EngineCameraManager.worldToScreen(worldX: boundaryPoints[i].x, worldY: boundaryPoints[i].y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: boundaryPoints[i + 1].x, worldY: boundaryPoints[i + 1].y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), edgeCol, 1.5)
            }
            // Close back to first point
            let pFirst = EngineCameraManager.worldToScreen(worldX: boundaryPoints[0].x, worldY: boundaryPoints[0].y, cam: cam)
            let pLast = EngineCameraManager.worldToScreen(worldX: boundaryPoints[boundaryPoints.count - 1].x,
                                                     worldY: boundaryPoints[boundaryPoints.count - 1].y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: pLast.x, y: pLast.y), ImVec2(x: pFirst.x, y: pFirst.y),
                              makeCol32(0, 255, 128, 80), 1.0)
        }

        // Rubber-band from last point to current mouse
        if let last = boundaryPoints.last {
            let p1 = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                              makeCol32(0, 255, 128, 100), 1.0)
        }

        // If we have >= 3 points, show a semi-transparent fill
        if boundaryPoints.count >= 3 {
            var fillPts: [ImVec2] = []
            for pt in boundaryPoints {
                let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                fillPts.append(ImVec2(x: sp.x, y: sp.y))
            }
            let fillCount = Int32(fillPts.count)
            fillPts.withUnsafeMutableBufferPointer { buf in
                ImDrawListAddConvexPolyFilled(drawList, buf.baseAddress, fillCount, fillCol)
            }
        }

        // Vertex dots
        let dotCol = makeCol32(0, 200, 100, 255)
        for pt in boundaryPoints {
            let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sp.x, y: sp.y), 3.0, dotCol, 0)
        }
    }
}
