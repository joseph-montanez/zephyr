import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PolygonMath
// =========================================================================

/// Regular-polygon vertex math behind POLYGON (headless-testable).
public enum PolygonMath {

    public enum Mode {
        case inscribed
        case circumscribed
    }

    /// Vertices for a regular polygon: `sides` vertices on a circle of
    /// `radius` around `center`, first vertex at `startAngle`. For
    /// circumscribed, `radius` is the center-to-flat distance and vertices
    /// sit at radius / cos(π/sides), offset half a step so flats face the
    /// cardinal directions of `startAngle`.
    public static func vertices(
        sides: Int, center: Vector3, radius: Double,
        startAngle: Double, mode: Mode
    ) -> [Vector3] {
        let step = 2.0 * Double.pi / Double(sides)
        switch mode {
        case .inscribed:
            return (0..<sides).map { k in
                let a = startAngle + Double(k) * step
                return Vector3(
                    x: center.x + radius * cos(a),
                    y: center.y + radius * sin(a),
                    z: center.z)
            }
        case .circumscribed:
            let vertexRadius = radius / cos(Double.pi / Double(sides))
            let offset = startAngle + Double.pi / Double(sides)
            return (0..<sides).map { k in
                let a = offset + Double(k) * step
                return Vector3(
                    x: center.x + vertexRadius * cos(a),
                    y: center.y + vertexRadius * sin(a),
                    z: center.z)
            }
        }
    }

    /// Vertices from an edge: v0 = `first`, v1 = `second`, remaining
    /// vertices by left turns of the exterior angle (CCW interior).
    public static func verticesFromEdge(
        sides: Int, first: Vector3, second: Vector3
    ) -> [Vector3] {
        var verts = [first, second]
        let turn = Double.pi - 2.0 * Double.pi / Double(sides)
        var dir = Vector3(x: second.x - first.x, y: second.y - first.y, z: 0)
        var prev = second
        for _ in 2..<sides {
            let cosT = cos(turn), sinT = sin(turn)
            dir = Vector3(
                x: dir.x * cosT - dir.y * sinT,
                y: dir.x * sinT + dir.y * cosT, z: 0)
            let next = Vector3(x: prev.x + dir.x, y: prev.y + dir.y, z: 0)
            verts.append(next)
            prev = next
        }
        return verts
    }
}

// =========================================================================
// MARK: - PolygonCommand (POLYGON / POL)
// =========================================================================

/// Draw a regular polygon: sides → center → Inscribed/Circumscribed/Edge →
/// radius (click or typed) or two edge points. Commits one closed
/// `.polyline` entity in a single undo step.
@MainActor
public final class PolygonCommand: FeatureCommand {

    private enum State {
        case sides
        case center(sides: Int)
        case mode(sides: Int, center: Vector3)
        case radius(sides: Int, center: Vector3, mode: PolygonMath.Mode)
        case edgeFirst(sides: Int, center: Vector3)
        case edgeSecond(sides: Int, center: Vector3, first: Vector3)
    }

    private var state: State = .sides
    private var mouseWorld = Vector3(x: 0, y: 0, z: 0)

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .sides
        processor.commandPrompt = "Enter number of sides <4>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        if case .mode = state {
            return [
                .init(value: "I", title: "Inscribed", aliases: ["INSCRIBED"],
                      description: "Vertices on the circle"),
                .init(value: "C", title: "Circumscribed", aliases: ["CIRCUMSCRIBED"],
                      description: "Flats tangent to the circle"),
                .init(value: "E", title: "Edge", aliases: ["EDGE"],
                      description: "Two points define the first edge"),
            ]
        }
        return []
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch state {
        case .sides:
            guard let n = Int(upper), n >= 3, n <= 1024 else {
                processor.commandPrompt = "Enter a whole number of sides (3-1024):"
                return .handled
            }
            state = .center(sides: n)
            processor.commandPrompt = "Specify center of polygon:"
            return .handled

        case .mode(let sides, let center):
            if upper == "I" || upper == "INSCRIBED" {
                state = .radius(sides: sides, center: center, mode: .inscribed)
                processor.commandPrompt = "Specify radius of circle (click or type):"
                return .handled
            }
            if upper == "C" || upper == "CIRCUMSCRIBED" {
                state = .radius(sides: sides, center: center, mode: .circumscribed)
                processor.commandPrompt = "Specify radius of circle (click or type):"
                return .handled
            }
            if upper == "E" || upper == "EDGE" {
                state = .edgeFirst(sides: sides, center: center)
                processor.commandPrompt = "Specify first endpoint of edge:"
                return .handled
            }
            return .continue

        case .radius(let sides, let center, let mode):
            guard let r = Double(upper), r > 1e-9 else {
                processor.commandPrompt = "Specify radius of circle (click or type):"
                return .handled
            }
            // Typed radius starts the first vertex due east.
            commit(vertices: PolygonMath.vertices(
                sides: sides, center: center, radius: r,
                startAngle: 0, mode: mode),
                engine: engine, processor: processor)
            return .finished

        case .center, .edgeFirst, .edgeSecond:
            return .continue
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let pt = Vector3(x: worldX, y: worldY, z: 0)
        switch state {
        case .sides:
            processor.commandPrompt = "Enter a whole number of sides (3-1024):"
            return .handled

        case .center(let sides):
            state = .mode(sides: sides, center: pt)
            processor.commandPrompt =
                "Enter an option [Inscribed in circle/Circumscribed about circle/Edge] <Inscribed>:"
            return .handled

        case .mode(let sides, let center):
            // Click during mode = accept default (Inscribed) with this radius.
            let r = hypot(worldX - center.x, worldY - center.y)
            guard r > 1e-9 else {
                processor.commandPrompt = "Radius too small. Click a radius point or type an option."
                return .handled
            }
            let a = atan2(worldY - center.y, worldX - center.x)
            commit(vertices: PolygonMath.vertices(
                sides: sides, center: center, radius: r,
                startAngle: a, mode: .inscribed),
                engine: engine, processor: processor)
            return .finished

        case .radius(let sides, let center, let mode):
            let r = hypot(worldX - center.x, worldY - center.y)
            guard r > 1e-9 else {
                processor.commandPrompt = "Radius too small. Click a radius point or type a value."
                return .handled
            }
            let a = atan2(worldY - center.y, worldX - center.x)
            commit(vertices: PolygonMath.vertices(
                sides: sides, center: center, radius: r,
                startAngle: a, mode: mode),
                engine: engine, processor: processor)
            return .finished

        case .edgeFirst(let sides, let center):
            state = .edgeSecond(sides: sides, center: center, first: pt)
            processor.commandPrompt = "Specify second endpoint of edge:"
            return .handled

        case .edgeSecond(let sides, _, let first):
            guard hypot(worldX - first.x, worldY - first.y) > 1e-9 else {
                processor.commandPrompt = "Edge too short. Specify second endpoint of edge:"
                return .handled
            }
            commit(vertices: PolygonMath.verticesFromEdge(
                sides: sides, first: first, second: pt),
                engine: engine, processor: processor)
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        mouseWorld = Vector3(x: worldX, y: worldY, z: 0)
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // Live outline preview once a center exists; the radius/edge
        // follows the mouse. Click points already snap via the engine.
        let preview: [Vector3]?
        switch state {
        case .mode(let sides, let center):
            let r = hypot(mouseWorld.x - center.x, mouseWorld.y - center.y)
            guard r > 1e-9 else { return }
            let a = atan2(mouseWorld.y - center.y, mouseWorld.x - center.x)
            preview = PolygonMath.vertices(
                sides: sides, center: center, radius: r,
                startAngle: a, mode: .inscribed)
        case .radius(let sides, let center, let mode):
            let r = hypot(mouseWorld.x - center.x, mouseWorld.y - center.y)
            guard r > 1e-9 else { return }
            let a = atan2(mouseWorld.y - center.y, mouseWorld.x - center.x)
            preview = PolygonMath.vertices(
                sides: sides, center: center, radius: r,
                startAngle: a, mode: mode)
        case .edgeSecond(let sides, _, let first):
            guard hypot(mouseWorld.x - first.x, mouseWorld.y - first.y) > 1e-9 else { return }
            preview = PolygonMath.verticesFromEdge(
                sides: sides, first: first, second: mouseWorld)
        case .sides, .center, .edgeFirst:
            return
        }
        guard let verts = preview, verts.count >= 3 else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)
        for i in verts.indices {
            let a = verts[i], b = verts[(i + 1) % verts.count]
            let pa = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
            let pb = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: pa.x, y: pa.y), ImVec2(x: pb.x, y: pb.y), col, 1.5)
        }
    }

    private func commit(
        vertices: [Vector3],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [.polyline(
                path: CADPolyline(points: vertices, isClosed: true))])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Polygon created (\(vertices.count) sides)."
    }
}
