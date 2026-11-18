import Foundation

// =========================================================================
// MARK: - RegionBoolean (Step 2: UNION / SUBTRACT / INTERSECT)
// =========================================================================
//
// Planar-arrangement Booleans over the Step 1 region model. Every input
// ring (outer or hole, in world coordinates) is tessellated at the recorded
// chord tolerance, split at all crossings into a planar graph, and the
// resulting faces are classified against the input solids with an
// even-odd point-in-ring test. Selected face boundaries are chained into
// loops and nested into outer-plus-hole faces with the same parity rule
// as `CADBoundaryDetector.classifyLoops`, so UNION of disjoint inputs
// yields several faces, SUBTRACT of a contained cutter yields a hole,
// and empty INTERSECT yields no faces.
//
// Straight input spans stay exact; bulge arcs are linearized within
// `chordTolerance` (Step 0 budget: 0.001-0.005 world units). Outputs are
// straight-segment closed polylines. Degenerate input the arrangement
// cannot represent (zero-length spans) is dropped before the walk; tangent
// touches resolve to the touching point and classify by the same rule.

public enum RegionBooleanOp: Sendable {
    case union
    case subtract
    case intersect
}

/// One input solid in world coordinates: a closed outer loop plus holes.
public struct BooleanSolid: Sendable {
    public var outer: CADPolyline
    public var holes: [CADPolyline]
    public var layerID: UUID
    public var color: ColorRGBA?
    public var sourceHandles: Set<UUID>

    public init(
        outer: CADPolyline,
        holes: [CADPolyline] = [],
        layerID: UUID,
        color: ColorRGBA? = nil,
        sourceHandles: Set<UUID> = []
    ) {
        self.outer = outer
        self.holes = holes
        self.layerID = layerID
        self.color = color
        self.sourceHandles = sourceHandles
    }
}

/// One output face in world coordinates: a closed outer loop plus holes.
public struct BooleanFace: Sendable {
    public var outer: CADPolyline
    public var holes: [CADPolyline]
    public var planeZ: Double
    public var layerID: UUID
    public var color: ColorRGBA?

    public init(
        outer: CADPolyline,
        holes: [CADPolyline] = [],
        planeZ: Double,
        layerID: UUID,
        color: ColorRGBA? = nil
    ) {
        self.outer = outer
        self.holes = holes
        self.planeZ = planeZ
        self.layerID = layerID
        self.color = color
    }
}

public enum RegionBoolean {

    /// Max deviation of a tessellated arc span from the true arc.
    /// Straight spans are unaffected (they tessellate exactly).
    public static let chordTolerance: Double = 0.002
    /// Node identity quantum: endpoints closer than this merge.
    public static let nodeQuantum: Double = 1e-9
    /// Split params nearer than this to a span end are ignored (the node
    /// already exists there).
    public static let splitEps: Double = 1e-9
    /// Face test-point offset from the first boundary edge midpoint.
    /// The half-edge walk keeps face interiors on the LEFT of travel
    /// (verified by `testArrangementKeepsInteriorOnLeft`). Must stay far
    /// above the ray-cast nudge in `isPointInRing` and far below the
    /// thinnest legitimate feature (bolt-hole diameter in fixtures is ~1).
    public static let testOffset: Double = 1e-5

    // MARK: - Entry point

    /// Runs `op` over `targets` (and `cutters` for subtract).
    /// Returns output faces plus user-facing failure messages. A clean
    /// empty result (covered target, null intersection) returns no faces
    /// and no failures; the caller reports it.
    public static func apply(
        _ op: RegionBooleanOp,
        targets: [BooleanSolid],
        cutters: [BooleanSolid] = [],
        chordTolerance: Double = RegionBoolean.chordTolerance
    ) -> (faces: [BooleanFace], failures: [String]) {
        guard !targets.isEmpty else {
            return ([], ["No target regions selected."])
        }
        if op == .subtract, cutters.isEmpty {
            return ([], ["No cutting regions selected."])
        }
        let involved = op == .subtract ? targets + cutters : targets

        // Coplanarity gate: every ring of every solid shares one Z.
        var zMin = Double.infinity, zMax = -Double.infinity
        for solid in involved {
            for ring in [solid.outer] + solid.holes {
                for v in ring.vertices {
                    zMin = min(zMin, v.position.z)
                    zMax = max(zMax, v.position.z)
                }
            }
        }
        guard zMax - zMin <= RegionBuilder.planarTolerance else {
            return ([], [
                "Selected regions lie on different elevations "
                    + "(spread \(zMax - zMin)). "
                    + "Boolean operations require coplanar regions.",
            ])
        }
        let planeZ = (zMin + zMax) / 2.0

        // Tessellate every ring; tag each with owning solid + hole flag.
        struct TaggedRing {
            var points: [Vector3]
            var solidIndex: Int
            var isHole: Bool
        }
        var rings: [TaggedRing] = []
        for (index, solid) in involved.enumerated() {
            let outer = tessellateRing(solid.outer, chordTolerance: chordTolerance)
            guard outer.count >= 3 else { continue }
            rings.append(TaggedRing(
                points: outer, solidIndex: index, isHole: false))
            for hole in solid.holes {
                let pts = tessellateRing(hole, chordTolerance: chordTolerance)
                guard pts.count >= 3 else { continue }
                rings.append(TaggedRing(
                    points: pts, solidIndex: index, isHole: true))
            }
        }
        guard !rings.isEmpty else {
            return ([], ["Degenerate loop rejected (fewer than 3 points)."])
        }

        let targetCount = targets.count
        let arrangement = Arrangement(rings: rings.map(\.points))

        // Classify each face against the input solids.
        var selected: [Bool] = []
        selected.reserveCapacity(arrangement.faces.count)
        for faceIndex in 0..<arrangement.faces.count {
            let test = arrangement.testPoints[faceIndex]
            let inTarget = (0..<targetCount).contains { si in
                solidContains(solids: involved, solidIndex: si, point: test)
            }
            switch op {
            case .union:
                selected.append(inTarget)
            case .intersect:
                selected.append((0..<targetCount).allSatisfy { si in
                    solidContains(solids: involved, solidIndex: si, point: test)
                })
            case .subtract:
                let inCutter = (targetCount..<involved.count).contains { si in
                    solidContains(solids: involved, solidIndex: si, point: test)
                }
                selected.append(inTarget && !inCutter)
            }
        }
        guard selected.contains(true) else { return ([], []) }

        // Boundary: half-edges with exactly one selected side.
        let loops = arrangement.boundaryLoops(selected: selected)
        guard !loops.isEmpty else { return ([], []) }

        // Nest into outer-plus-hole faces with the standard parity rule.
        let regions = CADBoundaryDetector.classifyLoops(loops, islandStyle: 0)
        // New faces inherit the first target's layer and color.
        let anchor = targets[0]
        var faces: [BooleanFace] = []
        for region in regions {
            guard region.outer.count >= 3 else { continue }
            let outer = CADPolyline(
                points: region.outer.map {
                    Vector3(x: $0.x, y: $0.y, z: planeZ)
                },
                isClosed: true)
            let holes = region.holes.compactMap { hole -> CADPolyline? in
                guard hole.count >= 3 else { return nil }
                return CADPolyline(
                    points: hole.map {
                        Vector3(x: $0.x, y: $0.y, z: planeZ)
                    },
                    isClosed: true)
            }
            faces.append(BooleanFace(
                outer: outer, holes: holes, planeZ: planeZ,
                layerID: anchor.layerID, color: anchor.color))
        }
        return (faces, [])
    }

    // MARK: - Input extraction (region-only enforcement)

    /// Reads region entities into world-space solids. Any non-region
    /// entity (or block reference, or open loop) is a failure; the caller
    /// aborts with no document changes.
    public static func extractSolids(
        from entities: [CADEntity]
    ) -> (solids: [BooleanSolid], failures: [String]) {
        var solids: [BooleanSolid] = []
        var failures: [String] = []
        for entity in entities {
            guard CADRegion.isRegionEntity(entity) else {
                failures.append(
                    "Entity is not a region - Boolean operations require "
                        + "region entities (use REGION first).")
                continue
            }
            guard entity.blockID == nil else {
                failures.append(
                    "Block references cannot be used in Boolean operations - "
                        + "EXPLODE them first.")
                continue
            }
            guard let prims = entity.localGeometry, !prims.isEmpty else {
                if CADRegion.acisBlob(of: entity) != nil {
                    failures.append(
                        "Entity is an opaque ACIS region - Boolean operations "
                            + "require editable region geometry.")
                } else {
                    failures.append("Degenerate loop rejected (no geometry).")
                }
                continue
            }
            var loops: [CADPolyline] = []
            var ok = true
            for prim in prims {
                guard case let .polyline(path, _) = prim, path.isClosed else {
                    failures.append(
                        "Degenerate loop rejected (region loop is not a "
                            + "closed polyline).")
                    ok = false
                    break
                }
                loops.append(path.transformed(by: entity.transform))
            }
            if !ok { continue }
            solids.append(BooleanSolid(
                outer: loops[0],
                holes: Array(loops.dropFirst()),
                layerID: entity.layerID,
                color: primColor(of: prims[0]),
                sourceHandles: [entity.handle]))
        }
        return (solids, failures)
    }

    private static func primColor(of prim: CADPrimitive) -> ColorRGBA? {
        switch prim {
        case let .polyline(_, color): return color
        default: return nil
        }
    }

    // MARK: - Tessellation at chord tolerance

    /// Tessellates one closed loop; straight spans stay exact, bulge arcs
    /// are divided so no span deviates more than `chordTolerance`.
    public static func tessellateRing(
        _ path: CADPolyline,
        chordTolerance: Double = RegionBoolean.chordTolerance
    ) -> [Vector3] {
        var pts: [Vector3] = []
        pts.reserveCapacity(max(4, path.segmentCount * 4))
        for seg in 0..<path.segmentCount {
            let a = path.vertices[seg].position
            let b = path.vertices[path.endVertexIndex(forSegment: seg)].position
            if pts.isEmpty { pts.append(a) }
            if let arc = path.arcParameters(forSegment: seg) {
                let n = divisionsForArc(
                    radius: arc.radius, sweep: abs(arc.sweep),
                    chordTolerance: chordTolerance)
                for i in 1...n {
                    let t = Double(i) / Double(n)
                    let ang = arc.startAngle + arc.sweep * t
                    pts.append(Vector3(
                        x: arc.center.x + cos(ang) * arc.radius,
                        y: arc.center.y + sin(ang) * arc.radius,
                        z: a.z + (b.z - a.z) * t))
                }
            } else {
                pts.append(b)
            }
        }
        // Drop the duplicated closing point and consecutive duplicates.
        if pts.count > 1, let first = pts.first, let last = pts.last,
           last.distance(to: first) <= 1e-9 {
            pts.removeLast()
        }
        var clean: [Vector3] = []
        clean.reserveCapacity(pts.count)
        for p in pts {
            if let last = clean.last, last.distance(to: p) <= 1e-9 { continue }
            clean.append(p)
        }
        if clean.count > 1, let first = clean.first, let last = clean.last,
           last.distance(to: first) <= 1e-9 {
            clean.removeLast()
        }
        return clean
    }

    private static func divisionsForArc(
        radius: Double, sweep: Double, chordTolerance: Double
    ) -> Int {
        guard radius > 1e-12, sweep > 1e-12 else { return 1 }
        // Sagitta s = r(1 - cos(sweep/2n)) <= tol.
        let clamped = max(-1.0, min(1.0, 1.0 - min(chordTolerance, radius) / radius))
        let denom = 2.0 * acos(clamped)
        guard denom > 1e-12 else { return 4 }
        return max(4, Int(ceil(sweep / denom)))
    }

    /// Tessellated shoelace area (bulges linearized). Used for net-area
    /// reporting on holed region entities.
    public static func tessellatedArea(of path: CADPolyline) -> Double {
        let ring = tessellateRing(path)
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) * 0.5
    }

    /// Exact perimeter: arc spans use radius * sweep, straight spans use
    /// chord length.
    public static func exactPerimeter(of path: CADPolyline) -> Double {
        var total = 0.0
        for seg in 0..<path.segmentCount {
            if let arc = path.arcParameters(forSegment: seg) {
                total += abs(arc.sweep) * arc.radius
            } else {
                let a = path.vertices[seg].position
                let b = path.vertices[path.endVertexIndex(forSegment: seg)].position
                total += hypot(b.x - a.x, b.y - a.y)
            }
        }
        return total
    }

    // MARK: - Face classification helpers

    private static func solidContains(
        solids: [BooleanSolid], solidIndex: Int, point: Vector3
    ) -> Bool {
        // Rebuild this solid's tessellated rings (cheap: few rings).
        // Outer even-odd containment minus any hole containment.
        let solid = solids[solidIndex]
        let outer = tessellateRing(solid.outer)
        guard isPointInRing(point, outer) else { return false }
        for hole in solid.holes {
            if isPointInRing(point, tessellateRing(hole)) { return false }
        }
        return true
    }

    /// Even-odd ray cast with a tiny +y nudge so a ray starting exactly
    /// on a vertex still counts consistently. Kept far below
    /// `testOffset` so face test points never cross back over the edge
    /// they were offset from.
    public static func isPointInRing(_ p: Vector3, _ ring: [Vector3]) -> Bool {
        let py = p.y + 1e-9
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i], pj = ring[j]
            if ((pi.y > py) != (pj.y > py)) {
                let x = (pj.x - pi.x) * (py - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

// =========================================================================
// MARK: - Arrangement (planar graph + face walk)
// =========================================================================

extension RegionBoolean {

    /// Planar straight-line graph built from closed rings. Splits every
    /// span at all crossings, walks faces with a rightmost (minimum signed
    /// turn) rule that keeps face interiors on the LEFT of travel, and
    /// extracts boundary loops for a per-face selection.
    struct Arrangement {
        var nodes: [Vector3] = []
        var halfFrom: [Int] = []
        var halfTo: [Int] = []
        var twin: [Int] = []
        var outgoing: [[Int]] = []
        var faces: [[Vector3]] = []
        var faceOfHalf: [Int] = []
        var testPoints: [Vector3] = []

        private struct NodeKey: Hashable {
            var x: Int64
            var y: Int64
        }

        init(rings: [[Vector3]]) {
            // 1. Raw spans (drop zero-length crumbs).
            var segs: [(a: Vector3, b: Vector3)] = []
            for ring in rings {
                guard ring.count >= 3 else { continue }
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[(i + 1) % ring.count]
                    if a.distance(to: b) > 1e-12 { segs.append((a, b)) }
                }
            }
            guard !segs.isEmpty else { return }

            // 2. Split every span at all crossings / touches / overlaps.
            var splits = Array(repeating: [0.0, 1.0], count: segs.count)
            for i in 0..<segs.count {
                for j in (i + 1)..<segs.count {
                    // Bounding-box reject (padded).
                    let eps = 1e-9
                    if max(segs[i].a.x, segs[i].b.x) < min(segs[j].a.x, segs[j].b.x) - eps
                        || max(segs[j].a.x, segs[j].b.x) < min(segs[i].a.x, segs[i].b.x) - eps
                        || max(segs[i].a.y, segs[i].b.y) < min(segs[j].a.y, segs[j].b.y) - eps
                        || max(segs[j].a.y, segs[j].b.y) < min(segs[i].a.y, segs[i].b.y) - eps {
                        continue
                    }
                    Self.addSplits(i, j, segs: segs, splits: &splits)
                }
            }

            // 3. Sub-spans -> quantized nodes, deduplicated undirected edges.
            var keyToNode: [NodeKey: Int] = [:]
            func nodeID(_ p: Vector3) -> Int {
                let key = NodeKey(
                    x: Int64((p.x / RegionBoolean.nodeQuantum).rounded()),
                    y: Int64((p.y / RegionBoolean.nodeQuantum).rounded()))
                if let existing = keyToNode[key] { return existing }
                let id = nodes.count
                nodes.append(Vector3(x: p.x, y: p.y, z: p.z))
                keyToNode[key] = id
                return id
            }
            struct EdgeKey: Hashable {
                var lo: Int
                var hi: Int
            }
            var seen = Set<EdgeKey>()
            var pairs: [(Int, Int)] = []
            for (index, seg) in segs.enumerated() {
                var params = splits[index].sorted()
                // Dedup params that would make sub-quantum crumbs.
                var kept: [Double] = []
                for t in params {
                    if let last = kept.last, t - last < 1e-7 { continue }
                    kept.append(t)
                }
                params = kept
                for k in 0..<(params.count - 1) {
                    let t0 = params[k], t1 = params[k + 1]
                    guard t1 > t0 else { continue }
                    let p0 = Vector3(
                        x: seg.a.x + (seg.b.x - seg.a.x) * t0,
                        y: seg.a.y + (seg.b.y - seg.a.y) * t0,
                        z: seg.a.z + (seg.b.z - seg.a.z) * t0)
                    let p1 = Vector3(
                        x: seg.a.x + (seg.b.x - seg.a.x) * t1,
                        y: seg.a.y + (seg.b.y - seg.a.y) * t1,
                        z: seg.a.z + (seg.b.z - seg.a.z) * t1)
                    if p0.distance(to: p1) <= 1e-9 { continue }
                    let n0 = nodeID(p0), n1 = nodeID(p1)
                    if n0 == n1 { continue }
                    let key = EdgeKey(lo: min(n0, n1), hi: max(n0, n1))
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    pairs.append((n0, n1))
                }
            }
            guard !pairs.isEmpty else { return }

            // 4. Half-edges + twins (each undirected edge yields one pair).
            for (a, b) in pairs {
                let fwd = halfFrom.count
                halfFrom.append(a)
                halfTo.append(b)
                let rev = halfFrom.count
                halfFrom.append(b)
                halfTo.append(a)
                twin.append(rev)
                twin.append(fwd)
            }
            outgoing = Array(repeating: [], count: nodes.count)
            for he in 0..<halfFrom.count {
                outgoing[halfFrom[he]].append(he)
            }
            var angle = [Double](repeating: 0, count: halfFrom.count)
            for he in 0..<halfFrom.count {
                let a = nodes[halfFrom[he]], b = nodes[halfTo[he]]
                angle[he] = atan2(b.y - a.y, b.x - a.x)
            }
            for n in 0..<nodes.count {
                outgoing[n].sort { angle[$0] < angle[$1] }
            }

            // 5. Face walk: at each vertex take the MINIMUM clockwise turn
            // from the back direction, excluding the backtrack edge.
            // (Minimum signed turn backtracks on outer faces and loops
            // forever; maximum-cw sails straight through T-junctions and
            // double-covers the plane.) Minimum-cw-exclusive keeps every
            // face interior on the LEFT of travel.
            var used = [Bool](repeating: false, count: halfFrom.count)
            faceOfHalf = [Int](repeating: -1, count: halfFrom.count)
            var faceRep: [Int] = []
            let cap = halfFrom.count * 4 + 16
            for start in 0..<halfFrom.count where !used[start] {
                var cur = start
                var loop: [Int] = []
                var guardCount = 0
                repeat {
                    used[cur] = true
                    faceOfHalf[cur] = faces.count
                    loop.append(halfFrom[cur])
                    let v = halfTo[cur]
                    let u = halfFrom[cur]
                    let back = atan2(
                        nodes[u].y - nodes[v].y, nodes[u].x - nodes[v].x)
                    var best = -1
                    var bestCw = Double.infinity
                    for oe in outgoing[v] where oe != twin[cur] {
                        let w = halfTo[oe]
                        if w == v { continue }
                        let ang = atan2(
                            nodes[w].y - nodes[v].y, nodes[w].x - nodes[v].x)
                        var cw = back - ang
                        while cw < 0 { cw += 2.0 * Double.pi }
                        while cw >= 2.0 * Double.pi { cw -= 2.0 * Double.pi }
                        if cw < bestCw {
                            bestCw = cw
                            best = oe
                        }
                    }
                    guard best >= 0 else { break }
                    cur = best
                    guardCount += 1
                    if guardCount > cap { break }
                } while cur != start
                faces.append(loop.map { nodes[$0] })
                faceRep.append(start)
            }

            // 6. Test points: midpoint of the face's first edge, offset LEFT
            // (the walk keeps interiors on the left of travel).
            testPoints = []
            testPoints.reserveCapacity(faces.count)
            for he in faceRep {
                let a = nodes[halfFrom[he]], b = nodes[halfTo[he]]
                let len = max(hypot(b.x - a.x, b.y - a.y), 1e-12)
                let nx = -(b.y - a.y) / len
                let ny = (b.x - a.x) / len
                testPoints.append(Vector3(
                    x: (a.x + b.x) / 2.0 + nx * RegionBoolean.testOffset,
                    y: (a.y + b.y) / 2.0 + ny * RegionBoolean.testOffset,
                    z: (a.z + b.z) / 2.0))
            }
        }

        /// Chains boundary half-edges (exactly one selected side) into loops.
        func boundaryLoops(selected: [Bool]) -> [[Vector3]] {
            guard selected.count == faces.count else { return [] }
            var use: [Bool] = halfFrom.indices.map { he in
                selected[faceOfHalf[he]] != selected[faceOfHalf[twin[he]]]
            }
            var fromMap: [Int: [Int]] = [:]
            for he in halfFrom.indices where use[he] {
                fromMap[halfFrom[he], default: []].append(he)
            }
            var loops: [[Vector3]] = []
            for start in halfFrom.indices where use[start] {
                var cur = start
                var loop: [Vector3] = []
                var guardCount = 0
                repeat {
                    // Consume both directions: the twin would chain the
                    // same geometric loop reversed (double emission).
                    use[cur] = false
                    use[twin[cur]] = false
                    loop.append(nodes[halfFrom[cur]])
                    let v = halfTo[cur]
                    guard let nexts = fromMap[v], !nexts.isEmpty else { break }
                    // Prefer continuing straight (minimum turn), never
                    // U-turning onto the backtrack edge.
                    let back = atan2(
                        nodes[halfFrom[cur]].y - nodes[v].y,
                        nodes[halfFrom[cur]].x - nodes[v].x)
                    var best = -1
                    var bestTurn = Double.infinity
                    for nx in nexts where use[nx] && nx != twin[cur] {
                        let w = halfTo[nx]
                        let ang = atan2(
                            nodes[w].y - nodes[v].y, nodes[w].x - nodes[v].x)
                        var turn = ang - back
                        while turn <= -Double.pi { turn += 2.0 * Double.pi }
                        while turn > Double.pi { turn -= 2.0 * Double.pi }
                        if abs(turn) < abs(bestTurn) {
                            bestTurn = turn
                            best = nx
                        }
                    }
                    // Dead end (should not happen for closed boundaries):
                    // stop instead of wandering onto used edges.
                    guard best >= 0 else { break }
                    cur = best
                    guardCount += 1
                    if guardCount > halfFrom.count + 4 { break }
                } while cur != start
                if loop.count >= 3 { loops.append(loop) }
            }
            return loops
        }

        // MARK: - Segment pair splitting

        private static func addSplits(
            _ i: Int, _ j: Int,
            segs: [(a: Vector3, b: Vector3)],
            splits: inout [[Double]]
        ) {
            let a = segs[i].a, b = segs[i].b
            let c = segs[j].a, d = segs[j].b
            let ux = b.x - a.x, uy = b.y - a.y
            let vx = d.x - c.x, vy = d.y - c.y
            let lu = hypot(ux, uy), lv = hypot(vx, vy)
            guard lu > 1e-12, lv > 1e-12 else { return }
            let denom = ux * vy - uy * vx
            let eps = RegionBoolean.splitEps
            if abs(denom) > 1e-12 * lu * lv {
                let wx = c.x - a.x, wy = c.y - a.y
                let t = (wx * vy - wy * vx) / denom
                let u = (wx * uy - wy * ux) / denom
                if t > eps, t < 1.0 - eps { splits[i].append(t) }
                if u > eps, u < 1.0 - eps { splits[j].append(u) }
            } else {
                // Parallel: split at overlapping collinear endpoints.
                let dist = abs((c.x - a.x) * uy - (c.y - a.y) * ux) / lu
                guard dist <= 1e-9 else { return }
                let iLen2 = lu * lu
                for p in [c, d] {
                    let t = ((p.x - a.x) * ux + (p.y - a.y) * uy) / iLen2
                    if t > eps, t < 1.0 - eps { splits[i].append(t) }
                }
                let jLen2 = lv * lv
                for p in [a, b] {
                    let u = ((p.x - c.x) * vx + (p.y - c.y) * vy) / jLen2
                    if u > eps, u < 1.0 - eps { splits[j].append(u) }
                }
            }
        }
    }
}

