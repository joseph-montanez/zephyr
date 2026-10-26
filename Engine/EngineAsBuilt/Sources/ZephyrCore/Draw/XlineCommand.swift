import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel

// =========================================================================
// MARK: - XlineMath
// =========================================================================

/// Angle-bisector direction behind XLINE/Bisect (headless-testable).
/// Returns nil when a leg has zero length; opposite rays bisect
/// perpendicular to the first leg.
public enum XlineMath {

    public static func bisector(vertex: Vector3, start: Vector3, end: Vector3) -> Vector3? {
        func unit(_ v: Vector3) -> Vector3? {
            let m = hypot(v.x, v.y)
            guard m > 1e-9 else { return nil }
            return Vector3(x: v.x / m, y: v.y / m, z: 0)
        }
        guard let u1 = unit(Vector3(x: start.x - vertex.x, y: start.y - vertex.y, z: 0)),
              let u2 = unit(Vector3(x: end.x - vertex.x, y: end.y - vertex.y, z: 0))
        else { return nil }
        var bx = u1.x + u2.x, by = u1.y + u2.y
        if hypot(bx, by) < 1e-9 {
            bx = -u1.y
            by = u1.x
        }
        return Vector3(x: bx, y: by, z: 0)
    }
}

// =========================================================================
// MARK: - XlineCommand
// =========================================================================

/// Interactive construction line. Default flow: through-point then
/// direction (drag preview extends both ways, no arrowhead). LT options,
/// chosen before the through point:
/// Hor / Ver (through-point, fixed direction), Ang (typed angle, then
/// through-point), Bisect (vertex + two points, line through the vertex),
/// Offset (distance + source line + side → parallel xline via `Offset2D`).
@MainActor
public final class XlineCommand: FeatureCommand {

    private enum State {
        case waitingForPoint
        case waitingForDirection(pointX: Double, pointY: Double)
        case horPoint
        case verPoint
        case angAngle
        case angPoint(angleDeg: Double)
        case bisVertex
        case bisStart(vertex: Vector3)
        case bisEnd(vertex: Vector3, start: Vector3)
        case offDistance
        case offPick(distance: Double)
        case offSide(distance: Double, source: CADPrimitive, sourceZ: Double)
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
        processor.commandPrompt =
            "Specify a through point or [Hor/Ver/Ang/Bisect/Offset] (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForPoint
        input.reset()
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        guard case .waitingForPoint = state else { return [] }
        return [
            .init(value: "H", title: "Hor", aliases: ["HOR"],
                  description: "Horizontal construction line"),
            .init(value: "V", title: "Ver", aliases: ["VER"],
                  description: "Vertical construction line"),
            .init(value: "A", title: "Ang", aliases: ["ANG"],
                  description: "Construction line at a typed angle"),
            .init(value: "B", title: "Bisect", aliases: ["BISECT"],
                  description: "Bisector of three picked points"),
            .init(value: "O", title: "Offset", aliases: ["OFFSET"],
                  description: "Parallel line at a distance from a source line"),
        ]
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch state {
        case .waitingForPoint:
            switch upper {
            case "H", "HOR":
                state = .horPoint
                processor.commandPrompt = "Specify through point for horizontal line:"
                return .handled
            case "V", "VER":
                state = .verPoint
                processor.commandPrompt = "Specify through point for vertical line:"
                return .handled
            case "A", "ANG":
                state = .angAngle
                processor.commandPrompt = "Enter angle for construction line:"
                return .handled
            case "B", "BISECT":
                state = .bisVertex
                processor.commandPrompt = "Specify angle vertex point:"
                return .handled
            case "O", "OFFSET":
                state = .offDistance
                processor.commandPrompt = "Specify offset distance:"
                return .handled
            default:
                return .continue
            }

        case .angAngle:
            guard let deg = Double(upper), deg.isFinite else {
                processor.commandPrompt = "Enter angle in degrees:"
                return .handled
            }
            state = .angPoint(angleDeg: deg)
            processor.commandPrompt = "Specify through point:"
            return .handled

        case .offDistance:
            guard let d = Double(upper), d.isFinite, d > 1e-9 else {
                processor.commandPrompt = "Specify a positive offset distance:"
                return .handled
            }
            state = .offPick(distance: d)
            processor.commandPrompt = "Select a line, ray, or construction line:"
            return .handled

        case .waitingForDirection, .horPoint, .verPoint, .angPoint,
             .bisVertex, .bisStart, .bisEnd, .offPick, .offSide:
            // Dynamic angle entry while aiming the default two-point flow.
            let dynResult = input.handleText(text)
            switch dynResult {
            case .ignored: return .continue
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

        case .horPoint:
            return commitXLine(pointX: worldX, pointY: worldY, dx: 1, dy: 0,
                               engine: engine, processor: processor)

        case .verPoint:
            return commitXLine(pointX: worldX, pointY: worldY, dx: 0, dy: 1,
                               engine: engine, processor: processor)

        case .angAngle:
            processor.commandPrompt = "Enter angle in degrees:"
            return .handled

        case .angPoint(let angleDeg):
            let rad = angleDeg * .pi / 180.0
            return commitXLine(pointX: worldX, pointY: worldY,
                               dx: cos(rad), dy: sin(rad),
                               engine: engine, processor: processor)

        case .bisVertex:
            state = .bisStart(vertex: Vector3(x: worldX, y: worldY, z: 0))
            processor.commandPrompt = "Specify angle start point:"
            return .handled

        case .bisStart(let vertex):
            state = .bisEnd(vertex: vertex, start: Vector3(x: worldX, y: worldY, z: 0))
            processor.commandPrompt = "Specify angle end point:"
            return .handled

        case .bisEnd(let vertex, let start):
            let end = Vector3(x: worldX, y: worldY, z: 0)
            return commitBisector(vertex: vertex, start: start, end: end,
                                  engine: engine, processor: processor)

        case .offDistance:
            processor.commandPrompt = "Specify a positive offset distance:"
            return .handled

        case .offPick(let distance):
            guard let picked = pickLineSource(
                worldX: worldX, worldY: worldY, engine: engine)
            else {
                processor.commandPrompt = "Select a line, ray, or construction line:"
                return .handled
            }
            state = .offSide(distance: distance, source: picked.prim, sourceZ: picked.z)
            processor.commandPrompt = "Specify side for the offset line:"
            return .handled

        case .offSide(let distance, let source, let sourceZ):
            return commitOffset(distance: distance, source: source, sourceZ: sourceZ,
                                sideX: worldX, sideY: worldY,
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

    // MARK: - Commit

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

    private func commitBisector(vertex: Vector3, start: Vector3, end: Vector3,
                                engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard let dir = XlineMath.bisector(vertex: vertex, start: start, end: end) else {
            processor.commandPrompt = "Points coincide. Specify angle end point:"
            state = .bisEnd(vertex: vertex, start: start)
            return .handled
        }
        return commitXLine(pointX: vertex.x, pointY: vertex.y, dx: dir.x, dy: dir.y,
                           engine: engine, processor: processor)
    }

    /// Resolve the clicked entity to a line-like source primitive in WORLD
    /// coordinates (entity transform applied), with its plane z.
    private func pickLineSource(
        worldX: Double, worldY: Double, engine: PhrostEngine
    ) -> (prim: CADPrimitive, z: Double)? {
        let doc = engine.document
        guard let handle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: doc,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false
        ), let entity = doc.entity(for: handle),
            let prim = entity.localGeometry?.first
        else { return nil }
        let t = entity.transform
        switch prim {
        case .line(let s, let e, _):
            let ws = t.transformPoint(s), we = t.transformPoint(e)
            return (.line(start: ws, end: we), ws.z)
        case .ray(let s, let d, _):
            let ws = t.transformPoint(s)
            let wd = t.transformPoint(Vector3(x: s.x + d.x, y: s.y + d.y, z: s.z))
            return (.ray(start: ws, direction: Vector3(x: wd.x - ws.x, y: wd.y - ws.y, z: 0)), ws.z)
        case .xline(let p, let d, _):
            let wp = t.transformPoint(p)
            let wd = t.transformPoint(Vector3(x: p.x + d.x, y: p.y + d.y, z: p.z))
            return (.xline(point: wp, direction: Vector3(x: wd.x - wp.x, y: wd.y - wp.y, z: 0)), wp.z)
        default:
            return nil
        }
    }

    private func commitOffset(distance: Double, source: CADPrimitive, sourceZ: Double,
                              sideX: Double, sideY: Double,
                              engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard let curve = source.toKernelCurves().first else {
            processor.commandPrompt = "Cannot offset that object. Select a line, ray, or construction line:"
            state = .offPick(distance: distance)
            return .handled
        }
        guard let moved = Offset2D.offsetSingleCurve(
            curve, distance: distance,
            sidePoint: Point2d(x: sideX, y: sideY))
        else {
            processor.commandPrompt = "Offset failed. Specify side for the offset line:"
            return .handled
        }
        let rebuilt = CADPrimitive.fromKernelCurve(moved, preservingColorFrom: source)
        guard let prim = rebuilt, case .xline(let base, let dir, _) = prim else {
            processor.commandPrompt = "Offset did not produce a line. Select a line, ray, or construction line:"
            state = .offPick(distance: distance)
            return .handled
        }
        // Rebuilt curves are planar: restore the source plane z.
        let placed: CADPrimitive = .xline(
            point: Vector3(x: base.x, y: base.y, z: sourceZ),
            direction: Vector3(x: dir.x, y: dir.y, z: 0))
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [placed])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Offset xline created."
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // Preview direction for the aiming states; fixed-direction options
        // preview through the mouse point.
        let fixedDir: (Double, Double)?
        let anchor: (Double, Double)?
        switch state {
        case .waitingForDirection(let px, let py):
            fixedDir = nil
            anchor = (px, py)
        case .horPoint:
            fixedDir = (1, 0)
            anchor = (currentMouseWorldX, currentMouseWorldY)
        case .verPoint:
            fixedDir = (0, 1)
            anchor = (currentMouseWorldX, currentMouseWorldY)
        case .angPoint(let deg):
            let rad = deg * .pi / 180.0
            fixedDir = (cos(rad), sin(rad))
            anchor = (currentMouseWorldX, currentMouseWorldY)
        case .bisEnd(let vertex, let start):
            // Preview the bisector using the mouse as the end point.
            let end = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            let u1 = Vector3(x: start.x - vertex.x, y: start.y - vertex.y, z: 0)
            let u2 = Vector3(x: end.x - vertex.x, y: end.y - vertex.y, z: 0)
            let m1 = hypot(u1.x, u1.y), m2 = hypot(u2.x, u2.y)
            guard m1 > 1e-9, m2 > 1e-9 else { return }
            var bx = u1.x / m1 + u2.x / m2, by = u1.y / m1 + u2.y / m2
            if hypot(bx, by) < 1e-9 {
                bx = -(u1.y / m1)
                by = u1.x / m1
            }
            drawPreviewLine(
                cam: cam, anchorX: vertex.x, anchorY: vertex.y,
                dirX: bx, dirY: by)
            return
        case .waitingForPoint, .angAngle, .bisVertex, .bisStart,
             .offDistance, .offPick, .offSide:
            return
        }
        guard let anchor, let fixedDir else {
            // Two-point aiming: direction follows the mouse.
            guard case .waitingForDirection(let px, let py) = state else { return }
            let dx = currentMouseWorldX - px
            let dy = currentMouseWorldY - py
            guard hypot(dx, dy) > 1e-9 else { return }
            drawPreviewLine(cam: cam, anchorX: px, anchorY: py, dirX: dx, dirY: dy)
            input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
            return
        }
        drawPreviewLine(cam: cam, anchorX: anchor.0, anchorY: anchor.1,
                        dirX: fixedDir.0, dirY: fixedDir.1)
    }

    private func drawPreviewLine(cam: CameraTransform, anchorX: Double, anchorY: Double,
                                 dirX: Double, dirY: Double) {
        let m = hypot(dirX, dirY)
        guard m > 1e-9 else { return }
        let ux = dirX / m, uy = dirY / m
        let farDist = 25000.0
        let p1 = EngineCameraManager.worldToScreen(
            worldX: anchorX - ux * farDist, worldY: anchorY - uy * farDist, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(
            worldX: anchorX + ux * farDist, worldY: anchorY + uy * farDist, cam: cam)
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y),
                          makeCol32(0, 255, 128, 200), 1.5)
    }
}
