import Foundation

// =========================================================================
// MARK: - PeditGeometryEngine
// =========================================================================

/// Pure polyline geometry for the `PEDIT` command (no engine/UI/undo).
///
/// Every function maps `CADPolyline -> CADPolyline?` (nil = rejected input:
/// degenerate geometry or an invalid parameter such as a negative width).
/// The command layer owns target resolution, prompts, selection, and the
/// single `replaceEntities` undo batch per subcommand; PR4 adds Join here
/// and PR5 adds Fit/Spline/Decurve.
public enum PeditGeometryEngine {

    /// Tolerance for snapping out zero-length segments (world units).
    public static let zeroLengthTolerance: Double = 1e-9

    // MARK: - Sanitize

    /// Drops consecutive duplicate vertices (and a closing duplicate of the
    /// first vertex on closed paths) so no zero-length segment survives an
    /// edit. Frame/generated `kind` and tangents ride with their vertices.
    /// Returns nil when fewer than 2 vertices remain.
    public static func sanitized(_ path: CADPolyline) -> CADPolyline? {
        var kept: [CADPolylineVertex] = []
        kept.reserveCapacity(path.vertices.count)
        for vertex in path.vertices {
            if let last = kept.last,
               last.position.distance(to: vertex.position) <= zeroLengthTolerance {
                continue
            }
            kept.append(vertex)
        }
        if path.isClosed, kept.count > 1,
           let first = kept.first, let last = kept.last,
           last.position.distance(to: first.position) <= zeroLengthTolerance {
            kept.removeLast()
        }
        guard kept.count >= 2 else { return nil }
        var result = path
        result.vertices = kept
        return result
    }

    // MARK: - Close / Open / LtGen

    public static func closed(_ path: CADPolyline) -> CADPolyline {
        var result = path
        result.isClosed = true
        return result
    }

    public static func opened(_ path: CADPolyline) -> CADPolyline {
        var result = path
        result.isClosed = false
        return result
    }

    public static func withLineTypeGeneration(
        _ path: CADPolyline, enabled: Bool
    ) -> CADPolyline {
        var result = path
        result.lineTypeGenerationEnabled = enabled
        return result
    }

    // MARK: - Width / Taper

    /// Sets every segment's start and end width to `width`.
    /// Returns nil for negative widths.
    public static func withGlobalWidth(
        _ path: CADPolyline, width: Double
    ) -> CADPolyline? {
        guard width >= 0 else { return nil }
        var result = path
        for index in result.vertices.indices {
            result.vertices[index].startWidth = width
            result.vertices[index].endWidth = width
        }
        return result
    }

    /// Linear width gradient from `fromWidth` at the first vertex to
    /// `toWidth` at the last. Vertex *i* of *N* carries
    /// `from + (to - from) * i / (N - 1)` as both its start and end width,
    /// so the rendered strip interpolates smoothly segment to segment.
    /// Returns nil for negative widths.
    public static func tapered(
        _ path: CADPolyline, from fromWidth: Double, to toWidth: Double
    ) -> CADPolyline? {
        guard fromWidth >= 0, toWidth >= 0, path.vertices.count >= 2 else { return nil }
        var result = path
        let last = Double(path.vertices.count - 1)
        for index in result.vertices.indices {
            let w = fromWidth + (toWidth - fromWidth) * Double(index) / last
            result.vertices[index].startWidth = w
            result.vertices[index].endWidth = w
        }
        return result
    }

    // MARK: - Reverse

    /// Direction-flipped path. Vertex order reverses; bulges negate and shift
    /// with their segment (vertex *i* carries segment *i*→*i+1*); widths swap
    /// start/end; tangents rotate by π (travel direction flips); kinds ride
    /// with their positions. Closed paths keep vertex 0 fixed so reversing
    /// twice restores the original exactly. `REVERSE` delegates here.
    public static func reversed(_ path: CADPolyline) -> CADPolyline {
        let vertices = path.vertices
        guard vertices.count > 1 else { return path }
        var flipped: [CADPolylineVertex] = []
        flipped.reserveCapacity(vertices.count)
        if path.isClosed {
            flipped.append(flippedVertexForReverse(
                vertices[0],
                bulge: -vertices[vertices.count - 1].bulge,
                startWidth: vertices[vertices.count - 1].endWidth,
                endWidth: vertices[vertices.count - 1].startWidth))
            for j in 1..<vertices.count {
                let oldIndex = vertices.count - j
                let sourceSegment = vertices[oldIndex - 1]
                flipped.append(flippedVertexForReverse(
                    vertices[oldIndex],
                    bulge: -sourceSegment.bulge,
                    startWidth: sourceSegment.endWidth,
                    endWidth: sourceSegment.startWidth))
            }
        } else {
            let count = vertices.count
            for j in 0..<count {
                if j < count - 1 {
                    let source = vertices[count - 2 - j]
                    flipped.append(flippedVertexForReverse(
                        vertices[count - 1 - j],
                        bulge: -source.bulge,
                        startWidth: source.endWidth,
                        endWidth: source.startWidth))
                } else {
                    // New last vertex has no outgoing segment: carry the old
                    // tail values verbatim so double-reverse is exact
                    // (tangent still rotates: +2π over two reverses).
                    let tail = vertices[count - 1]
                    flipped.append(flippedVertexForReverse(
                        vertices[0],
                        bulge: tail.bulge,
                        startWidth: tail.startWidth,
                        endWidth: tail.endWidth))
                }
            }
        }
        var result = path
        result.vertices = flipped
        return result
    }

    private static func flippedVertexForReverse(
        _ vertex: CADPolylineVertex,
        bulge: Double, startWidth: Double, endWidth: Double
    ) -> CADPolylineVertex {
        var copy = vertex
        copy.bulge = bulge
        copy.startWidth = startWidth
        copy.endWidth = endWidth
        if let tangent = copy.tangent {
            copy.tangent = remainder(tangent + .pi, 2 * .pi)
        }
        return copy
    }

    // MARK: - Vertex editing (PR3)

    /// Minimum vertex counts: 2 for open, 3 for closed.
    public static func minimumVertexCount(isClosed: Bool) -> Int {
        isClosed ? 3 : 2
    }

    /// Moves vertex `index` to `position`. Tangents and kinds ride along;
    /// callers re-derive Fit/Spline output (PR5) from the edited frame.
    public static func moved(
        _ path: CADPolyline, index: Int, to position: Vector3
    ) -> CADPolyline? {
        guard path.vertices.indices.contains(index) else { return nil }
        var result = path
        result.vertices[index].position = position
        return sanitized(result)
    }

    /// Inserts `position` as a new vertex immediately after `index`.
    /// Returns the new path and the inserted vertex's index.
    public static func inserted(
        _ path: CADPolyline, after index: Int, position: Vector3
    ) -> (path: CADPolyline, index: Int)? {
        guard path.vertices.indices.contains(index) else { return nil }
        var result = path
        result.vertices.insert(CADPolylineVertex(position: position), at: index + 1)
        guard let clean = sanitized(result) else { return nil }
        return (clean, index + 1)
    }

    /// Deletes vertex `index`. Returns nil when the minimum vertex count
    /// would be violated (open ≥ 2, closed ≥ 3) or the index is out of range.
    public static func deleted(
        _ path: CADPolyline, index: Int
    ) -> CADPolyline? {
        guard path.vertices.indices.contains(index),
              path.vertices.count - 1 >= minimumVertexCount(isClosed: path.isClosed)
        else { return nil }
        var result = path
        result.vertices.remove(at: index)
        return sanitized(result)
    }

    /// Splits at vertex `index`. Open paths yield the two halves
    /// `[0...i]` and `[i...end]`; a closed path yields one open path with
    /// the same vertices. Generated-vertex state does not survive the split:
    /// results reset to `.none` (refit via PEDIT), mirroring trim semantics.
    public static func breakAt(
        _ path: CADPolyline, index: Int
    ) -> [CADPolyline]? {
        guard path.vertices.indices.contains(index) else { return nil }
        if path.isClosed {
            var opened = path
            opened.isClosed = false
            opened.curveType = .none
            opened.vertices = opened.vertices.map { vertex in
                var plain = vertex
                plain.kind = .normal
                return plain
            }
            return sanitized(opened).map { [$0] }
        }
        let first = CADPolyline(
            vertices: Array(path.vertices[...index]),
            isClosed: false,
            lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
        let second = CADPolyline(
            vertices: Array(path.vertices[index...]),
            isClosed: false,
            lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
        let cleanFirst = sanitized(first)
        let cleanSecond = sanitized(second)
        guard let cleanFirst, let cleanSecond else { return nil }
        return [cleanFirst, cleanSecond]
    }

    /// Sets the tangent direction (radians, internal convention) at `index`.
    public static func withTangent(
        _ path: CADPolyline, index: Int, angle: Double
    ) -> CADPolyline? {
        guard path.vertices.indices.contains(index) else { return nil }
        var result = path
        result.vertices[index].tangent = angle
        return result
    }

    /// Sets the start/end widths of the segment leaving vertex `index`.
    /// Returns nil for negative widths or an out-of-range index.
    public static func withSegmentWidth(
        _ path: CADPolyline, index: Int, start: Double, end: Double
    ) -> CADPolyline? {
        guard path.vertices.indices.contains(index), start >= 0, end >= 0 else { return nil }
        var result = path
        result.vertices[index].startWidth = start
        result.vertices[index].endWidth = end
        return result
    }

    /// Removes every vertex strictly between `from` and `to`, joining them
    /// with a single segment. On closed paths the range may wrap
    /// (`from > to` walks through vertex 0). Returns nil when the indices
    /// match, are adjacent (nothing to remove), or the minimum vertex count
    /// would be violated.
    public static func straightened(
        _ path: CADPolyline, from: Int, to: Int
    ) -> CADPolyline? {
        let count = path.vertices.count
        guard path.vertices.indices.contains(from),
              path.vertices.indices.contains(to),
              from != to
        else { return nil }
        var remove: Set<Int> = []
        if path.isClosed {
            var cursor = (from + 1) % count
            while cursor != to {
                remove.insert(cursor)
                cursor = (cursor + 1) % count
            }
        } else {
            let lo = min(from, to) + 1
            let hi = max(from, to)
            guard lo < hi else { return nil }
            remove = Set(lo..<hi)
        }
        guard !remove.isEmpty,
              count - remove.count >= minimumVertexCount(isClosed: path.isClosed)
        else { return nil }
        var result = path
        result.vertices = result.vertices.enumerated().compactMap {
            remove.contains($0.offset) ? nil : $0.element
        }
        return sanitized(result)
    }

    // MARK: - Join (PR4)

    /// A join participant: a local path plus its entity transform.
    /// The engine bakes everything to world space, chains whole objects
    /// end-to-end (never tessellating curves), and maps the result back
    /// into the target's local space.
    public struct JoinSource {
        public var path: CADPolyline
        public var transform: Transform3D
        public init(path: CADPolyline, transform: Transform3D = .identity) {
            self.path = path
            self.transform = transform
        }
    }

    /// Endpoints closer than this (world units) are treated as touching.
    /// Same rationale as `JoinCommand.endpointTolerance`: absorbs
    /// single-precision DXF import rounding without accidental merges.
    public static let joinFuzz: Double = 0.001

    /// Chains `sources` onto `target` end-to-end, preserving bulges, widths,
    /// and tangents. Returns the joined path in the target's local space,
    /// or nil when nothing touches the target, a participant is unjoinable
    /// (closed, curved Fit/Spline state, block-relative, or non-uniformly
    /// scaled target), or the result degenerates.
    ///
    /// Rules (v1): the target must be open with `.none` curve state;
    /// sources must be open `.none` polylines (frame/gen kinds rejected —
    /// Decurve first) or plain lines/arcs supplied as 2-vertex paths;
    /// generated vertices never survive a join; tangents ride with their
    /// vertices; the result never auto-closes (use Close explicitly).
    public static func joinPolylines(
        target: JoinSource, sources: [JoinSource], fuzz: Double = joinFuzz
    ) -> CADPolyline? {
        guard !target.path.isClosed,
              target.path.curveType == .none,
              isUniformlyScaled(target.transform),
              target.path.vertices.count >= 2
        else { return nil }
        var chain = worldBaked(target)
        guard chain.points.count >= 2 else { return nil }
        var remaining = sources
        var joinedAny = false
        var progressed = true
        while progressed && !remaining.isEmpty {
            progressed = false
            for (index, source) in remaining.enumerated() {
                guard let baked = worldBakedIfJoinable(source) else {
                    remaining.remove(at: index)
                    progressed = true
                    break
                }
                if let appended = appending(baked, to: chain, fuzz: fuzz) {
                    chain = appended
                    joinedAny = true
                    remaining.remove(at: index)
                    progressed = true
                    break
                }
            }
        }
        guard joinedAny else { return nil }
        let worldPath = chainToPath(chain)
        let local = worldPath.transformed(by: target.transform.inverse())
        return sanitized(local)
    }

    // MARK: Join internals

    /// World-space chain. Points and tangents are per-vertex (count N);
    /// bulges and widths are per-segment (count N-1, segment *i* leaves
    /// vertex *i*), matching `CADPolylineVertex` convention.
    private struct WorldChain {
        var points: [Vector3]
        var bulges: [Double]
        var startWidths: [Double]
        var endWidths: [Double]
        var tangents: [Double?]
    }

    private static func isUniformlyScaled(_ transform: Transform3D) -> Bool {
        let scale = transform.scale
        return abs(abs(scale.x) - abs(scale.y)) <= 1e-9
    }

    /// Bakes a participant to world space. Non-uniformly scaled sources fall
    /// back to tessellated straight segments (their curve state cannot
    /// survive the bake); tangents interpolate the same way the renderer
    /// interpolates widths.
    private static func worldBaked(_ source: JoinSource) -> WorldChain {
        let local = source.path
        if !isUniformlyScaled(source.transform) {
            let tessellated = local.tessellatedPoints()
            let zero = [Double](repeating: 0, count: max(tessellated.count - 1, 0))
            return WorldChain(
                points: tessellated.map { source.transform.transformPoint($0) },
                bulges: zero, startWidths: zero, endWidths: zero,
                tangents: [Double?](repeating: nil, count: tessellated.count))
        }
        let world = local.transformed(by: source.transform)
        let segments = world.vertices.dropLast()
        return WorldChain(
            points: world.vertices.map(\.position),
            bulges: segments.map(\.bulge),
            startWidths: segments.map(\.startWidth),
            endWidths: segments.map(\.endWidth),
            tangents: world.vertices.map(\.tangent))
    }

    private static func worldBakedIfJoinable(_ source: JoinSource) -> WorldChain? {
        guard !source.path.isClosed,
              source.path.curveType == .none,
              !source.path.vertices.contains(where: { $0.kind != .normal }),
              source.path.vertices.count >= 2
        else { return nil }
        let baked = worldBaked(source)
        guard baked.points.count >= 2 else { return nil }
        return baked
    }

    /// Tries to attach `candidate` to either end of `chain` (reversing it
    /// first when the far ends touch). The chain's joint position wins
    /// (touch is within fuzz); widths and bulge follow the outgoing
    /// segment, so the candidate's duplicate endpoint is dropped
    /// wholesale.
    private static func appending(
        _ candidate: WorldChain, to chain: WorldChain, fuzz: Double
    ) -> WorldChain? {
        guard let chainStart = chain.points.first,
              let chainEnd = chain.points.last,
              let candStart = candidate.points.first,
              let candEnd = candidate.points.last
        else { return nil }
        if chainEnd.distance(to: candStart) <= fuzz {
            return concatenated(chain, candidate)
        }
        if chainEnd.distance(to: candEnd) <= fuzz {
            return concatenated(chain, reversed(candidate))
        }
        if chainStart.distance(to: candEnd) <= fuzz {
            return concatenated(candidate, chain)
        }
        if chainStart.distance(to: candStart) <= fuzz {
            return concatenated(reversed(candidate), chain)
        }
        return nil
    }

    /// Concatenates two chains, dropping the second chain's first point
    /// (the duplicate joint endpoint).
    private static func concatenated(
        _ first: WorldChain, _ second: WorldChain
    ) -> WorldChain {
        var second = second
        second.points.removeFirst()
        second.tangents.removeFirst()
        // Segment arrays stay aligned: dropping the duplicate endpoint drops
        // no segment (segment count = points - 1 on each side already).
        return WorldChain(
            points: first.points + second.points,
            bulges: first.bulges + second.bulges,
            startWidths: first.startWidths + second.startWidths,
            endWidths: first.endWidths + second.endWidths,
            tangents: first.tangents + second.tangents)
    }

    /// Reverses a world chain: segment order flips, bulges negate, widths
    /// swap, tangents rotate by π (same rules as `reversed(_:)`).
    private static func reversed(_ chain: WorldChain) -> WorldChain {
        let count = chain.points.count
        guard count > 1 else { return chain }
        var points: [Vector3] = []
        var bulges: [Double] = []
        var startWidths: [Double] = []
        var endWidths: [Double] = []
        var tangents: [Double?] = []
        points.reserveCapacity(count)
        for j in 0..<count {
            points.append(chain.points[count - 1 - j])
            tangents.append(chain.tangents[count - 1 - j].map { remainder($0 + .pi, 2 * .pi) })
        }
        for j in 0..<(count - 1) {
            bulges.append(-chain.bulges[count - 2 - j])
            startWidths.append(chain.endWidths[count - 2 - j])
            endWidths.append(chain.startWidths[count - 2 - j])
        }
        return WorldChain(points: points, bulges: bulges,
                          startWidths: startWidths, endWidths: endWidths, tangents: tangents)
    }

    private static func chainToPath(_ chain: WorldChain) -> CADPolyline {
        var vertices: [CADPolylineVertex] = []
        vertices.reserveCapacity(chain.points.count)
        for (index, point) in chain.points.enumerated() {
            let isLast = index == chain.points.count - 1
            vertices.append(CADPolylineVertex(
                position: point,
                bulge: isLast ? 0 : chain.bulges[index],
                startWidth: isLast ? chain.endWidths.last ?? 0 : chain.startWidths[index],
                endWidth: isLast ? chain.endWidths.last ?? 0 : chain.endWidths[index],
                tangent: chain.tangents[index]))
        }
        return CADPolyline(vertices: vertices)
    }

    // MARK: - Fit / Spline / Decurve (PR5)

    /// Samples per straight span when generating Fit/Spline vertices.
    public static let curveSamplesPerSpan: Int = 12
    /// Hard cap on generated vertex counts (decimates sampling, never shape).
    public static let maxGeneratedVertices: Int = 4000

    /// Cubic Hermite fit passing strictly through every vertex. Straight
    /// segments use Catmull-Rom tangents; vertices carrying a user tangent
    /// (PEDIT Tangent) use it with chord-length magnitude. Frame vertices
    /// stay `.normal`; inserted samples are `.curveFitGenerated`.
    /// Returns nil for bulged paths (straighten arcs first), already-curved
    /// paths (Decurve first), or degenerate input.
    public static func fitCurve(
        _ path: CADPolyline, samplesPerSpan: Int = curveSamplesPerSpan
    ) -> CADPolyline? {
        guard path.curveType == .none,
              !path.hasBulges,
              path.vertices.allSatisfy({ $0.kind == .normal }),
              path.vertices.count >= 2
        else { return nil }
        let positions = path.vertices.map(\.position)
        let count = positions.count
        let spans = path.isClosed ? count : count - 1
        let sps = max(2, min(samplesPerSpan,
                             max(2, maxGeneratedVertices / max(spans, 1))))
        func neighbor(_ i: Int) -> Vector3 {
            if path.isClosed { return positions[(i + count) % count] }
            return positions[min(max(i, 0), count - 1)]
        }
        func tangent(at i: Int) -> Vector3 {
            if let user = path.vertices[i].tangent {
                // User direction in XY with chord-length magnitude (the
                // standard Hermite scaling); Z follows the chord like CR.
                let chord = neighbor(i + 1) - neighbor(i - 1)
                let length = max(hypot(chord.x, chord.y), 1e-12)
                let dz = (neighbor(i + 1).z - neighbor(i - 1).z) * 0.5
                return Vector3(x: cos(user) * length, y: sin(user) * length, z: dz)
            }
            return (neighbor(i + 1) - neighbor(i - 1)) * 0.5
        }
        var out: [CADPolylineVertex] = []
        out.reserveCapacity(count + spans * sps)
        for span in 0..<spans {
            let i1 = path.isClosed ? span % count : span
            let i2 = path.isClosed ? (span + 1) % count : span + 1
            let p1 = positions[i1]
            let p2 = positions[i2]
            let m1 = tangent(at: i1)
            let m2 = tangent(at: i2)
            out.append(path.vertices[i1])
            for step in 1...sps {
                let t = Double(step) / Double(sps + 1)
                let t2 = t * t
                let t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                let h11 = t3 - t2
                let point = p1 * h00 + m1 * h10 + p2 * h01 + m2 * h11
                let fraction = (Double(span) + t) / Double(spans)
                out.append(CADPolylineVertex(
                    position: point,
                    startWidth: widthAt(fraction: fraction, in: path),
                    endWidth: widthAt(fraction: fraction, in: path),
                    kind: .curveFitGenerated))
            }
        }
        if !path.isClosed {
            out.append(path.vertices[count - 1])
        }
        var result = path
        result.vertices = out
        result.curveType = .fit
        return sanitized(result)
    }

    /// B-spline using the vertices as the control polygon (curve is pulled
    /// toward the vertices, touching only open ends). Degree follows
    /// SPLINETYPE: quadratic (5) or cubic (6). Frames become
    /// `.splineFrame`, samples `.splineGenerated`. Open paths reuse
    /// `NURBSEvaluator` (clamped uniform knots); closed paths use a periodic
    /// de Boor below. Same nil contract as `fitCurve`, plus a control-count
    /// floor (cubic ≥ 4, quadratic ≥ 3).
    public static func splineCurve(
        _ path: CADPolyline, quadratic: Bool,
        samplesPerSpan: Int = curveSamplesPerSpan
    ) -> CADPolyline? {
        let degree = quadratic ? 2 : 3
        guard path.curveType == .none,
              !path.hasBulges,
              path.vertices.allSatisfy({ $0.kind == .normal }),
              path.vertices.count >= degree + 1
        else { return nil }
        let controls = path.vertices.map(\.position)
        let sampled: [Vector3]
        if path.isClosed {
            guard let periodic = evaluatePeriodicBSpline(
                points: controls, degree: degree, samplesPerSpan: samplesPerSpan)
            else { return nil }
            sampled = periodic
        } else {
            let knots = clampedUniformKnots(count: controls.count, degree: degree)
            let spans = controls.count - degree
            let sps = max(2, min(samplesPerSpan,
                                 max(2, maxGeneratedVertices / max(spans, 1))))
            sampled = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots, controlPoints: controls,
                segmentsPerSpan: sps)
            guard sampled.count >= 2 else { return nil }
        }
        // Storage order is frames (original control polygon, in order)
        // then generated curve samples (in curve order). The renderer skips
        // off-curve `.splineFrame` vertices via `displayPath`, so the drawn
        // curve follows the samples; Decurve drops the samples and unmarks
        // the frames, restoring the original array exactly.
        var out: [CADPolylineVertex] = []
        out.reserveCapacity(path.vertices.count + sampled.count)
        for vertex in path.vertices {
            var frame = vertex
            frame.kind = .splineFrame
            out.append(frame)
        }
        for (index, point) in sampled.enumerated() {
            let fraction = Double(index) / Double(max(sampled.count - 1, 1))
            let w = widthAt(fraction: fraction, in: path)
            out.append(CADPolylineVertex(
                position: point, startWidth: w, endWidth: w,
                kind: .splineGenerated))
        }
        var result = path
        result.vertices = out
        result.curveType = quadratic ? .splineQuadratic : .splineCubic
        return sanitized(result)
    }

    /// Restores the pre-smoothing vertex array: drops every generated
    /// vertex, unmarks frames, clears the curve type. User tangents survive
    /// (they are per-vertex data, not curve state). Returns nil when there
    /// is nothing to decurve.
    public static func decurved(_ path: CADPolyline) -> CADPolyline? {
        guard path.curveType != .none ||
                path.vertices.contains(where: { $0.kind != .normal })
        else { return nil }
        var result = path
        result.vertices = path.vertices.compactMap { vertex in
            switch vertex.kind {
            case .normal:
                return vertex
            case .splineFrame:
                var plain = vertex
                plain.kind = .normal
                return plain
            case .curveFitGenerated, .splineGenerated:
                return nil
            }
        }
        result.curveType = .none
        guard result.vertices.count >= minimumVertexCount(isClosed: result.isClosed) else { return nil }
        return sanitized(result)
    }

    // MARK: Curve internals

    /// Width along the frame at global fraction (chord-length weighted),
    /// averaging the bracketing segment's start/end widths.
    private static func widthAt(fraction: Double, in path: CADPolyline) -> Double {
        let count = path.vertices.count
        guard count >= 2 else { return 0 }
        var lengths: [Double] = []
        lengths.reserveCapacity(path.isClosed ? count : count - 1)
        var total = 0.0
        let spans = path.isClosed ? count : count - 1
        for span in 0..<spans {
            let a = path.vertices[span % count].position
            let b = path.vertices[(span + 1) % count].position
            let length = hypot(b.x - a.x, b.y - a.y)
            lengths.append(length)
            total += length
        }
        guard total > 1e-12 else {
            let v = path.vertices[0]
            return (v.startWidth + v.endWidth) * 0.5
        }
        var target = max(0, min(1, fraction)) * total
        for span in 0..<spans {
            if target <= lengths[span] || span == spans - 1 {
                let vertex = path.vertices[span % count]
                let localT = lengths[span] > 1e-12 ? target / lengths[span] : 0
                return vertex.startWidth + (vertex.endWidth - vertex.startWidth) * localT
            }
            target -= lengths[span]
        }
        let last = path.vertices[(spans - 1) % count]
        return last.endWidth
    }

    private static func clampedUniformKnots(count: Int, degree: Int) -> [Double] {
        var knots: [Double] = []
        knots.reserveCapacity(count + degree + 1)
        for _ in 0...degree { knots.append(0) }
        if count > degree + 1 {
            for i in 1..<(count - degree) { knots.append(Double(i)) }
        }
        let last = Double(max(count - degree, 1))
        for _ in 0...degree { knots.append(last) }
        return knots
    }

    /// Periodic (cyclic) B-spline for closed loops: uniform infinite knots
    /// with modular control indexing. Returns exactly
    /// `points.count * samplesPerSpan` loop vertices, or nil for degenerate
    /// input.
    private static func evaluatePeriodicBSpline(
        points: [Vector3], degree: Int, samplesPerSpan: Int
    ) -> [Vector3]? {
        let m = points.count
        guard m > degree, degree >= 1, samplesPerSpan >= 1 else { return nil }
        func knot(_ i: Int) -> Double { Double(i) }
        func deBoor(span: Int, t: Double) -> Vector3 {
            var d: [Vector3] = (0...degree).map { points[(span - degree + $0 + m * degree) % m] }
            for r in 1...degree {
                for j in stride(from: degree, through: r, by: -1) {
                    let denom = knot(span + j - r + 1) - knot(span - degree + j)
                    let alpha = denom > 1e-12 ? (t - knot(span - degree + j)) / denom : 0
                    d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
                }
            }
            return d[degree]
        }
        var out: [Vector3] = []
        out.reserveCapacity(m * samplesPerSpan)
        for span in degree..<(degree + m) {
            for step in 0..<samplesPerSpan {
                let t = Double(span) + Double(step) / Double(samplesPerSpan)
                out.append(deBoor(span: span, t: t))
            }
        }
        guard out.count >= 2 else { return nil }
        return out
    }

    // MARK: - Line / Arc conversion

    /// 2-vertex polyline for a LINE's endpoints.
    public static func convertedFromLine(start: Vector3, end: Vector3) -> CADPolyline? {
        let path = CADPolyline(points: [start, end])
        return sanitized(path)
    }

    /// 2-vertex polyline for an ARC, preserving curvature as a bulge
    /// (`tan(sweep/4)` in internal orientation). A degenerate zero-sweep arc
    /// becomes a closed two-semicircle loop, mirroring hatch-circle handling.
    public static func convertedFromArc(
        center: Vector3, radius: Double, startAngle: Double, endAngle: Double
    ) -> CADPolyline? {
        guard radius > 1e-12 else { return nil }
        var sweep = endAngle - startAngle
        while sweep > 2 * .pi { sweep -= 2 * .pi }
        while sweep < -2 * .pi { sweep += 2 * .pi }
        if abs(sweep) <= 1e-12 {
            let mid = Vector3(
                x: center.x - radius, y: center.y, z: center.z)
            let start = Vector3(
                x: center.x + radius, y: center.y, z: center.z)
            return CADPolyline(
                vertices: [
                    CADPolylineVertex(position: start, bulge: 1.0),
                    CADPolylineVertex(position: mid, bulge: 1.0),
                ],
                isClosed: true)
        }
        let start = Vector3(
            x: center.x + radius * cos(startAngle),
            y: center.y + radius * sin(startAngle),
            z: center.z)
        let end = Vector3(
            x: center.x + radius * cos(endAngle),
            y: center.y + radius * sin(endAngle),
            z: center.z)
        let path = CADPolyline(vertices: [
            CADPolylineVertex(position: start, bulge: tan(sweep / 4.0)),
            CADPolylineVertex(position: end),
        ])
        return sanitized(path)
    }
}
