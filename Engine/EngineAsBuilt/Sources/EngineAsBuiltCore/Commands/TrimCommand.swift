import Foundation
import CSDL3
import ImGui
import SwiftSDL

private final class TrimMutationState {
    var didModify = false
}

// =========================================================================
// MARK: - TrimCommand
// =========================================================================

/// TRIM — Quick-mode trim with exploding cutting edges.
///
/// **Workflow (AutoCAD-style quick trim):**
///   1. Type `TRIM` (or `TR`). All visible entities become potential cutting edges.
///   2. Click on an entity near the portion you want to remove.
///   3. The entity is shortened/trimmed to nearest intersection(s) with cutting edges,
///      keeping the side you clicked on. Command stays active — Esc to finish.
///
/// **Algorithm (per click):**
///   - **Step 1** — Hit-test at RAW (unsnapped) click. Unsnapped coords preserve correct
///     side-selection logic that snap would corrupt.
///   - **Step 2** — Exclude block references as trim targets (must explode first).
///   - **Step 3** — Find nearest primitive in entity's `localGeometry` by distance to click.
///   - **Step 4** — Collect cutting edges: explode every primitive from all OTHER visible
///     entities into line segments. Curved primitives use high-precision adaptive
///     tessellation so intersections are suitable for subsequent trim/join operations.
///       * Polygon/FillPolygon/Rect → edge loops
///   - **Step 5** — Compute intersection(s) between target and all cutting segments.
///   - **Step 6** — Compute click parameter `tClick` along target. Pick intersection
///     whose parameter is closest to `tClick`:
///       * `tClick < tHit` → click before intersection → trim start-side (remove [0..tHit])
///       * `tClick > tHit` → click after intersection → trim end-side (remove [tHit..1])
///   - **Step 7** — Apply trim: update entity geometry via doc. Delete entity if no primitives remain.
///
/// **Per-primitive trim strategies:**
///   - `.line` — Direct segment-segment intersection, parameterized line trim.
///   - `.arc` — Segment-circle intersection on arc sweep, parameterized angle trim.
///   - `.circle` — Multi-intersection: click selects which arc segment to remove.
///     Converts circle to arc spanning the non-removed portion. Requires ≥2 intersections.
///   - All others (polygons, splines, ellipses, rects, etc.) — Exploded to segments,
///     trimmed by segment-segment intersection along parameterized polyline.
///     Result rebuilt as `.line()` primitives.
///
/// **Scope:** Endpoint/segment trim only — shortens or removes portion of entity.
/// Does not split entity into two pieces or bridge-trim middle sections between two
/// intersections (v2).
@MainActor
public final class TrimCommand: FeatureCommand {

    // MARK: - State

    /// True while command is waiting for clicks; Esc or empty-space click sets false.
    private var active: Bool = true

    // MARK: - Init

    public init() {}

    public var isSnappingEnabled: Bool { return false }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = true
        processor.commandPrompt = "Click on an object to trim (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
    }

    // MARK: - Helpers

    /// Explodes a primitive into a list of world-space line segments using the given transform.
    ///
    /// Each primitive type is tessellated into a high-precision polyline approximation:
    ///   - Line → single segment
    ///   - Polygon / FillPolygon / FillComplexPolygon / Gradient → closed loop of edges
    ///   - Circle / arc / ellipse → adaptive subdivision bounded by chord error
    ///   - Spline → dense NURBS evaluation
    ///   - Rect / FillRect → 4 corners as closed loop
    /// Used for collecting cutting edges (world space) and for exploded target trimming (local space).
    private func explode(primitive: CADPrimitive, t: Transform3D) -> [(Vector3, Vector3)] {
        /// Returns enough segments to keep the sagitta below roughly one ten-millionth
        /// of the radius. The cap prevents pathological geometry from making TRIM
        /// unresponsive while still improving the previous 32–48 segment curves by
        /// nearly two orders of magnitude.
        func curvedSegmentCount(radius: Double, span: Double = 2.0 * .pi) -> Int {
            guard radius > 1e-12, span > 0 else { return 2 }
            let relativeChordError = 1e-7
            let maxStep = 2.0 * acos(max(-1.0, min(1.0, 1.0 - relativeChordError)))
            guard maxStep.isFinite, maxStep > 0 else { return 4096 }
            return max(2, min(4096, Int(ceil(span / maxStep))))
        }

        var segs: [(Vector3, Vector3)] = []
        switch primitive {
        case .line(let ls, let le, _):
            // Single line: transform both endpoints.
            segs.append((t.transformPoint(ls), t.transformPoint(le)))
        case .polygon(let pts, _), .fillPolygon(let pts, _), .fillComplexPolygon(let pts, _, _), .gradient(let pts, _, _, _, _, _):
            // Closed polygon: edge between consecutive points + closing edge.
            guard pts.count >= 2 else { return [] }
            for i in 0..<(pts.count - 1) { segs.append((t.transformPoint(pts[i]), t.transformPoint(pts[i+1]))) }
            segs.append((t.transformPoint(pts.last!), t.transformPoint(pts.first!)))
        case .polyline(let pts, _):
            // Open polyline: edge between consecutive points only.
            guard pts.count >= 2 else { return [] }
            for i in 0..<(pts.count - 1) { segs.append((t.transformPoint(pts[i]), t.transformPoint(pts[i+1]))) }
        case .circle(let center, let radius, _):
            let seg = curvedSegmentCount(radius: radius)
            var pts: [Vector3] = []
            for i in 0..<seg {
                let a = 2.0 * Double.pi * Double(i) / Double(seg)
                pts.append(t.transformPoint(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)))
            }
            for i in 0..<(pts.count - 1) { segs.append((pts[i], pts[i+1])) }
            segs.append((pts.last!, pts.first!))
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * Double.pi }
            let seg = curvedSegmentCount(radius: radius, span: span)
            var pts: [Vector3] = []
            for i in 0...seg {
                let a = startAngle + span * Double(i) / Double(seg)
                pts.append(t.transformPoint(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)))
            }
            for i in 0..<(pts.count - 1) { segs.append((pts[i], pts[i+1])) }
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let segsCount = curvedSegmentCount(radius: max(majorLen, abs(minorLen)))
            let rot = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(rot); let sinRot = sin(rot)
            for i in 0..<segsCount {
                let t1 = Double(i) * 2.0 * .pi / Double(segsCount)
                let t2a = Double((i + 1) % segsCount) * 2.0 * .pi / Double(segsCount)
                let p1 = Vector3(
                    x: majorLen * cos(t1) * cosRot - minorLen * sin(t1) * sinRot + center.x,
                    y: majorLen * cos(t1) * sinRot + minorLen * sin(t1) * cosRot + center.y,
                    z: center.z)
                let p2 = Vector3(
                    x: majorLen * cos(t2a) * cosRot - minorLen * sin(t2a) * sinRot + center.x,
                    y: majorLen * cos(t2a) * sinRot + minorLen * sin(t2a) * cosRot + center.y,
                    z: center.z)
                segs.append((t.transformPoint(p1), t.transformPoint(p2)))
            }
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            // Dense evaluation is used here because these segments are construction
            // geometry for intersections, not merely display geometry.
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let segmentCount = min(4096, max(512, controlPoints.count * 128))
            let evaluated = NURBSEvaluator.evaluate(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: w,
                segments: segmentCount)
            if evaluated.count >= 2 {
                for i in 0..<(evaluated.count - 1) {
                    segs.append((t.transformPoint(evaluated[i]), t.transformPoint(evaluated[i+1])))
                }
            }
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            // Four corners as closed polyline.
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ]
            for i in 0..<4 {
                segs.append((t.transformPoint(corners[i]), t.transformPoint(corners[(i+1)%4])))
            }
        default: break
        }
        return segs
    }

    /// Computes intersection points between a finite line segment and a circle.
    ///
    /// Solves the quadratic: `|A + t*(B-A) - C|² = r²` for t ∈ [0, 1] (with 1e-9 slop).
    /// Returns 0, 1, or 2 world-space intersection points. Used by arc/circle trim
    /// to find where cutting edges intersect circular geometry.
    ///
    /// - Parameters:
    ///   - segmentA, segmentB: world-space endpoints of the cutting segment
    ///   - circleCenter: world-space center of the target circle/arc
    ///   - radius: world-space radius (accounting for scale)
    /// - Returns: up to 2 intersection points (de-duplicated if t values are within 1e-12)
    private func intersectSegmentCircle(
        segmentA: Vector3, segmentB: Vector3,
        circleCenter: Vector3, radius: Double
    ) -> [Vector3] {
        let dir = Vector3(x: segmentB.x - segmentA.x, y: segmentB.y - segmentA.y, z: segmentB.z - segmentA.z)
        let dx = dir.x; let dy = dir.y
        let fx = segmentA.x - circleCenter.x; let fy = segmentA.y - circleCenter.y

        let a = dx * dx + dy * dy
        let b = 2.0 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius

        let discriminant = b * b - 4.0 * a * c
        if discriminant < 0 { return [] }

        let sqrtD = sqrt(discriminant)
        let t1 = (-b - sqrtD) / (2.0 * a)
        let t2 = (-b + sqrtD) / (2.0 * a)

        var result: [Vector3] = []
        // t must be within [0, 1] (with small epsilon for numerical stability)
        if t1 >= -1e-9 && t1 <= 1.0 + 1e-9 {
            result.append(Vector3(x: segmentA.x + t1 * dx, y: segmentA.y + t1 * dy, z: segmentA.z))
        }
        if t2 >= -1e-9 && t2 <= 1.0 + 1e-9 && abs(t2 - t1) > 1e-12 {
            result.append(Vector3(x: segmentA.x + t2 * dx, y: segmentA.y + t2 * dy, z: segmentA.z))
        }
        return result
    }

    /// Extracts the color from a primitive, if it carries one.
    ///
    /// Used when rebuilding exploded primitives (splines, polygons, etc.) as `.line()` primitives
    /// so the resulting lines retain the original entity's color. Returns nil for primitives
    /// that have no intrinsic color (e.g. `.isVisible`, `.handle`, `.blockRef`).
    private func colorForPrimitive(_ p: CADPrimitive) -> ColorRGBA? {
        switch p {
        case .line(_, _, let c): return c
        case .arc(_, _, _, _, let c): return c
        case .circle(_, _, let c): return c
        case .ellipse(_, _, _, let c): return c
        case .spline(_, _, _, _, let c): return c
        case .polygon(_, let c): return c
        case .polyline(_, let c): return c
        case .rect(_, _, let c): return c
        case .fillPolygon(_, let c): return c
        case .fillRect(_, _, let c): return c
        default: return nil
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard active else { return .finished }

        // Use RAW (unsnapped) coords so side-selection is not corrupted
        // by snap pulling the click onto the intersection itself.
        let rawScreenX = engine.interaction.lastMouseX
        let rawScreenY = engine.interaction.lastMouseY
        let (rawWX, rawWY) = engine.camera.screenToWorld(screenX: Float(rawScreenX), screenY: Float(rawScreenY), windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let rawClick = Vector3(x: rawWX, y: rawWY, z: 0)

        let doc = engine.document

        // ── Step 1: Hit-test for entity under click ──
        // Use simplifyComplexBlocks: false for precise primitive picking.
        guard let hitHandle = CADHitTesting.hitTest(
            worldX: rawWX, worldY: rawWY,
            document: doc,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false
        ) else {
            // Clicked empty space → finish command.
            active = false
            processor.commandPrompt = nil
            return .finished
        }

        // ── Step 2: Exclude block references ──
        guard let entity = doc.entity(for: hitHandle) else { return .continue }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Cannot trim block references. Explode them first."
            return .continue
        }

        // ── Step 3: Find nearest primitive in localGeometry ──
        guard let localGeom = entity.localGeometry, !localGeom.isEmpty else {
            processor.commandPrompt = "Entity has no local geometry."
            return .continue
        }

        let transform = entity.transform
        let invTransform = transform.inverse()

        // Find closest primitive (any type) by squared distance to raw click.
        var bestPrimIndex: Int? = nil
        var bestPrimDistSq: Double = .infinity

        for (i, prim) in localGeom.enumerated() {
            if let d = CADHitTesting.distanceSqToPrimitive(prim, point: rawClick, transform: transform, t2: .infinity) {
                if d < bestPrimDistSq {
                    bestPrimDistSq = d
                    bestPrimIndex = i
                }
            }
        }

        guard let primIndex = bestPrimIndex else {
            processor.commandPrompt = "No primitive found."
            return .continue
        }

        let targetPrim = localGeom[primIndex]

        // ── Step 4: Collect cutting edges from all OTHER visible entities ──
        // Every primitive from every other entity is exploded into line segments.
        // Skip invisible layers, block references, and the target entity itself.
        var cuttingSegments: [(Vector3, Vector3)] = []
        for otherEntity in doc.entitiesView {
            guard otherEntity.handle != hitHandle else { continue }
            guard let layer = doc.layer(for: otherEntity.layerID), layer.isVisible else { continue }
            guard otherEntity.blockID == nil else { continue }
            guard let geom = doc.resolvedGeometry(for: otherEntity) else { continue }
            for prim in geom {
                cuttingSegments.append(contentsOf: explode(primitive: prim, t: otherEntity.transform))
            }
        }

        // ── Step 5–7: Trim based on primitive type ──
        // newGeometry is a mutable copy; deleteTarget/updateTarget mutate it in-place.
        var newGeometry = localGeom
        let mutationState = TrimMutationState()

        /// Removes the target primitive from the geometry copy.
        func deleteTarget() {
            newGeometry.remove(at: primIndex)
            mutationState.didModify = true
        }

        /// Replaces the target primitive with new primitives at same index.
        func updateTarget(_ newPrims: [CADPrimitive]) {
            newGeometry.remove(at: primIndex)
            newGeometry.insert(contentsOf: newPrims, at: primIndex)
            mutationState.didModify = true
        }

        switch targetPrim {

        // ── .line: segment-segment intersection, parameterized trim ──
        case .line(let ls, let le, let color):
            // Convert line to world space.
            let ws = transform.transformPoint(ls)
            let we = transform.transformPoint(le)
            let segDX = we.x - ws.x; let segDY = we.y - ws.y
            let segLenSq = segDX * segDX + segDY * segDY
            if segLenSq <= 1e-18 { deleteTarget(); break }

            // Compute tClick: the click's projection onto the segment, clamped to [0,1].
            let dpX: Double = rawClick.x - ws.x
            let dpY: Double = rawClick.y - ws.y
            let dot: Double = dpX * segDX + dpY * segDY
            var tClick: Double = dot / segLenSq
            tClick = max(0.0, min(1.0, tClick))

            // Find all segment-segment intersections with cutting edges.
            // Exclude intersections at endpoints (tolerance 1e-9) — those aren't trims.
            struct Hit { let point: Vector3; let t: Double }
            var hits: [Hit] = []

            for edge in cuttingSegments {
                guard let res = CADGeometryMath.segmentSegmentIntersection(a: ws, b: we, c: edge.0, d: edge.1) else { continue }
                if res.t > 1e-9 && res.t < 1.0 - 1e-9 { hits.append(Hit(point: res.point, t: res.t)) }
            }

            if hits.isEmpty {
                // A numerical miss must never destroy otherwise valid geometry.
                break
            } else {
                var tBefore = 0.0
                var tAfter = 1.0
                for h in hits {
                    if h.t < tClick && h.t > tBefore { tBefore = h.t }
                    if h.t > tClick && h.t < tAfter { tAfter = h.t }
                }
                
                var newPrims: [CADPrimitive] = []
                if tBefore > 1e-9 {
                    let localBefore = Vector3(
                        x: ls.x + tBefore * (le.x - ls.x),
                        y: ls.y + tBefore * (le.y - ls.y),
                        z: ls.z + tBefore * (le.z - ls.z))
                    newPrims.append(.line(start: ls, end: localBefore, color: color))
                }
                if tAfter < 1.0 - 1e-9 {
                    let localAfter = Vector3(
                        x: ls.x + tAfter * (le.x - ls.x),
                        y: ls.y + tAfter * (le.y - ls.y),
                        z: ls.z + tAfter * (le.z - ls.z))
                    newPrims.append(.line(start: localAfter, end: le, color: color))
                }
                if newPrims.isEmpty {
                    break
                } else {
                    updateTarget(newPrims)
                }
            }

        // ── .arc: segment-circle intersection on arc sweep, parameterized angle trim ──
        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            // Convert arc to world space: center + rotation, radius * scale.
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * max(abs(s.x), abs(s.y))
            let wsa = startAngle + transform.rotation
            let wea = endAngle + transform.rotation
            // Normalize sweep to positive CCW range.
            var span = wea - wsa
            if span < 0 { span += 2 * .pi }

            // Find segment-circle intersections that lie on the arc's CCW sweep.
            struct Hit { let point: Vector3; let angle: Double }
            var hits: [Hit] = []

            for edge in cuttingSegments {
                let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
                for pt in pts {
                    let a: Double = atan2(pt.y - wc.y, pt.x - wc.x)
                    let wsaSpan: Double = wsa + span
                    if CADGeometryMath.angleIsOnCCWSweep(angle: a, start: wsa, end: wsaSpan) {
                        hits.append(Hit(point: pt, angle: a))
                    }
                }
            }

            if hits.isEmpty {
                break
            } else {
                // Compute click angle and normalize within [0, 2π).
                let rawAngle = atan2(rawClick.y - wc.y, rawClick.x - wc.x)
                let twoPi = 2.0 * .pi
                func norm(_ v: Double) -> Double { var r = v.truncatingRemainder(dividingBy: twoPi); if r < 0 { r += twoPi }; return r }
                
                // clickT is the angle from arc start to click, normalized.
                let rawDiff: Double = rawAngle - wsa
                let clickT: Double = norm(rawDiff)
                
                var tBefore = 0.0
                var tAfter = span
                for h in hits {
                    let hT = norm(h.angle - wsa)
                    if hT < clickT && hT > tBefore { tBefore = hT }
                    if hT > clickT && hT < tAfter { tAfter = hT }
                }

                var newPrims: [CADPrimitive] = []
                if tBefore > 1e-5 {
                    let localEnd = startAngle + tBefore
                    newPrims.append(.arc(center: center, radius: radius, startAngle: startAngle, endAngle: localEnd, color: color))
                }
                if tAfter < span - 1e-5 {
                    let localStart = startAngle + tAfter
                    let localEnd = startAngle + span
                    newPrims.append(.arc(center: center, radius: radius, startAngle: localStart, endAngle: localEnd, color: color))
                }
                
                if newPrims.isEmpty {
                    break
                } else {
                    updateTarget(newPrims)
                }
            }

        // ── .circle: multi-intersection → pick arc segment to remove, convert to .arc ──
        // Circle trim deletes the arc between two consecutive intersection points
        // that contains the click, converting the circle into the remaining arc.
        // Requires ≥2 distinct intersections on the circle.
        case .circle(let center, let radius, let color):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * max(abs(s.x), abs(s.y))

            struct Hit { let point: Vector3; let angle: Double }
            var hits: [Hit] = []

            // Collect all segment-circle intersection points (no sweep filtering — full circle).
            for edge in cuttingSegments {
                let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
                for pt in pts {
                    let a = atan2(pt.y - wc.y, pt.x - wc.x)
                    hits.append(Hit(point: pt, angle: a))
                }
            }

            if hits.isEmpty {
                break
            } else {
                let clickAngle = atan2(rawClick.y - wc.y, rawClick.x - wc.x)
                let twoPi = 2.0 * .pi
                func norm(_ v: Double) -> Double { var r = v.truncatingRemainder(dividingBy: twoPi); if r < 0 { r += twoPi }; return r }

                // Deduplicate intersection angles (within 1e-5 tolerance) and sort CCW.
                var sortedAngles: [Double] = []
                for h in hits {
                    let a = norm(h.angle)
                    if !sortedAngles.contains(where: { abs($0 - a) < 1e-5 || abs($0 - a) > twoPi - 1e-5 }) {
                        sortedAngles.append(a)
                    }
                }
                sortedAngles.sort()
                
                if sortedAngles.isEmpty {
                    break
                } else if sortedAngles.count < 2 {
                    processor.commandPrompt = "Circle needs at least 2 distinct intersections to trim."
                } else {
                    // Find which angular segment contains the click.
                    // segmentIndex is the start of the removed arc.
                    var segmentIndex = sortedAngles.count - 1
                    let cAngle = norm(clickAngle)
                    for i in 0..<sortedAngles.count {
                        if cAngle < sortedAngles[i] {
                            segmentIndex = (i == 0) ? sortedAngles.count - 1 : i - 1
                            break
                        }
                    }
                    
                    // Remove arc from one intersection to the next (CCW).
                    // The kept arc goes from removeEnd to removeStart.
                    let removeStartW = sortedAngles[segmentIndex]
                    let removeEndW = sortedAngles[(segmentIndex + 1) % sortedAngles.count]
                    
                    // Convert back to local angles by subtracting entity rotation.
                    let localStart = removeEndW - transform.rotation
                    let localEnd = removeStartW - transform.rotation
                    
                    // Circle becomes an arc covering the non-removed portion.
                    updateTarget([.arc(center: center, radius: radius, startAngle: localStart, endAngle: localEnd, color: color)])
                }
            }

        // ── .spline: NURBS subdivision trim (preserves spline type) ──
        // Uses knot-insertion (Boehm's algorithm) to split the NURBS curve at
        // the intersection parameter, preserving the original spline representation.
        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let p = degree

            // Transform cutting edges to local space for intersection testing.
            let localEdges: [(Vector3, Vector3)] = cuttingSegments.map { edge in
                (invTransform.transformPoint(edge.0),
                 invTransform.transformPoint(edge.1))
            }

            // Find all intersection parameters along the spline.
            struct SplineHit { let t: Double; let point: Vector3 }
            var hits: [SplineHit] = []

            for edge in localEdges {
                let results = NURBSEvaluator.findIntersectionParameters(
                    degree: p,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: w,
                    segmentA: edge.0,
                    segmentB: edge.1
                )
                for result in results {
                    // Avoid duplicate intersections at nearly the same t
                    let isDuplicate = hits.contains { abs($0.t - result.t) < 1e-6 }
                    if !isDuplicate {
                        hits.append(SplineHit(t: result.t, point: result.point))
                    }
                }
            }

            if hits.isEmpty {
                break
            } else {
                // Compute click parameter along the spline.
                // Find closest point on the evaluated polyline to the click,
                // then get the corresponding NURBS parameter.
                let invClick = invTransform.transformPoint(rawClick)
                let tClick = NURBSEvaluator.findClosestParameter(
                    degree: p,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: w,
                    to: invClick,
                    segments: 48)

                let minT = knots.min() ?? 0.0
                let maxT = knots.max() ?? 1.0
                var tBefore = minT
                var tAfter = maxT

                for h in hits {
                    if h.t < tClick && h.t > tBefore { tBefore = h.t }
                    if h.t > tClick && h.t < tAfter { tAfter = h.t }
                }

                var newPrims: [CADPrimitive] = []
                var subdivisionFailed = false

                if tBefore > minT + 1e-6 {
                    if let split = NURBSEvaluator.subdivide(
                        degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tBefore
                    ) {
                        newPrims.append(.spline(
                            controlPoints: split.left.controlPoints,
                            knots: split.left.knots,
                            degree: p,
                            weights: split.left.weights,
                            color: color))
                    } else {
                        subdivisionFailed = true
                    }
                }

                if tAfter < maxT - 1e-6 {
                    if let split = NURBSEvaluator.subdivide(
                        degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tAfter
                    ) {
                        newPrims.append(.spline(
                            controlPoints: split.right.controlPoints,
                            knots: split.right.knots,
                            degree: p,
                            weights: split.right.weights,
                            color: color))
                    } else {
                        subdivisionFailed = true
                    }
                }

                if subdivisionFailed {
                    // Subdivision failed — fall back to polyline trim.
                    fallthrough
                }

                if newPrims.isEmpty {
                    break
                } else {
                    updateTarget(newPrims)
                }
            }

        // ── default: exploded polyline trim (polygons, ellipses, rects, etc.) ──
        // Generic trim for any non-line/non-arc/non-circle/non-spline primitive:
        //   1. Explode primitive into local-space segments (no transform).
        //   2. Build cumulative length array for parameterizing along polyline.
        //   3. Find closest segment to click → compute global tClick ∈ [0,1].
        //   4. Intersect all cutting edges (inverse-transformed to local) with exploded segments.
        //   5. Choose intersection closest to tClick.
        //   6. Rebuild the kept portion as `.line()` primitives.
        default:
            // Explode in local space (identity transform) for parameterization.
            let targetSegs = explode(primitive: targetPrim, t: .identity)
            if targetSegs.isEmpty { deleteTarget(); break }

            // Cumulative length array: cumLen[i] = total length from start to segment i start.
            var cumLen: [Double] = [0]
            for s in targetSegs {
                let dx: Double = s.1.x - s.0.x
                let dy: Double = s.1.y - s.0.y
                let dxSq: Double = dx * dx
                let dySq: Double = dy * dy
                let segLen: Double = sqrt(dxSq + dySq)
                cumLen.append(cumLen.last! + segLen)
            }
            let totalLen = cumLen.last!
            guard totalLen > 1e-9 else { deleteTarget(); break }

            // Find which segment contains the click and compute global tClick.
            var bestSegIdx = 0
            var bestDistSq = Double.infinity
            var bestSegTClick = 0.0
            let invClick = invTransform.transformPoint(rawClick)
            for (i, s) in targetSegs.enumerated() {
                let dx: Double = s.1.x - s.0.x
                let dy: Double = s.1.y - s.0.y
                let dxSq: Double = dx * dx
                let dySq: Double = dy * dy
                let ls: Double = dxSq + dySq
                var t: Double = 0.0
                if ls > 1e-18 {
                    let dX: Double = invClick.x - s.0.x
                    let dY: Double = invClick.y - s.0.y
                    let dot: Double = dX * dx + dY * dy
                    t = dot / ls
                    t = max(0.0, min(1.0, t))
                }
                let qx = s.0.x + t*dx
                let qy = s.0.y + t*dy
                let distDX = invClick.x - qx
                let distDY = invClick.y - qy
                let distSq = (distDX * distDX) + (distDY * distDY)
                if distSq < bestDistSq {
                    bestDistSq = distSq
                    bestSegIdx = i
                    bestSegTClick = t
                }
            }
            let tClick = (cumLen[bestSegIdx] + bestSegTClick * (cumLen[bestSegIdx+1] - cumLen[bestSegIdx])) / totalLen

            // Find all intersections between cutting edges and exploded segments.
            // Edges transformed to local space via inverse transform.
            struct Hit { let localPoint: Vector3; let t: Double }
            var hits: [Hit] = []

            for edge in cuttingSegments {
                let localEdge0 = invTransform.transformPoint(edge.0)
                let localEdge1 = invTransform.transformPoint(edge.1)

                for (i, s) in targetSegs.enumerated() {
                    guard let res = CADGeometryMath.segmentSegmentIntersection(a: s.0, b: s.1, c: localEdge0, d: localEdge1) else { continue }
                    if res.t >= -1e-9 && res.t <= 1.0 + 1e-9 {
                        let segLen = cumLen[i+1] - cumLen[i]
                        let globalT = (cumLen[i] + res.t * segLen) / totalLen
                        if globalT > 1e-9 && globalT < 1.0 - 1e-9 {
                            hits.append(Hit(localPoint: res.point, t: globalT))
                        }
                    }
                }
            }

            if hits.isEmpty {
                break
            } else {
                var tBefore = 0.0
                var tAfter = 1.0
                for h in hits {
                    if h.t < tClick && h.t > tBefore { tBefore = h.t }
                    if h.t > tClick && h.t < tAfter { tAfter = h.t }
                }

                var newPrims: [CADPrimitive] = []
                let color = colorForPrimitive(targetPrim)
                
                /// Builds `.line()` primitives for the portion of the exploded polyline
                /// between global parameters startT and endT (both in [0,1]).
                /// Skips degenerate segments (<1e-9 length).
                func buildLines(fromT startT: Double, toT endT: Double) {
                    guard endT > startT else { return }
                    for (i, s) in targetSegs.enumerated() {
                        let segStartT = cumLen[i] / totalLen
                        let segEndT = cumLen[i+1] / totalLen
                        
                        if segEndT <= startT + 1e-9 { continue }
                        if segStartT >= endT - 1e-9 { continue }
                        
                        let startDiff: Double = startT - segStartT
                        let endDiff: Double = endT - segStartT
                        let segDiff: Double = segEndT - segStartT
                        let localStartFraction: Double = max(0.0, startDiff / segDiff)
                        let localEndFraction: Double = min(1.0, endDiff / segDiff)
                        
                        let dx: Double = s.1.x - s.0.x
                        let dy: Double = s.1.y - s.0.y
                        let pA = Vector3(x: s.0.x + localStartFraction * dx, y: s.0.y + localStartFraction * dy, z: s.0.z)
                        let pB = Vector3(x: s.0.x + localEndFraction * dx, y: s.0.y + localEndFraction * dy, z: s.0.z)
                        
                        let diffX: Double = pB.x - pA.x
                        let diffY: Double = pB.y - pA.y
                        let diffXSq: Double = diffX * diffX
                        let diffYSq: Double = diffY * diffY
                        if diffXSq + diffYSq > 1e-9 {
                            newPrims.append(.line(start: pA, end: pB, color: color))
                        }
                    }
                }

                if tBefore > 1e-9 {
                    buildLines(fromT: 0.0, toT: tBefore)
                }
                if tAfter < 1.0 - 1e-9 {
                    buildLines(fromT: tAfter, toT: 1.0)
                }
                
                if newPrims.isEmpty {
                    break
                } else {
                    updateTarget(newPrims)
                }
            }
        }

        // ── Step 8: Apply the change ──
        if !mutationState.didModify {
            processor.commandPrompt = "No valid trim intersection found. Geometry was left unchanged."
            return .continue
        } else if newGeometry.isEmpty {
            // No primitives remain → delete entity entirely.
            doc.removeEntities(handles: Set([hitHandle]))
            engine.cadSelection.clearSelection()
        } else {
            doc.updateEntityGeometry(for: hitHandle, geometry: newGeometry)
        }

        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Trimmed. Click another object or Esc to finish."

        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // No-op — no live preview for trim (would be expensive with explode).
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            active = false
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // No overlay — trim shows no preview graphics.
    }
}
