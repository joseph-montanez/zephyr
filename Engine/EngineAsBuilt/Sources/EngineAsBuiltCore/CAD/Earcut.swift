#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import ucrt
#endif

/// A faithful Swift port of the Mapbox Earcut polygon triangulation algorithm
/// (https://github.com/mapbox/earcut), including hole elimination via the
/// two-sided bridge (`splitPolygon`), the z-order curve acceleration for large
/// rings, and the standard `filterPoints → cureLocalIntersections → splitEarcut`
/// fallback chain for degenerate / self-intersecting input.
///
/// Coordinates are interleaved `Float`s: `[x0, y0, x1, y1, ...]`. `holeIndices`
/// gives the *vertex* index (not the flat-array index) at which each hole ring
/// begins. The returned array is a flat list of triangle *vertex* indices
/// (three per triangle), suitable for `flatData[index * dim]` lookups.
///
/// IMPORTANT — ring winding is normalised internally. The outer ring is forced
/// clockwise and holes are forced counter-clockwise (as `signedArea` measures
/// it), so the caller may pass rings in *either* orientation. Getting these two
/// orientations backwards is what silently drops holes, so the convention is
/// pinned here rather than left to the caller.
public enum Earcut {

    // MARK: - Public API

    public static func triangulate(_ data: [Float], holeIndices: [Int] = [], dimensions: Int = 2)
        -> [Int]
    {
        let dim = Swift.max(2, dimensions)
        var triangles: [Int] = []

        let hasHoles = !holeIndices.isEmpty
        let outerLen = hasHoles ? holeIndices[0] * dim : data.count

        guard
            var outerNode = linkedList(
                data: data, start: 0, end: outerLen, dim: dim, clockwise: true)
        else {
            return triangles
        }
        // A ring of fewer than three distinct vertices has no area.
        if outerNode.next === outerNode.prev {
            return triangles
        }

        var minX: Float = 0
        var minY: Float = 0
        var invSize: Float = 0

        if hasHoles {
            outerNode = eliminateHoles(
                data: data, holeIndices: holeIndices, outerNode: outerNode, dim: dim)
        }

        // For non-trivial rings, build a bounding box and a z-order hash so ear
        // testing becomes roughly O(n·log n) instead of O(n²).
        if data.count > 80 * dim {
            minX = data[0]
            minY = data[1]
            var maxX = data[0]
            var maxY = data[1]

            var i = dim
            while i < outerLen {
                let x = data[i]
                let y = data[i + 1]
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
                i += dim
            }

            // invSize maps the longest bbox side onto the 15-bit hash range.
            let size = Swift.max(maxX - minX, maxY - minY)
            invSize = size != 0 ? 32767.0 / size : 0
        }

        earcutLinked(
            ear: outerNode, triangles: &triangles, dim: dim, minX: minX, minY: minY,
            invSize: invSize, pass: 0)

        return triangles
    }

    // MARK: - Linked-list construction

    /// Build a circular doubly-linked list from a slice of the coordinate array,
    /// normalising it to the requested winding.
    private static func linkedList(data: [Float], start: Int, end: Int, dim: Int, clockwise: Bool)
        -> LinkedNode?
    {
        var last: LinkedNode? = nil

        if clockwise == (signedArea(data: data, start: start, end: end, dim: dim) > 0) {
            var i = start
            while i < end {
                last = insertNode(index: i / dim, x: data[i], y: data[i + 1], last: last)
                i += dim
            }
        } else {
            var i = end - dim
            while i >= start {
                last = insertNode(index: i / dim, x: data[i], y: data[i + 1], last: last)
                i -= dim
            }
        }

        if let lastNode = last, equals(lastNode, lastNode.next!) {
            removeNode(lastNode)
            last = lastNode.next
        }

        return last
    }

    /// Drop collinear or duplicate vertices between `start` and `end` (inclusive
    /// ring walk). Returns a still-valid node on the (possibly shortened) ring.
    @discardableResult
    private static func filterPoints(_ start: LinkedNode?, _ inEnd: LinkedNode? = nil)
        -> LinkedNode?
    {
        guard let start = start else { return start }
        var end = inEnd ?? start

        var p = start
        var again = false
        repeat {
            again = false
            if !p.steiner && (equals(p, p.next!) || signedTriangleArea(p.prev!, p, p.next!) == 0) {
                removeNode(p)
                p = p.prev!
                end = p
                if p === p.next! { break }
                again = true
            } else {
                p = p.next!
            }
        } while again || p !== end

        return end
    }

    // MARK: - Main ear-slicing loop

    private static func earcutLinked(
        ear inEar: LinkedNode?, triangles: inout [Int], dim: Int, minX: Float, minY: Float,
        invSize: Float, pass: Int
    ) {
        guard var ear = inEar else { return }

        // Index the ring with a z-order curve on the first pass.
        if pass == 0 && invSize != 0 {
            indexCurve(ear, minX: minX, minY: minY, invSize: invSize)
        }

        var stop = ear

        // Iterate, slicing ears off, until the remaining ring is a triangle.
        while ear.prev !== ear.next {
            let prev = ear.prev!
            let next = ear.next!

            let isAnEar =
                invSize != 0
                ? isEarHashed(ear, minX: minX, minY: minY, invSize: invSize)
                : isEar(ear)

            if isAnEar {
                triangles.append(prev.index)
                triangles.append(ear.index)
                triangles.append(next.index)

                removeNode(ear)

                // Skipping one vertex ahead leads to a better-shaped result.
                ear = next.next!
                stop = next.next!
                continue
            }

            ear = next

            // We looped all the way around without finding an ear — the ring is
            // either degenerate or self-intersecting. Escalate through fallbacks.
            if ear === stop {
                if pass == 0 {
                    earcutLinked(
                        ear: filterPoints(ear), triangles: &triangles, dim: dim, minX: minX,
                        minY: minY, invSize: invSize, pass: 1)
                } else if pass == 1 {
                    let cured = cureLocalIntersections(filterPoints(ear), triangles: &triangles)
                    earcutLinked(
                        ear: cured, triangles: &triangles, dim: dim, minX: minX, minY: minY,
                        invSize: invSize, pass: 2)
                } else if pass == 2 {
                    splitEarcut(
                        ear, triangles: &triangles, dim: dim, minX: minX, minY: minY,
                        invSize: invSize)
                }
                break
            }
        }
    }

    /// Linear ear test (used when the ring is small enough to skip hashing).
    private static func isEar(_ ear: LinkedNode) -> Bool {
        let a = ear.prev!
        let b = ear
        let c = ear.next!

        if signedTriangleArea(a, b, c) >= 0 { return false }  // reflex corner

        let x0 = Swift.min(a.x, b.x, c.x)
        let y0 = Swift.min(a.y, b.y, c.y)
        let x1 = Swift.max(a.x, b.x, c.x)
        let y1 = Swift.max(a.y, b.y, c.y)

        var p = c.next!
        while p !== a {
            if p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1
                && pointInTriangle(
                    ax: a.x, ay: a.y, bx: b.x, by: b.y, cx: c.x, cy: c.y, px: p.x, py: p.y)
                && signedTriangleArea(p.prev!, p, p.next!) >= 0
            {
                return false
            }
            p = p.next!
        }
        return true
    }

    /// Ear test accelerated by the z-order curve: only points whose z-code lies
    /// within the ear's bounding box need to be checked.
    private static func isEarHashed(_ ear: LinkedNode, minX: Float, minY: Float, invSize: Float)
        -> Bool
    {
        let a = ear.prev!
        let b = ear
        let c = ear.next!

        if signedTriangleArea(a, b, c) >= 0 { return false }

        let x0 = Swift.min(a.x, b.x, c.x)
        let y0 = Swift.min(a.y, b.y, c.y)
        let x1 = Swift.max(a.x, b.x, c.x)
        let y1 = Swift.max(a.y, b.y, c.y)

        let minZ = zOrder(x: x0, y: y0, minX: minX, minY: minY, invSize: invSize)
        let maxZ = zOrder(x: x1, y: y1, minX: minX, minY: minY, invSize: invSize)

        var p = ear.prevZ
        var n = ear.nextZ

        // Walk outward in both directions while inside the z-range.
        while let pp = p, pp.z >= minZ, let nn = n, nn.z <= maxZ {
            if pp.x >= x0 && pp.x <= x1 && pp.y >= y0 && pp.y <= y1 && pp !== a && pp !== c
                && pointInTriangle(
                    ax: a.x, ay: a.y, bx: b.x, by: b.y, cx: c.x, cy: c.y, px: pp.x, py: pp.y)
                && signedTriangleArea(pp.prev!, pp, pp.next!) >= 0
            {
                return false
            }
            p = pp.prevZ

            if nn.x >= x0 && nn.x <= x1 && nn.y >= y0 && nn.y <= y1 && nn !== a && nn !== c
                && pointInTriangle(
                    ax: a.x, ay: a.y, bx: b.x, by: b.y, cx: c.x, cy: c.y, px: nn.x, py: nn.y)
                && signedTriangleArea(nn.prev!, nn, nn.next!) >= 0
            {
                return false
            }
            n = nn.nextZ
        }

        while let pp = p, pp.z >= minZ {
            if pp.x >= x0 && pp.x <= x1 && pp.y >= y0 && pp.y <= y1 && pp !== a && pp !== c
                && pointInTriangle(
                    ax: a.x, ay: a.y, bx: b.x, by: b.y, cx: c.x, cy: c.y, px: pp.x, py: pp.y)
                && signedTriangleArea(pp.prev!, pp, pp.next!) >= 0
            {
                return false
            }
            p = pp.prevZ
        }

        while let nn = n, nn.z <= maxZ {
            if nn.x >= x0 && nn.x <= x1 && nn.y >= y0 && nn.y <= y1 && nn !== a && nn !== c
                && pointInTriangle(
                    ax: a.x, ay: a.y, bx: b.x, by: b.y, cx: c.x, cy: c.y, px: nn.x, py: nn.y)
                && signedTriangleArea(nn.prev!, nn, nn.next!) >= 0
            {
                return false
            }
            n = nn.nextZ
        }

        return true
    }

    /// Remove self-intersections by clipping ears that span an intersecting pair.
    private static func cureLocalIntersections(_ inStart: LinkedNode?, triangles: inout [Int])
        -> LinkedNode?
    {
        guard var start = inStart else { return inStart }
        var p = start

        repeat {
            let a = p.prev!
            let b = p.next!.next!

            if !equals(a, b) && intersects(a, p, p.next!, b) && locallyInside(a, b)
                && locallyInside(b, a)
            {
                triangles.append(a.index)
                triangles.append(p.index)
                triangles.append(b.index)

                removeNode(p)
                removeNode(p.next!)

                p = b
                start = b
            }
            p = p.next!
        } while p !== start

        return filterPoints(p)
    }

    /// Split a stuck polygon into two along a valid diagonal, then recurse.
    private static func splitEarcut(
        _ start: LinkedNode, triangles: inout [Int], dim: Int, minX: Float, minY: Float,
        invSize: Float
    ) {
        var a = start
        repeat {
            var b = a.next!.next!
            while b !== a.prev! {
                if a.index != b.index && isValidDiagonal(a, b) {
                    var c: LinkedNode? = splitPolygon(a, b)

                    let fa = filterPoints(a, a.next)
                    c = filterPoints(c, c?.next)

                    earcutLinked(
                        ear: fa, triangles: &triangles, dim: dim, minX: minX, minY: minY,
                        invSize: invSize, pass: 0)
                    earcutLinked(
                        ear: c, triangles: &triangles, dim: dim, minX: minX, minY: minY,
                        invSize: invSize, pass: 0)
                    return
                }
                b = b.next!
            }
            a = a.next!
        } while a !== start
    }

    // MARK: - Hole elimination

    private static func eliminateHoles(
        data: [Float], holeIndices: [Int], outerNode: LinkedNode, dim: Int
    ) -> LinkedNode {
        var queue: [LinkedNode] = []
        var currentOuter = outerNode

        for i in 0..<holeIndices.count {
            let start = holeIndices[i] * dim
            let end = i < holeIndices.count - 1 ? holeIndices[i + 1] * dim : data.count

            if let list = linkedList(data: data, start: start, end: end, dim: dim, clockwise: false)
            {
                if list === list.next! { list.steiner = true }
                queue.append(getLeftmost(list))
            }
        }

        // Process holes left-to-right so their bridges never cross.
        queue.sort { $0.x < $1.x }

        for holeNode in queue {
            currentOuter = eliminateHole(holeNode, currentOuter)
        }

        return currentOuter
    }

    /// Bridge a single hole into the outer ring, then clean up both seams.
    private static func eliminateHole(_ hole: LinkedNode, _ outerNode: LinkedNode) -> LinkedNode {
        guard let bridge = findHoleBridge(hole, outerNode) else {
            return outerNode
        }

        let bridgeReverse = splitPolygon(bridge, hole)

        filterPoints(bridgeReverse, bridgeReverse.next)
        return filterPoints(bridge, bridge.next) ?? outerNode
    }

    private static func findHoleBridge(_ hole: LinkedNode, _ outerNode: LinkedNode) -> LinkedNode? {
        var outerCount = 0
        var temp = outerNode
        repeat {
            outerCount += 1
            temp = temp.next!
        } while temp !== outerNode

        var holeCount = 0
        var tempH = hole
        repeat {
            holeCount += 1
            tempH = tempH.next!
        } while tempH !== hole

        let logDiagnostics = (outerCount == 76 && holeCount == 51)
        if logDiagnostics {
            print("--- findHoleBridge for Circle2 (76) and R-outer (51) ---")
            print("  Hole leftmost point: (\(hole.x), \(hole.y))")
        }

        var p = outerNode
        let hx = hole.x
        let hy = hole.y
        var qx: Float = -Float.infinity
        var m: LinkedNode? = nil

        // 1. Cast a ray to the left of the hole and find the outer edge it hits.
        var stepsChecked = 0
        repeat {
            let next = p.next!
            stepsChecked += 1
            if hy <= p.y && hy >= next.y && next.y != p.y {
                let x = p.x + (hy - p.y) * (next.x - p.x) / (next.y - p.y)
                if logDiagnostics {
                    print(
                        "    Edge \(p.index)->\(next.index): p=(\(p.x), \(p.y)) next=(\(next.x), \(next.y)) intersects at x=\(x)"
                    )
                }
                if x <= hx + 1e-2 && x > qx {
                    qx = x
                    m = p.x < next.x ? p : next
                    if logDiagnostics {
                        print(
                            "      Updating candidate: x=\(x) <= hx+0.01, candidate node index=\(m!.index) at (\(m!.x), \(m!.y))"
                        )
                    }
                    if x == hx {
                        if logDiagnostics { print("      Direct touch, returning \(m!.index)") }
                        return m
                    }
                }
            }
            p = p.next!
        } while p !== outerNode

        if logDiagnostics {
            print(
                "  Raycast ended: stepsChecked=\(stepsChecked), candidate m=\(m?.index ?? -1), qx=\(qx)"
            )
        }

        guard var bestNode = m else {
            if logDiagnostics { print("  Returning nil (no candidate found)") }
            return nil
        }

        // 2. The ray hit point (qx, hy) may not be a vertex. If any other ring
        //    vertex lies inside the triangle (hole, hit point, candidate), it is
        //    a better — and visible — connection. Pick the one at the minimum
        //    angle to the ray.
        let stop = bestNode
        let mx = bestNode.x
        let my = bestNode.y
        var tanMin: Float = Float.infinity

        p = bestNode
        var checkedInside = 0
        repeat {
            if hx >= p.x && p.x >= mx && hx != p.x
                && pointInTriangle(
                    ax: hy < my ? hx : qx, ay: hy,
                    bx: mx, by: my,
                    cx: hy < my ? qx : hx, cy: hy,
                    px: p.x, py: p.y)
            {
                checkedInside += 1
                let tan = abs(hy - p.y) / (hx - p.x)  // tangent of the connection angle

                if logDiagnostics {
                    print(
                        "    Inside node candidate: index=\(p.index) (\(p.x), \(p.y)), tan=\(tan), locallyInside=\(locallyInside(p, hole))"
                    )
                }

                if locallyInside(p, hole)
                    && (tan < tanMin
                        || (tan == tanMin
                            && (p.x > bestNode.x
                                || (p.x == bestNode.x && sectorContainsSector(bestNode, p)))))
                {
                    bestNode = p
                    tanMin = tan
                    if logDiagnostics {
                        print("      Updating bestNode to \(p.index), tanMin=\(tanMin)")
                    }
                }
            }
            p = p.next!
        } while p !== stop

        if logDiagnostics {
            print("  Completed. bestNode=\(bestNode.index), tanMin=\(tanMin)")
        }

        return bestNode
    }

    // MARK: - Geometry predicates

    /// Does the diagonal m→p lie strictly inside the angle of the m sector?
    private static func sectorContainsSector(_ m: LinkedNode, _ p: LinkedNode) -> Bool {
        return signedTriangleArea(m.prev!, m, p.prev!) < 0
            && signedTriangleArea(p.next!, m, m.next!) < 0
    }

    private static func getLeftmost(_ start: LinkedNode) -> LinkedNode {
        var p = start
        var leftmost = start
        repeat {
            if p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y) {
                leftmost = p
            }
            p = p.next!
        } while p !== start
        return leftmost
    }

    private static func pointInTriangle(
        ax: Float, ay: Float, bx: Float, by: Float, cx: Float, cy: Float, px: Float, py: Float
    ) -> Bool {
        return (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0
            && (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0
            && (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0
    }

    private static func isValidDiagonal(_ a: LinkedNode, _ b: LinkedNode) -> Bool {
        return a.next!.index != b.index && a.prev!.index != b.index && !intersectsPolygon(a, b)
            && ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
                && (signedTriangleArea(a.prev!, a, b.prev!) != 0
                    || signedTriangleArea(a, b.prev!, b) != 0))
                || (equals(a, b) && signedTriangleArea(a.prev!, a, a.next!) > 0
                    && signedTriangleArea(b.prev!, b, b.next!) > 0))
    }

    /// Signed area of triangle p1·p2·p3 (twice). Negative = convex turn for a
    /// clockwise-wound ring, which is the convention this file pins.
    private static func signedTriangleArea(_ p1: LinkedNode, _ p2: LinkedNode, _ p3: LinkedNode)
        -> Float
    {
        return (p2.y - p1.y) * (p3.x - p2.x) - (p2.x - p1.x) * (p3.y - p2.y)
    }

    private static func equals(_ p1: LinkedNode, _ p2: LinkedNode) -> Bool {
        return p1.x == p2.x && p1.y == p2.y
    }

    /// Do segments p1q1 and p2q2 intersect (including collinear-overlap cases)?
    private static func intersects(
        _ p1: LinkedNode, _ q1: LinkedNode, _ p2: LinkedNode, _ q2: LinkedNode
    ) -> Bool {
        let o1 = sign(signedTriangleArea(p1, q1, p2))
        let o2 = sign(signedTriangleArea(p1, q1, q2))
        let o3 = sign(signedTriangleArea(p2, q2, p1))
        let o4 = sign(signedTriangleArea(p2, q2, q1))

        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        return false
    }

    private static func sign(_ num: Float) -> Int {
        return num > 0 ? 1 : (num < 0 ? -1 : 0)
    }

    /// For collinear p·q·r, does q lie on segment pr?
    private static func onSegment(_ p: LinkedNode, _ q: LinkedNode, _ r: LinkedNode) -> Bool {
        return q.x <= Swift.max(p.x, r.x) && q.x >= Swift.min(p.x, r.x)
            && q.y <= Swift.max(p.y, r.y) && q.y >= Swift.min(p.y, r.y)
    }

    /// Does diagonal a→b cross any polygon edge?
    private static func intersectsPolygon(_ a: LinkedNode, _ b: LinkedNode) -> Bool {
        var p = a
        repeat {
            let next = p.next!
            if p.index != a.index && next.index != a.index && p.index != b.index
                && next.index != b.index && intersects(p, next, a, b)
            {
                return true
            }
            p = p.next!
        } while p !== a
        return false
    }

    /// Is diagonal a→b locally inside the polygon at vertex a?
    private static func locallyInside(_ a: LinkedNode, _ b: LinkedNode) -> Bool {
        return signedTriangleArea(a.prev!, a, a.next!) < 0
            ? signedTriangleArea(a, b, a.next!) >= 0 && signedTriangleArea(a, a.prev!, b) >= 0
            : signedTriangleArea(a, b, a.prev!) < 0 || signedTriangleArea(a, a.next!, b) < 0
    }

    /// Does the diagonal's midpoint lie inside the polygon?
    private static func middleInside(_ a: LinkedNode, _ b: LinkedNode) -> Bool {
        var p = a
        var inside = false
        let px = (a.x + b.x) / 2
        let py = (a.y + b.y) / 2
        repeat {
            let next = p.next!
            if ((p.y > py) != (next.y > py)) && next.y != p.y
                && (px < (next.x - p.x) * (py - p.y) / (next.y - p.y) + p.x)
            {
                inside.toggle()
            }
            p = p.next!
        } while p !== a
        return inside
    }

    /// Splice the polygon in two along a→b, inserting a mirrored pair of bridge
    /// nodes so *both* resulting rings stay closed. Returns the new node `b2`.
    @discardableResult
    private static func splitPolygon(_ a: LinkedNode, _ b: LinkedNode) -> LinkedNode {
        let a2 = LinkedNode(index: a.index, x: a.x, y: a.y)
        let b2 = LinkedNode(index: b.index, x: b.x, y: b.y)
        let an = a.next!
        let bp = b.prev!

        a.next = b
        b.prev = a

        a2.next = an
        an.prev = a2

        b2.next = a2
        a2.prev = b2

        bp.next = b2
        b2.prev = bp

        return b2
    }

    private static func insertNode(index: Int, x: Float, y: Float, last: LinkedNode?) -> LinkedNode
    {
        let node = LinkedNode(index: index, x: x, y: y)
        if let last = last {
            node.next = last.next
            node.prev = last
            last.next!.prev = node
            last.next = node
        } else {
            node.prev = node
            node.next = node
        }
        return node
    }

    private static func removeNode(_ node: LinkedNode) {
        node.next!.prev = node.prev
        node.prev!.next = node.next

        if let pz = node.prevZ { pz.nextZ = node.nextZ }
        if let nz = node.nextZ { nz.prevZ = node.prevZ }
    }

    // MARK: - z-order curve

    /// Assign z-order codes and link the ring in z-order for fast ear testing.
    private static func indexCurve(_ start: LinkedNode, minX: Float, minY: Float, invSize: Float) {
        var p = start
        repeat {
            if p.z == 0 {
                p.z = zOrder(x: p.x, y: p.y, minX: minX, minY: minY, invSize: invSize)
            }
            p.prevZ = p.prev
            p.nextZ = p.next
            p = p.next!
        } while p !== start

        p.prevZ!.nextZ = nil
        p.prevZ = nil

        _ = sortLinked(p)
    }

    /// Simon Tatham's O(n·log n) in-place merge sort over the z-linked list.
    @discardableResult
    private static func sortLinked(_ list: LinkedNode) -> LinkedNode {
        var list: LinkedNode? = list
        var inSize = 1

        while true {
            var p = list
            list = nil
            var tail: LinkedNode? = nil
            var numMerges = 0

            while let pp = p {
                numMerges += 1
                var q: LinkedNode? = pp
                var pSize = 0
                for _ in 0..<inSize {
                    pSize += 1
                    q = q?.nextZ
                    if q == nil { break }
                }
                var qSize = inSize

                while pSize > 0 || (qSize > 0 && q != nil) {
                    let e: LinkedNode
                    if pSize != 0 && (qSize == 0 || q == nil || p!.z <= q!.z) {
                        e = p!
                        p = p!.nextZ
                        pSize -= 1
                    } else {
                        e = q!
                        q = q!.nextZ
                        qSize -= 1
                    }

                    if let t = tail {
                        t.nextZ = e
                    } else {
                        list = e
                    }
                    e.prevZ = tail
                    tail = e
                }

                p = q
            }

            tail?.nextZ = nil
            inSize *= 2

            if numMerges <= 1 { break }
        }

        return list!
    }

    /// Interleave the bits of the (bbox-normalised, 15-bit) x and y into a
    /// 30-bit Morton / z-order code.
    private static func zOrder(x: Float, y: Float, minX: Float, minY: Float, invSize: Float) -> Int
    {
        var lx = Int((x - minX) * invSize)
        var ly = Int((y - minY) * invSize)

        lx = (lx | (lx << 8)) & 0x00FF_00FF
        lx = (lx | (lx << 4)) & 0x0F0F_0F0F
        lx = (lx | (lx << 2)) & 0x3333_3333
        lx = (lx | (lx << 1)) & 0x5555_5555

        ly = (ly | (ly << 8)) & 0x00FF_00FF
        ly = (ly | (ly << 4)) & 0x0F0F_0F0F
        ly = (ly | (ly << 2)) & 0x3333_3333
        ly = (ly | (ly << 1)) & 0x5555_5555

        return lx | (ly << 1)
    }

    // MARK: - Node

    private final class LinkedNode {
        let index: Int  // vertex index in the source coordinate array
        let x: Float
        let y: Float
        var prev: LinkedNode?
        var next: LinkedNode?
        var z: Int = 0  // z-order code (0 = not yet computed)
        var prevZ: LinkedNode?
        var nextZ: LinkedNode?
        var steiner: Bool = false

        init(index: Int, x: Float, y: Float) {
            self.index = index
            self.x = x
            self.y = y
        }
    }

    /// Twice the signed area of a ring slice. > 0 means clockwise as measured by
    /// the shoelace variant used throughout this file.
    private static func signedArea(data: [Float], start: Int, end: Int, dim: Int) -> Float {
        var sum: Float = 0
        var j = end - dim
        var i = start
        while i < end {
            sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1])
            j = i
            i += dim
        }
        return sum
    }
}

@inline(__always)
public func earcut(data: [Float], holeIndices: [Int], dim: Int) -> [Int] {
    return Earcut.triangulate(data, holeIndices: holeIndices, dimensions: dim)
}
