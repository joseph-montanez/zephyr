import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - MeasureGeomTool
//
// Multi-mode measurement tool for the CAD application.
//
// Modes (cycled via Tab key):
//   - .quick: Real-time orthogonal raycast (±X, ±Y) from cursor to nearest
//     geometry PLUS boundary extraction with side-length and interior-angle
//     overlays. Uses spatial caching (point-in-polygon test) to avoid
//     recomputing the boundary every frame.
//   - .distance: Two-click point-to-point distance measurement with snapping.
//   - .area: Click inside enclosed region to detect boundary and compute area.
//   - .angle: Stub — reserved for future three-click angle measurement.
//
// All visuals are drawn via ImGui foreground draw list (immediate-mode).
// World coordinates are stored and projected to screen in renderOverlay each
// frame so lines/labels stay pinned to geometry during pan/zoom.

public enum MeasureMode: Sendable {
    case quick
    case distance
    case area
    case angle
}

@MainActor
public final class MeasureGeomTool: FeatureCommand {

    // MARK: - Constants

    /// Epsilon for orthogonal angle detection (|dot| < this → 90° corner).
    private static let orthoEpsilon: Double = 1e-4

    /// Size (in world units) of the orthogonal square icon drawn at right-angle corners.
    private static let orthoIconSize: Double = 0.15

    /// Number of line segments used to approximate a non-orthogonal angle arc.
    private static let arcSegments: Int = 12

    // MARK: - State

    public var currentMode: MeasureMode = .quick

    // Quick Measure — orthogonal rays
    /// Stored as world-space (cursor origin, intersection point) for each direction.
    /// Index 0: +X, 1: -X, 2: +Y, 3: -Y
    private var quickMeasurements: [(origin: Vector3, hit: Vector3)?] = [nil, nil, nil, nil]
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    // Distance Mode
    private var distancePointA: Vector3? = nil
    private var distancePointB: Vector3? = nil

    // Area Mode
    private var areaBoundary: [Vector3]? = nil
    private var areaLabel: String? = nil
    private var areaLabelPosition: Vector3? = nil

    // Active measurement labels: (text, world position)
    private var activeLabels: [(String, Vector3)] = []

    // --- Boundary cache (Quick Measure spatial caching) ---
    /// Cached enclosing polygon from the last successful boundary detection.
    /// When non-nil and the cursor is still inside it, boundary detection is skipped.
    private var cachedBoundary: [Vector3]? = nil

    /// Boundary edges extracted from the cached polygon (for side-length rendering).
    private var boundaryEdges: [(a: Vector3, b: Vector3)] = []

    /// Angle markers for each vertex of the boundary.
    /// isOrthogonal → draw square corner icon; otherwise → draw arc + angle text.
    private var angleMarkers: [(vertex: Vector3, angleDeg: Double, isOrthogonal: Bool, labelText: String)] = []

    // MARK: - Init

    public init() {}

    // MARK: - FeatureCommand Conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        resetState()
        processor.commandPrompt = "Measure [Q]uick | [D]istance | [A]rea — Tab to cycle, Esc to exit"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        resetState()
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch currentMode {
        case .quick:
            return .continue

        case .distance:
            return handleDistanceClick(worldX: worldX, worldY: worldY, engine: engine, processor: processor)

        case .area:
            return handleAreaClick(worldX: worldX, worldY: worldY, engine: engine, processor: processor)

        case .angle:
            activeLabels = [("Angle mode: not yet implemented", Vector3(x: worldX, y: worldY, z: 0))]
            return .continue
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY

        switch currentMode {
        case .quick:
            updateQuickMeasure(engine: engine)

        case .distance:
            if let ptA = distancePointA {
                activeLabels = [(
                    formatDistance(CADGeometryMath.pointToSegmentDistSq(
                        Vector3(x: worldX, y: worldY, z: 0), ptA, ptA)).0,
                    Vector3(x: (ptA.x + worldX) / 2, y: (ptA.y + worldY) / 2, z: 0)
                )]
            }

        case .area, .angle:
            break
        }
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_TAB:
            cycleMode(processor: processor)
            return .continue

        case SDL_SCANCODE_Q:
            currentMode = .quick
            resetModeState()
            processor.commandPrompt = "Quick Measure — orthogonal raycast + boundary active"
            return .continue

        case SDL_SCANCODE_D:
            currentMode = .distance
            resetModeState()
            processor.commandPrompt = "Distance — click first point"
            return .continue

        case SDL_SCANCODE_A:
            currentMode = .area
            resetModeState()
            processor.commandPrompt = "Area — click inside enclosed region"
            return .continue

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_ESCAPE:
            return .finished

        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)

        switch currentMode {
        case .quick:
            renderQuickOverlay(drawList: drawList, cam: cam)

        case .distance:
            renderDistanceOverlay(drawList: drawList, cam: cam)

        case .area:
            renderAreaOverlay(drawList: drawList, cam: cam)

        case .angle:
            break
        }

        renderLabels(drawList: drawList, cam: cam)
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        var pts: [Vector3] = []
        if let a = distancePointA { pts.append(a) }
        if let b = distancePointB { pts.append(b) }
        return pts
    }

    // =====================================================================
    // MARK: - Quick Measure (upgraded with boundary overlay)
    // =====================================================================

    private func updateQuickMeasure(engine: PhrostEngine) {
        let cursor = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)

        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let vpW = vp.maxX - vp.minX
        let vpH = vp.maxY - vp.minY
        let vpDiagonal = sqrt((vpW * vpW) + (vpH * vpH))
        let maxDist = vpDiagonal * 1.5

        // Clear ephemeral state.
        for i in 0..<4 { quickMeasurements[i] = nil }
        activeLabels.removeAll(keepingCapacity: true)
        boundaryEdges.removeAll(keepingCapacity: true)
        angleMarkers.removeAll(keepingCapacity: true)

        // ----- Orthogonal rays (±X, ±Y) -----
        let directions: [(dx: Double, dy: Double, label: String)] = [
            ( 1,  0, "+X"), (-1,  0, "-X"), ( 0,  1, "+Y"), ( 0, -1, "-Y"),
        ]
        for dirIdx in 0..<4 {
            let dir = directions[dirIdx]
            let rayDir = Vector3(x: dir.dx, y: dir.dy, z: 0)
            let candidates = engine.document.entityHandlesAlongRay(
                rayOrigin: cursor, rayDir: rayDir, maxDistance: maxDist)
            let handles = candidates ?? []

            var closestHit: Vector3? = nil
            var closestDistSq = Double.infinity
            var hitCount = 0

            for handle in handles {
                guard hitCount < 500 else { break }
                guard let entity = engine.document.entity(for: handle) else { continue }
                guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard let geometry = engine.document.resolvedGeometry(for: entity) else { continue }
                hitCount += 1

                let transform = entity.transform
                for prim in geometry {
                    if let hitPoint = intersectPrimitive(prim, transform: transform,
                                                          rayOrigin: cursor, rayDir: rayDir)
                    {
                        let hdx = hitPoint.x - cursor.x
                        let hdy = hitPoint.y - cursor.y
                        let dsq = (hdx * hdx) + (hdy * hdy)
                        if dsq < closestDistSq {
                            closestDistSq = dsq
                            closestHit = hitPoint
                        }
                    }
                }
            }

            if let hit = closestHit {
                quickMeasurements[dirIdx] = (cursor, hit)
                let dist = sqrt(closestDistSq)
                let mid = Vector3(x: (cursor.x + hit.x) / 2, y: (cursor.y + hit.y) / 2, z: 0)
                activeLabels.append(("\(dir.label): \(formatDistanceShort(dist))", mid))
            }
        }

        // ----- Boundary detection (with spatial caching) -----
        updateBoundaryOverlay(engine: engine, cursor: cursor)
    }

    /// Attempt boundary detection at the cursor, caching the result so subsequent
    /// frames skip the expensive wall-following when the cursor hasn't left the room.
    private func updateBoundaryOverlay(engine: PhrostEngine, cursor: Vector3) {
        // 1. Point-in-polygon cache check.
        if let cached = cachedBoundary, cached.count >= 3 {
            if Self.pointInPolygon(point: cursor, polygon: cached) {
                // Cursor is still inside the same room — reuse cached boundary.
                buildBoundaryEdgesAndAngles(from: cached)
                return
            }
            // Cursor left the room — fall through to re-detect.
        }

        // 2. Run boundary detector.
        cachedBoundary = nil
        if let polygon = CADBoundaryDetector.findEnclosingPolygon(
            seedX: cursor.x, seedY: cursor.y, document: engine.document)
        {
            cachedBoundary = polygon
            buildBoundaryEdgesAndAngles(from: polygon)
        }
    }

    /// Populate `boundaryEdges` and `angleMarkers` from a polygon, also pushing
    /// side-length labels into `activeLabels`.
    private func buildBoundaryEdgesAndAngles(from polygon: [Vector3]) {
        let n = polygon.count
        guard n >= 3 else { return }

        // Side-length labels.
        boundaryEdges.reserveCapacity(n)
        for i in 0..<n {
            let j = (i + 1) % n
            let a = polygon[i]
            let b = polygon[j]
            boundaryEdges.append((a, b))
            let mid = Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: 0)
            let dist = a.distance(to: b)
            activeLabels.append((formatDistanceShort(dist), mid))
        }

        // Interior angles.
        angleMarkers.reserveCapacity(n)
        for i in 0..<n {
            let prev = polygon[(i - 1 + n) % n]
            let curr = polygon[i]
            let next = polygon[(i + 1) % n]

            let u = Vector3(x: prev.x - curr.x, y: prev.y - curr.y, z: 0)
            let v = Vector3(x: next.x - curr.x, y: next.y - curr.y, z: 0)

            let uLen = u.magnitude
            let vLen = v.magnitude
            guard uLen > 1e-12, vLen > 1e-12 else { continue }

            let uNorm = u / uLen
            let vNorm = v / vLen
            let dot = uNorm.x * vNorm.x + uNorm.y * vNorm.y
            let clampedDot = max(-1.0, min(1.0, dot))
            let angleRad = acos(clampedDot)
            let angleDeg = angleRad * 180.0 / .pi

            let isOrtho = abs(dot) < Self.orthoEpsilon
            let labelText = "\(String(format: "%.0f", angleDeg))°"
            angleMarkers.append((vertex: curr, angleDeg: angleDeg,
                                 isOrthogonal: isOrtho, labelText: labelText))
        }
    }

    // MARK: - Intersection helper

    /// Test a single CADPrimitive against a ray. Returns the closest intersection point or nil.
    private func intersectPrimitive(
        _ prim: CADPrimitive, transform: Transform3D,
        rayOrigin: Vector3, rayDir: Vector3
    ) -> Vector3? {
        switch prim {
        case .line(let start, let end, _):
            let ws = transform.transformPoint(start)
            let we = transform.transformPoint(end)
            return CADGeometryMath.intersectRayLine(
                rayOrigin: rayOrigin, rayDir: rayDir, lineP1: ws, lineP2: we)

        case .circle(let center, let radius, _):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * max(abs(s.x), abs(s.y))
            return CADGeometryMath.intersectRayCircle(
                rayOrigin: rayOrigin, rayDir: rayDir,
                circleCenter: wc, radius: wr).first

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * max(abs(s.x), abs(s.y))
            let rot = transform.rotation
            return CADGeometryMath.intersectRayArc(
                rayOrigin: rayOrigin, rayDir: rayDir,
                arcCenter: wc, radius: wr,
                startAngle: startAngle + rot, endAngle: endAngle + rot).first

        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let corners: [Vector3] = [
                transform.transformPoint(origin),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: 0)),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: 0)),
                transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: 0)),
            ]
            for i in 0..<4 {
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: corners[i], lineP2: corners[(i + 1) % 4])
                { return h }
            }
            return nil

        case .polygon(let pts, _), .fillPolygon(let pts, _):
            let wpts = pts.map { transform.transformPoint($0) }
            for i in 0..<wpts.count {
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: wpts[i], lineP2: wpts[(i + 1) % wpts.count])
                { return h }
            }
            return nil

        case .polyline(let pts, _):
            let wpts = pts.map { transform.transformPoint($0) }
            for i in 0..<(wpts.count - 1) {
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: wpts[i], lineP2: wpts[i + 1])
                { return h }
            }
            return nil

        case .fillComplexPolygon(let outer, _, _), .gradient(let outer, _, _, _, _, _):
            let wpts = outer.map { transform.transformPoint($0) }
            for i in 0..<(wpts.count - 1) {
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: wpts[i], lineP2: wpts[i + 1])
                { return h }
            }
            if wpts.count >= 3 {
                return CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: wpts[wpts.count - 1], lineP2: wpts[0])
            }
            return nil

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let segs = 32
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let rotA = atan2(majorAxis.y, majorAxis.x)
            let cosR = cos(rotA), sinR = sin(rotA)
            var epts: [Vector3] = []
            epts.reserveCapacity(segs)
            for i in 0..<segs {
                let t = Double(i) * 2.0 * .pi / Double(segs)
                let lp = Vector3(
                    x: center.x + majorLen * cos(t) * cosR - minorLen * sin(t) * sinR,
                    y: center.y + majorLen * cos(t) * sinR + minorLen * sin(t) * cosR,
                    z: center.z)
                epts.append(transform.transformPoint(lp))
            }
            for i in 0..<segs {
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir,
                    lineP1: epts[i], lineP2: epts[(i + 1) % segs])
                { return h }
            }
            return nil

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluate(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segments: 24)
            guard evaluated.count >= 2 else { return nil }
            for i in 0..<(evaluated.count - 1) {
                let ws = transform.transformPoint(evaluated[i])
                let we = transform.transformPoint(evaluated[i + 1])
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir, lineP1: ws, lineP2: we)
                { return h }
            }
            return nil

        case .ray(let start, let direction, _):
            let ws = transform.transformPoint(start)
            let wd = transform.transformPoint(
                Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            return CADGeometryMath.intersectRayLine(
                rayOrigin: rayOrigin, rayDir: rayDir, lineP1: ws, lineP2: wd)

        default:
            return nil
        }
    }

    // =====================================================================
    // MARK: - Distance Mode
    // =====================================================================

    private func handleDistanceClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let x: Double, y: Double
        if let snap = engine.snap.currentSnapResult {
            x = snap.worldPos.x; y = snap.worldPos.y
        } else {
            x = worldX; y = worldY
        }

        if distancePointA == nil {
            distancePointA = Vector3(x: x, y: y, z: 0)
            distancePointB = nil
            activeLabels.removeAll()
            processor.commandPrompt = "Select second point (Esc to cancel)"
        } else {
            distancePointB = Vector3(x: x, y: y, z: 0)
            let a = distancePointA!, b = distancePointB!
            let dist = a.distance(to: b)
            let mid = Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: 0)
            var labels: [(String, Vector3)] = [(formatDistanceShort(dist), mid)]
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            let offset = 20 / engine.camera.zoom
            if dx > 1e-9 {
                labels.append(("ΔX: \(formatDistanceShort(dx))",
                               Vector3(x: mid.x, y: mid.y - offset, z: 0)))
            }
            if dy > 1e-9 {
                labels.append(("ΔY: \(formatDistanceShort(dy))",
                               Vector3(x: mid.x, y: mid.y - offset * 2, z: 0)))
            }
            activeLabels = labels
            distancePointA = nil
            distancePointB = nil
            processor.commandPrompt = "Distance recorded. Click first point for next (Esc to exit)."
        }
        return .continue
    }

    // =====================================================================
    // MARK: - Area Mode
    // =====================================================================

    private func handleAreaClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        areaBoundary = nil; areaLabel = nil; areaLabelPosition = nil
        activeLabels.removeAll()

        if let polygon = CADBoundaryDetector.findEnclosingPolygon(
            seedX: worldX, seedY: worldY, document: engine.document)
        {
            areaBoundary = polygon
            let area = CADBoundaryDetector.shoelaceArea(polygon: polygon)
            let label = "Area: \(formatAreaShort(area))"
            areaLabel = label
            var cx = 0.0, cy = 0.0
            for pt in polygon { cx += pt.x; cy += pt.y }
            cx /= Double(polygon.count); cy /= Double(polygon.count)
            areaLabelPosition = Vector3(x: cx, y: cy, z: 0)
            activeLabels = [(label, Vector3(x: cx, y: cy, z: 0))]
            processor.commandPrompt = "\(label). Click again or Esc to exit."
        } else {
            activeLabels = [("No enclosed area found", Vector3(x: worldX, y: worldY, z: 0))]
            processor.commandPrompt = "No enclosed boundary detected. Click again or Esc."
        }
        return .continue
    }

    // =====================================================================
    // MARK: - Rendering
    // =====================================================================

    private func renderQuickOverlay(drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform) {
        let rayColor = ImGui_Color(0, 255, 200, 160)
        let dimLineColor = ImGui_Color(255, 200, 100, 100)

        // Crosshair.
        let cs = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let sz: Float = 8
        ImDrawListAddLine(drawList, ImVec2(x: cs.x - sz, y: cs.y), ImVec2(x: cs.x + sz, y: cs.y), rayColor, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: cs.x, y: cs.y - sz), ImVec2(x: cs.x, y: cs.y + sz), rayColor, 1.0)

        // Orthogonal rays.
        for i in 0..<4 {
            guard let m = quickMeasurements[i] else { continue }
            let so = EngineCameraManager.worldToScreen(worldX: m.origin.x, worldY: m.origin.y, cam: cam)
            let sh = EngineCameraManager.worldToScreen(worldX: m.hit.x, worldY: m.hit.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: so.x, y: so.y), ImVec2(x: sh.x, y: sh.y), dimLineColor, 1.5)
        }

        // Boundary overlay (edges + angle markers).
        renderBoundaryOverlay(drawList: drawList, cam: cam)
    }

    /// Render the cached/closest boundary: solid edges, orthogonal square icons,
    /// and non-orthogonal angle arcs.
    private func renderBoundaryOverlay(drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform) {
        let edgeColor = ImGui_Color(0, 180, 255, 220)
        let orthoColor = ImGui_Color(100, 255, 150, 220)
        let arcColor = ImGui_Color(255, 180, 60, 200)

        // Solid boundary edges.
        for edge in boundaryEdges {
            let s1 = EngineCameraManager.worldToScreen(worldX: edge.a.x, worldY: edge.a.y, cam: cam)
            let s2 = EngineCameraManager.worldToScreen(worldX: edge.b.x, worldY: edge.b.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), edgeColor, 2.0)
        }

        // Angle markers.
        for marker in angleMarkers {
            if marker.isOrthogonal {
                drawOrthoIcon(drawList: drawList, vertex: marker.vertex, cam: cam, color: orthoColor)
            } else {
                drawAngleArc(drawList: drawList, vertex: marker.vertex,
                             angleDeg: marker.angleDeg, cam: cam, color: arcColor)
            }
        }
    }

    /// Draw a 3-segment square icon at a right-angle corner.
    /// The icon is sized by `orthoIconSize` in world units (converted to screen pixels).
    private func drawOrthoIcon(
        drawList: UnsafeMutablePointer<ImDrawList>?, vertex: Vector3,
        cam: CameraTransform, color: UInt32
    ) {
        let sv = EngineCameraManager.worldToScreen(worldX: vertex.x, worldY: vertex.y, cam: cam)
        let sw = EngineCameraManager.worldToScreen(
            worldX: vertex.x + Self.orthoIconSize, worldY: vertex.y, cam: cam)
        let screenSize = sw.x - sv.x
        let s = screenSize > 0 ? screenSize : Float(Self.orthoIconSize * cam.camZoom)

        // The square icon traces: right → up → left (3 segments forming └ shape).
        let x = sv.x; let y = sv.y
        let p0 = ImVec2(x: x + s, y: y)
        let p1 = ImVec2(x: x + s, y: y - s)
        let p2 = ImVec2(x: x, y: y - s)

        ImDrawListAddLine(drawList, ImVec2(x: x, y: y), p0, color, 1.5)
        ImDrawListAddLine(drawList, p0, p1, color, 1.5)
        ImDrawListAddLine(drawList, p1, p2, color, 1.5)
    }

    /// Draw a small arc representing a non-orthogonal interior angle, approximated
    /// with `arcSegments` line segments, plus the angle text label.
    private func drawAngleArc(
        drawList: UnsafeMutablePointer<ImDrawList>?, vertex: Vector3,
        angleDeg: Double, cam: CameraTransform, color: UInt32
    ) {
        let arcRadius: Double = Self.orthoIconSize * 1.2
        let segs = Self.arcSegments

        // Draw a symmetric arc centered on the angle bisector: from -halfAngle to +halfAngle.
        let halfAngle = angleDeg / 2.0 * .pi / 180.0

        // Build world-space arc points relative to the vertex.
        var worldPts: [ImVec2] = []
        worldPts.reserveCapacity(segs + 2)
        for i in 0...segs {
            let t = -halfAngle + 2.0 * halfAngle * Double(i) / Double(segs)
            let wx = vertex.x + arcRadius * cos(t)
            let wy = vertex.y + arcRadius * sin(t)
            let sp = EngineCameraManager.worldToScreen(worldX: wx, worldY: wy, cam: cam)
            worldPts.append(ImVec2(x: sp.x, y: sp.y))
        }

        // Draw arc as a polyline.
        for i in 0..<(worldPts.count - 1) {
            ImDrawListAddLine(drawList, worldPts[i], worldPts[i + 1], color, 1.5)
        }

        // Place angle text near the arc midpoint (along the bisector).
        let labelRadius = arcRadius * 1.6
        let lx = vertex.x + labelRadius
        let ly = vertex.y
        let lsp = EngineCameraManager.worldToScreen(worldX: lx, worldY: ly, cam: cam)
        let angleText = "\(Int(round(angleDeg)))°"
        let textSize = ImGuiCalcTextSize(angleText, nil, false, -1)
        ImDrawListAddText(drawList,
            ImVec2(x: lsp.x - textSize.x / 2, y: lsp.y - textSize.y / 2),
            color, angleText, nil)
    }

    private func renderDistanceOverlay(drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform) {
        let lineColor = ImGui_Color(0, 255, 200, 200)
        let dotColor = ImGui_Color(0, 255, 128, 255)

        if let a = distancePointA, let b = distancePointB {
            let sa = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
            let sb = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sa.x, y: sa.y), ImVec2(x: sb.x, y: sb.y), lineColor, 2.0)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sa.x, y: sa.y), 3.0, dotColor, 0)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sb.x, y: sb.y), 3.0, dotColor, 0)
        }

        if let a = distancePointA {
            let sa = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
            let sc = EngineCameraManager.worldToScreen(
                worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sa.x, y: sa.y), ImVec2(x: sc.x, y: sc.y),
                              ImGui_Color(0, 255, 200, 100), 1.0)
            ImDrawListAddCircleFilled(drawList, ImVec2(x: sa.x, y: sa.y), 3.0, dotColor, 0)
        }
    }

    private func renderAreaOverlay(drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform) {
        guard let boundary = areaBoundary, boundary.count >= 3 else { return }
        let fillColor = ImGui_Color(0, 200, 255, 40)
        let lineColor = ImGui_Color(0, 200, 255, 200)

        if boundary.count <= 32 {
            var screenPts: [ImVec2] = []
            screenPts.reserveCapacity(boundary.count)
            for pt in boundary {
                let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                screenPts.append(ImVec2(x: sp.x, y: sp.y))
            }
            screenPts.withUnsafeBufferPointer { buf in
                ImDrawListAddConvexPolyFilled(drawList, buf.baseAddress, Int32(boundary.count), fillColor)
            }
        }

        for i in 0..<boundary.count {
            let j = (i + 1) % boundary.count
            let sp1 = EngineCameraManager.worldToScreen(worldX: boundary[i].x, worldY: boundary[i].y, cam: cam)
            let sp2 = EngineCameraManager.worldToScreen(worldX: boundary[j].x, worldY: boundary[j].y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sp1.x, y: sp1.y), ImVec2(x: sp2.x, y: sp2.y), lineColor, 2.0)
        }
    }

    private func renderLabels(drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform) {
        let textColor = ImGui_Color(255, 255, 255, 240)
        let bgColor = ImGui_Color(0, 0, 0, 180)

        for (text, pos) in activeLabels {
            let sp = EngineCameraManager.worldToScreen(worldX: pos.x, worldY: pos.y, cam: cam)
            let textSize = ImGuiCalcTextSize(text, nil, false, -1)
            let pad: Float = 3
            let bgMin = ImVec2(x: sp.x - textSize.x / 2 - pad, y: sp.y - pad)
            let bgMax = ImVec2(x: sp.x + textSize.x / 2 + pad, y: sp.y + textSize.y + pad)
            ImDrawListAddRectFilled(drawList, bgMin, bgMax, bgColor, 3.0, 0)
            ImDrawListAddText(drawList, ImVec2(x: sp.x - textSize.x / 2, y: sp.y), textColor, text, nil)
        }
    }

    // =====================================================================
    // MARK: - Geometry Helpers
    // =====================================================================

    /// Point-in-polygon test using the ray-casting (even-odd rule) algorithm.
    /// Casts a ray to the right (+X) and counts polygon edge crossings.
    private static func pointInPolygon(point: Vector3, polygon: [Vector3]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        let px = point.x, py = point.y
        for i in 0..<n {
            let yi = polygon[i].y, yj = polygon[j].y
            let xi = polygon[i].x, xj = polygon[j].x
            if (yi > py) != (yj > py) {
                let xIntersect = xj + (py - yj) / (yi - yj) * (xi - xj)
                if px < xIntersect {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    // =====================================================================
    // MARK: - Helpers
    // =====================================================================

    private func cycleMode(processor: CADCommandProcessor) {
        switch currentMode {
        case .quick:  currentMode = .distance; processor.commandPrompt = "Distance — click first point"
        case .distance: currentMode = .area; processor.commandPrompt = "Area — click inside enclosed region"
        case .area:   currentMode = .angle;   processor.commandPrompt = "Angle — not yet implemented"
        case .angle:  currentMode = .quick;   processor.commandPrompt = "Quick Measure — orthogonal raycast + boundary active"
        }
        resetModeState()
    }

    private func resetState() {
        currentMode = .quick
        resetModeState()
    }

    private func resetModeState() {
        for i in 0..<4 { quickMeasurements[i] = nil }
        distancePointA = nil
        distancePointB = nil
        areaBoundary = nil
        areaLabel = nil
        areaLabelPosition = nil
        activeLabels.removeAll()
        cachedBoundary = nil
        boundaryEdges.removeAll()
        angleMarkers.removeAll()
    }

    private func formatDistance(_ distSq: Double) -> (String, Double) {
        let dist = sqrt(distSq)
        return (formatDistanceShort(dist), dist)
    }

    private func formatDistanceShort(_ dist: Double) -> String {
        if dist < 0.01       { return String(format: "%.4f", dist) }
        else if dist < 1.0   { return String(format: "%.3f", dist) }
        else if dist < 1000  { return String(format: "%.2f", dist) }
        else                 { return String(format: "%.1f", dist) }
    }

    private func formatAreaShort(_ area: Double) -> String {
        if area < 0.01         { return String(format: "%.4f sq units", area) }
        else if area < 1.0     { return String(format: "%.3f sq units", area) }
        else if area < 1000    { return String(format: "%.2f sq units", area) }
        else if area < 1_000_000 { return String(format: "%.1f sq units", area) }
        else                   { return String(format: "%.0f sq units", area) }
    }
}

// MARK: - ImGui Color Helper

/// Create an ImGui 32-bit color (ABGR packed) from 0-255 components.
@inlinable
internal func ImGui_Color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
    UInt32(a) << 24 | UInt32(b) << 16 | UInt32(g) << 8 | UInt32(r)
}
