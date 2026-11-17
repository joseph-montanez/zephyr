// Sources/ZephyrCore/Commands/OverkillEngine.swift
import Foundation

/// OVERKILL (Delete Duplicate Objects): pure comparison/geometry core.
///
/// Evaluates selected (or drawing-wide) geometry and computes a plan that
/// deletes exact duplicates, merges collinear lines / co-circular arcs, and
/// removes degenerate (zero-length) and redundant (arc-over-circle,
/// standalone-covered-by-polyline) objects. The thin `OverkillCommand`
/// applies the resulting plan through one `replaceEntities` batch, which is
/// exactly one undo entry.
///
/// Pass order: exact duplicates → zero-length/arc-over-circle cleanup →
/// polyline-internal optimization → collinear/co-circular merging →
/// standalone-vs-polyline coverage. Later passes see earlier results.
///
/// Key semantics (AutoCAD LT parity):
/// - Tolerance is in drawing (world) units; default `1e-6`.
/// - Two objects merge only when their *effective* properties match after
///   masking `ignoredProperties`. The survivor (or merged object) inherits
///   the first constituent's layer, style, and xdata.
/// - Locked, frozen, and hidden layers are never touched, nor are
///   viewport-projected entities, block contents, or (when
///   `protectAssociative` is set) dimensions, leaders, arrays, hatch
///   carriers, and group/constraint members. Group/constraint members may
///   survive as the kept duplicate but are never deleted or merged away.
/// - Scope notes: DXF group 39 (thickness) is not modeled anywhere in
///   Zephyr's entity/style types, so `.thickness` is accepted but currently
///   a no-op (thickness always compares equal). Polyline segments with
///   nonzero bulge do not participate in coverage/merging (whole-polyline
///   duplicates still work). Non-uniform-scale transforms compare
///   approximately; text rotation is compared uncomposed.
@MainActor
public enum OverkillEngine {

    nonisolated public static let defaultTolerance: Double = 0.000001

    // MARK: - Options

    nonisolated public static func sanitizedTolerance(_ raw: Double) -> Double {
        raw.isFinite && raw > 0 ? raw : defaultTolerance
    }
}

// =========================================================================
// MARK: - Ignored properties
// =========================================================================

/// LT "Ignore Object Property" toggles. Every toggle except `.thickness`
/// masks a real modeled field (see `OverkillEngine.propSig`); `.thickness`
/// is accepted for script compatibility but changes nothing.
public enum OverkillIgnoredProperty: String, CaseIterable, Sendable {
    case color
    case layer
    case linetype
    case linetypeScale
    case lineweight
    case thickness
    case transparency
    case plotStyle
}

// =========================================================================
// MARK: - Options
// =========================================================================

public struct OverkillOptions: Sendable {
    public var tolerance: Double
    public var ignoredProperties: Set<OverkillIgnoredProperty>
    public var optimizePolylineSegments: Bool
    public var ignorePolylineWidths: Bool
    public var keepPolylinesIntact: Bool
    public var mergePartialOverlap: Bool
    public var mergeEndToEnd: Bool
    public var protectAssociative: Bool

    public init(
        tolerance: Double = OverkillEngine.defaultTolerance,
        ignoredProperties: Set<OverkillIgnoredProperty> = [],
        optimizePolylineSegments: Bool = true,
        ignorePolylineWidths: Bool = false,
        keepPolylinesIntact: Bool = false,
        mergePartialOverlap: Bool = true,
        mergeEndToEnd: Bool = true,
        protectAssociative: Bool = true
    ) {
        self.tolerance = tolerance
        self.ignoredProperties = ignoredProperties
        self.optimizePolylineSegments = optimizePolylineSegments
        self.ignorePolylineWidths = ignorePolylineWidths
        self.keepPolylinesIntact = keepPolylinesIntact
        self.mergePartialOverlap = mergePartialOverlap
        self.mergeEndToEnd = mergeEndToEnd
        self.protectAssociative = protectAssociative
    }

    public var effectiveTolerance: Double {
        OverkillEngine.sanitizedTolerance(tolerance)
    }

    public func ignores(_ property: OverkillIgnoredProperty) -> Bool {
        ignoredProperties.contains(property)
    }
}

// =========================================================================
// MARK: - Report & plan
// =========================================================================

public struct OverkillReport: Sendable {
    public var deletedDuplicates = 0
    public var mergedSources = 0
    public var unifiedCreated = 0
    public var optimizedPolylines = 0
    public var cleanedUp = 0
    public var skippedLockedFrozen = 0
    public var skippedHidden = 0
    public var skippedProjected = 0
    public var skippedBlock = 0
    public var skippedAssociative = 0
    public var skippedReferenced = 0
    public var skippedUnsupported = 0
    public var skippedPartial = 0

    public init() {}

    public var totalRemoved: Int { deletedDuplicates + mergedSources + cleanedUp }

    public var totalSkipped: Int {
        skippedLockedFrozen + skippedHidden + skippedProjected
            + skippedBlock + skippedAssociative + skippedReferenced
            + skippedUnsupported + skippedPartial
    }

    public var didChange: Bool { totalRemoved > 0 || optimizedPolylines > 0 }

    public var summary: String {
        var parts: [String] = []
        if deletedDuplicates > 0 {
            parts.append("\(deletedDuplicates) duplicate\(deletedDuplicates == 1 ? "" : "s") deleted")
        }
        if mergedSources > 0 {
            parts.append(
                "\(mergedSources) segment\(mergedSources == 1 ? "" : "s") merged into "
                    + "\(unifiedCreated) object\(unifiedCreated == 1 ? "" : "s")")
        }
        if cleanedUp > 0 {
            parts.append("\(cleanedUp) redundant object\(cleanedUp == 1 ? "" : "s") removed")
        }
        if optimizedPolylines > 0 {
            parts.append("\(optimizedPolylines) polyline\(optimizedPolylines == 1 ? "" : "s") optimized")
        }
        var message = parts.isEmpty
            ? "No duplicates found."
            : parts.joined(separator: ", ") + "."
        if totalSkipped > 0 {
            var reasons: [String] = []
            if skippedLockedFrozen > 0 { reasons.append("\(skippedLockedFrozen) locked/frozen") }
            if skippedHidden > 0 { reasons.append("\(skippedHidden) hidden") }
            if skippedProjected > 0 { reasons.append("\(skippedProjected) projected") }
            if skippedBlock > 0 { reasons.append("\(skippedBlock) in blocks") }
            if skippedAssociative > 0 { reasons.append("\(skippedAssociative) associative") }
            if skippedReferenced > 0 { reasons.append("\(skippedReferenced) referenced") }
            if skippedUnsupported > 0 { reasons.append("\(skippedUnsupported) unsupported") }
            if skippedPartial > 0 { reasons.append("\(skippedPartial) partial") }
            message += " \(totalSkipped) object\(totalSkipped == 1 ? "" : "s") skipped "
                + "(\(reasons.joined(separator: ", ")))."
        }
        return message
    }
}

public struct OverkillPlan: Sendable {
    public var remove: Set<UUID>
    public var add: [CADEntity]
    public var report: OverkillReport

    public init(remove: Set<UUID> = [], add: [CADEntity] = [], report: OverkillReport = OverkillReport()) {
        self.remove = remove
        self.add = add
        self.report = report
    }

    public var isEmpty: Bool { remove.isEmpty && add.isEmpty }
}

// =========================================================================
// MARK: - Effective property signature
// =========================================================================

/// Effective style after masking ignored properties. Layer fields fall back
/// to the owning layer; per-entity DXF overrides ride in xdata
/// (`dxf.color`, `dxf.lineType`, `dxf.lineWeight`, `dxf.lineTypeScale`,
/// `dxf.plotStyleHandle`); per-primitive color overrides ride on the
/// primitive itself. Raw xdata values compare by exact value (conservative:
/// unknown encodings never compare equal).
struct OverkillPropSig: Hashable {
    var layer: UUID?
    var color: ColorRGBA?
    var linetype: String?
    var linetypeScale: Double?
    var lineweight: Double?
    var transparency: Int?
    var plotStyle: String?
}

@MainActor
extension OverkillEngine {

    static func entitySig(
        entity: CADEntity, layer: Layer?, options: OverkillOptions
    ) -> OverkillPropSig {
        let ig = options.ignoredProperties
        let xdata = entity.xdata
        return OverkillPropSig(
            layer: ig.contains(.layer) ? nil : entity.layerID,
            color: nil,
            linetype: ig.contains(.linetype)
                ? nil
                : (xdata["dxf.lineType"]?.stringValue?.uppercased()
                    ?? layer?.lineType.uppercased()),
            linetypeScale: ig.contains(.linetypeScale)
                ? nil : xdata["dxf.lineTypeScale"]?.doubleValue,
            lineweight: ig.contains(.lineweight)
                ? nil
                : (xdata["dxf.lineWeight"]?.doubleValue
                    ?? xdata["dxf.lineWeight"]?.intValue.map(Double.init)
                    ?? layer?.lineWeight),
            transparency: ig.contains(.transparency) ? nil : layer?.transparency,
            plotStyle: ig.contains(.plotStyle)
                ? nil
                : (xdata["dxf.plotStyleHandle"]?.stringValue?.uppercased()
                    ?? layer?.plotStyleHandle?.uppercased())
        )
    }

    static func fullSig(
        entity: CADEntity, primColor: ColorRGBA?, layer: Layer?,
        options: OverkillOptions
    ) -> OverkillPropSig {
        var sig = entitySig(entity: entity, layer: layer, options: options)
        if !options.ignoredProperties.contains(.color) {
            sig.color = primColor ?? layer?.color
        }
        return sig
    }
}

// =========================================================================
// MARK: - Math helpers (local: Vector3 exposes only arithmetic + distance)
// =========================================================================

struct OverkillMath {
    @inline(__always)
    static func dot(_ a: Vector3, _ b: Vector3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inline(__always)
    static func cross(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x)
    }

    @inline(__always)
    static func length(_ a: Vector3) -> Double {
        (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
    }

    static func normalized(_ a: Vector3) -> Vector3? {
        let len = length(a)
        guard len > 1e-18 else { return nil }
        return a * (1.0 / len)
    }

    static func dist(_ a: Vector3, _ b: Vector3) -> Double {
        length(a - b)
    }

    /// Distance from point `p` to segment `ab` (3D).
    static func distPointToSegment(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let ab = b - a
        let denom = dot(ab, ab)
        guard denom > 1e-24 else { return dist(p, a) }
        var t = dot(p - a, ab) / denom
        t = min(1.0, max(0.0, t))
        return dist(p, a + ab * t)
    }

    static func positiveRemainder(_ angle: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        let value = angle.truncatingRemainder(dividingBy: twoPi)
        return value < 0 ? value + twoPi : value
    }
}

// =========================================================================
// MARK: - Normalized world-space shapes
// =========================================================================

/// One normalized primitive in world space. Positions are world-space;
/// bulge/widths are raw (exact under rigid transforms, approximate under
/// non-uniform scale — see file header).
struct OverkillPrim: Hashable {
    var kind: UInt8 // 0 line, 1 circle, 2 arc, 3 polyline, 4 text
    var p0: Vector3
    var p1: Vector3
    var radius: Double
    var startAngle: Double
    var sweep: Double // normalized to (0, 2π] for arcs
    var text: String
    var textHeight: Double
    var textRotation: Double
    var textStyle: String?
    var alignH: Int
    var alignV: Int
    var mtextWidth: Double?
    var polyClosed: Bool
    var polyCurve: CADPolylineCurveType
    var polyVerts: [OverkillPolyVert]
    var color: ColorRGBA?

    struct OverkillPolyVert: Hashable {
        var p: Vector3
        var bulge: Double
        var w0: Double
        var w1: Double
        var kind: CADPolylineVertexKind
        /// Index into the source `CADPolyline.vertices` for rebuilds.
        var origIdx: Int
    }
}

/// Entity-level normalized shape: one primitive, or a multiset for
/// multi-primitive entities (matched order-independently).
enum OverkillShape {
    case single(OverkillPrim)
    case multi([OverkillPrim])
}

/// Working record for one in-scope entity.
struct OverkillRecord {
    var entity: CADEntity
    var layer: Layer?
    var shape: OverkillShape
    var entitySig: OverkillPropSig
    var order: Int
    var isProtected: Bool
    var consumed = false
    // Merge-pass scratch (valid for single line/arc records only).
    var lineOrigin = Vector3.zero
    var lineDir = Vector3(x: 1, y: 0, z: 0)
    var lineS0 = 0.0
    var lineS1 = 0.0
    var lineAbsorptions = 0
    /// Index of the record holding the survivor properties (lowest order).
    var linePropIdx = -1
    var arcIntervals: [(start: Double, sweep: Double)] = []
    var arcAbsorptions = 0
}

/// Coarse spatial hash over world bounding boxes expanded by tolerance, so
/// near-identical geometry always shares at least one cell.
struct OverkillHash {
    struct Cell: Hashable { var x: Int; var y: Int; var z: Int }

    var cell: Double
    var cells: [Cell: [Int]] = [:]

    init(tolerance: Double) {
        cell = max(1.0, 64.0 * tolerance)
    }

    mutating func insert(_ index: Int, boxMin: Vector3, boxMax: Vector3, pad: Double) {
        let loX = Int(floor((boxMin.x - pad) / cell))
        let hiX = Int(floor((boxMax.x + pad) / cell))
        let loY = Int(floor((boxMin.y - pad) / cell))
        let hiY = Int(floor((boxMax.y + pad) / cell))
        let loZ = Int(floor((boxMin.z - pad) / cell))
        let hiZ = Int(floor((boxMax.z + pad) / cell))
        for ix in loX...hiX {
            for iy in loY...hiY {
                for iz in loZ...hiZ {
                    cells[Cell(x: ix, y: iy, z: iz), default: []].append(index)
                }
            }
        }
    }

    func query(boxMin: Vector3, boxMax: Vector3, pad: Double) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        let loX = Int(floor((boxMin.x - pad) / cell))
        let hiX = Int(floor((boxMax.x + pad) / cell))
        let loY = Int(floor((boxMin.y - pad) / cell))
        let hiY = Int(floor((boxMax.y + pad) / cell))
        let loZ = Int(floor((boxMin.z - pad) / cell))
        let hiZ = Int(floor((boxMax.z + pad) / cell))
        for ix in loX...hiX {
            for iy in loY...hiY {
                for iz in loZ...hiZ {
                    for index in cells[Cell(x: ix, y: iy, z: iz)] ?? [] {
                        if seen.insert(index).inserted { out.append(index) }
                    }
                }
            }
        }
        return out
    }
}

@MainActor
extension OverkillEngine {

    // MARK: - Shape bounding boxes (world)

    static func shapePoints(_ prim: OverkillPrim) -> [Vector3] {
        switch prim.kind {
        case 0: return [prim.p0, prim.p1]
        case 1:
            return [
                Vector3(x: prim.p0.x - prim.radius, y: prim.p0.y, z: prim.p0.z),
                Vector3(x: prim.p0.x + prim.radius, y: prim.p0.y, z: prim.p0.z),
            ]
        case 2:
            // Containment box: endpoints + center, expanded by radius.
            let a = prim.p0 + Vector3(x: cos(prim.startAngle) * prim.radius,
                                      y: sin(prim.startAngle) * prim.radius, z: 0)
            let endAngle = prim.startAngle + prim.sweep
            let b = prim.p0 + Vector3(x: cos(endAngle) * prim.radius,
                                      y: sin(endAngle) * prim.radius, z: 0)
            return [a, b, prim.p0]
        case 3: return prim.polyVerts.map { $0.p }
        case 4:
            let margin = max(prim.textHeight, 1.0)
            return [
                prim.p0 - Vector3(x: margin, y: margin, z: margin),
                prim.p0 + Vector3(x: margin, y: margin, z: margin),
            ]
        default: return [prim.p0]
        }
    }

    static func shapeBox(_ shape: OverkillShape) -> (Vector3, Vector3) {
        let prims: [OverkillPrim]
        switch shape {
        case .single(let p): prims = [p]
        case .multi(let ps): prims = ps
        }
        var lo = Vector3(x: .infinity, y: .infinity, z: .infinity)
        var hi = Vector3(x: -.infinity, y: -.infinity, z: -.infinity)
        for prim in prims {
            for p in shapePoints(prim) {
                lo = Vector3(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
                hi = Vector3(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
            }
            if prim.kind == 1 || prim.kind == 2 {
                let r = prim.radius
                let pad = Vector3(x: r, y: r, z: 0)
                lo = Vector3(x: min(lo.x, prim.p0.x - pad.x),
                             y: min(lo.y, prim.p0.y - pad.y),
                             z: min(lo.z, prim.p0.z - pad.z))
                hi = Vector3(x: max(hi.x, prim.p0.x + pad.x),
                             y: max(hi.y, prim.p0.y + pad.y),
                             z: max(hi.z, prim.p0.z + pad.z))
            }
        }
        if lo.x == .infinity {
            lo = Vector3.zero; hi = Vector3.zero
        }
        return (lo, hi)
    }

    // MARK: - Candidate construction

    enum SkipReason {
        case lockedFrozen, hidden, projected, block, associative, unsupported
    }

    /// Normalize one entity to a working record, or the reason it is out
    /// of scope. All coordinates are world-space.
    static func makeRecord(
        entity: CADEntity, order: Int, referenced: Set<UUID>,
        options: OverkillOptions, document: CADDocument
    ) -> (OverkillRecord?, SkipReason?) {
        let layer = document.layer(for: entity.layerID)
        if let layer {
            if layer.isLocked || layer.isFrozen { return (nil, .lockedFrozen) }
            if !layer.isVisible { return (nil, .hidden) }
        }
        if entity.isViewportProjected { return (nil, .projected) }
        if entity.blockID != nil { return (nil, .block) }
        if options.protectAssociative,
           entity.dimensionMetadata != nil || entity.leaderData != nil
            || entity.arrayData != nil {
            return (nil, .associative)
        }
        guard let prims = entity.localGeometry, !prims.isEmpty else {
            return (nil, .unsupported)
        }
        let t = entity.transform
        var normed: [OverkillPrim] = []
        normed.reserveCapacity(prims.count)
        for prim in prims {
            guard let n = normalizePrim(prim, transform: t) else {
                return (nil, .unsupported)
            }
            if options.protectAssociative, case .polyline(let path, _) = prim,
               path.isHatchBoundaryCarrier || !path.hatchEdges.isEmpty {
                return (nil, .associative)
            }
            normed.append(n)
        }
        let isProtected = referenced.contains(entity.handle)
        let entitySig = entitySig(entity: entity, layer: layer, options: options)
        let shape: OverkillShape = normed.count == 1 ? .single(normed[0]) : .multi(normed)
        var record = OverkillRecord(
            entity: entity, layer: layer, shape: shape,
            entitySig: entitySig, order: order, isProtected: isProtected)
        if case .single(let prim) = shape, prim.kind == 0,
           let dir = OverkillMath.normalized(prim.p1 - prim.p0) {
            record.lineOrigin = prim.p0
            record.lineDir = dir
            record.lineS0 = 0
            record.lineS1 = OverkillMath.dist(prim.p0, prim.p1)
        }
        if case .single(let prim) = shape, prim.kind == 2 {
            record.arcIntervals = splitArcInterval(start: prim.startAngle, sweep: prim.sweep)
        }
        return (record, nil)
    }

    /// Normalize one primitive to world space. Returns nil for types
    /// OVERKILL does not handle (spline, ellipse, hatch, point, ray, xline,
    /// image, table, rect/polygon fills, gradients, pen strokes).
    static func normalizePrim(_ prim: CADPrimitive, transform t: Transform3D) -> OverkillPrim? {
        let blank = OverkillPrim(
            kind: 255, p0: .zero, p1: .zero, radius: 0, startAngle: 0,
            sweep: 0, text: "", textHeight: 0, textRotation: 0,
            textStyle: nil, alignH: 0, alignV: 0, mtextWidth: nil,
            polyClosed: false, polyCurve: .none, polyVerts: [], color: nil)
        switch prim {
        case .line(let start, let end, let color):
            var n = blank
            n.kind = 0
            n.p0 = t.transformPoint(start)
            n.p1 = t.transformPoint(end)
            n.color = color
            return n
        case .circle(let center, let radius, let color):
            var n = blank
            n.kind = 1
            n.p0 = t.transformPoint(center)
            n.radius = radius
            n.color = color
            return n
        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            var n = blank
            n.kind = 2
            n.p0 = t.transformPoint(center)
            n.radius = radius
            let start = OverkillMath.positiveRemainder(startAngle)
            var sweep = OverkillMath.positiveRemainder(endAngle - startAngle)
            if sweep <= 0 { sweep = 2.0 * Double.pi }
            n.startAngle = start
            n.sweep = sweep
            n.color = color
            return n
        case .polyline(let path, let color):
            var n = blank
            n.kind = 3
            n.polyClosed = path.isClosed
            n.polyCurve = path.curveType
            n.polyVerts = path.vertices.enumerated().map { idx, v in
                OverkillPrim.OverkillPolyVert(
                    p: t.transformPoint(v.position),
                    bulge: v.bulge, w0: v.startWidth, w1: v.endWidth,
                    kind: v.kind, origIdx: idx)
            }
            n.color = color
            return n
        case .text(let position, let text, let height, let rotation,
                   let style, let alignH, let alignV, let mtextWidth, let color):
            var n = blank
            n.kind = 4
            n.p0 = t.transformPoint(position)
            n.text = text
            n.textHeight = height
            n.textRotation = rotation
            n.textStyle = style?.uppercased()
            n.alignH = alignH
            n.alignV = alignV
            n.mtextWidth = mtextWidth
            n.color = color
            return n
        default:
            return nil
        }
    }

    /// Split a (possibly wrapping) arc into non-wrapping [0, 2π) intervals.
    static func splitArcInterval(start: Double, sweep: Double) -> [(start: Double, sweep: Double)] {
        let twoPi = 2.0 * Double.pi
        let s = OverkillMath.positiveRemainder(start)
        if s + sweep <= twoPi + 1e-12 {
            return [(s, min(sweep, twoPi))]
        }
        return [(s, twoPi - s), (0, s + sweep - twoPi)]
    }

    // MARK: - Shape equality (exact duplicates)

    static func primsEqual(
        _ a: OverkillPrim, _ b: OverkillPrim,
        sigA: OverkillPropSig, sigB: OverkillPropSig,
        tol: Double, widthsIgnored: Bool
    ) -> Bool {
        // sigA/sigB already combine entity-level props with per-prim color.
        guard a.kind == b.kind, sigA == sigB else { return false }
        switch a.kind {
        case 0:
            return (OverkillMath.dist(a.p0, b.p0) <= tol && OverkillMath.dist(a.p1, b.p1) <= tol)
                || (OverkillMath.dist(a.p0, b.p1) <= tol && OverkillMath.dist(a.p1, b.p0) <= tol)
        case 1:
            return OverkillMath.dist(a.p0, b.p0) <= tol && abs(a.radius - b.radius) <= tol
        case 2:
            guard OverkillMath.dist(a.p0, b.p0) <= tol,
                  abs(a.radius - b.radius) <= tol,
                  abs(a.sweep - b.sweep) <= angleTol(radius: a.radius, tol: tol) else { return false }
            let aEnd = a.startAngle + a.sweep
            let bEnd = b.startAngle + b.sweep
            let fwd = angularDist(a.startAngle, b.startAngle, radius: a.radius) <= tol
                && angularDist(aEnd, bEnd, radius: a.radius) <= tol
            let rev = angularDist(a.startAngle, bEnd, radius: a.radius) <= tol
                && angularDist(aEnd, b.startAngle, radius: a.radius) <= tol
            return fwd || rev
        case 3:
            return polylinesEqual(a, b, tol: tol, widthsIgnored: widthsIgnored)
        case 4:
            return OverkillMath.dist(a.p0, b.p0) <= tol
                && a.text == b.text
                && abs(a.textHeight - b.textHeight) <= tol
                && angularDist(a.textRotation, b.textRotation, radius: 1.0) <= max(tol, 1e-9)
                && a.textStyle == b.textStyle
                && a.alignH == b.alignH && a.alignV == b.alignV
                && bothEqualWithin(a.mtextWidth, b.mtextWidth, tol: tol)
        default:
            return false
        }
    }

    static func angularDist(_ a: Double, _ b: Double, radius: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var d = abs(a - b).truncatingRemainder(dividingBy: twoPi)
        if d > Double.pi { d = twoPi - d }
        return d * radius
    }

    static func angleTol(radius: Double, tol: Double) -> Double {
        tol / max(radius, tol)
    }

    static func bothEqualWithin(_ a: Double?, _ b: Double?, tol: Double) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x - y) <= tol
        default: return false
        }
    }

    static func polylinesEqual(
        _ a: OverkillPrim, _ b: OverkillPrim, tol: Double, widthsIgnored: Bool
    ) -> Bool {
        guard a.polyClosed == b.polyClosed, a.polyCurve == b.polyCurve,
              a.polyVerts.count == b.polyVerts.count else { return false }
        let n = a.polyVerts.count
        if n == 0 { return true }
        func vertsEqual(_ x: OverkillPrim.OverkillPolyVert,
                        _ y: OverkillPrim.OverkillPolyVert) -> Bool {
            guard x.kind == y.kind,
                  OverkillMath.dist(x.p, y.p) <= tol,
                  abs(x.bulge - y.bulge) <= tol else { return false }
            if !widthsIgnored {
                guard abs(x.w0 - y.w0) <= tol, abs(x.w1 - y.w1) <= tol else { return false }
            }
            return true
        }
        // Open polylines: forward or reversed.
        if !a.polyClosed {
            let fwd = zip(a.polyVerts, b.polyVerts).allSatisfy(vertsEqual)
            if fwd { return true }
            return zip(a.polyVerts, b.polyVerts.reversed()).allSatisfy(vertsEqual)
        }
        // Closed: any rotation, either direction.
        for offset in 0..<n {
            var ok = true
            for i in 0..<n {
                if !vertsEqual(a.polyVerts[(offset + i) % n], b.polyVerts[i]) { ok = false; break }
            }
            if ok { return true }
            ok = true
            for i in 0..<n {
                if !vertsEqual(a.polyVerts[(offset - i + n * 2) % n], b.polyVerts[i]) { ok = false; break }
            }
            if ok { return true }
        }
        return false
    }

    static func shapesEqual(
        _ a: OverkillRecord, _ b: OverkillRecord,
        options: OverkillOptions, tol: Double
    ) -> Bool {
        let widthsIgnored = options.ignorePolylineWidths
        switch (a.shape, b.shape) {
        case (.single(let pa), .single(let pb)):
            let sigA = fullSig(entity: a.entity, primColor: pa.color, layer: a.layer, options: options)
            let sigB = fullSig(entity: b.entity, primColor: pb.color, layer: b.layer, options: options)
            return primsEqual(pa, pb, sigA: sigA, sigB: sigB,
                              tol: tol, widthsIgnored: widthsIgnored)
        case (.multi(let psA), .multi(let psB)):
            guard psA.count == psB.count, a.entitySig == b.entitySig else { return false }
            var unmatched = psB
            for pa in psA {
                let sigA = fullSig(entity: a.entity, primColor: pa.color, layer: a.layer, options: options)
                guard let hit = unmatched.firstIndex(where: { pb in
                    let sigB = fullSig(entity: b.entity, primColor: pb.color, layer: b.layer, options: options)
                    return primsEqual(pa, pb, sigA: sigA, sigB: sigB,
                                      tol: tol, widthsIgnored: widthsIgnored)
                }) else { return false }
                unmatched.remove(at: hit)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Main entry

    /// Compute the OVERKILL plan for `handles` (nil = all entities).
    /// Pure: reads the document, never mutates it.
    public static func plan(
        document: CADDocument, handles: Set<UUID>?, options: OverkillOptions
    ) -> OverkillPlan {
        let tol = options.effectiveTolerance
        var report = OverkillReport()

        // Referenced handles survive as the kept duplicate but are never
        // deleted or merged away.
        var referenced = Set<UUID>()
        for group in document.groups.values { referenced.formUnion(group.members) }
        for constraint in document.constraintsView {
            referenced.insert(constraint.entityA)
            if let b = constraint.entityB { referenced.insert(b) }
        }

        // Document-order records for in-scope entities.
        var records: [OverkillRecord] = []
        var indexByHandle: [UUID: Int] = [:]
        for entity in document.allEntities {
            if let scope = handles, !scope.contains(entity.handle) { continue }
            let order = records.count
            let (record, skip) = makeRecord(
                entity: entity, order: order, referenced: referenced,
                options: options, document: document)
            if let record {
                indexByHandle[entity.handle] = records.count
                records.append(record)
            } else {
                switch skip {
                case .lockedFrozen: report.skippedLockedFrozen += 1
                case .hidden: report.skippedHidden += 1
                case .projected: report.skippedProjected += 1
                case .block: report.skippedBlock += 1
                case .associative: report.skippedAssociative += 1
                case .unsupported, .none: report.skippedUnsupported += 1
                }
            }
        }

        passExactDuplicates(records: &records, options: options, tol: tol, report: &report)
        passCleanup(records: &records, options: options, tol: tol, report: &report)
        if options.optimizePolylineSegments {
            passCoverage(records: &records, options: options, tol: tol, report: &report)
        }
        if options.mergePartialOverlap || options.mergeEndToEnd {
            passMergeLines(records: &records, options: options, tol: tol, report: &report)
            passMergeArcs(records: &records, options: options, tol: tol, report: &report)
        }

        _ = indexByHandle
        return assemblePlan(records: records, report: report)
    }

    /// Staging for entities created during the passes (merges, rewrites).
    static var pendingAdditions: [CADEntity] = []

    static func assemblePlan(records: [OverkillRecord], report: OverkillReport) -> OverkillPlan {
        var remove = Set<UUID>()
        for record in records where record.consumed {
            remove.insert(record.entity.handle)
        }
        // New entities created by rewrites carry fresh handles, so the
        // original handles above are exactly the undo set.
        let plan = OverkillPlan(remove: remove, add: pendingAdditions, report: report)
        pendingAdditions.removeAll()
        return plan
    }

    // MARK: - Pass A: exact duplicates

    static func passExactDuplicates(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        var hash = OverkillHash(tolerance: tol)
        for i in records.indices {
            let (lo, hi) = shapeBox(records[i].shape)
            hash.insert(i, boxMin: lo, boxMax: hi, pad: tol)
        }
        for i in records.indices {
            if records[i].consumed { continue }
            let (lo, hi) = shapeBox(records[i].shape)
            var group: [Int] = [i]
            for j in hash.query(boxMin: lo, boxMax: hi, pad: tol) {
                if j <= i || records[j].consumed { continue }
                if shapesEqual(records[i], records[j], options: options, tol: tol) {
                    group.append(j)
                }
            }
            guard group.count > 1 else { continue }
            // Survivor: protected first, then document order. Protected
            // non-survivors are kept and counted as referenced skips.
            let sorted = group.sorted {
                if records[$0].isProtected != records[$1].isProtected {
                    return records[$0].isProtected
                }
                return records[$0].order < records[$1].order
            }
            for doomed in sorted.dropFirst() {
                if records[doomed].isProtected {
                    report.skippedReferenced += 1
                } else {
                    records[doomed].consumed = true
                    report.deletedDuplicates += 1
                }
            }
        }
    }

    // MARK: - Pass B: zero-length + arc-over-circle + polyline optimize

    static func passCleanup(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        // Index surviving circles for the arc-over-circle check.
        for i in records.indices {
            if records[i].consumed { continue }
            guard case .single(let prim) = records[i].shape else { continue }
            switch prim.kind {
            case 0 where OverkillMath.dist(prim.p0, prim.p1) <= tol:
                records[i].consumed = true
                report.cleanedUp += 1
            case 1 where prim.radius <= tol:
                records[i].consumed = true
                report.cleanedUp += 1
            case 2 where prim.radius * prim.sweep <= tol:
                records[i].consumed = true
                report.cleanedUp += 1
            case 4 where prim.text.isEmpty:
                records[i].consumed = true
                report.cleanedUp += 1
            default:
                break
            }
        }
        passArcOverCircle(records: &records, options: options, tol: tol, report: &report)
        passOptimizePolylines(records: &records, options: options, tol: tol, report: &report)
    }

    /// Delete arcs coincident with a same-property circle (the circle
    /// already draws them). A lone full-sweep arc becomes a circle.
    static func passArcOverCircle(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        let twoPi = 2.0 * Double.pi
        var circleIndices: [Int] = []
        for i in records.indices {
            if records[i].consumed { continue }
            if case .single(let prim) = records[i].shape, prim.kind == 1 {
                circleIndices.append(i)
            }
        }
        for i in records.indices {
            if records[i].consumed { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 2 else { continue }
            let sigA = fullSig(entity: records[i].entity, primColor: prim.color,
                               layer: records[i].layer, options: options)
            var covered = false
            for c in circleIndices {
                if records[c].consumed { continue }
                guard case .single(let circ) = records[c].shape else { continue }
                let sigC = fullSig(entity: records[c].entity, primColor: circ.color,
                                   layer: records[c].layer, options: options)
                if sigA == sigC,
                   OverkillMath.dist(prim.p0, circ.p0) <= tol,
                   abs(prim.radius - circ.radius) <= tol {
                    covered = true
                    break
                }
            }
            if covered {
                if records[i].isProtected {
                    report.skippedReferenced += 1
                } else {
                    records[i].consumed = true
                    report.cleanedUp += 1
                }
                continue
            }
            if prim.sweep >= twoPi - angleTol(radius: prim.radius, tol: tol) {
                // Full-sweep arc with no circle: rewrite as a circle.
                if records[i].isProtected {
                    report.skippedReferenced += 1
                    continue
                }
                let entity = records[i].entity
                let primColor: ColorRGBA?
                if case .single(let p) = records[i].shape { primColor = p.color } else { primColor = nil }
                let circle = CADEntity(
                    layerID: entity.layerID,
                    localGeometry: [.circle(center: prim.p0, radius: prim.radius, color: primColor)],
                    transform: .identity,
                    xdata: entity.xdata,
                    drawOrder: entity.drawOrder)
                records[i].consumed = true
                pendingAdditions.append(circle)
                report.mergedSources += 1
                report.unifiedCreated += 1
            }
        }
    }

    /// Collapse duplicate vertices and straight-run middle vertices inside
    /// polylines (world-space decisions, mapped back to local storage).
    /// Skipped entirely when `keepPolylinesIntact` is set.
    static func passOptimizePolylines(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        if options.keepPolylinesIntact { return }
        for i in records.indices {
            if records[i].consumed || records[i].isProtected { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 3 else { continue }
            guard let originalPath = polylinePath(of: records[i].entity),
                  originalPath.curveType == .none else { continue }
            let widthsIgnored = options.ignorePolylineWidths
            var verts = prim.polyVerts
            var changed = false
            // Drop duplicate consecutive vertices (straight, widthless runs).
            var kept: [OverkillPrim.OverkillPolyVert] = []
            for v in verts {
                if let last = kept.last,
                   OverkillMath.dist(last.p, v.p) <= tol,
                   abs(last.bulge) <= tol, abs(v.bulge) <= tol,
                   (widthsIgnored || (abs(last.w0) <= tol && abs(last.w1) <= tol
                        && abs(v.w0) <= tol && abs(v.w1) <= tol)) {
                    changed = true
                    continue
                }
                kept.append(v)
            }
            verts = kept
            // Closed loops: first/last within tolerance.
            if prim.polyClosed, verts.count > 1,
               let first = verts.first, let last = verts.last,
               OverkillMath.dist(first.p, last.p) <= tol,
               abs(first.bulge) <= tol, abs(last.bulge) <= tol {
                if widthsIgnored || (abs(first.w0) <= tol && abs(first.w1) <= tol
                        && abs(last.w0) <= tol && abs(last.w1) <= tol) {
                    verts.removeLast()
                    changed = true
                }
            }
            // Drop middle vertices on straight runs.
            if verts.count >= 3 {
                var slim: [OverkillPrim.OverkillPolyVert] = [verts[0]]
                for k in 1..<(verts.count - 1) {
                    let a = slim.last!
                    let m = verts[k]
                    let b = verts[k + 1]
                    if abs(a.bulge) <= tol, abs(m.bulge) <= tol,
                       (widthsIgnored || (abs(a.w0) <= tol && abs(a.w1) <= tol
                            && abs(m.w0) <= tol && abs(m.w1) <= tol)),
                       OverkillMath.distPointToSegment(m.p, a.p, b.p) <= tol {
                        changed = true
                        continue
                    }
                    slim.append(m)
                }
                slim.append(verts[verts.count - 1])
                verts = slim
            }
            let minVerts = 2
            if verts.count < minVerts {
                records[i].consumed = true
                report.cleanedUp += 1
                continue
            }
            if changed {
                // Rebuild from the ORIGINAL local vertices (no world/local
                // roundtrip error): only the dropped indices disappear.
                let newLocalVerts = verts.map { wv -> CADPolylineVertex in
                    let orig = originalPath.vertices[wv.origIdx]
                    return CADPolylineVertex(
                        position: orig.position, bulge: orig.bulge,
                        startWidth: orig.startWidth, endWidth: orig.endWidth,
                        kind: orig.kind, tangent: orig.tangent)
                }
                let newPath = CADPolyline(
                    vertices: newLocalVerts,
                    isClosed: originalPath.isClosed,
                    lineTypeGenerationEnabled: originalPath.lineTypeGenerationEnabled,
                    curveType: .none,
                    hatchEdges: [],
                    isHatchBoundaryCarrier: false,
                    hatchLoopType: originalPath.hatchLoopType,
                    hatchSourceBoundaryHandles: originalPath.hatchSourceBoundaryHandles)
                let oldEntity = records[i].entity
                let rebuilt = CADEntity(
                    layerID: oldEntity.layerID,
                    localGeometry: [.polyline(path: newPath, color: prim.color)],
                    transform: oldEntity.transform,
                    xdata: oldEntity.xdata,
                    drawOrder: oldEntity.drawOrder)
                records[i].consumed = true
                pendingAdditions.append(rebuilt)
                // The rewritten polyline re-enters the working set so later
                // passes (coverage, merge) see current geometry.
                if let rebuiltPath = polylinePath(of: rebuilt),
                   let newPrim = normalizePrim(
                       .polyline(path: rebuiltPath, color: prim.color),
                       transform: rebuilt.transform) {
                    var next = records[i]
                    next.entity = rebuilt
                    next.shape = .single(newPrim)
                    next.consumed = false
                    records.append(next)
                }
                report.optimizedPolylines += 1
            }
        }
    }

    // MARK: - Polyline helpers

    static func polylinePath(of entity: CADEntity) -> CADPolyline? {
        for prim in entity.localGeometry ?? [] {
            if case .polyline(let path, _) = prim { return path }
        }
        return nil
    }

    static func straightSegments(
        of prim: OverkillPrim, tol: Double, widthsIgnored: Bool
    ) -> [(a: Vector3, b: Vector3, width: Double)] {
        guard prim.kind == 3 else { return [] }
        let verts = prim.polyVerts
        guard verts.count >= 2 else { return [] }
        let count = prim.polyClosed ? verts.count : verts.count - 1
        var out: [(Vector3, Vector3, Double)] = []
        for s in 0..<count {
            let v0 = verts[s]
            let v1 = verts[(s + 1) % verts.count]
            guard abs(v0.bulge) <= tol else { continue }
            let w = max(abs(v0.w0), abs(v0.w1), abs(v1.w0), abs(v1.w1))
            if w > tol && !widthsIgnored { continue }
            out.append((v0.p, v1.p, w))
        }
        return out
    }

    // MARK: - Pass D: standalone-vs-polyline coverage

    /// Delete standalone lines fully covered by same-property straight
    /// polyline segments. Partially covered lines are kept and counted.
    static func passCoverage(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        let widthsIgnored = options.ignorePolylineWidths
        struct Seg {
            var a: Vector3; var b: Vector3
            var sig: OverkillPropSig
            var verts: [Vector3]
        }
        // Segments per polyline record.
        var polySegs: [Int: [Seg]] = [:]
        var polyHash = OverkillHash(tolerance: tol)
        for i in records.indices {
            if records[i].consumed { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 3 else { continue }
            let segs = straightSegments(of: prim, tol: tol, widthsIgnored: widthsIgnored)
            if segs.isEmpty { continue }
            let sig = fullSig(entity: records[i].entity, primColor: prim.color,
                              layer: records[i].layer, options: options)
            let (lo, hi) = shapeBox(records[i].shape)
            // Only width-eligible segments participate; sig is per polyline.
            var list: [Seg] = []
            for s in segs {
                list.append(Seg(a: s.a, b: s.b, sig: sig, verts: []))
                let slo = Vector3(x: min(s.a.x, s.b.x), y: min(s.a.y, s.b.y), z: min(s.a.z, s.b.z))
                let shi = Vector3(x: max(s.a.x, s.b.x), y: max(s.a.y, s.b.y), z: max(s.a.z, s.b.z))
                polyHash.insert(i, boxMin: slo, boxMax: shi, pad: tol)
            }
            polySegs[i] = list
            _ = (lo, hi)
        }
        if polySegs.isEmpty { return }

        for i in records.indices {
            if records[i].consumed || records[i].isProtected { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 0 else { continue }
            let len = OverkillMath.dist(prim.p0, prim.p1)
            if len <= tol { continue } // already handled
            let sig = fullSig(entity: records[i].entity, primColor: prim.color,
                              layer: records[i].layer, options: options)
            let (lo, hi) = shapeBox(records[i].shape)
            var owners: [Int] = []
            for pi in polyHash.query(boxMin: lo, boxMax: hi, pad: tol) {
                if records[pi].consumed { continue }
                if polySegs[pi] == nil { continue }
                if !owners.contains(pi) { owners.append(pi) }
            }
            if owners.isEmpty { continue }
            guard let dir = OverkillMath.normalized(prim.p1 - prim.p0) else { continue }
            // Try each candidate polyline: full coverage by its segments?
            var fullyCovered = false
            var everPartial = false
            for pi in owners {
                guard let list = polySegs[pi] else { continue }
                // Signature must match the polyline's own signature.
                if list.first?.sig != sig { continue }
                guard case .single(let pprim) = records[pi].shape else { continue }
                var ts: [Double] = [0, len]
                for v in pprim.polyVerts.map({ $0.p }) {
                    let t = OverkillMath.dot(v - prim.p0, dir)
                    if t >= -tol, t <= len + tol,
                       OverkillMath.distPointToSegment(v, prim.p0, prim.p1) <= tol {
                        ts.append(min(max(t, 0), len))
                    }
                }
                ts.sort()
                var cuts: [Double] = []
                for t in ts {
                    if let last = cuts.last, abs(last - t) <= tol { continue }
                    cuts.append(t)
                }
                if cuts.count < 2 { continue }
                var coveredPieces = 0
                var totalPieces = 0
                for k in 0..<(cuts.count - 1) {
                    let mid = prim.p0 + dir * ((cuts[k] + cuts[k + 1]) / 2.0)
                    totalPieces += 1
                    var hit = false
                    for s in list {
                        if OverkillMath.distPointToSegment(mid, s.a, s.b) <= tol {
                            hit = true
                            break
                        }
                    }
                    if hit { coveredPieces += 1 }
                }
                if totalPieces > 0, coveredPieces == totalPieces {
                    fullyCovered = true
                    break
                }
                if coveredPieces > 0 { everPartial = true }
            }
            if fullyCovered {
                records[i].consumed = true
                report.cleanedUp += 1
            } else if everPartial {
                report.skippedPartial += 1
            }
        }
    }

    // MARK: - Pass E: collinear line merging

    /// Merge overlapping or end-to-end collinear single lines sharing one
    /// effective-property signature into unified line entities.
    static func passMergeLines(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        // Seed every eligible single line.
        var groups: [OverkillPropSig: [Int]] = [:]
        for i in records.indices {
            if records[i].consumed || records[i].isProtected { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 0 else { continue }
            let len = OverkillMath.dist(prim.p0, prim.p1)
            if len <= tol { continue }
            guard let dir = OverkillMath.normalized(prim.p1 - prim.p0) else { continue }
            records[i].lineOrigin = prim.p0
            records[i].lineDir = dir
            records[i].lineS0 = 0
            records[i].lineS1 = len
            records[i].lineAbsorptions = 0
            records[i].linePropIdx = i
            let sig = fullSig(entity: records[i].entity, primColor: prim.color,
                              layer: records[i].layer, options: options)
            groups[sig, default: []].append(i)
        }
        for (_, members) in groups {
            if members.count < 2 { continue }
            mergeLineGroup(members, records: &records, options: options, tol: tol, report: &report)
        }
    }

    /// Greedy fixpoint absorption within one signature group.
    static func mergeLineGroup(
        _ members: [Int], records: inout [OverkillRecord],
        options: OverkillOptions, tol: Double, report: inout OverkillReport
    ) {
        var active = Set(members)
        var changed = true
        while changed {
            changed = false
            var hash = OverkillHash(tolerance: tol)
            for s in active {
                let a = records[s].lineOrigin + records[s].lineDir * records[s].lineS0
                let b = records[s].lineOrigin + records[s].lineDir * records[s].lineS1
                let lo = Vector3(x: min(a.x, b.x), y: min(a.y, b.y), z: min(a.z, b.z))
                let hi = Vector3(x: max(a.x, b.x), y: max(a.y, b.y), z: max(a.z, b.z))
                hash.insert(s, boxMin: lo, boxMax: hi, pad: tol)
            }
            let ordered = active.sorted()
            for r in ordered {
                if !active.contains(r) { continue }
                let ra = records[r].lineOrigin + records[r].lineDir * records[r].lineS0
                let rb = records[r].lineOrigin + records[r].lineDir * records[r].lineS1
                let lo = Vector3(x: min(ra.x, rb.x), y: min(ra.y, rb.y), z: min(ra.z, rb.z))
                let hi = Vector3(x: max(ra.x, rb.x), y: max(ra.y, rb.y), z: max(ra.z, rb.z))
                var absorbed = false
                for s in hash.query(boxMin: lo, boxMax: hi, pad: tol) {
                    if s == r || !active.contains(s) { continue }
                    if let union = mergeUnions(
                        seed: records[s], segA: ra, segB: rb,
                        options: options, tol: tol) {
                        records[s].lineS0 = union.0
                        records[s].lineS1 = union.1
                        records[s].lineAbsorptions += records[r].lineAbsorptions + 1
                        if records[r].order < records[records[s].linePropIdx].order {
                            records[s].linePropIdx = records[r].linePropIdx
                        }
                        records[r].consumed = true
                        active.remove(r)
                        changed = true
                        absorbed = true
                        break
                    }
                }
                _ = absorbed
            }
        }
        // Emit one unified line per seed that absorbed at least one partner.
        for s in active where records[s].lineAbsorptions > 0 {
            let prop = records[records[s].linePropIdx]
            let p0 = records[s].lineOrigin + records[s].lineDir * records[s].lineS0
            let p1 = records[s].lineOrigin + records[s].lineDir * records[s].lineS1
            var primColor: ColorRGBA?
            if case .single(let p) = prop.shape { primColor = p.color }
            let merged = CADEntity(
                layerID: prop.entity.layerID,
                localGeometry: [.line(start: p0, end: p1, color: primColor)],
                transform: .identity,
                xdata: prop.entity.xdata,
                drawOrder: prop.entity.drawOrder)
            records[s].consumed = true
            pendingAdditions.append(merged)
            report.mergedSources += records[s].lineAbsorptions + 1
            report.unifiedCreated += 1
        }
    }

    /// Merge candidate segment (a, b) into the seed union. Returns the new
    /// union interval on the seed axis, or nil when not mergeable under the
    /// enabled flags. Candidate endpoints may lie slightly off-axis (≤ tol).
    static func mergeUnions(
        seed: OverkillRecord, segA: Vector3, segB: Vector3,
        options: OverkillOptions, tol: Double
    ) -> (Double, Double)? {
        let axisLen = seed.lineS1 - seed.lineS0
        let candLen = OverkillMath.dist(segA, segB)
        guard axisLen > tol, candLen > tol else { return nil }
        guard let candDir = OverkillMath.normalized(segB - segA) else { return nil }
        let parallel = abs(OverkillMath.length(OverkillMath.cross(seed.lineDir, candDir)))
        if parallel > tol / max(axisLen, candLen) { return nil }
        // Perpendicular offset of both endpoints to the seed line.
        let offA = OverkillMath.length(OverkillMath.cross(segA - seed.lineOrigin, seed.lineDir))
        let offB = OverkillMath.length(OverkillMath.cross(segB - seed.lineOrigin, seed.lineDir))
        if offA > tol || offB > tol { return nil }
        let ta = OverkillMath.dot(segA - seed.lineOrigin, seed.lineDir)
        let tb = OverkillMath.dot(segB - seed.lineOrigin, seed.lineDir)
        let lo = min(seed.lineS0, ta, tb)
        let hi = max(seed.lineS1, ta, tb)
        let overlap = min(seed.lineS1, max(ta, tb)) - max(seed.lineS0, min(ta, tb))
        // Disjoint beyond tolerance: never bridge the gap.
        guard overlap >= -tol else { return nil }
        if overlap > tol {
            guard options.mergePartialOverlap else { return nil }
        } else {
            guard options.mergeEndToEnd else { return nil }
        }
        return (lo, hi)
    }

    // MARK: - Pass F: co-circular arc merging

    /// Merge overlapping or end-to-end arcs sharing center, radius, and
    /// effective properties. Full-circle coverage becomes a circle.
    static func passMergeArcs(
        records: inout [OverkillRecord], options: OverkillOptions,
        tol: Double, report: inout OverkillReport
    ) {
        // Group by signature first.
        var groups: [OverkillPropSig: [Int]] = [:]
        for i in records.indices {
            if records[i].consumed || records[i].isProtected { continue }
            guard case .single(let prim) = records[i].shape, prim.kind == 2 else { continue }
            if prim.radius * prim.sweep <= tol { continue }
            let sig = fullSig(entity: records[i].entity, primColor: prim.color,
                              layer: records[i].layer, options: options)
            groups[sig, default: []].append(i)
        }
        for (_, members) in groups {
            if members.count < 2 { continue }
            // Cluster by center + radius.
            var clusters: [[Int]] = []
            for m in members {
                guard case .single(let pm) = records[m].shape else { continue }
                var placed = false
                for c in clusters.indices {
                    guard case .single(let pc) = records[clusters[c][0]].shape else { continue }
                    if OverkillMath.dist(pm.p0, pc.p0) <= tol,
                       abs(pm.radius - pc.radius) <= tol {
                        clusters[c].append(m)
                        placed = true
                        break
                    }
                }
                if !placed { clusters.append([m]) }
            }
            for cluster in clusters {
                if cluster.count < 2 { continue }
                mergeArcCluster(cluster, records: &records, options: options, tol: tol, report: &report)
            }
        }
    }

    static func mergeArcCluster(
        _ cluster: [Int], records: inout [OverkillRecord],
        options: OverkillOptions, tol: Double, report: inout OverkillReport
    ) {
        let twoPi = 2.0 * Double.pi
        guard let firstIdx = cluster.first,
              case .single(let firstPrim) = records[firstIdx].shape else { return }
        let center = firstPrim.p0
        let radius = firstPrim.radius
        let aTol = angleTol(radius: radius, tol: tol)
        struct Piece { var start: Double; var sweep: Double; var member: Int }
        var pieces: [Piece] = []
        for m in cluster {
            guard case .single(let prim) = records[m].shape else { continue }
            for iv in splitArcInterval(start: prim.startAngle, sweep: prim.sweep) {
                pieces.append(Piece(start: iv.start, sweep: iv.sweep, member: m))
            }
        }
        // Sort and greedily merge touching/overlapping intervals.
        pieces.sort { $0.start < $1.start }
        struct Run { var start: Double; var end: Double; var members: Set<Int> }
        var runs: [Run] = []
        for piece in pieces {
            let pEnd = piece.start + piece.sweep
            if var last = runs.last, piece.start <= last.end + tol {
                let overlap = last.end - piece.start
                if overlap > tol, !options.mergePartialOverlap {
                    runs.append(Run(start: piece.start, end: pEnd, members: [piece.member]))
                    continue
                }
                if overlap <= tol, !options.mergeEndToEnd {
                    runs.append(Run(start: piece.start, end: pEnd, members: [piece.member]))
                    continue
                }
                last.end = max(last.end, pEnd)
                last.members.insert(piece.member)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(start: piece.start, end: pEnd, members: [piece.member]))
            }
        }
        let merged = runs.filter { $0.members.count > 1 }
        if merged.isEmpty { return }
        var consumedMembers = Set<Int>()
        for run in merged { consumedMembers.formUnion(run.members) }
        // Survivor props from the lowest-order consumed member.
        let propIdx = consumedMembers.sorted { records[$0].order < records[$1].order }.first!
        let prop = records[propIdx]
        var primColor: ColorRGBA?
        if case .single(let p) = prop.shape { primColor = p.color }
        for m in consumedMembers {
            records[m].consumed = true
            report.mergedSources += 1
        }
        if merged.count == 1,
           merged[0].end - merged[0].start >= twoPi - aTol {
            let circle = CADEntity(
                layerID: prop.entity.layerID,
                localGeometry: [.circle(center: center, radius: radius, color: primColor)],
                transform: .identity,
                xdata: prop.entity.xdata,
                drawOrder: prop.entity.drawOrder)
            pendingAdditions.append(circle)
            report.unifiedCreated += 1
            return
        }
        for run in merged {
            let start = OverkillMath.positiveRemainder(run.start)
            let end = start + (run.end - run.start)
            let arc = CADEntity(
                layerID: prop.entity.layerID,
                localGeometry: [.arc(center: center, radius: radius,
                                     startAngle: start, endAngle: end, color: primColor)],
                transform: .identity,
                xdata: prop.entity.xdata,
                drawOrder: prop.entity.drawOrder)
            pendingAdditions.append(arc)
            report.unifiedCreated += 1
        }
    }
}
