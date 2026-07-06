import Foundation

// =========================================================================
// MARK: - CADSnapEngine
//
// Computes the nearest geometric anchor point to a given world-space cursor
// position, enabling precision drafting (snapping to endpoints, midpoints,
// centers, etc.).
//
// Supports these anchor types:
//   - Vertex (polyline/line endpoints)
//   - Midpoint (segment center)
//   - Center (circle/arc/ellipse center)
//   - Quadrant (circle/arc at 0°, 90°, 180°, 270°)
//   - Insertion point (block/text insertion base)
//   - Nearest (closest point on any curve)
//
// The snap engine operates on resolved CADPrimitives for maximum accuracy.
// Results are cached in the engine's _currentSnapResult for the current frame.

// =========================================================================
// MARK: - SnapResult
// =========================================================================

/// Result of a snap hit-test.
public struct SnapResult: Hashable, Sendable {
    public let entityHandle: UUID
    public let anchor: AnchorPoint
    /// World-space position where the snap occurred.
    public let worldPos: Vector3

    public init(entityHandle: UUID, anchor: AnchorPoint, worldPos: Vector3) {
        self.entityHandle = entityHandle
        self.anchor = anchor
        self.worldPos = worldPos
    }
}

// =========================================================================
// MARK: - SnapEngine
// =========================================================================

/// Precision snap engine using tiered filtering for O(log n) performance at scale.
///
/// **Tier 1:** Broad phase — AABB proximity test on each entity's cached
/// `worldBoundingBox` (padded by snap threshold). Rejects 99%+ of entities
/// with a cheap AABB test.
///
/// **Tier 2:** Narrow phase — For candidate entities, transforms their local-space
/// `anchorPoints` to world-space and finds the closest one within threshold.
///
/// **Tier 3:** Nearest-on-curve — If no discrete anchor is within threshold,
/// solves the nearest point ON curved geometry (arcs, circles, ellipses,
/// splines) to the cursor. Discrete anchors deliberately take priority:
/// endpoints/midpoints/centers/quadrants are the points a drafter is aiming
/// for, and without priority the on-curve snap (which is by construction at
/// least as close to the cursor) would always shadow them.
///
/// Because anchor points are stored in local space, moving an entity only updates
/// its `Transform3D` — zero anchor recalculation needed.
public final class SnapEngine {
    /// Default snap threshold in world units.
    public var threshold: Double

    /// Enables Tier 3 nearest-on-curve snapping (AutoCAD "Nearest" osnap for
    /// curved geometry). Toggleable so a future osnap settings UI can expose it.
    public var nearestOnCurveEnabled: Bool = true

    /// Tessellation density used when snapping to splines. The snap target is
    /// the same polyline approximation the renderer draws, so what you snap to
    /// is what you see.
    public var splineSnapSegments: Int = 64

    /// Sentinel UUID used as `entityHandle` for grid-snap results.
    /// Grid points are not real entities — this sentinel ensures they never
    /// match any actual entity handle (e.g., for self-snapping exclusion).
    public static let gridSnapSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init(threshold: Double = 12.0) {
        self.threshold = threshold
    }

    /// Compute the nearest grid intersection to a world-space cursor position.
    /// Returns a `SnapResult` using `gridSnapSentinel` as the entity handle
    /// and `.nearest` as the anchor type.
    public static func nearestGridSnap(
        worldX: Double,
        worldY: Double,
        originX: Double,
        originY: Double,
        spacing: Double,
        threshold: Double
    ) -> SnapResult? {
        guard spacing > 0 else { return nil }
        // Snap to nearest grid intersection
        let gx = round((worldX - originX) / spacing) * spacing + originX
        let gy = round((worldY - originY) / spacing) * spacing + originY
        let dx = gx - worldX
        let dy = gy - worldY
        let dist = sqrt(dx * dx + dy * dy)
        guard dist < threshold else { return nil }
        return SnapResult(
            entityHandle: gridSnapSentinel,
            anchor: .nearest(localPosition: Vector3(x: gx, y: gy, z: 0)),
            worldPos: Vector3(x: gx, y: gy, z: 0)
        )
    }

    /// Find the nearest extension snap point — projects the cursor onto the
    /// infinite extension of lines past their endpoints, and onto the tangent
    /// extension of arcs past their endpoints.
    ///
    /// Extension snaps are tested AFTER discrete anchor snap but BEFORE grid
    /// and nearest-on-curve snaps. The snap result always uses `AnchorPoint.nearest`.
    ///
    /// Uses the same candidate set computed during Tier 1 broad phase to avoid
    /// redundant AABB testing.
    private func nearestExtensionSnap(
        cursor: Vector3,
        candidates: [CADEntity],
        resolveGeometry: ((CADEntity) -> [CADPrimitive]?)?,
        threshold: Double
    ) -> SnapResult? {
        var best: SnapResult? = nil
        var bestDist = threshold

        for entity in candidates {
            let geometry = resolveGeometry?(entity) ?? entity.localGeometry
            guard let geometry, !geometry.isEmpty else { continue }

            let invTransform = entity.transform.inverse()
            let localCursor = invTransform.transformPoint(cursor)

            for prim in geometry {
                switch prim {
                case .polyline(let path, _):
                    let points = path.tessellatedPoints()
                    for i in 0..<(points.count - 1) {
                        let start = points[i]
                        let end = points[i + 1]
                        let dir = Vector3(x: end.x - start.x, y: end.y - start.y, z: 0)
                        let lenSq = dir.magnitudeSquared
                        guard lenSq > 1e-12 else { continue }
                        let dirNorm = Vector3(x: dir.x / sqrt(lenSq), y: dir.y / sqrt(lenSq), z: 0)
                        // Extension past end
                        let rxEnd = localCursor.x - end.x
                        let ryEnd = localCursor.y - end.y
                        let tEnd = rxEnd * dirNorm.x + ryEnd * dirNorm.y
                        if tEnd > 0 {
                            let perpDist = abs(rxEnd * dirNorm.y - ryEnd * dirNorm.x)
                            if perpDist < bestDist {
                                bestDist = perpDist
                                let proj = Vector3(x: end.x + dirNorm.x * tEnd, y: end.y + dirNorm.y * tEnd, z: end.z)
                                best = SnapResult(
                                    entityHandle: entity.handle,
                                    anchor: .nearest(localPosition: proj),
                                    worldPos: entity.transform.transformPoint(proj))
                            }
                        }
                        // Extension past start
                        let negDirX = -dirNorm.x
                        let negDirY = -dirNorm.y
                        let rxStart = localCursor.x - start.x
                        let ryStart = localCursor.y - start.y
                        let tStart = rxStart * negDirX + ryStart * negDirY
                        if tStart > 0 {
                            let perpDist = abs(rxStart * negDirY - ryStart * negDirX)
                            if perpDist < bestDist {
                                bestDist = perpDist
                                let proj = Vector3(x: start.x + negDirX * tStart, y: start.y + negDirY * tStart, z: start.z)
                                best = SnapResult(
                                    entityHandle: entity.handle,
                                    anchor: .nearest(localPosition: proj),
                                    worldPos: entity.transform.transformPoint(proj))
                            }
                        }
                    }

                case .line(let start, let end, _):
                    // Line segment: check extension past start and past end.
                    let dir = Vector3(x: end.x - start.x, y: end.y - start.y, z: 0)
                    let lenSq = dir.magnitudeSquared
                    guard lenSq > 1e-12 else { break }
                    let dirNorm = Vector3(x: dir.x / sqrt(lenSq), y: dir.y / sqrt(lenSq), z: 0)

                    // Check extension past `end` — infinite ray ahead of endpoint.
                    let rxEnd = localCursor.x - end.x
                    let ryEnd = localCursor.y - end.y
                    let tEnd = rxEnd * dirNorm.x + ryEnd * dirNorm.y
                    if tEnd > 0 {
                        // Cross-product perpendicular distance (dirNorm is unit-length).
                        let perpDist = abs(rxEnd * dirNorm.y - ryEnd * dirNorm.x)
                        if perpDist < bestDist {
                            bestDist = perpDist
                            let proj = Vector3(x: end.x + dirNorm.x * tEnd, y: end.y + dirNorm.y * tEnd, z: end.z)
                            best = SnapResult(
                                entityHandle: entity.handle,
                                anchor: .nearest(localPosition: proj),
                                worldPos: entity.transform.transformPoint(proj))
                        }
                    }

                    // Check extension past `start` — infinite ray in opposite direction.
                    let negDirX = -dirNorm.x
                    let negDirY = -dirNorm.y
                    let rxStart = localCursor.x - start.x
                    let ryStart = localCursor.y - start.y
                    let tStart = rxStart * negDirX + ryStart * negDirY
                    if tStart > 0 {
                        let perpDist = abs(rxStart * negDirY - ryStart * negDirX)
                        if perpDist < bestDist {
                            bestDist = perpDist
                            let proj = Vector3(x: start.x + negDirX * tStart, y: start.y + negDirY * tStart, z: start.z)
                            best = SnapResult(
                                entityHandle: entity.handle,
                                anchor: .nearest(localPosition: proj),
                                worldPos: entity.transform.transformPoint(proj))
                        }
                    }

                case .arc(let center, let radius, let startAngle, let endAngle, _):
                    // Arc: tangent extension at each endpoint.
                    let span = endAngle - startAngle >= 0
                        ? endAngle - startAngle
                        : endAngle - startAngle + 2.0 * .pi

                    // Tangent at start angle = perpendicular to radius.
                    // tanStart is already normalized: (-sin)² + cos² = 1.
                    let startPt = Vector3(
                        x: center.x + cos(startAngle) * radius,
                        y: center.y + sin(startAngle) * radius, z: center.z)
                    let tanStart = Vector3(
                        x: -sin(startAngle), y: cos(startAngle), z: 0)

                    let rxS = localCursor.x - startPt.x
                    let ryS = localCursor.y - startPt.y
                    let tS = rxS * tanStart.x + ryS * tanStart.y
                    if tS > 0 {
                        let perpDist = abs(rxS * tanStart.y - ryS * tanStart.x)
                        if perpDist < bestDist {
                            bestDist = perpDist
                            let proj = Vector3(
                                x: startPt.x + tanStart.x * tS,
                                y: startPt.y + tanStart.y * tS, z: startPt.z)
                            best = SnapResult(
                                entityHandle: entity.handle,
                                anchor: .nearest(localPosition: proj),
                                worldPos: entity.transform.transformPoint(proj))
                        }
                    }

                    // Tangent at end angle.
                    let endPt = Vector3(
                        x: center.x + cos(startAngle + span) * radius,
                        y: center.y + sin(startAngle + span) * radius, z: center.z)
                    let tanEnd = Vector3(
                        x: -sin(startAngle + span), y: cos(startAngle + span), z: 0)

                    let rxE = localCursor.x - endPt.x
                    let ryE = localCursor.y - endPt.y
                    let tE = rxE * tanEnd.x + ryE * tanEnd.y
                    if tE > 0 {
                        let perpDist = abs(rxE * tanEnd.y - ryE * tanEnd.x)
                        if perpDist < bestDist {
                            bestDist = perpDist
                            let proj = Vector3(
                                x: endPt.x + tanEnd.x * tE,
                                y: endPt.y + tanEnd.y * tE, z: endPt.z)
                            best = SnapResult(
                                entityHandle: entity.handle,
                                anchor: .nearest(localPosition: proj),
                                worldPos: entity.transform.transformPoint(proj))
                        }
                    }

                default:
                    break
                }
            }
        }

        return best
    }

    /// Find the nearest snap point within threshold.
    /// Returns nil if no anchor point or on-curve point is within range.
    ///
    /// `resolveGeometry` supplies primitives for entities whose geometry is not
    /// stored locally (block instances reference shared block definitions, in
    /// the instance's local space). When nil, `entity.localGeometry` is used,
    /// which covers all loose entities; block-instance curves then only snap
    /// at their anchor points.
    ///
    /// When `extensionSnapEnabled` is true, the engine also looks for snaps
    /// along the infinite extension of line/arc endpoints. Extension snaps
    /// have lower priority than discrete anchors but beat grid snaps.
    ///
    /// When `gridSnapEnabled` is true, grid intersections at `gridSpacing`
    /// (from `gridOriginX`, `gridOriginY`) are also tested. Grid snaps have
    /// lower priority than entity discrete anchors and extension snaps but
    /// higher priority than on-curve nearest points.
    public func nearestSnap(
        worldX: Double,
        worldY: Double,
        entities: [CADEntity],
        threshold: Double? = nil,
        resolveGeometry: ((CADEntity) -> [CADPrimitive]?)? = nil,
        extensionSnapEnabled: Bool = false,
        extensionThresholdPx: Double = 12.0,
        pixelsPerWorldUnit: Double = 1.0,
        gridSnapEnabled: Bool = false,
        gridOriginX: Double = 0,
        gridOriginY: Double = 0,
        gridSpacing: Double = 10,
        nearestOnCurveOverride: Bool? = nil
    ) -> SnapResult? {
        let thresh = threshold ?? self.threshold
        let cursor = Vector3(x: worldX, y: worldY, z: 0)

        // Tier 1: Broad phase — AABB proximity filter.
        var candidates: [CADEntity] = []
        for entity in entities {
            guard let wbb = entity.worldBoundingBox else { continue }
            if wbb.expanded(by: thresh).contains(cursor) {
                candidates.append(entity)
            }
        }

        // Tier 2: Narrow phase — exact anchor-point distance.
        var best: SnapResult? = nil
        var bestDist = thresh

        for entity in candidates {
            for ap in entity.anchorPoints {
                let worldPos = ap.worldPosition(transform: entity.transform)
                let dx = worldPos.x - cursor.x
                let dy = worldPos.y - cursor.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist {
                    bestDist = dist
                    best = SnapResult(
                        entityHandle: entity.handle,
                        anchor: ap,
                        worldPos: worldPos
                    )
                }
            }
        }

        // Anchor snaps win whenever one is in range — a drafter hovering near
        // an endpoint wants the endpoint, not the on-curve point that is
        // necessarily at least as close to the cursor.
        if best != nil { return best }

        // Tier 2.6: Extension snaps — snap to points along the infinite
        // extension of lines and the tangent extension of arcs past their
        // endpoints. Lower priority than discrete anchors but beats grid snap.
        if extensionSnapEnabled {
            let extThreshWorld = extensionThresholdPx / max(pixelsPerWorldUnit, 0.001)
            if let extSnap = nearestExtensionSnap(
                cursor: cursor, candidates: candidates,
                resolveGeometry: resolveGeometry,
                threshold: min(thresh, extThreshWorld))
            {
                return extSnap
            }
        }

        // Tier 2.5: Grid intersection snap.
        // Tested AFTER entity discrete anchors but BEFORE on-curve nearest.
        // Grid intersections are precise, discrete targets — they should beat
        // the fuzzy on-curve snap, but lose to explicit entity geometry anchors.
        if gridSnapEnabled {
            if let gridSnap = SnapEngine.nearestGridSnap(
                worldX: worldX, worldY: worldY,
                originX: gridOriginX, originY: gridOriginY,
                spacing: gridSpacing, threshold: thresh)
            {
                return gridSnap
            }
        }

        let doNearestOnCurve = nearestOnCurveOverride ?? nearestOnCurveEnabled
        guard doNearestOnCurve else { return nil }

        // Tier 3: Nearest point on curved geometry.
        // The cursor is transformed into entity-local space, the nearest point
        // is solved on the local curve, then mapped back through the entity
        // transform. Under rotation + uniform scale this is exact; under
        // non-uniform scale it is the same approximation used throughout the
        // codebase (max |sx|,|sy|), and the candidate's distance is still
        // measured in true world space.
        var bestCurve: SnapResult? = nil
        var bestCurveDist = thresh

        for entity in candidates {
            let geometry = resolveGeometry?(entity) ?? entity.localGeometry
            guard let geometry, !geometry.isEmpty else { continue }

            let invTransform = entity.transform.inverse()
            let localCursor = invTransform.transformPoint(cursor)

            for prim in geometry {
                let localNearest: Vector3?
                switch prim {
                case .table: localNearest = nil
                case .point(let position, _):
                    localNearest = position

                case .line(let start, let end, _):
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: [start, end])

                case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
                    let corners = [
                        origin,
                        Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                        Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                        Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
                    ]
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: corners, closed: true)

                case .polygon(let points, _), .fillPolygon(let points, _):
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: points, closed: true)

                case .polyline(let path, _):
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: path.tessellatedPoints(), closed: false)

                case .fillComplexPolygon(let outer, let holes, _):
                    var bestNP: Vector3? = nil
                    var bestDistSq = Double.greatestFiniteMagnitude
                    func checkChain(_ chain: [Vector3]) {
                        if let np = CADGeometryMath.nearestPointOnPolyline(to: localCursor, points: chain, closed: true) {
                            let dsq = (np - localCursor).magnitudeSquared
                            if dsq < bestDistSq {
                                bestDistSq = dsq
                                bestNP = np
                            }
                        }
                    }
                    checkChain(outer)
                    for hole in holes {
                        checkChain(hole)
                    }
                    localNearest = bestNP

                case .gradient(let outer, let holes, _, _, _, _):
                    var bestNP: Vector3? = nil
                    var bestDistSq = Double.greatestFiniteMagnitude
                    func checkChain(_ chain: [Vector3]) {
                        if let np = CADGeometryMath.nearestPointOnPolyline(to: localCursor, points: chain, closed: true) {
                            let dsq = (np - localCursor).magnitudeSquared
                            if dsq < bestDistSq {
                                bestDistSq = dsq
                                bestNP = np
                            }
                        }
                    }
                    checkChain(outer)
                    for hole in holes {
                        checkChain(hole)
                    }
                    localNearest = bestNP

                case .arc(let center, let radius, let startAngle, let endAngle, _):
                    localNearest = CADGeometryMath.nearestPointOnArc(
                        to: localCursor, center: center, radius: radius,
                        startAngle: startAngle, endAngle: endAngle)

                case .circle(let center, let radius, _):
                    localNearest = CADGeometryMath.nearestPointOnCircle(
                        to: localCursor, center: center, radius: radius)

                case .ellipse(let center, let majorAxis, let minorRatio, _):
                    localNearest = CADGeometryMath.nearestPointOnEllipse(
                        to: localCursor, center: center,
                        majorAxis: majorAxis, minorRatio: minorRatio)

                case .spline(let controlPoints, let knots, let degree, let weights, _):
                    guard controlPoints.count >= 2 else {
                        localNearest = nil
                        break
                    }
                    let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
                    let sampled = NURBSEvaluator.evaluateByKnotSpans(
                        degree: degree, knots: knots,
                        controlPoints: controlPoints, weights: w,
                        segmentsPerSpan: max(4, splineSnapSegments / 4))
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: sampled)

                case .text(let position, _, _, _, _, _, _, _, _):
                    localNearest = position

                case .hatch(let boundary, _, _, _, _, _):
                    localNearest = CADGeometryMath.nearestPointOnPolyline(
                        to: localCursor, points: boundary, closed: true)

                case .ray(let start, let direction, _):
                    let dirNorm = direction.normalized
                    let v = localCursor - start
                    let t = v.dot(dirNorm)
                    if t < 0 {
                        localNearest = start
                    } else {
                        localNearest = start + dirNorm * t
                    }
                case .image:
                    localNearest = nil
                }

                guard let lp = localNearest else { continue }
                let worldPos = entity.transform.transformPoint(lp)
                let dx = worldPos.x - cursor.x
                let dy = worldPos.y - cursor.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestCurveDist {
                    bestCurveDist = dist
                    bestCurve = SnapResult(
                        entityHandle: entity.handle,
                        anchor: .nearest(localPosition: lp),
                        worldPos: worldPos
                    )
                }
            }
        }

        return bestCurve
    }
}