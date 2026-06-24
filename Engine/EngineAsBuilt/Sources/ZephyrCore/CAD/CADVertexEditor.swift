import Foundation

// =========================================================================
// MARK: - CADVertexEditor
//
// Provides direct vertex manipulation for grip-based editing.
// Allows moving individual vertices of an entity's render primitives
// without going through the full regeneration pipeline — enabling
// responsive interactive dragging of vertex and midpoint grips.
import SwiftSDL

@MainActor
public final class CADVertexEditor {
    public unowned let bridge: CADRendererBridge
    public init(bridge: CADRendererBridge) {
        self.bridge = bridge
    }


    public var arcEditSessions: [String: ArcEditSession] = [:]

    /// Snapshot of an arc's three defining world points, captured on the first
    /// frame of a grip drag. The two points NOT being dragged stay pinned at
    /// these positions for the whole drag; only the dragged point accumulates
    /// mouse deltas. Re-deriving the points from the live arc parameters every
    /// frame is wrong: the parametric midpoint relocates after every re-solve
    /// (so the "fixed" mid drifts), and arcAnglesIncludingMid may swap
    /// start/end to keep the stored sweep CCW (so grip indices 1/2 change
    /// physical identity mid-drag).
    public struct ArcEditSession {
        public let primitiveIndex: Int
        /// 1 = start grip, 2 = end grip, 3 = mid grip.
        public let gripIndex: Int
        public var startWorld: Vector3
        public var endWorld: Vector3
        public var midWorld: Vector3
    }

    /// Returns the arc edit session for (handle, vertexIndex), creating it from
    /// the current world points on the first call of a drag, then applies the
    /// per-frame delta to the dragged point only. The session is cleared by
    /// endVertexDirectEdit on mouse-up.
    public func arcSessionApplyingDelta(
        handle: UUID, vertexIndex: Int,
        primitiveIndex: Int, gripIndex: Int,
        currentStart: Vector3, currentEnd: Vector3, currentMid: Vector3,
        dx: Double, dy: Double
    ) -> ArcEditSession {
        let key = "\(handle.uuidString):\(vertexIndex)"
        var session = arcEditSessions[key] ?? ArcEditSession(
            primitiveIndex: primitiveIndex,
            gripIndex: gripIndex,
            startWorld: currentStart,
            endWorld: currentEnd,
            midWorld: currentMid)

        switch session.gripIndex {
        case 1:
            session.startWorld.x += dx
            session.startWorld.y += dy
        case 2:
            session.endWorld.x += dx
            session.endWorld.y += dy
        default:
            session.midWorld.x += dx
            session.midWorld.y += dy
        }

        arcEditSessions[key] = session
        return session
    }



    /// After a vertex/midpoint drag, write the render primitive positions back to the
    /// entity's CADPrimitive source data so hit testing works at the new position.
    public func finalizeVertexDrag(
        handle: UUID, in gm: GeometryManager, document: CADDocument
    ) {
        guard let ids = bridge.entityPrimitiveMap[handle],
              let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity)
        else { return }

        let invTransform = entity.transform.inverse()
        var newGeometry = geometry

        for (primIdx, var prim) in geometry.enumerated() {
            guard primIdx < ids.count, let rp = gm.getPrimitive(id: ids[primIdx]) else { break }

            // Read world positions from render primitive, transform back to local
            var localPts: [Vector3] = []
            for p in rp.points {
                let world = Vector3(x: Double(p.x), y: Double(p.y), z: 0)
                localPts.append(invTransform.transformPoint(world))
            }

            // Update the CADPrimitive with new local positions
            switch prim {
            case .point(_, let c):
                if let pt = localPts.first { prim = .point(position: pt, color: c) }
            case .line(_, _, let c):
                if localPts.count >= 2 { prim = .line(start: localPts[0], end: localPts[1], color: c) }
            case .rect(_, let size, let c):
                if let pt = localPts.first { prim = .rect(origin: pt, size: size, color: c) }
            case .fillRect(_, let size, let c):
                if let pt = localPts.first { prim = .fillRect(origin: pt, size: size, color: c) }
            case .polygon(_, let c):
                prim = .polygon(points: localPts, color: c)
            case .polyline(_, let c):
                prim = .polyline(points: localPts, color: c)
            case .fillPolygon(_, let c):
                prim = .fillPolygon(points: localPts, color: c)
            case .fillComplexPolygon(_, let holes, let c):
                prim = .fillComplexPolygon(outer: localPts, holes: holes, color: c)
            case .circle(_, _, let c):
                // localPts[0]=center, [1]=east, [2]=north, [3]=west, [4]=south
                if localPts.count >= 5 {
                    let newCenter = localPts[0]
                    // Average radius from all 4 quadrant points
                    let r1 = hypot(localPts[1].x - newCenter.x, localPts[1].y - newCenter.y)
                    let r2 = hypot(localPts[2].x - newCenter.x, localPts[2].y - newCenter.y)
                    let r3 = hypot(localPts[3].x - newCenter.x, localPts[3].y - newCenter.y)
                    let r4 = hypot(localPts[4].x - newCenter.x, localPts[4].y - newCenter.y)
                    let newRadius = (r1 + r2 + r3 + r4) / 4.0
                    prim = .circle(center: newCenter, radius: newRadius, color: c)
                }
            case .arc:
                // Intentional no-op. For arcs, rp.points holds the tessellated
                // polyline (segments + 1 samples), NOT [center, start, end, mid],
                // so deriving parameters from it here would corrupt the arc.
                // Arc grip drags write the solved CADPrimitive live on every
                // frame (moveVertexDirect), so the source geometry is already
                // authoritative. This branch is also unreachable in practice:
                // gripEditedGeometryNeedsFinalize returns false for geometry
                // containing an arc.
                break
            case .spline(_, let knots, let degree, let weights, let c):
                // Control points are the grip points; update them directly
                if !localPts.isEmpty {
                    prim = .spline(controlPoints: localPts, knots: knots,
                                   degree: degree, weights: weights, color: c)
                }
            case .ellipse(_, _, let minorRatio, let c):
                // localPts[0]=center, [1]=major+end, [2]=major-end, [3]=minor+end, [4]=minor-end
                if localPts.count >= 5 {
                    let newCenter = localPts[0]
                    let v1 = Vector3(x: localPts[1].x - newCenter.x, y: localPts[1].y - newCenter.y, z: 0)
                    let halfMajor = v1.magnitude
                    let newMajorAxis = Vector3(x: v1.x, y: v1.y, z: 0)
                    let v3 = Vector3(x: localPts[3].x - newCenter.x, y: localPts[3].y - newCenter.y, z: 0)
                    let halfMinor = v3.magnitude
                    let newMinorRatio = halfMajor > 1e-9 ? halfMinor / halfMajor : minorRatio
                    prim = .ellipse(center: newCenter, majorAxis: newMajorAxis, minorRatio: newMinorRatio, color: c)
                }
            case .hatch(_, let pattern, let scale, let angle, let c):
                prim = .hatch(boundary: localPts, pattern: pattern, scale: scale, angle: angle, color: c)
            case .ray(_, _, let c):
                if localPts.count >= 2 {
                    let dir = Vector3(x: localPts[1].x - localPts[0].x, y: localPts[1].y - localPts[0].y, z: 0)
                    prim = .ray(start: localPts[0], direction: dir, color: c)
                }
            default: break
            }
            newGeometry[primIdx] = prim
        }

        // Write back to source
        if let blockID = entity.blockID {
            document.updateBlockGeometry(handle: blockID, geometry: newGeometry)
        } else {
            document.updateEntityGeometry(for: handle, geometry: newGeometry)
        }
    }

    public func forEachWorldSegment(
        handle: UUID, in gm: GeometryManager,
        _ body: @MainActor (_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Void
    ) {
        guard let ids = bridge.entityPrimitiveMap[handle] else { return }
        for id in ids {
            guard let rp = gm.getPrimitive(id: id), rp.points.count >= 2 else { continue }
            let pts = rp.points  // local reference, no copy
            for i in 0..<(pts.count - 1) {
                body(Double(pts[i].x), Double(pts[i].y),
                     Double(pts[i+1].x), Double(pts[i+1].y))
            }
        }
    }



    /// Directly rotate primitives around a center point by angle delta (radians).
    public func rotatePrimitivesDirect(
        handles: Set<UUID>, around center: (Double, Double),
        angleDelta: Double, in gm: GeometryManager
    ) {
        let cx = Float(center.0)
        let cy = Float(center.1)
        let cosR = Float(cos(angleDelta))
        let sinR = Float(sin(angleDelta))
        for handle in handles {
            guard let ids = bridge.entityPrimitiveMap[handle] else { continue }
            for id in ids {
                guard let prim = gm.getPrimitive(id: id) else { continue }
                func rotate(_ p: inout SDL_FPoint) {
                    let rx = p.x - cx
                    let ry = p.y - cy
                    p.x = cx + rx * cosR - ry * sinR
                    p.y = cy + rx * sinR + ry * cosR
                }
                for i in 0..<prim.points.count { rotate(&prim.points[i]) }
                for i in 0..<prim.rects.count {
                    var r = prim.rects[i]
                    // Rotate top-left and bottom-right, rebuild rect from them
                    var tl = SDL_FPoint(x: r.x, y: r.y)
                    var br = SDL_FPoint(x: r.x + r.w, y: r.y + r.h)
                    rotate(&tl)
                    rotate(&br)
                    r.x = min(tl.x, br.x)
                    r.y = min(tl.y, br.y)
                    r.w = abs(br.x - tl.x)
                    r.h = abs(br.y - tl.y)
                    prim.rects[i] = r
                }
                for i in 0..<prim.corners.count { rotate(&prim.corners[i]) }
                // Bounds: recompute lazily — just invalidate
                prim.worldMinX = nil  // forces lazy recompute on next access
                prim.cameraGenerationPoints = -1
                prim.cameraGenerationRects = -1
                prim.cameraGenerationCorners = -1
            }
        }
    }



    /// Directly scale primitives around a center point by factor.
    public func scalePrimitivesDirect(
        handles: Set<UUID>, around center: (Double, Double),
        factor: Double, in gm: GeometryManager
    ) {
        let cx = Float(center.0)
        let cy = Float(center.1)
        let f = Float(factor)
        for handle in handles {
            guard let ids = bridge.entityPrimitiveMap[handle] else { continue }
            for id in ids {
                guard let prim = gm.getPrimitive(id: id) else { continue }
                func scale(_ p: inout SDL_FPoint) {
                    p.x = cx + (p.x - cx) * f
                    p.y = cy + (p.y - cy) * f
                }
                for i in 0..<prim.points.count { scale(&prim.points[i]) }
                for i in 0..<prim.rects.count {
                    var r = prim.rects[i]
                    var tl = SDL_FPoint(x: r.x, y: r.y)
                    var br = SDL_FPoint(x: r.x + r.w, y: r.y + r.h)
                    scale(&tl)
                    scale(&br)
                    r.x = min(tl.x, br.x)
                    r.y = min(tl.y, br.y)
                    r.w = abs(br.x - tl.x)
                    r.h = abs(br.y - tl.y)
                    prim.rects[i] = r
                }
                for i in 0..<prim.corners.count { scale(&prim.corners[i]) }
                prim.worldMinX = nil
                prim.cameraGenerationPoints = -1
                prim.cameraGenerationRects = -1
                prim.cameraGenerationCorners = -1
            }
        }
    }


    public func endVertexDirectEdit(handle: UUID, vertexIndex: Int) {
        arcEditSessions.removeValue(forKey: "\(handle.uuidString):\(vertexIndex)")
    }
}