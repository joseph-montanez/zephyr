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
        let seed = Vector3(x: seedX, y: seedY, z: 0)
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
            guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
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
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
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

            case .ellipse(_, _, _, _):
                break  // Ellipses are approximated later if needed.

            default:
                break
            }
        }
        return edges
    }
}
