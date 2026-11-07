import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADBoundaryDetector
//
// Detects the enclosed boundary polygon from a seed point by ray-casting to
// find the nearest edge, then wall-following (half-edge traversal) around the
// perimeter until the loop closes. Uses epsilon tolerance for vertex adjacency
// to handle real-world DXF files with micro-gaps and overshoot corners.
// =========================================================================

public enum CADBoundaryDetector {

    public struct BoundaryRegion: Sendable {
        public let outer: [Vector3]
        public let holes: [[Vector3]]

        public init(outer: [Vector3], holes: [[Vector3]] = []) {
            self.outer = outer
            self.holes = holes
        }
    }

    // MARK: - Edge representation

    private struct Edge: Hashable, Sendable {
        let a: Vector3
        let b: Vector3
        let entityHandle: UUID

        /// Edge midpoint (for adjacency sorting).
        var mid: Vector3 {
            Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: 0)
        }

        static func == (lhs: Edge, rhs: Edge) -> Bool {
            (lhs.a == rhs.a && lhs.b == rhs.b) || (lhs.a == rhs.b && lhs.b == rhs.a)
        }

        func hash(into hasher: inout Hasher) {
            // Order-independent hash.
            let h1 = a.hashValue
            let h2 = b.hashValue
            hasher.combine(h1 ^ h2)
        }

        /// Check if this edge shares a vertex with `other` within epsilon tolerance.
        func sharesVertex(with other: Edge, epsilonSq: Double) -> Bool {
            let aa = (a - other.a).magnitudeSquared
            let ab = (a - other.b).magnitudeSquared
            let ba = (b - other.a).magnitudeSquared
            let bb = (b - other.b).magnitudeSquared
            return aa < epsilonSq || ab < epsilonSq || ba < epsilonSq || bb < epsilonSq
        }

        /// The shared vertex between two edges (within epsilon), or nil.
        func sharedVertex(with other: Edge, epsilonSq: Double) -> Vector3? {
            if (a - other.a).magnitudeSquared < epsilonSq || (a - other.b).magnitudeSquared < epsilonSq { return a }
            if (b - other.a).magnitudeSquared < epsilonSq || (b - other.b).magnitudeSquared < epsilonSq { return b }
            return nil
        }

        /// The non-shared endpoint of this edge when shared vertex is `v`.
        func oppositeVertex(_ v: Vector3) -> Vector3 {
            (a - v).magnitudeSquared < (b - v).magnitudeSquared ? b : a
        }
    }

    // MARK: - Public API

    /// Find the enclosing polygon boundary from a seed point.
    ///
    /// Algorithm:
    /// 1. Cast a ray from the seed to find the nearest edge.
    /// 2. Wall-follow around the perimeter, using half-edge adjacency with epsilon tolerance.
    /// 3. Return the ordered polygon vertices when the loop closes.
    ///
    /// - Parameters:
    ///   - seedX, seedY: Seed point in world coordinates (click point).
    ///   - document: The CAD document to query.
    ///   - maxEdgeCount: Safety limit for non-manifold geometry (prevents infinite loops).
    ///   - timeoutMs: Maximum wall-following time in milliseconds.
    ///   - epsilonSq: Squared distance threshold for vertex adjacency (default: 1e-6).
    /// - Returns: Ordered world-space vertices of the enclosing polygon, or nil if none found.
    public static func findEnclosingPolygon(
        seedX: Double, seedY: Double,
        document: CADDocument,
        maxEdgeCount: Int = 500,
        timeoutMs: UInt64 = 200,
        epsilonSq: Double = 1e-6
    ) -> [Vector3]? {
        findEnclosingRegion(
            seedX: seedX, seedY: seedY,
            document: document,
            maxEdgeCount: maxEdgeCount,
            timeoutMs: timeoutMs,
            epsilonSq: epsilonSq
        )?.outer
    }

    /// Classifies an array of closed loops into boundary regions with nested holes according to the island detection style:
    /// - 0: Normal (alternating odd-parity nesting: even depths are hatched regions, odd depths are holes)
    /// - 1: Outer (outermost loop at depth 0 with depth 1 holes; inner islands omitted)
    /// - 2: Ignore (outermost loop at depth 0 with all islands ignored / 0 holes)
    public static func classifyLoops(
        _ loops: [[Vector3]],
        islandStyle: Int = 0
    ) -> [BoundaryRegion] {
        let cleaned = loops.compactMap { loop -> (points: [Vector3], area: Double)? in
            let c = cleanLoop(loop, epsilonSq: 1e-10)
            guard c.count >= 3 else { return nil }
            let a = shoelaceArea(polygon: c)
            guard a > 1e-9 else { return nil }
            return (c, a)
        }
        guard !cleaned.isEmpty else { return [] }

        var parent = Array<Int?>(repeating: nil, count: cleaned.count)
        for child in cleaned.indices {
            let probe = interiorSamplePoint(for: cleaned[child].points)
            var best: Int?
            var bestArea = Double.infinity
            for possibleParent in cleaned.indices where possibleParent != child {
                guard cleaned[possibleParent].area > cleaned[child].area + 1e-9 else { continue }
                let parentPoints = cleaned[possibleParent].points
                guard pointInPolygon(probe, polygon: parentPoints)
                    || cleaned[child].points.contains(where: { pointInPolygon($0, polygon: parentPoints) }) else { continue }
                if cleaned[possibleParent].area < bestArea {
                    best = possibleParent
                    bestArea = cleaned[possibleParent].area
                }
            }
            parent[child] = best
        }

        func depth(_ index: Int) -> Int {
            var count = 0
            var cursor = parent[index]
            var visited = Set<Int>()
            while let current = cursor, visited.insert(current).inserted {
                count += 1
                cursor = parent[current]
            }
            return count
        }

        let depths = cleaned.indices.map(depth)
        var children = Array(repeating: [Int](), count: cleaned.count)
        for index in cleaned.indices {
            if let p = parent[index] { children[p].append(index) }
        }

        if islandStyle == 2 {
            // Ignore: Only top-level outer boundaries (depth 0), with NO holes.
            return cleaned.indices
                .filter { depths[$0] == 0 }
                .sorted { cleaned[$0].area > cleaned[$1].area }
                .map { outerIndex in
                    BoundaryRegion(outer: cleaned[outerIndex].points, holes: [])
                }
        } else if islandStyle == 1 {
            // Outer: Only top-level outer boundaries (depth 0), with only immediate depth 1 holes.
            return cleaned.indices
                .filter { depths[$0] == 0 }
                .sorted { cleaned[$0].area > cleaned[$1].area }
                .map { outerIndex in
                    let holeIndices = children[outerIndex]
                        .filter { depths[$0] == 1 }
                        .sorted { cleaned[$0].area > cleaned[$1].area }
                    return BoundaryRegion(
                        outer: cleaned[outerIndex].points,
                        holes: holeIndices.map { cleaned[$0].points })
                }
        } else {
            // Normal (default): Alternating odd-parity island nesting
            return cleaned.indices
                .filter { depths[$0] % 2 == 0 }
                .sorted { cleaned[$0].area > cleaned[$1].area }
                .map { outerIndex in
                    let holeIndices = children[outerIndex]
                        .filter { depths[$0] == depths[outerIndex] + 1 }
                        .sorted { cleaned[$0].area > cleaned[$1].area }
                    return BoundaryRegion(
                        outer: cleaned[outerIndex].points,
                        holes: holeIndices.map { cleaned[$0].points })
                }
        }
    }

    public static func findEnclosingRegions(
        seedX: Double, seedY: Double,
        document: CADDocument,
        islandStyle: Int = 0,
        maxEdgeCount: Int = 500,
        timeoutMs: UInt64 = 200,
        epsilonSq: Double = 1e-6
    ) -> [BoundaryRegion]? {
        let seed = Vector3(x: seedX, y: seedY, z: 0)
        guard let outer = findOuterEnclosingPolygon(
            seed: seed,
            document: document,
            maxEdgeCount: maxEdgeCount,
            timeoutMs: timeoutMs,
            epsilonSq: epsilonSq
        ) else {
            return nil
        }

        if islandStyle == 2 {
            return [BoundaryRegion(outer: outer, holes: [])]
        }

        let holes = findHoleLoops(inside: outer, seed: seed, document: document, epsilonSq: epsilonSq)
        if holes.isEmpty {
            return [BoundaryRegion(outer: outer, holes: [])]
        }

        return classifyLoops([outer] + holes, islandStyle: islandStyle)
    }

    public static func findEnclosingRegion(
        seedX: Double, seedY: Double,
        document: CADDocument,
        islandStyle: Int = 0,
        maxEdgeCount: Int = 500,
        timeoutMs: UInt64 = 200,
        epsilonSq: Double = 1e-6
    ) -> BoundaryRegion? {
        findEnclosingRegions(
            seedX: seedX, seedY: seedY,
            document: document,
            islandStyle: islandStyle,
            maxEdgeCount: maxEdgeCount,
            timeoutMs: timeoutMs,
            epsilonSq: epsilonSq
        )?.first
    }

    private static func findOuterEnclosingPolygon(
        seed: Vector3,
        document: CADDocument,
        maxEdgeCount: Int,
        timeoutMs: UInt64,
        epsilonSq: Double
    ) -> [Vector3]? {
        let startTime = SDL_GetTicks()
        let tol = sqrt(epsilonSq)

        // ----- Phase 0: collect every visible world edge once -----
        // The legacy walker below only joins edges at shared endpoints, so a
        // line crossing the middle of a circle was invisible to it and the
        // hatch filled the whole circle. Node (split) all edges at every
        // interior crossing first so intersections become real graph vertices.
        var rawEdges: [Edge] = []
        for entity in document.entitiesView {
            guard let layer = document.layer(for: entity.layerID),
                  layer.isEffectivelyVisible else { continue }
            guard let geometry = document.resolvedGeometry(for: entity) else { continue }
            rawEdges.append(contentsOf: collectWorldEdges(
                from: geometry, transform: entity.transform, handle: entity.handle))
        }
        rawEdges = rawEdges.filter { ($0.b - $0.a).magnitudeSquared > 1e-18 }

        if !rawEdges.isEmpty, rawEdges.count <= 3000,
           let graph = nodeEdges(rawEdges, tol: tol, epsilonSq: epsilonSq,
                                 startTime: startTime, timeoutMs: timeoutMs),
           let face = seedFace(in: graph, seed: seed, maxEdgeCount: maxEdgeCount,
                               startTime: startTime, timeoutMs: timeoutMs)
        {
            return face
        }

        // Fallback: vertex-to-vertex wall-following without intersection noding.
        return legacyFindOuterEnclosingPolygon(
            seed: seed, document: document,
            maxEdgeCount: maxEdgeCount, timeoutMs: timeoutMs, epsilonSq: epsilonSq)
    }

    // MARK: - Noded boundary graph (crossing-aware face tracing)

    /// Split every edge at each interior intersection so crossings become
    /// shared vertices, then weld endpoints, drop duplicates and prune
    /// dangling spurs. Returns nil on timeout or when nothing traceable
    /// remains (the caller falls back to the legacy walker).
    private static func nodeEdges(
        _ edges: [Edge],
        tol: Double,
        epsilonSq: Double,
        startTime: UInt64,
        timeoutMs: UInt64
    ) -> (points: [Vector3], segments: [(Int, Int)])? {
        let n = edges.count
        var splits = Array(repeating: [Double](), count: n)
        func addParam(_ i: Int, _ t: Double) {
            if t > 1e-9 && t < 1.0 - 1e-9 { splits[i].append(t) }
        }
        var pairChecks = 0
        for i in 0..<n {
            let a1 = edges[i].a, a2 = edges[i].b
            let aMinX = min(a1.x, a2.x) - tol, aMaxX = max(a1.x, a2.x) + tol
            let aMinY = min(a1.y, a2.y) - tol, aMaxY = max(a1.y, a2.y) + tol
            let d1x = a2.x - a1.x, d1y = a2.y - a1.y
            for j in (i + 1)..<n {
                let b1 = edges[j].a, b2 = edges[j].b
                if aMinX > max(b1.x, b2.x) + tol || aMaxX < min(b1.x, b2.x) - tol { continue }
                if aMinY > max(b1.y, b2.y) + tol || aMaxY < min(b1.y, b2.y) - tol { continue }
                pairChecks += 1
                if pairChecks % 2048 == 0, SDL_GetTicks() - startTime > timeoutMs { return nil }
                let d2x = b2.x - b1.x, d2y = b2.y - b1.y
                let cross = d1x * d2y - d1y * d2x
                if abs(cross) > 1e-12 {
                    if let hit = CADGeometryMath.segmentSegmentIntersection(a: a1, b: a2, c: b1, d: b2) {
                        addParam(i, hit.t)
                        addParam(j, hit.u)
                    }
                    continue
                }
                // Parallel: only collinear overlaps matter.
                let denom1 = d1x * d1x + d1y * d1y
                let denom2 = d2x * d2x + d2y * d2y
                guard denom1 > 1e-18, denom2 > 1e-18 else { continue }
                let invLen1 = 1.0 / sqrt(denom1)
                let distB1 = abs((b1.x - a1.x) * d1y - (b1.y - a1.y) * d1x) * invLen1
                let distB2 = abs((b2.x - a1.x) * d1y - (b2.y - a1.y) * d1x) * invLen1
                guard distB1 <= tol, distB2 <= tol else { continue }
                let t0 = ((b1.x - a1.x) * d1x + (b1.y - a1.y) * d1y) / denom1
                let t1 = ((b2.x - a1.x) * d1x + (b2.y - a1.y) * d1y) / denom1
                let lo = max(0.0, min(t0, t1)), hi = min(1.0, max(t0, t1))
                if hi < lo { continue }
                addParam(i, lo)
                addParam(i, hi)
                let px1 = a1.x + d1x * lo, py1 = a1.y + d1y * lo
                let px2 = a1.x + d1x * hi, py2 = a1.y + d1y * hi
                addParam(j, ((px1 - b1.x) * d2x + (py1 - b1.y) * d2y) / denom2)
                addParam(j, ((px2 - b1.x) * d2x + (py2 - b1.y) * d2y) / denom2)
            }
        }

        // Split edges at the collected parameters.
        var subA = [Vector3]()
        var subB = [Vector3]()
        for i in 0..<n {
            let a1 = edges[i].a
            let dx = edges[i].b.x - a1.x, dy = edges[i].b.y - a1.y, dz = edges[i].b.z - a1.z
            if splits[i].isEmpty {
                subA.append(a1)
                subB.append(edges[i].b)
                continue
            }
            let sorted = splits[i].sorted()
            var uniq: [Double] = []
            for t in sorted {
                if let last = uniq.last, abs(t - last) <= 1e-9 { continue }
                uniq.append(t)
            }
            var prevT = 0.0
            for t in uniq + [1.0] {
                let p1 = Vector3(x: a1.x + dx * prevT, y: a1.y + dy * prevT, z: a1.z + dz * prevT)
                let p2 = Vector3(x: a1.x + dx * t, y: a1.y + dy * t, z: a1.z + dz * t)
                if (p2 - p1).magnitudeSquared > 1e-18 {
                    subA.append(p1)
                    subB.append(p2)
                }
                prevT = t
            }
        }

        // Weld endpoints within tolerance into shared nodes.
        let cell = max(tol, 1e-9)
        struct CellKey: Hashable { var ix: Int; var iy: Int }
        var cellMap = [CellKey: [Int]]()
        var points = [Vector3]()
        func nodeID(for p: Vector3) -> Int {
            let ix = Int(floor(p.x / cell)), iy = Int(floor(p.y / cell))
            for ddx in -1...1 {
                for ddy in -1...1 {
                    if let list = cellMap[CellKey(ix: ix + ddx, iy: iy + ddy)] {
                        for id in list {
                            let q = points[id]
                            let ex = q.x - p.x, ey = q.y - p.y
                            if ex * ex + ey * ey <= epsilonSq { return id }
                        }
                    }
                }
            }
            let id = points.count
            points.append(p)
            cellMap[CellKey(ix: ix, iy: iy), default: []].append(id)
            return id
        }
        var segPairs = [(Int, Int)]()
        for k in 0..<subA.count {
            let na = nodeID(for: subA[k]), nb = nodeID(for: subB[k])
            if na == nb { continue }
            segPairs.append((min(na, nb), max(na, nb)))
        }
        var seen = Set<UInt64>()
        var segs: [(Int, Int)] = []
        for s in segPairs {
            let key = (UInt64(s.0) << 32) | UInt64(s.1)
            if seen.insert(key).inserted { segs.append(s) }
        }
        if segs.isEmpty { return nil }

        // Prune dangling spurs (leaf nodes) so dead-end extensions cannot
        // trap the face walk. Closed loops are unaffected.
        var degree = Array(repeating: 0, count: points.count)
        for s in segs { degree[s.0] += 1; degree[s.1] += 1 }
        var nodeSegs = Array(repeating: [Int](), count: points.count)
        for (idx, s) in segs.enumerated() { nodeSegs[s.0].append(idx); nodeSegs[s.1].append(idx) }
        var active = Array(repeating: true, count: segs.count)
        var queue = [Int]()
        for v in 0..<points.count where degree[v] <= 1 { queue.append(v) }
        var head = 0
        while head < queue.count {
            if SDL_GetTicks() - startTime > timeoutMs { return nil }
            let v = queue[head]; head += 1
            if degree[v] != 1 { continue }
            var target = -1
            for si in nodeSegs[v] where active[si] { target = si; break }
            if target < 0 { continue }
            active[target] = false
            let s = segs[target]
            let other = s.0 == v ? s.1 : s.0
            degree[v] = 0
            degree[other] -= 1
            if degree[other] == 1 {
                queue.append(other)
            } else if degree[other] < 0 {
                degree[other] = 0
            }
        }
        var finalSegs: [(Int, Int)] = []
        for (idx, s) in segs.enumerated() where active[idx] { finalSegs.append(s) }
        if finalSegs.isEmpty { return nil }
        return (points, finalSegs)
    }

    /// Trace the smallest face containing `seed` in a noded graph. The start
    /// directed edge is picked from the nearest +X ray hit: the seed lies to
    /// the left of an upward-going hit edge (right of a downward one), so the
    /// keep-left walk from that directed edge is the seed's face.
    private static func seedFace(
        in graph: (points: [Vector3], segments: [(Int, Int)]),
        seed: Vector3,
        maxEdgeCount: Int,
        startTime: UInt64,
        timeoutMs: UInt64
    ) -> [Vector3]? {
        let points = graph.points
        var adjacency = Array(repeating: [(neighbor: Int, angle: Double)](), count: points.count)
        for s in graph.segments {
            let a = points[s.0], b = points[s.1]
            let ang = atan2(b.y - a.y, b.x - a.x)
            var rev = ang + Double.pi
            if rev > Double.pi { rev -= 2 * Double.pi }
            adjacency[s.0].append((s.1, ang))
            adjacency[s.1].append((s.0, rev))
        }
        for v in adjacency.indices { adjacency[v].sort { $0.angle < $1.angle } }

        func chooseNext(prev: Int, curr: Int) -> Int? {
            let outs = adjacency[curr]
            if outs.isEmpty { return nil }
            let rev = atan2(points[prev].y - points[curr].y, points[prev].x - points[curr].x)
            let twoPi = 2.0 * Double.pi
            var best: Int? = nil
            var bestCW = Double.infinity
            for o in outs {
                if o.neighbor == prev { continue }
                var cw = rev - o.angle
                cw = cw.truncatingRemainder(dividingBy: twoPi)
                if cw < 0 { cw += twoPi }
                if cw < bestCW { bestCW = cw; best = o.neighbor }
            }
            return best ?? prev
        }

        func traceDirected(startU: Int, startV: Int) -> [Vector3]? {
            var polyNodes = [startU]
            var prev = startU, curr = startV
            var visited = Set<UInt64>()
            while true {
                if SDL_GetTicks() - startTime > timeoutMs { return nil }
                let key = (UInt64(prev) << 32) | UInt64(curr)
                if !visited.insert(key).inserted { return nil }
                polyNodes.append(curr)
                if polyNodes.count > maxEdgeCount + 1 { return nil }
                guard let nxt = chooseNext(prev: prev, curr: curr) else { return nil }
                prev = curr
                curr = nxt
                if prev == startU && curr == startV { break }
            }
            let ids = Array(polyNodes.dropLast())
            if ids.count < 3 { return nil }
            return ids.map { points[$0] }
        }

        let rayDir = Vector3(x: 1, y: 0, z: 0)
        var hits: [(dist: Double, a: Int, b: Int)] = []
        for s in graph.segments {
            if SDL_GetTicks() - startTime > timeoutMs { return nil }
            let pa = points[s.0], pb = points[s.1]
            if let pt = CADGeometryMath.intersectRayLine(
                rayOrigin: seed, rayDir: rayDir, lineP1: pa, lineP2: pb)
            {
                let dist = seed.distance(to: pt)
                if dist > 1e-9 { hits.append((dist, s.0, s.1)) }
            }
        }
        hits.sort { $0.dist < $1.dist }
        var traced = 0
        for h in hits {
            if traced >= 8 { break }
            let pa = points[h.a], pb = points[h.b]
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            if dx * dx + dy * dy < 1e-18 { continue }
            // Grazing horizontal hits are owned by another edge at the crossing.
            if abs(dy) <= 1e-12 * max(1.0, sqrt(dx * dx + dy * dy)) { continue }
            traced += 1
            if SDL_GetTicks() - startTime > timeoutMs { return nil }
            let (u, v) = dy > 0 ? (h.a, h.b) : (h.b, h.a)
            if let poly = traceDirected(startU: u, startV: v),
               poly.count >= 3, pointInPolygon(seed, polygon: poly)
            {
                return poly
            }
        }
        return nil
    }

    private static func legacyFindOuterEnclosingPolygon(
        seed: Vector3,
        document: CADDocument,
        maxEdgeCount: Int,
        timeoutMs: UInt64,
        epsilonSq: Double
    ) -> [Vector3]? {
        let startTime = SDL_GetTicks()

        // ----- Phase 1: Ray-cast to find the first edge -----
        // Cast a ray in the +X direction to find the nearest intersecting edge.
        let rayDir = Vector3(x: 1, y: 0, z: 0)
        var nearestEdge: Edge? = nil
        var nearestDist = Double.infinity

        // Get candidate entities along the ray from the seed to a reasonable distance.
        let candidates = document.entityHandlesAlongRay(
            rayOrigin: seed, rayDir: rayDir, maxDistance: 100_000)
        let entityHandles = candidates ?? Array(document.entitiesView.map { $0.handle })

        for handle in entityHandles {
            guard let entity = document.entity(for: handle) else { continue }
            guard let layer = document.layer(for: entity.layerID), layer.isEffectivelyVisible else { continue }
            guard let geometry = document.resolvedGeometry(for: entity) else { continue }

            let worldEdges = collectWorldEdges(from: geometry, transform: entity.transform, handle: handle)
            for edge in worldEdges {
                if let pt = CADGeometryMath.intersectRayLine(
                    rayOrigin: seed, rayDir: rayDir, lineP1: edge.a, lineP2: edge.b)
                {
                    let dist = seed.distance(to: pt)
                    if dist < nearestDist && dist > 1e-9 {  // skip exact coincidences
                        nearestDist = dist
                        nearestEdge = edge
                    }
                }
            }
        }

        guard let firstEdge = nearestEdge else { return nil }

        // ----- Phase 2: Wall-following -----
        // Start from the first edge, walk the perimeter by finding the next connected edge
        // at each vertex that has the most extreme rightward turn.

        var perimeter: [Vector3] = []
        // Start with the endpoint of the first edge that is farther from the seed.
        let d1 = seed.distance(to: firstEdge.a)
        let d2 = seed.distance(to: firstEdge.b)
        var currentVertex = d1 > d2 ? firstEdge.a : firstEdge.b
        var prevVertex = d1 > d2 ? firstEdge.b : firstEdge.a
        perimeter.append(prevVertex)
        perimeter.append(currentVertex)

        let startVertex = prevVertex
        var edgeCount = 0

        while edgeCount < maxEdgeCount {
            // Timeout guard.
            if SDL_GetTicks() - startTime > timeoutMs {
                return nil
            }

            // Find all edges that connect to the current vertex (within epsilon).
            let direction = Vector3(x: currentVertex.x - prevVertex.x,
                                    y: currentVertex.y - prevVertex.y, z: 0)
            var bestTurn: Double = -Double.infinity
            var bestNextVertex: Vector3? = nil

            // Search near the current vertex.
            let searchRadius: Double = 10.0
            let nearbyCandidates = document.entityHandlesInWorldRect(
                minX: currentVertex.x - searchRadius,
                minY: currentVertex.y - searchRadius,
                maxX: currentVertex.x + searchRadius,
                maxY: currentVertex.y + searchRadius)
            let nearbyHandles = nearbyCandidates ?? Array(document.entitiesView.map { $0.handle })

            for handle in nearbyHandles {
                guard let entity = document.entity(for: handle) else { continue }
                guard let layer = document.layer(for: entity.layerID), layer.isEffectivelyVisible else { continue }
                guard let geometry = document.resolvedGeometry(for: entity) else { continue }

                let worldEdges = collectWorldEdges(from: geometry, transform: entity.transform, handle: handle)
                for edge in worldEdges {
                    // Check if this edge shares the current vertex.
                    guard let shared = edge.sharedVertex(with: Edge(a: currentVertex, b: currentVertex,
                                                                    entityHandle: UUID()),
                                                         epsilonSq: epsilonSq) else { continue }
                    let nextV = edge.oppositeVertex(shared)

                    // Don't go back the way we came.
                    if nextV.distance(to: prevVertex) < sqrt(epsilonSq) { continue }

                    // Compute the turn angle from the incoming direction.
                    let nextDir = Vector3(x: nextV.x - currentVertex.x,
                                          y: nextV.y - currentVertex.y, z: 0)
                    let cross = direction.x * nextDir.y - direction.y * nextDir.x
                    let dot = direction.x * nextDir.x + direction.y * nextDir.y
                    let angle = atan2(cross, dot)  // + for left turn, - for right turn

                    // For clockwise wall-following, prefer the most rightward turn (most negative angle).
                    // For counter-clockwise, prefer the most leftward.
                    // We'll use the most-negative-angle heuristic (rightmost turn).
                    if angle > bestTurn {
                        bestTurn = angle
                        bestNextVertex = nextV
                    }
                }
            }

            guard let nextVertex = bestNextVertex else { break }

            // Check if we've closed the loop.
            if nextVertex.distance(to: startVertex) < sqrt(epsilonSq) {
                // Close the polygon — remove the duplicate start vertex.
                if perimeter.count >= 3 {
                    return perimeter
                }
                break
            }

            // Check for self-intersection / revisit.
            if perimeter.count >= 3 {
                for i in 0..<(perimeter.count - 2) {
                    if nextVertex.distance(to: perimeter[i]) < sqrt(epsilonSq) {
                        // Loop closed earlier than expected.
                        return Array(perimeter[i...])
                    }
                }
            }

            perimeter.append(nextVertex)
            prevVertex = currentVertex
            currentVertex = nextVertex
            edgeCount += 1
        }

        // Return only if we have a valid polygon.
        return perimeter.count >= 3 ? perimeter : nil
    }

    // MARK: - Shoelace formula

    /// Compute the area of a polygon using the Shoelace formula.
    /// The polygon vertices must be ordered (CW or CCW), not self-intersecting.
    /// - Returns: Absolute area (always positive).
    public static func shoelaceArea(polygon: [Vector3]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum: Double = 0
        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            sum += polygon[i].x * polygon[j].y - polygon[j].x * polygon[i].y
        }
        return abs(sum) * 0.5
    }

    // MARK: - Helpers

    public static func findHoleLoops(
        inside outer: [Vector3],
        seed: Vector3,
        document: CADDocument,
        epsilonSq: Double
    ) -> [[Vector3]] {
        guard outer.count >= 3 else { return [] }

        let bbox = boundingBox(for: outer)
        let candidates = document.entityHandlesInWorldRect(
            minX: bbox.minX,
            minY: bbox.minY,
            maxX: bbox.maxX,
            maxY: bbox.maxY
        ) ?? Array(document.entitiesView.map { $0.handle })

        var holes: [[Vector3]] = []
        for handle in candidates {
            guard let entity = document.entity(for: handle) else { continue }
            guard let layer = document.layer(for: entity.layerID), layer.isEffectivelyVisible else { continue }
            guard let geometry = document.resolvedGeometry(for: entity) else { continue }

            for loop in collectClosedWorldLoops(from: geometry, transform: entity.transform) {
                let clean = cleanLoop(loop, epsilonSq: epsilonSq)
                guard clean.count >= 3 else { continue }

                let area = shoelaceArea(polygon: clean)
                guard area > 1e-9 else { continue }

                let sample = interiorSamplePoint(for: clean)
                guard pointInPolygon(sample, polygon: outer) else { continue }
                guard !pointInPolygon(seed, polygon: clean) else { continue }
                guard !holes.contains(where: { loopsNearlyEqual($0, clean, epsilonSq: epsilonSq) }) else { continue }

                holes.append(clean)
            }
        }

        holes.sort { shoelaceArea(polygon: $0) > shoelaceArea(polygon: $1) }
        return holes
    }

    private static func collectClosedWorldLoops(
        from geometry: [CADPrimitive], transform: Transform3D
    ) -> [[Vector3]] {
        var loops: [[Vector3]] = []

        func transformed(_ pts: [Vector3]) -> [Vector3] {
            pts.map { transform.transformPoint($0) }
        }

        func appendLoop(_ pts: [Vector3]) {
            let clean = cleanLoop(pts, epsilonSq: 1e-12)
            if clean.count >= 3 { loops.append(clean) }
        }

        func ellipseLoop(center: Vector3, majorAxis: Vector3, minorRatio: Double) -> [Vector3] {
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            guard majorLen > 1e-12, minorLen > 1e-12 else { return [] }
            let rot = atan2(majorAxis.y, majorAxis.x)
            let c = cos(rot)
            let s = sin(rot)
            return (0..<64).map { i in
                let t = Double(i) * 2.0 * .pi / 64.0
                let px = cos(t) * majorLen
                let py = sin(t) * minorLen
                return Vector3(
                    x: center.x + px * c - py * s,
                    y: center.y + px * s + py * c,
                    z: center.z
                )
            }
        }

        for prim in geometry {
            switch prim {
            case .rect(let origin, let size, _),
                 .fillRect(let origin, let size, _):
                appendLoop(transformed([
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                ]))

            case .polygon(let pts, _),
                 .fillPolygon(let pts, _):
                appendLoop(transformed(pts))

            case .fillComplexPolygon(let outer, let holes, _):
                appendLoop(transformed(outer))
                for hole in holes { appendLoop(transformed(hole)) }

            case .gradient(let outer, let holes, _, _, _, _):
                appendLoop(transformed(outer))
                for hole in holes { appendLoop(transformed(hole)) }

            case .circle(let center, let radius, _):
                guard radius > 1e-12 else { break }
                let pts = (0..<64).map { i -> Vector3 in
                    let t = Double(i) * 2.0 * .pi / 64.0
                    return Vector3(
                        x: center.x + cos(t) * radius,
                        y: center.y + sin(t) * radius,
                        z: center.z
                    )
                }
                appendLoop(transformed(pts))

            case .ellipse(let center, let majorAxis, let minorRatio, _):
                appendLoop(transformed(ellipseLoop(center: center, majorAxis: majorAxis, minorRatio: minorRatio)))

            case .polyline(let path, _):
                let pts = path.tessellatedPoints()
                if path.isClosed || endpointsCoincident(pts, epsilonSq: 1e-8) {
                    appendLoop(transformed(pts))
                }

            case .spline(let controlPoints, let knots, let degree, let weights, _):
                guard controlPoints.count >= 2 else { break }
                let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
                let pts = NURBSEvaluator.evaluateByKnotSpans(
                    degree: degree,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: w,
                    segmentsPerSpan: 12
                )
                if endpointsCoincident(pts, epsilonSq: 1e-8) {
                    appendLoop(transformed(pts))
                }

            case .penStroke(let vertices, _, _):
                guard vertices.count >= 2 else { break }
                let pts = vertices.map { $0.position }
                if endpointsCoincident(pts, epsilonSq: 1e-8) {
                    appendLoop(transformed(pts))
                }

            default:
                break
            }
        }

        return loops
    }

    private static func cleanLoop(_ loop: [Vector3], epsilonSq: Double) -> [Vector3] {
        var out: [Vector3] = []
        out.reserveCapacity(loop.count)

        for p in loop {
            if let last = out.last, (p - last).magnitudeSquared <= epsilonSq { continue }
            out.append(Vector3(x: p.x, y: p.y, z: 0))
        }

        if out.count > 1,
           let first = out.first,
           let last = out.last,
           (first - last).magnitudeSquared <= epsilonSq {
            out.removeLast()
        }

        return out
    }

    private static func endpointsCoincident(_ pts: [Vector3], epsilonSq: Double) -> Bool {
        guard let first = pts.first, let last = pts.last else { return false }
        return (first - last).magnitudeSquared <= epsilonSq
    }

    private static func boundingBox(for pts: [Vector3]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for p in pts {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }

        return (minX, minY, maxX, maxY)
    }

    private static func interiorSamplePoint(for loop: [Vector3]) -> Vector3 {
        var sx = 0.0
        var sy = 0.0
        for p in loop {
            sx += p.x
            sy += p.y
        }
        return Vector3(x: sx / Double(loop.count), y: sy / Double(loop.count), z: 0)
    }

    private static func pointInPolygon(_ point: Vector3, polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.y > point.y) != (pj.y > point.y)) {
                let denom = pj.y - pi.y
                if abs(denom) > 1e-12 {
                    let x = (pj.x - pi.x) * (point.y - pi.y) / denom + pi.x
                    if point.x < x { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }

    private static func loopsNearlyEqual(_ a: [Vector3], _ b: [Vector3], epsilonSq: Double) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let areaA = shoelaceArea(polygon: a)
        let areaB = shoelaceArea(polygon: b)
        guard abs(areaA - areaB) <= max(1e-7, max(areaA, areaB) * 1e-5) else { return false }

        let boxA = boundingBox(for: a)
        let boxB = boundingBox(for: b)
        let tol = max(sqrt(epsilonSq) * 10.0, 1e-5)
        return abs(boxA.minX - boxB.minX) <= tol
            && abs(boxA.minY - boxB.minY) <= tol
            && abs(boxA.maxX - boxB.maxX) <= tol
            && abs(boxA.maxY - boxB.maxY) <= tol
    }

    /// Collect all world-space line segments from primitive geometry.
    private static func collectWorldEdges(
        from geometry: [CADPrimitive], transform: Transform3D, handle: UUID
    ) -> [Edge] {
        var edges: [Edge] = []
        for prim in geometry {
            switch prim {
            case .line(let start, let end, _):
                let ws = transform.transformPoint(start)
                let we = transform.transformPoint(end)
                edges.append(Edge(a: ws, b: we, entityHandle: handle))

            case .rect(let origin, let size, _):
                let pts: [Vector3] = [
                    transform.transformPoint(origin),
                    transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: 0)),
                    transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: 0)),
                    transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: 0)),
                ]
                for i in 0..<4 {
                    let j = (i + 1) % 4
                    edges.append(Edge(a: pts[i], b: pts[j], entityHandle: handle))
                }

            case .polygon(let pts, _):
                let wpts = pts.map { transform.transformPoint($0) }
                for i in 0..<wpts.count {
                    let j = (i + 1) % wpts.count
                    edges.append(Edge(a: wpts[i], b: wpts[j], entityHandle: handle))
                }

            case .polyline(let path, _):
                let wpts = path.tessellatedPoints().map { transform.transformPoint($0) }
                for i in 0..<(wpts.count - 1) {
                    edges.append(Edge(a: wpts[i], b: wpts[i + 1], entityHandle: handle))
                }

            case .fillPolygon(let pts, _),
                 .fillComplexPolygon(let pts, _, _):
                let wpts = pts.map { transform.transformPoint($0) }
                for i in 0..<(wpts.count >= 2 ? wpts.count - 1 : 0) {
                    edges.append(Edge(a: wpts[i], b: wpts[i + 1], entityHandle: handle))
                }
                if wpts.count >= 3 {
                    edges.append(Edge(a: wpts[wpts.count - 1], b: wpts[0], entityHandle: handle))
                }

            case .circle(_, _, _), .arc(_, _, _, _, _):
                // For circles and arcs, tessellate into line segments for boundary detection.
                let tPrims = CADGeometryMath.transformPrimitives([prim], by: transform)
                for tp in tPrims {
                    if case .line(let s, let e, _) = tp {
                        edges.append(Edge(a: s, b: e, entityHandle: handle))
                    }
                    if case .polygon(let pts, _) = tp {
                        for i in 0..<pts.count {
                            let j = (i + 1) % pts.count
                            edges.append(Edge(a: pts[i], b: pts[j], entityHandle: handle))
                        }
                    }
                    if case .polyline(let path, _) = tp {
                        let pts = path.tessellatedPoints()
                        for i in 0..<(pts.count - 1) {
                            edges.append(Edge(a: pts[i], b: pts[i + 1], entityHandle: handle))
                        }
                    }
                }

            case .ellipse(let center, let majorAxis, let minorRatio, _):
                let majorLen = majorAxis.magnitude
                let minorLen = majorLen * minorRatio
                guard majorLen > 1e-12, minorLen > 1e-12 else { break }

                let rotation = atan2(majorAxis.y, majorAxis.x)
                let cosRotation = cos(rotation)
                let sinRotation = sin(rotation)
                let segmentCount = 64

                let points = (0..<segmentCount).map { index -> Vector3 in
                    let angle = Double(index) * 2.0 * .pi / Double(segmentCount)
                    let localX = cos(angle) * majorLen
                    let localY = sin(angle) * minorLen
                    return transform.transformPoint(Vector3(
                        x: center.x + localX * cosRotation - localY * sinRotation,
                        y: center.y + localX * sinRotation + localY * cosRotation,
                        z: center.z
                    ))
                }

                for index in 0..<points.count {
                    edges.append(Edge(
                        a: points[index],
                        b: points[(index + 1) % points.count],
                        entityHandle: handle
                    ))
                }

            case .spline(let controlPoints, let knots, let degree, let weights, _):
                let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
                // 12 segments per knot span matches the render path density — keeps edge count
                // manageable so the wall-follower stays under maxEdgeCount even for complex splines.
                let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                    degree: degree, knots: knots,
                    controlPoints: controlPoints, weights: w, segmentsPerSpan: 12)
                guard evaluated.count >= 2 else { break }
                let wpts = evaluated.map { transform.transformPoint($0) }
                for i in 0..<(wpts.count - 1) {
                    edges.append(Edge(a: wpts[i], b: wpts[i + 1], entityHandle: handle))
                }
                // Only append closing edge if endpoints are not already coincident.
                // Closed splines produce coincident start/end points via evaluateByKnotSpans;
                // a zero-length edge would break the wall-follower's atan2 angle heuristic.
                if let first = wpts.first, let last = wpts.last, first.distance(to: last) > 1e-6 {
                    edges.append(Edge(a: last, b: first, entityHandle: handle))
                }

            case .penStroke(let vertices, _, _):
                guard vertices.count >= 2 else { break }
                let wpts = vertices.map { transform.transformPoint($0.position) }
                for i in 0..<(wpts.count - 1) {
                    edges.append(Edge(a: wpts[i], b: wpts[i + 1], entityHandle: handle))
                }
                if let first = wpts.first, let last = wpts.last, first.distance(to: last) > 1e-6 {
                    edges.append(Edge(a: last, b: first, entityHandle: handle))
                }

            default:
                break
            }
        }
        return edges
    }
}
