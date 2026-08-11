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
//   - .quick: Real-time orthogonal raycast (±X, ±Y) that combines opposing
//     hits into AutoCAD-style width and length dimensions, or shows a local
//     angular measurement while the cursor touches a corner.
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

    private struct QuickLineSegment {
        let start: Vector3
        let end: Vector3
    }

    private struct QuickIncidentRay {
        let direction: Vector3
        let length: Double
    }

    private struct QuickAngleSpan {
        let vertex: Vector3
        let startAngle: Double
        let sweepAngle: Double
        let angleDegrees: Double
    }

    private struct QuickRadiusSpan {
        let center: Vector3
        let radius: Double
        let startAngle: Double
        let sweepAngle: Double
        let hitPoint: Vector3
    }

    private struct QuickLinearHit {
        let hitPoint: Vector3
        let start: Vector3
        let end: Vector3
    }

    // MARK: - State

    public var currentMode: MeasureMode = .quick

    // Quick Measure — orthogonal rays
    /// Stored as world-space (cursor origin, intersection point) for each direction.
    /// Index 0: +X, 1: -X, 2: +Y, 3: -Y
    private var quickMeasurements: [(origin: Vector3, hit: Vector3)?] = [nil, nil, nil, nil]
    private var quickWidthSpan: (start: Vector3, end: Vector3, distance: Double)? = nil
    private var quickLengthSpan: (start: Vector3, end: Vector3, distance: Double)? = nil
    private var quickAngleSpan: QuickAngleSpan? = nil
    private var quickHitAngleSpans: [QuickAngleSpan] = []
    private var quickRadiusSpan: QuickRadiusSpan? = nil
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

    // MARK: - Init

    public init() {}

    // MARK: - FeatureCommand Conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        resetState()
        processor.commandPrompt = "MEASUREGEOM [Distance/Area/Quick/eXit] <Quick>:"
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
            processor.commandPrompt = "Quick Measure — move between geometry, or touch a corner to show its angle"
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
    // MARK: - Quick Measure
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
        quickWidthSpan = nil
        quickLengthSpan = nil
        quickAngleSpan = nil
        quickHitAngleSpans.removeAll(keepingCapacity: true)
        quickRadiusSpan = nil
        activeLabels.removeAll(keepingCapacity: true)

        // ----- Orthogonal rays (±X, ±Y) -----
        let directions: [(dx: Double, dy: Double)] = [
            ( 1,  0), (-1,  0), ( 0,  1), ( 0, -1),
        ]
        let worldPerPixel = max(
            vpW / max(1.0, Double(engine.windowWidth)),
            vpH / max(1.0, Double(engine.windowHeight)))
        let sameHitToleranceSq = pow(max(worldPerPixel * 3.0, 1e-8), 2.0)
        var closestRadiusDistanceSq = Double.infinity

        for dirIdx in 0..<4 {
            let dir = directions[dirIdx]
            let rayDir = Vector3(x: dir.dx, y: dir.dy, z: 0)
            let candidates = engine.document.entityHandlesAlongRay(
                rayOrigin: cursor, rayDir: rayDir, maxDistance: maxDist)
            let handles = candidates ?? []

            var closestHit: Vector3? = nil
            var closestDistSq = Double.infinity
            var closestLinearHit: (hit: QuickLinearHit, distanceSq: Double)? = nil
            var closestRadiusHit: (span: QuickRadiusSpan, distanceSq: Double)? = nil
            var hitCount = 0

            for handle in handles {
                guard hitCount < 500 else { break }
                guard let entity = engine.document.entity(for: handle) else { continue }
                guard entity.dimensionMetadata == nil else { continue }
                guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard let geometry = engine.document.resolvedGeometry(for: entity) else { continue }
                hitCount += 1

                let transform = entity.transform
                for prim in geometry {
                    if let linearHit = intersectStraightPrimitive(
                        prim,
                        transform: transform,
                        rayOrigin: cursor,
                        rayDir: rayDir)
                    {
                        let dsq = squaredDistance(cursor, linearHit.hitPoint)
                        if dsq > 1e-12,
                           dsq < (closestLinearHit?.distanceSq ?? Double.infinity)
                        {
                            closestLinearHit = (linearHit, dsq)
                        }
                        if dsq > 1e-12, dsq < closestDistSq {
                            closestDistSq = dsq
                            closestHit = linearHit.hitPoint
                        }
                    }

                    if let radiusHit = intersectRadiusPrimitive(
                        prim,
                        transform: transform,
                        rayOrigin: cursor,
                        rayDir: rayDir)
                    {
                        let hdx = radiusHit.hitPoint.x - cursor.x
                        let hdy = radiusHit.hitPoint.y - cursor.y
                        let dsq = (hdx * hdx) + (hdy * hdy)
                        if dsq > 1e-12,
                           dsq < (closestRadiusHit?.distanceSq ?? Double.infinity)
                        {
                            closestRadiusHit = (radiusHit, dsq)
                        }
                    }

                    if let hitPoint = intersectPrimitive(prim, transform: transform,
                                                          rayOrigin: cursor, rayDir: rayDir)
                    {
                        let hdx = hitPoint.x - cursor.x
                        let hdy = hitPoint.y - cursor.y
                        let dsq = (hdx * hdx) + (hdy * hdy)
                        if dsq > 1e-12, dsq < closestDistSq {
                            closestDistSq = dsq
                            closestHit = hitPoint
                        }
                    }
                }
            }

            if let hit = closestHit {
                quickMeasurements[dirIdx] = (cursor, hit)
            }

            if let linearHit = closestLinearHit,
               linearHit.distanceSq <= closestDistSq + sameHitToleranceSq,
               let angleSpan = makeQuickHitAngleSpan(
                    hit: linearHit.hit,
                    rayDir: rayDir)
            {
                let duplicate = quickHitAngleSpans.contains {
                    squaredDistance($0.vertex, angleSpan.vertex) <= sameHitToleranceSq
                        && abs($0.angleDegrees - angleSpan.angleDegrees) <= 0.05
                }
                if !duplicate {
                    quickHitAngleSpans.append(angleSpan)
                }
            }

            if let radiusHit = closestRadiusHit,
               radiusHit.distanceSq <= closestDistSq + sameHitToleranceSq,
               radiusHit.distanceSq < closestRadiusDistanceSq
            {
                closestRadiusDistanceSq = radiusHit.distanceSq
                quickRadiusSpan = radiusHit.span
            }
        }

        if let right = quickMeasurements[0], let left = quickMeasurements[1] {
            let distance = abs(right.hit.x - left.hit.x)
            if distance > 1e-9 {
                quickWidthSpan = (start: left.hit, end: right.hit, distance: distance)
            }
        }

        if let up = quickMeasurements[2], let down = quickMeasurements[3] {
            let distance = abs(up.hit.y - down.hit.y)
            if distance > 1e-9 {
                quickLengthSpan = (start: down.hit, end: up.hit, distance: distance)
            }
        }

        quickAngleSpan = findQuickAngle(engine: engine, cursor: cursor, viewport: vp)
        if quickRadiusSpan != nil {
            quickAngleSpan = nil
        } else if quickAngleSpan != nil {
            quickWidthSpan = nil
            quickLengthSpan = nil
            quickHitAngleSpans.removeAll(keepingCapacity: true)
        }
    }

    private func findQuickAngle(
        engine: PhrostEngine,
        cursor: Vector3,
        viewport: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    ) -> QuickAngleSpan? {
        let viewWidth = max(1.0, Double(engine.windowWidth))
        let viewHeight = max(1.0, Double(engine.windowHeight))
        let worldPerPixel = max(
            (viewport.maxX - viewport.minX) / viewWidth,
            (viewport.maxY - viewport.minY) / viewHeight)
        let hoverTolerance = max(worldPerPixel * 14.0, 1e-8)
        let joinTolerance = max(worldPerPixel * 3.0, hoverTolerance * 0.18)
        let searchTolerance = hoverTolerance * 1.5

        let handles = engine.document.entityHandlesInWorldRect(
            minX: cursor.x - searchTolerance,
            minY: cursor.y - searchTolerance,
            maxX: cursor.x + searchTolerance,
            maxY: cursor.y + searchTolerance)
            ?? engine.document.allEntities.map(\.handle)

        var segments: [QuickLineSegment] = []
        segments.reserveCapacity(64)

        for handle in handles {
            guard segments.count < 256 else { break }
            guard let entity = engine.document.entity(for: handle) else { continue }
            guard entity.dimensionMetadata == nil else { continue }
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let geometry = engine.document.resolvedGeometry(for: entity) else { continue }

            for primitive in geometry {
                appendQuickAngleSegments(
                    from: primitive,
                    transform: entity.transform,
                    cursor: cursor,
                    tolerance: searchTolerance,
                    to: &segments)
                if segments.count >= 256 { break }
            }
        }

        guard segments.count >= 2 else { return nil }

        var candidateVertices: [Vector3] = []
        candidateVertices.reserveCapacity(segments.count * 2)
        let hoverSq = hoverTolerance * hoverTolerance

        for segment in segments {
            if squaredDistance(cursor, segment.start) <= hoverSq {
                candidateVertices.append(segment.start)
            }
            if squaredDistance(cursor, segment.end) <= hoverSq {
                candidateVertices.append(segment.end)
            }
        }

        if segments.count <= 96 {
            for firstIndex in 0..<(segments.count - 1) {
                for secondIndex in (firstIndex + 1)..<segments.count {
                    if let intersection = segmentIntersection(
                        segments[firstIndex], segments[secondIndex]),
                       squaredDistance(cursor, intersection) <= hoverSq
                    {
                        candidateVertices.append(intersection)
                    }
                }
            }
        }

        guard let vertex = candidateVertices.min(by: {
            squaredDistance(cursor, $0) < squaredDistance(cursor, $1)
        }) else { return nil }

        var rays: [QuickIncidentRay] = []
        let joinSq = joinTolerance * joinTolerance

        for segment in segments {
            let startDistanceSq = squaredDistance(vertex, segment.start)
            let endDistanceSq = squaredDistance(vertex, segment.end)

            if startDistanceSq <= joinSq {
                appendIncidentRay(from: vertex, toward: segment.end, to: &rays)
            } else if endDistanceSq <= joinSq {
                appendIncidentRay(from: vertex, toward: segment.start, to: &rays)
            } else if CADGeometryMath.pointToSegmentDistSq(
                vertex, segment.start, segment.end) <= joinSq
            {
                appendIncidentRay(from: vertex, toward: segment.start, to: &rays)
                appendIncidentRay(from: vertex, toward: segment.end, to: &rays)
            }
        }

        guard rays.count >= 2 else { return nil }

        let cursorVector = Vector3(
            x: cursor.x - vertex.x,
            y: cursor.y - vertex.y,
            z: 0)
        let cursorDistance = cursorVector.magnitude
        let cursorAngle = atan2(cursorVector.y, cursorVector.x)
        let minAngle = 1.0 * Double.pi / 180.0
        let maxAngle = 179.0 * Double.pi / 180.0

        var bestSpan: QuickAngleSpan? = nil
        var bestScore = Double.infinity

        for firstIndex in 0..<(rays.count - 1) {
            for secondIndex in (firstIndex + 1)..<rays.count {
                let first = rays[firstIndex]
                let second = rays[secondIndex]
                let dot = max(-1.0, min(1.0,
                    first.direction.x * second.direction.x
                    + first.direction.y * second.direction.y))
                let angle = acos(dot)
                guard angle >= minAngle, angle <= maxAngle else { continue }

                let firstAngle = atan2(first.direction.y, first.direction.x)
                let secondAngle = atan2(second.direction.y, second.direction.x)
                let ccwSweep = normalizedPositiveAngle(secondAngle - firstAngle)
                let startAngle: Double
                let sweepAngle: Double

                if ccwSweep <= Double.pi {
                    startAngle = firstAngle
                    sweepAngle = ccwSweep
                } else {
                    startAngle = secondAngle
                    sweepAngle = (2.0 * Double.pi) - ccwSweep
                }

                let bisector = startAngle + sweepAngle * 0.5
                let minRayLength = min(first.length, second.length)
                let score: Double
                if cursorDistance > joinTolerance * 0.25 {
                    let angularOffset = abs(normalizedSignedAngle(cursorAngle - bisector))
                    let insideWedge = angularOffset <= sweepAngle * 0.5 + 0.12
                    score = (insideWedge ? 0.0 : 10.0)
                        + angularOffset
                        + 0.05 / max(minRayLength / hoverTolerance, 0.1)
                } else {
                    score = abs(sweepAngle - Double.pi * 0.5)
                        + 0.05 / max(minRayLength / hoverTolerance, 0.1)
                }

                if score < bestScore {
                    bestScore = score
                    bestSpan = QuickAngleSpan(
                        vertex: vertex,
                        startAngle: startAngle,
                        sweepAngle: sweepAngle,
                        angleDegrees: sweepAngle * 180.0 / Double.pi)
                }
            }
        }

        return bestSpan
    }

    private func appendQuickAngleSegments(
        from primitive: CADPrimitive,
        transform: Transform3D,
        cursor: Vector3,
        tolerance: Double,
        to segments: inout [QuickLineSegment]
    ) {
        func append(_ start: Vector3, _ end: Vector3) {
            guard segments.count < 256 else { return }
            let worldStart = transform.transformPoint(start)
            let worldEnd = transform.transformPoint(end)
            guard worldStart.distance(to: worldEnd) > 1e-9 else { return }
            let toleranceSq = tolerance * tolerance
            guard CADGeometryMath.pointToSegmentDistSq(
                cursor, worldStart, worldEnd) <= toleranceSq
            else { return }
            segments.append(QuickLineSegment(start: worldStart, end: worldEnd))
        }

        switch primitive {
        case .line(let start, let end, _):
            append(start, end)

        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ]
            for index in 0..<4 {
                append(corners[index], corners[(index + 1) % 4])
            }

        case .polygon(let points, _), .fillPolygon(let points, _):
            guard points.count >= 2 else { return }
            for index in 0..<points.count {
                append(points[index], points[(index + 1) % points.count])
            }

        case .polyline(let path, _):
            guard path.segmentCount > 0 else { return }
            for index in 0..<path.segmentCount where abs(path.vertices[index].bulge) <= 1e-12 {
                append(
                    path.vertices[index].position,
                    path.vertices[path.endVertexIndex(forSegment: index)].position)
            }

        case .fillComplexPolygon(let outer, _, _), .gradient(let outer, _, _, _, _, _):
            guard outer.count >= 2 else { return }
            for index in 0..<outer.count {
                append(outer[index], outer[(index + 1) % outer.count])
            }

        default:
            break
        }
    }

    private func appendIncidentRay(
        from vertex: Vector3,
        toward point: Vector3,
        to rays: inout [QuickIncidentRay]
    ) {
        let vector = Vector3(x: point.x - vertex.x, y: point.y - vertex.y, z: 0)
        let length = vector.magnitude
        guard length > 1e-9 else { return }
        let direction = vector / length
        let duplicateThreshold = cos(0.5 * Double.pi / 180.0)
        if rays.contains(where: {
            $0.direction.x * direction.x + $0.direction.y * direction.y > duplicateThreshold
        }) {
            return
        }
        rays.append(QuickIncidentRay(direction: direction, length: length))
    }

    private func segmentIntersection(
        _ first: QuickLineSegment,
        _ second: QuickLineSegment
    ) -> Vector3? {
        let rx = first.end.x - first.start.x
        let ry = first.end.y - first.start.y
        let sx = second.end.x - second.start.x
        let sy = second.end.y - second.start.y
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 1e-12 else { return nil }

        let qpx = second.start.x - first.start.x
        let qpy = second.start.y - first.start.y
        let t = (qpx * sy - qpy * sx) / denominator
        let u = (qpx * ry - qpy * rx) / denominator
        let epsilon = 1e-8
        guard t >= -epsilon, t <= 1.0 + epsilon,
              u >= -epsilon, u <= 1.0 + epsilon
        else { return nil }

        return Vector3(
            x: first.start.x + t * rx,
            y: first.start.y + t * ry,
            z: 0)
    }

    private func squaredDistance(_ first: Vector3, _ second: Vector3) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }

    private func normalizedPositiveAngle(_ angle: Double) -> Double {
        let fullTurn = 2.0 * Double.pi
        var result = angle.truncatingRemainder(dividingBy: fullTurn)
        if result < 0 { result += fullTurn }
        return result
    }

    private func normalizedSignedAngle(_ angle: Double) -> Double {
        var result = normalizedPositiveAngle(angle)
        if result > Double.pi { result -= 2.0 * Double.pi }
        return result
    }


    private func intersectStraightPrimitive(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        rayOrigin: Vector3,
        rayDir: Vector3
    ) -> QuickLinearHit? {
        var best: QuickLinearHit? = nil
        var bestDistanceSq = Double.infinity

        func considerWorld(_ start: Vector3, _ end: Vector3) {
            guard start.distance(to: end) > 1e-9,
                  let hitPoint = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin,
                    rayDir: rayDir,
                    lineP1: start,
                    lineP2: end)
            else { return }

            let distanceSq = squaredDistance(rayOrigin, hitPoint)
            guard distanceSq > 1e-12, distanceSq < bestDistanceSq else { return }
            bestDistanceSq = distanceSq
            best = QuickLinearHit(hitPoint: hitPoint, start: start, end: end)
        }

        func considerLocal(_ start: Vector3, _ end: Vector3) {
            considerWorld(
                transform.transformPoint(start),
                transform.transformPoint(end))
        }

        switch primitive {
        case .line(let start, let end, _):
            considerLocal(start, end)

        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ]
            for index in 0..<4 {
                considerLocal(corners[index], corners[(index + 1) % 4])
            }

        case .polygon(let points, _), .fillPolygon(let points, _):
            guard points.count >= 2 else { return nil }
            for index in 0..<points.count {
                considerLocal(points[index], points[(index + 1) % points.count])
            }

        case .polyline(let path, _):
            guard path.segmentCount > 0 else { return nil }
            for index in 0..<path.segmentCount where abs(path.vertices[index].bulge) <= 1e-12 {
                considerLocal(
                    path.vertices[index].position,
                    path.vertices[path.endVertexIndex(forSegment: index)].position)
            }

        case .fillComplexPolygon(let outer, _, _), .gradient(let outer, _, _, _, _, _):
            guard outer.count >= 2 else { return nil }
            for index in 0..<outer.count {
                considerLocal(outer[index], outer[(index + 1) % outer.count])
            }

        default:
            break
        }

        return best
    }

    private func makeQuickHitAngleSpan(
        hit: QuickLinearHit,
        rayDir: Vector3
    ) -> QuickAngleSpan? {
        let segmentVector = Vector3(
            x: hit.end.x - hit.start.x,
            y: hit.end.y - hit.start.y,
            z: 0)
        guard segmentVector.magnitude > 1e-9 else { return nil }

        var wallAngle = normalizedPositiveAngle(
            atan2(segmentVector.y, segmentVector.x))
        if wallAngle >= Double.pi {
            wallAngle -= Double.pi
        }

        let towardCursorAngle = atan2(-rayDir.y, -rayDir.x)
        let ccwSweep = normalizedPositiveAngle(towardCursorAngle - wallAngle)
        let startAngle: Double
        let sweepAngle: Double

        if ccwSweep <= Double.pi {
            startAngle = wallAngle
            sweepAngle = ccwSweep
        } else {
            startAngle = towardCursorAngle
            sweepAngle = (2.0 * Double.pi) - ccwSweep
        }

        let angleDegrees = sweepAngle * 180.0 / Double.pi
        let orthogonalTolerance = 0.75
        guard angleDegrees > orthogonalTolerance,
              angleDegrees < 180.0 - orthogonalTolerance,
              abs(angleDegrees - 90.0) > orthogonalTolerance
        else { return nil }

        return QuickAngleSpan(
            vertex: hit.hitPoint,
            startAngle: startAngle,
            sweepAngle: sweepAngle,
            angleDegrees: angleDegrees)
    }

    private func intersectRadiusPrimitive(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        rayOrigin: Vector3,
        rayDir: Vector3
    ) -> QuickRadiusSpan? {
        func worldArc(
            center: Vector3,
            radius: Double,
            startAngle: Double,
            sweep: Double
        ) -> (center: Vector3, radius: Double, startAngle: Double, sweepAngle: Double)? {
            let sx = abs(transform.scale.x)
            let sy = abs(transform.scale.y)
            let scale = max(sx, sy)
            guard radius > 1e-9,
                  scale > 1e-12,
                  abs(sx - sy) <= scale * 1e-6
            else { return nil }

            let worldCenter = transform.transformPoint(center)
            let localStart = Vector3(
                x: center.x + cos(startAngle) * radius,
                y: center.y + sin(startAngle) * radius,
                z: center.z)
            let localEnd = Vector3(
                x: center.x + cos(startAngle + sweep) * radius,
                y: center.y + sin(startAngle + sweep) * radius,
                z: center.z)
            let worldStart = transform.transformPoint(localStart)
            let worldEnd = transform.transformPoint(localEnd)
            let startWorldAngle = atan2(
                worldStart.y - worldCenter.y,
                worldStart.x - worldCenter.x)
            let endWorldAngle = atan2(
                worldEnd.y - worldCenter.y,
                worldEnd.x - worldCenter.x)
            let worldRadius = worldCenter.distance(to: worldStart)
            let reversesOrientation = transform.scale.x * transform.scale.y < 0
            let isPositive = (sweep >= 0) != reversesOrientation

            if abs(abs(sweep) - 2.0 * Double.pi) <= 1e-7 {
                return (worldCenter, worldRadius, startWorldAngle, 2.0 * Double.pi)
            }

            if isPositive {
                return (
                    worldCenter,
                    worldRadius,
                    startWorldAngle,
                    normalizedPositiveAngle(endWorldAngle - startWorldAngle))
            }

            return (
                worldCenter,
                worldRadius,
                endWorldAngle,
                normalizedPositiveAngle(startWorldAngle - endWorldAngle))
        }

        func hit(
            center: Vector3,
            radius: Double,
            startAngle: Double,
            sweepAngle: Double
        ) -> QuickRadiusSpan? {
            let hitPoint: Vector3?
            if sweepAngle >= 2.0 * Double.pi - 1e-7 {
                hitPoint = CADGeometryMath.intersectRayCircle(
                    rayOrigin: rayOrigin,
                    rayDir: rayDir,
                    circleCenter: center,
                    radius: radius).first
            } else {
                hitPoint = CADGeometryMath.intersectRayArc(
                    rayOrigin: rayOrigin,
                    rayDir: rayDir,
                    arcCenter: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: startAngle + sweepAngle).first
            }

            guard let hitPoint else { return nil }
            return QuickRadiusSpan(
                center: center,
                radius: radius,
                startAngle: startAngle,
                sweepAngle: sweepAngle,
                hitPoint: hitPoint)
        }

        switch primitive {
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var sweep = normalizedPositiveAngle(endAngle - startAngle)
            if sweep <= 1e-12 && abs(endAngle - startAngle) > 1e-12 {
                sweep = 2.0 * Double.pi
            }
            guard let arc = worldArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                sweep: sweep)
            else { return nil }
            return hit(
                center: arc.center,
                radius: arc.radius,
                startAngle: arc.startAngle,
                sweepAngle: arc.sweepAngle)

        case .circle(let center, let radius, _):
            guard let arc = worldArc(
                center: center,
                radius: radius,
                startAngle: 0,
                sweep: 2.0 * Double.pi)
            else { return nil }
            return hit(
                center: arc.center,
                radius: arc.radius,
                startAngle: arc.startAngle,
                sweepAngle: arc.sweepAngle)

        case .polyline(let path, _):
            var best: QuickRadiusSpan? = nil
            var bestDistanceSq = Double.infinity
            for segmentIndex in 0..<path.segmentCount {
                guard let localArc = path.arcParameters(forSegment: segmentIndex),
                      let arc = worldArc(
                        center: localArc.center,
                        radius: localArc.radius,
                        startAngle: localArc.startAngle,
                        sweep: localArc.sweep),
                      let candidate = hit(
                        center: arc.center,
                        radius: arc.radius,
                        startAngle: arc.startAngle,
                        sweepAngle: arc.sweepAngle)
                else { continue }

                let distanceSq = squaredDistance(rayOrigin, candidate.hitPoint)
                if distanceSq < bestDistanceSq {
                    bestDistanceSq = distanceSq
                    best = candidate
                }
            }
            return best

        default:
            return nil
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

        case .polyline(let path, _):
            let wpts = path.tessellatedPoints().map { transform.transformPoint($0) }
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
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segmentsPerSpan: 6)
            guard evaluated.count >= 2 else { return nil }
            for i in 0..<(evaluated.count - 1) {
                let ws = transform.transformPoint(evaluated[i])
                let we = transform.transformPoint(evaluated[i + 1])
                if let h = CADGeometryMath.intersectRayLine(
                    rayOrigin: rayOrigin, rayDir: rayDir, lineP1: ws, lineP2: we)
                { return h }
            }
            return nil

        case .penStroke(let vertices, _, _):
            guard vertices.count >= 2 else { return nil }
            for i in 0..<(vertices.count - 1) {
                let ws = transform.transformPoint(vertices[i].position)
                let we = transform.transformPoint(vertices[i + 1].position)
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
        if let span = quickRadiusSpan {
            drawQuickRadius(drawList: drawList, span: span, cam: cam)
        }

        if let span = quickAngleSpan {
            drawQuickAngle(drawList: drawList, span: span, cam: cam)
            return
        }

        if let span = quickWidthSpan {
            drawQuickDimension(
                drawList: drawList,
                start: span.start,
                end: span.end,
                distance: span.distance,
                horizontal: true,
                cam: cam)
        }

        if let span = quickLengthSpan {
            drawQuickDimension(
                drawList: drawList,
                start: span.start,
                end: span.end,
                distance: span.distance,
                horizontal: false,
                cam: cam)
        }

        for span in quickHitAngleSpans {
            drawQuickAngle(drawList: drawList, span: span, cam: cam)
        }
    }

    private func drawQuickRadius(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        span: QuickRadiusSpan,
        cam: CameraTransform
    ) {
        let lineColor = ImGui_Color(255, 190, 60, 235)
        let textColor = ImGui_Color(255, 255, 255, 245)
        let bgColor = ImGui_Color(0, 0, 0, 210)
        let safeZoom = max(cam.camZoom, 1e-9)
        let segmentCount = min(
            256,
            max(16, Int(ceil(span.sweepAngle * span.radius * safeZoom / 8.0))))

        func screenPoint(angle: Double, radius: Double) -> ImVec2 {
            let worldX = span.center.x + cos(angle) * radius
            let worldY = span.center.y + sin(angle) * radius
            let screen = EngineCameraManager.worldToScreen(
                worldX: worldX,
                worldY: worldY,
                cam: cam)
            return ImVec2(x: screen.x, y: screen.y)
        }

        var previous = screenPoint(angle: span.startAngle, radius: span.radius)
        for index in 1...segmentCount {
            let fraction = Double(index) / Double(segmentCount)
            let current = screenPoint(
                angle: span.startAngle + span.sweepAngle * fraction,
                radius: span.radius)
            ImDrawListAddLine(drawList, previous, current, lineColor, 2.0)
            previous = current
        }

        let hitAngle = atan2(
            span.hitPoint.y - span.center.y,
            span.hitPoint.x - span.center.x)
        let leaderStart = screenPoint(angle: hitAngle, radius: span.radius * 0.98)
        let leaderEnd = screenPoint(angle: hitAngle, radius: span.radius * 0.56)
        let dx = leaderEnd.x - leaderStart.x
        let dy = leaderEnd.y - leaderStart.y
        let leaderLength = max(1.0, hypot(dx, dy))
        let dash: Float = 4.0
        let gap: Float = 4.0
        var distance: Float = 0
        while distance < leaderLength {
            let endDistance = min(distance + dash, leaderLength)
            let startFraction = distance / leaderLength
            let endFraction = endDistance / leaderLength
            ImDrawListAddLine(
                drawList,
                ImVec2(
                    x: leaderStart.x + dx * startFraction,
                    y: leaderStart.y + dy * startFraction),
                ImVec2(
                    x: leaderStart.x + dx * endFraction,
                    y: leaderStart.y + dy * endFraction),
                lineColor,
                1.5)
            distance += dash + gap
        }

        let text = formatDistanceShort(span.radius)
        let textSize = ImGuiCalcTextSize(text, nil, false, -1)
        let labelPoint = screenPoint(angle: hitAngle, radius: span.radius * 0.42)
        let textPos = ImVec2(
            x: labelPoint.x - textSize.x * 0.5,
            y: labelPoint.y - textSize.y * 0.5)
        let padX: Float = 4.0
        let padY: Float = 3.0
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: textPos.x - padX, y: textPos.y - padY),
            ImVec2(x: textPos.x + textSize.x + padX, y: textPos.y + textSize.y + padY),
            bgColor,
            3.0,
            0)
        ImDrawListAddText(drawList, textPos, textColor, text, nil)
    }

    private func drawQuickAngle(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        span: QuickAngleSpan,
        cam: CameraTransform
    ) {
        let lineColor = ImGui_Color(255, 190, 60, 235)
        let textColor = ImGui_Color(255, 255, 255, 245)
        let bgColor = ImGui_Color(0, 0, 0, 210)
        let safeZoom = max(cam.camZoom, 1e-9)
        let radius = 34.0 / safeZoom
        let rayLength = 48.0 / safeZoom
        let segmentCount = max(12, Int(ceil(span.sweepAngle * 18.0 / Double.pi)))

        let vertexScreen = EngineCameraManager.worldToScreen(
            worldX: span.vertex.x, worldY: span.vertex.y, cam: cam)

        func point(angle: Double, distance: Double) -> ImVec2 {
            let worldX = span.vertex.x + cos(angle) * distance
            let worldY = span.vertex.y + sin(angle) * distance
            let screen = EngineCameraManager.worldToScreen(
                worldX: worldX, worldY: worldY, cam: cam)
            return ImVec2(x: screen.x, y: screen.y)
        }

        let startRay = point(angle: span.startAngle, distance: rayLength)
        let endRay = point(angle: span.startAngle + span.sweepAngle, distance: rayLength)
        let vertex = ImVec2(x: vertexScreen.x, y: vertexScreen.y)
        ImDrawListAddLine(drawList, vertex, startRay, lineColor, 1.5)
        ImDrawListAddLine(drawList, vertex, endRay, lineColor, 1.5)

        var previous = point(angle: span.startAngle, distance: radius)
        for index in 1...segmentCount {
            let fraction = Double(index) / Double(segmentCount)
            let current = point(
                angle: span.startAngle + span.sweepAngle * fraction,
                distance: radius)
            ImDrawListAddLine(drawList, previous, current, lineColor, 1.5)
            previous = current
        }

        let tickPixels = 5.0
        for angle in [span.startAngle, span.startAngle + span.sweepAngle] {
            let arcPoint = point(angle: angle, distance: radius)
            let tangentAngle = angle + Double.pi * 0.5
            let tangentX = Float(cos(tangentAngle) * tickPixels)
            let tangentY = Float(sin(tangentAngle) * tickPixels)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: arcPoint.x - tangentX, y: arcPoint.y - tangentY),
                ImVec2(x: arcPoint.x + tangentX, y: arcPoint.y + tangentY),
                lineColor, 1.5)
        }

        let text = formatAngle(span.angleDegrees)
        let textSize = ImGuiCalcTextSize(text, nil, false, -1)
        let labelPoint = point(
            angle: span.startAngle + span.sweepAngle * 0.5,
            distance: radius + 17.0 / safeZoom)
        let textPos = ImVec2(
            x: labelPoint.x - textSize.x * 0.5,
            y: labelPoint.y - textSize.y * 0.5)
        let padX: Float = 4.0
        let padY: Float = 3.0
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: textPos.x - padX, y: textPos.y - padY),
            ImVec2(x: textPos.x + textSize.x + padX, y: textPos.y + textSize.y + padY),
            bgColor, 3.0, 0)
        ImDrawListAddText(drawList, textPos, textColor, text, nil)
    }

    private func drawQuickDimension(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        start: Vector3,
        end: Vector3,
        distance: Double,
        horizontal: Bool,
        cam: CameraTransform
    ) {
        let lineColor = ImGui_Color(255, 190, 60, 235)
        let textColor = ImGui_Color(255, 255, 255, 245)
        let bgColor = ImGui_Color(0, 0, 0, 210)
        let s1 = EngineCameraManager.worldToScreen(worldX: start.x, worldY: start.y, cam: cam)
        let s2 = EngineCameraManager.worldToScreen(worldX: end.x, worldY: end.y, cam: cam)
        let p1 = ImVec2(x: s1.x, y: s1.y)
        let p2 = ImVec2(x: s2.x, y: s2.y)
        let tick: Float = 6.0

        ImDrawListAddLine(drawList, p1, p2, lineColor, 1.5)
        if horizontal {
            ImDrawListAddLine(
                drawList,
                ImVec2(x: p1.x, y: p1.y - tick),
                ImVec2(x: p1.x, y: p1.y + tick),
                lineColor, 1.5)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: p2.x, y: p2.y - tick),
                ImVec2(x: p2.x, y: p2.y + tick),
                lineColor, 1.5)
        } else {
            ImDrawListAddLine(
                drawList,
                ImVec2(x: p1.x - tick, y: p1.y),
                ImVec2(x: p1.x + tick, y: p1.y),
                lineColor, 1.5)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: p2.x - tick, y: p2.y),
                ImVec2(x: p2.x + tick, y: p2.y),
                lineColor, 1.5)
        }

        let text = formatDistanceShort(distance)
        let textSize = ImGuiCalcTextSize(text, nil, false, -1)
        let center = ImVec2(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
        let textPos: ImVec2
        if horizontal {
            textPos = ImVec2(x: center.x - textSize.x * 0.5, y: center.y - textSize.y - 7.0)
        } else {
            textPos = ImVec2(x: center.x + 8.0, y: center.y - textSize.y * 0.5)
        }
        let padX: Float = 4.0
        let padY: Float = 3.0
        ImDrawListAddRectFilled(
            drawList,
            ImVec2(x: textPos.x - padX, y: textPos.y - padY),
            ImVec2(x: textPos.x + textSize.x + padX, y: textPos.y + textSize.y + padY),
            bgColor, 3.0, 0)
        ImDrawListAddText(drawList, textPos, textColor, text, nil)
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
    // MARK: - Helpers
    // =====================================================================

    private func cycleMode(processor: CADCommandProcessor) {
        switch currentMode {
        case .quick:  currentMode = .distance; processor.commandPrompt = "Distance — click first point"
        case .distance: currentMode = .area; processor.commandPrompt = "Area — click inside enclosed region"
        case .area:   currentMode = .angle;   processor.commandPrompt = "Angle — not yet implemented"
        case .angle:  currentMode = .quick;   processor.commandPrompt = "Quick Measure — move between geometry, or touch a corner to show its angle"
        }
        resetModeState()
    }

    private func resetState() {
        currentMode = .quick
        resetModeState()
    }

    private func resetModeState() {
        for i in 0..<4 { quickMeasurements[i] = nil }
        quickWidthSpan = nil
        quickLengthSpan = nil
        quickAngleSpan = nil
        quickHitAngleSpans.removeAll(keepingCapacity: true)
        quickRadiusSpan = nil
        distancePointA = nil
        distancePointB = nil
        areaBoundary = nil
        areaLabel = nil
        areaLabelPosition = nil
        activeLabels.removeAll()
    }

    private func formatDistance(_ distSq: Double) -> (String, Double) {
        let dist = sqrt(distSq)
        return (formatDistanceShort(dist), dist)
    }

    private func formatAngle(_ angle: Double) -> String {
        let rounded = angle.rounded()
        if abs(angle - rounded) < 0.01 {
            return String(format: "%.0f°", rounded)
        }
        return String(format: "%.2f°", angle)
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
