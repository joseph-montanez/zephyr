import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - ArcCommand
// =========================================================================

/// Interactive 3-point arc: start point, end point, then a third point ON the
/// arc that defines its curvature (standard CAD 3-point arc behavior).
///
/// Once the start and end points are placed they are fixed. While picking the
/// third point, only the bulge of the previewed arc changes as the mouse moves;
/// the arc is solved as the unique circle through (start, mouse, end), swept
/// from start to end through the mouse point.
@MainActor
public final class ArcCommand: FeatureCommand {

    private enum State {
        case waitingForStart
        case waitingForEnd(startX: Double, startY: Double)
        case waitingForMid(startX: Double, startY: Double, endX: Double, endY: Double)
    }

    private var state: State = .waitingForStart
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForStart
        processor.commandPrompt = "Specify start point of arc (Esc to cancel)."
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
            state = .waitingForEnd(startX: worldX, startY: worldY)
            processor.commandPrompt = "Specify end point of arc (Esc to cancel)."
            return .continue

        case .waitingForEnd(let sx, let sy):
            let chord = hypot(worldX - sx, worldY - sy)
            guard chord > 1e-9 else {
                processor.commandPrompt = "End point coincides with start point. Try again."
                return .continue
            }
            state = .waitingForMid(startX: sx, startY: sy, endX: worldX, endY: worldY)
            processor.commandPrompt = "Specify a point on the arc (Esc to cancel)."
            return .continue

        case .waitingForMid(let sx, let sy, let ex, let ey):
            let start = Vector3(x: sx, y: sy, z: 0)
            let end = Vector3(x: ex, y: ey, z: 0)
            let mid = Vector3(x: worldX, y: worldY, z: 0)

            guard let solved = CADGeometryMath.circleThroughThreePoints(start, mid, end) else {
                processor.commandPrompt = "Points are collinear. Pick a point off the chord."
                return .continue
            }

            let angles = CADGeometryMath.arcAnglesIncludingMid(
                center: solved.center, start: start, mid: mid, end: end)
            let prim: CADPrimitive = .arc(center: solved.center, radius: solved.radius,
                                           startAngle: angles.start, endAngle: angles.end)
            let entity = CADEntity(
                layerID: engine.document.activeLayerID ?? UUID(),
                localGeometry: [prim])
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Arc created."
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
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        func drawLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            let a = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: cam)
            let b = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), col, 1.5)
        }

        switch state {
        case .waitingForStart:
            break

        case .waitingForEnd(let sx, let sy):
            // Rubber-band chord from the fixed start point to the cursor.
            drawLine(sx, sy, currentMouseWorldX, currentMouseWorldY)

        case .waitingForMid(let sx, let sy, let ex, let ey):
            // Start and end are fixed; the cursor is the on-arc point that
            // defines the bulge. Solve the same circle the final entity will
            // use so the preview matches the result exactly.
            let start = Vector3(x: sx, y: sy, z: 0)
            let end = Vector3(x: ex, y: ey, z: 0)
            let mid = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)

            guard let solved = CADGeometryMath.circleThroughThreePoints(start, mid, end) else {
                // Cursor is (nearly) on the chord — degenerate arc, preview a line.
                drawLine(sx, sy, ex, ey)
                return
            }

            let angles = CADGeometryMath.arcAnglesIncludingMid(
                center: solved.center, start: start, mid: mid, end: end)
            var span = angles.end - angles.start
            if span < 0 { span += 2.0 * .pi }

            let segments = 48
            var points: [ImVec2] = []
            points.reserveCapacity(segments + 1)
            for i in 0...segments {
                let t = angles.start + span * Double(i) / Double(segments)
                let wx = solved.center.x + cos(t) * solved.radius
                let wy = solved.center.y + sin(t) * solved.radius
                let sp = EngineCameraManager.worldToScreen(worldX: wx, worldY: wy, cam: cam)
                points.append(ImVec2(x: sp.x, y: sp.y))
            }
            points.withUnsafeBufferPointer { buf in
                ImDrawListAddPolyline(drawList, buf.baseAddress, Int32(points.count), col, 1.5, ImDrawFlags(0))
            }
        }
    }
}
