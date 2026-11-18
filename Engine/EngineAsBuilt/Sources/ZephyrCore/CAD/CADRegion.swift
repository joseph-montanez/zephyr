import Foundation

// =========================================================================
// MARK: - CADRegion (Step 1: single-face 2D region)
// =========================================================================
//
// A Step 1 region is one closed planar loop stored as a closed CADPolyline
// (bulge arcs preserved, so circles survive as two bulge halves). The
// entity carries `markerKey` in xdata so LIST reports REGION while
// rendering, selection, snapping, AREA, and EXPLODE keep working through
// the existing closed-polyline paths. Holes and multi-face unions arrive
// in Step 2; `holes` is reserved here so call sites already compile
// against the final shape.

public struct CADRegion: Hashable, Sendable {
    /// Closed outer boundary in world coordinates (identity transform).
    public var outer: CADPolyline
    /// Reserved for SUBTRACT holes (Step 2). Always empty in Step 1.
    public var holes: [CADPolyline]

    /// xdata flag marking a closed-polyline entity as a REGION.
    public static let markerKey = "zephyr.region"

    /// xdata payload carrying an opaque retained ACIS modeler body
    /// (JSON: version plus ordered group-code/text lines). Present only on
    /// entities imported from DWG/DXF REGION records; absent on regions
    /// Zephyr builds itself (those export as LWPOLYLINEs).
    public static let acisBlobKey = "zephyr.regionAcis"

    /// Attaches a retained ACIS body to an entity (also marks it a region).
    public static func markAcisBlob(
        _ entity: inout CADEntity, version: Int, lines: [(code: Int, text: String)]
    ) {
        let payload: [String: Any] = [
            "v": version,
            "lines": lines.map { [$0.code, $0.text] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let text = String(data: data, encoding: .utf8) {
            entity.xdata[acisBlobKey] = .string(text)
            entity.xdata[markerKey] = .bool(true)
        }
    }

    /// Decodes a retained ACIS body, or nil when the entity carries none
    /// (including corrupt payloads, which are treated as absent).
    public static func acisBlob(
        of entity: CADEntity
    ) -> (version: Int, lines: [(code: Int, text: String)])? {
        guard case let .string(text)? = entity.xdata[acisBlobKey],
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let version = payload["v"] as? Int,
              let rawLines = payload["lines"] as? [[Any]]
        else { return nil }
        var lines: [(code: Int, text: String)] = []
        lines.reserveCapacity(rawLines.count)
        for entry in rawLines {
            guard entry.count == 2,
                  let code = entry[0] as? Int,
                  let line = entry[1] as? String,
                  code == 1 || code == 3
            else { return nil }
            lines.append((code: code, text: line))
        }
        return (version: version, lines: lines)
    }

    public init(outer: CADPolyline, holes: [CADPolyline] = []) {
        self.outer = outer
        self.holes = holes
    }

    public static func isRegionEntity(_ entity: CADEntity) -> Bool {
        entity.xdata[markerKey] == .bool(true)
    }
}

// =========================================================================
// MARK: - Region validation errors (user-facing messages)
// =========================================================================

public enum CADRegionError: Error, Sendable {
    case openLoop(gap: Double)
    case selfIntersecting
    case nonPlanar(spread: Double)
    case unsupportedEntity(String)
    case degenerateLoop(String)

    public var message: String {
        switch self {
        case .openLoop(let gap):
            return "Loop is open - endpoints do not meet (gap \(gap))."
        case .selfIntersecting:
            return "Self-intersecting loop rejected."
        case .nonPlanar:
            return "Loop is not planar - all vertices must share one Z elevation."
        case .unsupportedEntity(let kind):
            return "Entity type \(kind) cannot form a region in Step 1."
        case .degenerateLoop(let why):
            return "Degenerate loop rejected (\(why))."
        }
    }
}

// =========================================================================
// MARK: - RegionBuilder (pure, headless-testable)
// =========================================================================

/// Converts selected entities into closed region loops in world space.
///
/// Accepted Step 1 inputs: closed polylines/polygons/rects, circles,
/// closed ellipses (tessellated, approximate), and chains of lines, arcs,
/// and open polylines whose endpoints meet. Splines, text, rays, xlines,
/// images, and tables are rejected with a message.
public enum RegionBuilder {

    /// Endpoints closer than this (world units) are treated as meeting.
    /// Matches JoinCommand.endpointTolerance.
    public static let endpointTolerance: Double = 0.001
    /// Max Z spread for a loop to count as planar.
    public static let planarTolerance: Double = 1e-6
    /// Min tessellated shoelace area for a loop to count as real.
    /// Matches CADBoundaryDetector.classifyLoops.
    public static let minimumArea: Double = 1e-9

    public struct BuiltLoop: Sendable {
        public var polyline: CADPolyline
        public var sourceHandles: Set<UUID>
        public var layerID: UUID
        public var color: ColorRGBA?
    }

    /// One directed edge for chain joining. Bulge follows the DXF
    /// convention (tan(sweep/4)) for traversal start -> end.
    private struct ChainEdge: Sendable {
        var start: Vector3
        var end: Vector3
        var bulge: Double
        var handle: UUID
        var layerID: UUID
        var color: ColorRGBA?
    }

    public static func buildRegions(
        from entities: [CADEntity]
    ) -> (loops: [BuiltLoop], failures: [String]) {
        var loops: [BuiltLoop] = []
        var failures: [String] = []
        var edges: [ChainEdge] = []

        for entity in entities {
            guard entity.blockID == nil else {
                failures.append(
                    CADRegionError.unsupportedEntity("INSERT").message)
                continue
            }
            guard let geometry = entity.localGeometry, !geometry.isEmpty
            else {
                failures.append(
                    CADRegionError.degenerateLoop("no geometry").message)
                continue
            }
            let t = entity.transform
            for prim in geometry {
                switch prim {
                case let .circle(center, radius, color):
                    let world = t.transformPoint(center)
                    guard radius > endpointTolerance else {
                        failures.append(
                            CADRegionError.degenerateLoop("zero radius").message)
                        continue
                    }
                    let path = CADPolyline(
                        vertices: [
                            CADPolylineVertex(
                                position: Vector3(
                                    x: world.x + radius, y: world.y, z: world.z),
                                bulge: 1.0),
                            CADPolylineVertex(
                                position: Vector3(
                                    x: world.x - radius, y: world.y, z: world.z),
                                bulge: 1.0),
                        ],
                        isClosed: true)
                    addValidated(
                        path, handle: entity.handle, layerID: entity.layerID,
                        color: color, into: &loops, failures: &failures)

                case let .polyline(path, color):
                    if path.isClosed {
                        let world = path.transformed(by: t)
                        addValidated(
                            world, handle: entity.handle,
                            layerID: entity.layerID, color: color,
                            into: &loops, failures: &failures)
                    } else {
                        edges.append(
                            contentsOf: openPolylineEdges(
                                path, transform: t, handle: entity.handle,
                                layerID: entity.layerID, color: color))
                    }

                case let .polygon(points, color):
                    guard points.count >= 3 else {
                        failures.append(
                            CADRegionError.degenerateLoop("fewer than 3 points").message)
                        continue
                    }
                    let world = points.map { t.transformPoint($0) }
                    addValidated(
                        CADPolyline(points: world, isClosed: true),
                        handle: entity.handle, layerID: entity.layerID,
                        color: color, into: &loops, failures: &failures)

                case let .rect(origin, size, color):
                    guard abs(size.x) > endpointTolerance,
                          abs(size.y) > endpointTolerance
                    else {
                        failures.append(
                            CADRegionError.degenerateLoop("zero size").message)
                        continue
                    }
                    let corners = [
                        t.transformPoint(origin),
                        t.transformPoint(Vector3(
                            x: origin.x + size.x, y: origin.y, z: origin.z)),
                        t.transformPoint(Vector3(
                            x: origin.x + size.x, y: origin.y + size.y,
                            z: origin.z)),
                        t.transformPoint(Vector3(
                            x: origin.x, y: origin.y + size.y, z: origin.z)),
                    ]
                    addValidated(
                        CADPolyline(points: corners, isClosed: true),
                        handle: entity.handle, layerID: entity.layerID,
                        color: color, into: &loops, failures: &failures)

                case let .ellipse(center, majorAxis, minorRatio, color):
                    let worldCenter = t.transformPoint(center)
                    // Ellipse has no exact polyline form: tessellate at the
                    // Step 0 budget (256 spans clears 1e-4 area error at R=50).
                    let axisU = t.transformPoint(
                        Vector3(
                            x: center.x + majorAxis.x, y: center.y + majorAxis.y,
                            z: center.z)) - worldCenter
                    let axisLen = hypot(axisU.x, axisU.y)
                    guard axisLen > endpointTolerance, minorRatio > 1e-9 else {
                        failures.append(
                            CADRegionError.degenerateLoop("zero axis").message)
                        continue
                    }
                    let divisions = 256
                    var pts: [Vector3] = []
                    pts.reserveCapacity(divisions)
                    for i in 0..<divisions {
                        let a = 2.0 * Double.pi * Double(i) / Double(divisions)
                        pts.append(Vector3(
                            x: worldCenter.x + axisU.x * cos(a)
                                - axisU.y * minorRatio * sin(a),
                            y: worldCenter.y + axisU.y * cos(a)
                                + axisU.x * minorRatio * sin(a),
                            z: worldCenter.z))
                    }
                    addValidated(
                        CADPolyline(points: pts, isClosed: true),
                        handle: entity.handle, layerID: entity.layerID,
                        color: color, into: &loops, failures: &failures)

                case let .line(start, finish, color):
                    edges.append(ChainEdge(
                        start: t.transformPoint(start),
                        end: t.transformPoint(finish),
                        bulge: 0, handle: entity.handle,
                        layerID: entity.layerID, color: color))

                case let .arc(center, radius, startAngle, endAngle, color):
                    guard radius > endpointTolerance else {
                        failures.append(
                            CADRegionError.degenerateLoop("zero radius").message)
                        continue
                    }
                    let local0 = Vector3(
                        x: center.x + radius * cos(startAngle),
                        y: center.y + radius * sin(startAngle),
                        z: center.z)
                    let local1 = Vector3(
                        x: center.x + radius * cos(endAngle),
                        y: center.y + radius * sin(endAngle),
                        z: center.z)
                    let p0 = t.transformPoint(local0)
                    let p1 = t.transformPoint(local1)
                    var sweep = endAngle - startAngle
                    while sweep <= 0 { sweep += 2.0 * Double.pi }
                    while sweep > 2.0 * Double.pi { sweep -= 2.0 * Double.pi }
                    edges.append(ChainEdge(
                        start: p0, end: p1, bulge: tan(sweep / 4.0),
                        handle: entity.handle, layerID: entity.layerID,
                        color: color))

                default:
                    failures.append(
                        CADRegionError.unsupportedEntity(
                            primitiveKind(of: prim)).message)
                }
            }
        }

        if !edges.isEmpty {
            let (chained, chainFailures) = joinEdges(edges)
            loops.append(contentsOf: chained)
            failures.append(contentsOf: chainFailures)
        }
        return (loops, failures)
    }

    // MARK: - Validation

    public static func validate(_ path: CADPolyline) -> CADRegionError? {
        let verts = path.vertices.map(\.position)
        guard !verts.isEmpty else {
            return .degenerateLoop("no vertices")
        }
        let z0 = verts[0].z
        if verts.contains(where: { abs($0.z - z0) > planarTolerance }) {
            let spread = (verts.map(\.z).max() ?? z0) - (verts.map(\.z).min() ?? z0)
            return .nonPlanar(spread: spread)
        }
        guard path.isClosed else {
            return .openLoop(gap: openGap(of: path) ?? -1)
        }
        // Note: CADPolyline stores closed loops WITHOUT a duplicated
        // closing vertex (the last->first span is implicit), so no
        // first/last distance check applies here. Tessellation closes it.
        let ring = tessellatedRing(of: path)
        guard ring.count >= 3 else {
            return .degenerateLoop("fewer than 3 points")
        }
        // Crossing test precedes the area test so a figure-8 reports as
        // self-intersecting even when its lobes cancel to zero net area.
        if isSelfIntersecting(ring) { return .selfIntersecting }
        guard abs(shoelace(ring)) > minimumArea else {
            return .degenerateLoop("zero area")
        }
        return nil
    }

    // MARK: - Mass properties (tessellated chords, matches AREA semantics)

    public struct Mass: Sendable {
        public var area: Double
        public var perimeter: Double
        public var centroid: Vector3
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double
    }

    /// Area via tessellated shoelace (bulges linearized, same as
    /// `InquiryMath.polylineArea`); perimeter uses exact arc spans.
    public static func massProperties(of path: CADPolyline) -> Mass {
        let ring = tessellatedRing(of: path)
        let area2 = shoelace(ring)
        let area = abs(area2) / 2.0
        var cx = 0.0, cy = 0.0
        if abs(area2) > 1e-18 {
            for i in 0..<ring.count {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                let c = p.x * q.y - q.x * p.y
                cx += (p.x + q.x) * c
                cy += (p.y + q.y) * c
            }
            cx /= 3.0 * area2
            cy /= 3.0 * area2
        } else if let first = ring.first {
            cx = first.x
            cy = first.y
        }
        var perimeter = 0.0
        for seg in 0..<path.segmentCount {
            if let arc = path.arcParameters(forSegment: seg) {
                perimeter += abs(arc.sweep) * arc.radius
            } else {
                let a = path.vertices[seg].position
                let b = path.vertices[path.endVertexIndex(forSegment: seg)].position
                perimeter += hypot(b.x - a.x, b.y - a.y)
            }
        }
        let xs = ring.map(\.x), ys = ring.map(\.y)
        return Mass(
            area: area, perimeter: perimeter,
            centroid: Vector3(x: cx, y: cy, z: ring.first?.z ?? 0),
            minX: xs.min() ?? 0, minY: ys.min() ?? 0,
            maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }

    // MARK: - Private helpers

    private static func addValidated(
        _ path: CADPolyline, handle: UUID, layerID: UUID, color: ColorRGBA?,
        into loops: inout [BuiltLoop], failures: inout [String]
    ) {
        if let error = validate(path) {
            failures.append(error.message)
            return
        }
        loops.append(BuiltLoop(
            polyline: path, sourceHandles: [handle],
            layerID: layerID, color: color))
    }

    private static func primitiveKind(of prim: CADPrimitive) -> String {
        switch prim {
        case .spline: return "SPLINE"
        case .text: return "TEXT"
        case .ray: return "RAY"
        case .xline: return "XLINE"
        case .image: return "IMAGE"
        case .table: return "TABLE"
        case .hatch, .hatchPath, .gradient: return "HATCH"
        case .fillRect, .fillPolygon, .fillComplexPolygon: return "SOLID"
        case .penStroke: return "PENSTROKE"
        case .point: return "POINT"
        default: return "ENTITY"
        }
    }

    private static func openPolylineEdges(
        _ path: CADPolyline, transform t: Transform3D, handle: UUID,
        layerID: UUID, color: ColorRGBA?
    ) -> [ChainEdge] {
        let world = path.transformed(by: t)
        var out: [ChainEdge] = []
        for seg in 0..<world.segmentCount {
            let a = world.vertices[seg]
            let b = world.vertices[world.endVertexIndex(forSegment: seg)]
            out.append(ChainEdge(
                start: a.position, end: b.position, bulge: a.bulge,
                handle: handle, layerID: layerID, color: color))
        }
        return out
    }

    /// Greedy endpoint-cluster chaining. Returns closed loops plus one
    /// failure message per unclosable chain.
    private static func joinEdges(
        _ edges: [ChainEdge]
    ) -> (loops: [BuiltLoop], failures: [String]) {
        var loops: [BuiltLoop] = []
        var failures: [String] = []
        var unused = Set(edges.indices)

        while let seed = unused.first {
            unused.remove(seed)
            var ordered: [ChainEdge] = [edges[seed]]
            var handles: Set<UUID> = [edges[seed].handle]
            var closed = edges[seed].start.distance(to: edges[seed].end)
                < endpointTolerance

            while !closed, !unused.isEmpty {
                let tip = ordered.last!.end
                var best: Int?
                var bestDist = endpointTolerance
                var reverse = false
                for cand in unused {
                    let dStart = edges[cand].start.distance(to: tip)
                    if dStart < bestDist {
                        bestDist = dStart
                        best = cand
                        reverse = false
                    }
                    let dEnd = edges[cand].end.distance(to: tip)
                    if dEnd < bestDist {
                        bestDist = dEnd
                        best = cand
                        reverse = true
                    }
                }
                guard let next = best else { break }
                unused.remove(next)
                var edge = edges[next]
                if reverse {
                    swap(&edge.start, &edge.end)
                    edge.bulge = -edge.bulge
                }
                ordered.append(edge)
                handles.insert(edge.handle)
                closed = edge.end.distance(to: ordered[0].start)
                    < endpointTolerance
            }

            if !closed {
                let tip = ordered.last!.end
                let gap = tip.distance(to: ordered[0].start)
                failures.append(CADRegionError.openLoop(gap: gap).message)
                continue
            }
            var vertices: [CADPolylineVertex] = []
            vertices.reserveCapacity(ordered.count)
            for edge in ordered {
                vertices.append(CADPolylineVertex(
                    position: edge.start, bulge: edge.bulge))
            }
            let path = CADPolyline(vertices: vertices, isClosed: true)
            if let error = validate(path) {
                failures.append(error.message)
                continue
            }
            loops.append(BuiltLoop(
                polyline: path, sourceHandles: handles,
                layerID: edges[seed].layerID, color: edges[seed].color))
        }
        return (loops, failures)
    }

    private static func openGap(of path: CADPolyline) -> Double? {
        guard let first = path.vertices.first?.position,
              let last = path.vertices.last?.position
        else { return nil }
        return first.distance(to: last)
    }

    /// Tessellated ring without the duplicated closing point and
    /// without consecutive duplicates (so a doubled vertex reads as
    /// degenerate, not as a self-touching span).
    private static func tessellatedRing(of path: CADPolyline) -> [Vector3] {
        var pts = path.tessellatedPoints()
        if pts.count > 1, let first = pts.first, let last = pts.last,
           first.distance(to: last) <= 1e-9 {
            pts.removeLast()
        }
        var clean: [Vector3] = []
        clean.reserveCapacity(pts.count)
        for p in pts {
            if let last = clean.last, last.distance(to: p) <= 1e-9 { continue }
            clean.append(p)
        }
        if clean.count > 1, let first = clean.first, let last = clean.last,
           first.distance(to: last) <= 1e-9 {
            clean.removeLast()
        }
        return clean
    }

    private static func shoelace(_ ring: [Vector3]) -> Double {
        var sum = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum
    }

    /// O(n^2) proper-crossing test on the tessellated ring. Adjacent
    /// spans (and the first/last pair) share a vertex by construction and
    /// are skipped; any other touch or crossing rejects the loop.
    private static func isSelfIntersecting(_ ring: [Vector3]) -> Bool {
        let n = ring.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            let a1 = ring[i], a2 = ring[(i + 1) % n]
            for j in (i + 1)..<n {
                if j == i { continue }
                if (j + 1) % n == i { continue }
                if (i + 1) % n == j { continue }
                let b1 = ring[j], b2 = ring[(j + 1) % n]
                if segmentsTouch(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    private static func orientation(
        _ a: Vector3, _ b: Vector3, _ c: Vector3
    ) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func onSegment(
        _ a: Vector3, _ p: Vector3, _ b: Vector3
    ) -> Bool {
        let eps = 1e-9
        return min(a.x, b.x) - eps <= p.x && p.x <= max(a.x, b.x) + eps
            && min(a.y, b.y) - eps <= p.y && p.y <= max(a.y, b.y) + eps
    }

    private static func segmentsTouch(
        _ p1: Vector3, _ p2: Vector3, _ p3: Vector3, _ p4: Vector3
    ) -> Bool {
        let eps = 1e-12
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps))
            && ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps)) {
            return true
        }
        if abs(d1) <= eps && onSegment(p3, p1, p4) { return true }
        if abs(d2) <= eps && onSegment(p3, p2, p4) { return true }
        if abs(d3) <= eps && onSegment(p1, p3, p2) { return true }
        if abs(d4) <= eps && onSegment(p1, p4, p2) { return true }
        return false
    }
}
