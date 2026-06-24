import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - SplineCommand
// =========================================================================

/// Interactive spline: pick N control points, double-click or Enter to finish.
/// Creates a `.spline` CADPrimitive with uniform clamped knots.
@MainActor
public final class SplineCommand: FeatureCommand {

    private var controlPoints: [Vector3] = []
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        controlPoints.removeAll()
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        processor.commandPrompt = "Specify control point (Enter/Esc to finish when done)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        controlPoints.removeAll()
    }

    public func getDrawingSnapPoints() -> [Vector3] { controlPoints }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        controlPoints.append(Vector3(x: worldX, y: worldY, z: 0))
        if controlPoints.count == 1 {
            processor.commandPrompt = "Specify next control point (double-click or Enter/Esc to finish)."
        } else {
            processor.commandPrompt = "\(controlPoints.count) control points. Next or double-click/Enter to finish."
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
        let count = controlPoints.count
        guard count >= 2 else {
            processor.commandPrompt = "Need at least 2 control points for a spline."
            return .continue
        }
        let degree = min(3, count - 1)
        let knots = generateUniformKnots(controlPointCount: count, degree: degree)

        let prim: CADPrimitive = .spline(controlPoints: controlPoints,
                                          knots: knots,
                                          degree: degree,
                                          weights: nil)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [prim])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Spline created (degree \(degree), \(count) control points)."
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let curveCol = makeCol32(0, 255, 128, 200)
        let cpCol = makeCol32(255, 200, 50, 200)
        let hullCol = makeCol32(255, 200, 50, 80)

        // Draw control polygon (hull)
        if controlPoints.count >= 2 {
            for i in 0..<(controlPoints.count - 1) {
                let p1 = EngineCameraManager.worldToScreen(worldX: controlPoints[i].x, worldY: controlPoints[i].y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: controlPoints[i + 1].x, worldY: controlPoints[i + 1].y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), hullCol, 1.0)
            }
        }

        // Draw evaluated NURBS curve
        if controlPoints.count >= 2 {
            let degree = min(3, controlPoints.count - 1)
            let knots = generateUniformKnots(controlPointCount: controlPoints.count, degree: degree)
            let w = Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluate(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segments: 48)

            if evaluated.count >= 2 {
                var pts: [ImVec2] = []
                for pt in evaluated {
                    let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                    pts.append(ImVec2(x: sp.x, y: sp.y))
                }
                pts.withUnsafeBufferPointer { buf in
                    ImDrawListAddPolyline(drawList, buf.baseAddress, Int32(pts.count), curveCol, 1.5, ImDrawFlags(0))
                }
            }
        }

        // Rubber-band from last CP to cursor
        if let last = controlPoints.last {
            let p1 = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
            let p2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                              makeCol32(255, 200, 50, 100), 1.0)
        }

        // Control point dots
        for pt in controlPoints {
            let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sp.x, y: sp.y), 3.5, cpCol, 0)
        }
    }
}
