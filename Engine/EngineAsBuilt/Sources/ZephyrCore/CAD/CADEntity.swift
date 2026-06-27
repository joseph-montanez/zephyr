import Foundation

// =========================================================================
// MARK: - CADEntity & CADPrimitive
//
// CADEntity: Represents a single entity in the CAD drawing — a line, circle,
// polyline, text, block reference (INSERT), etc. Each entity has a UUID handle,
// a layer assignment, a transform (position/rotation/scale), and an optional
// parent block ID (nil = top-level entity, non-nil = block reference).
//
// CADPrimitive: The low-level geometric primitives that form entity geometry.
// These are the building blocks used by the rendering bridge to produce GPU
// draw calls. Each primitive can optionally carry a ColorRGBA for entity-level
// color overrides (DXF BYOBJECT colors). Includes: point, line, rect, polygon,
// circle, arc, spline, text, ellipse, hatch, ray, and gradient types.

// =========================================================================
// MARK: - CADPrimitive
// =========================================================================

public struct CADPolylineVertex: Hashable, Sendable {
    public var position: Vector3
    public var bulge: Double
    public var startWidth: Double
    public var endWidth: Double

    public init(
        position: Vector3,
        bulge: Double = 0,
        startWidth: Double = 0,
        endWidth: Double = 0
    ) {
        self.position = position
        self.bulge = bulge
        self.startWidth = startWidth
        self.endWidth = endWidth
    }
}

public struct CADPolyline: Hashable, Sendable, RandomAccessCollection, MutableCollection {
    public typealias Index = Int
    public typealias Element = Vector3

    public var vertices: [CADPolylineVertex]
    public var isClosed: Bool
    public var lineTypeGenerationEnabled: Bool

    public init(
        vertices: [CADPolylineVertex],
        isClosed: Bool = false,
        lineTypeGenerationEnabled: Bool = false
    ) {
        self.vertices = vertices
        self.isClosed = isClosed
        self.lineTypeGenerationEnabled = lineTypeGenerationEnabled
    }

    public init(
        points: [Vector3],
        isClosed: Bool = false,
        lineTypeGenerationEnabled: Bool = false
    ) {
        self.vertices = points.map { CADPolylineVertex(position: $0) }
        self.isClosed = isClosed
        self.lineTypeGenerationEnabled = lineTypeGenerationEnabled
    }

    public var startIndex: Int { vertices.startIndex }
    public var endIndex: Int { vertices.endIndex }

    public func index(after i: Int) -> Int { vertices.index(after: i) }
    public func index(before i: Int) -> Int { vertices.index(before: i) }

    public subscript(position: Int) -> Vector3 {
        get { vertices[position].position }
        set { vertices[position].position = newValue }
    }

    public var points: [Vector3] { vertices.map(\.position) }
    public var hasBulges: Bool { vertices.contains { abs($0.bulge) > 1e-12 } }
    public var segmentCount: Int {
        guard vertices.count >= 2 else { return 0 }
        return isClosed ? vertices.count : vertices.count - 1
    }

    public func endVertexIndex(forSegment index: Int) -> Int {
        (index + 1) % vertices.count
    }

    public func point(onSegment index: Int, t: Double) -> Vector3 {
        guard index >= 0, index < segmentCount else { return .zero }
        let start = vertices[index]
        let end = vertices[endVertexIndex(forSegment: index)]
        let clampedT = Swift.max(0, Swift.min(1, t))
        guard abs(start.bulge) > 1e-12,
              let arc = arcParameters(forSegment: index)
        else {
            return Vector3(
                x: start.position.x + (end.position.x - start.position.x) * clampedT,
                y: start.position.y + (end.position.y - start.position.y) * clampedT,
                z: start.position.z + (end.position.z - start.position.z) * clampedT)
        }
        let angle = arc.startAngle + arc.sweep * clampedT
        return Vector3(
            x: arc.center.x + cos(angle) * arc.radius,
            y: arc.center.y + sin(angle) * arc.radius,
            z: start.position.z + (end.position.z - start.position.z) * clampedT)
    }

    public func segmentMidpoint(_ index: Int) -> Vector3 {
        point(onSegment: index, t: 0.5)
    }

    public func arcParameters(
        forSegment index: Int
    ) -> (center: Vector3, radius: Double, startAngle: Double, sweep: Double)? {
        guard index >= 0, index < segmentCount else { return nil }
        let start = vertices[index]
        let end = vertices[endVertexIndex(forSegment: index)]
        let bulge = start.bulge
        guard abs(bulge) > 1e-12 else { return nil }

        let dx = end.position.x - start.position.x
        let dy = end.position.y - start.position.y
        let chord = hypot(dx, dy)
        guard chord > 1e-12 else { return nil }

        let factor = (1.0 - bulge * bulge) / (4.0 * bulge)
        let center = Vector3(
            x: (start.position.x + end.position.x) * 0.5 - dy * factor,
            y: (start.position.y + end.position.y) * 0.5 + dx * factor,
            z: (start.position.z + end.position.z) * 0.5)
        let radius = chord * (1.0 + bulge * bulge) / (4.0 * abs(bulge))
        let startAngle = atan2(start.position.y - center.y, start.position.x - center.x)
        return (center, radius, startAngle, 4.0 * atan(bulge))
    }

    public func tessellatedPoints(segmentsPerRadian: Double = 12.0) -> [Vector3] {
        guard let first = vertices.first?.position else { return [] }
        guard segmentCount > 0 else { return [first] }

        var result: [Vector3] = [first]
        result.reserveCapacity(vertices.count + segmentCount * 4)
        for segment in 0..<segmentCount {
            if let arc = arcParameters(forSegment: segment) {
                let divisions = Swift.max(
                    4, Int(ceil(abs(arc.sweep) * segmentsPerRadian)))
                for step in 1...divisions {
                    result.append(point(
                        onSegment: segment,
                        t: Double(step) / Double(divisions)))
                }
            } else {
                result.append(vertices[endVertexIndex(forSegment: segment)].position)
            }
        }
        return result
    }

    public func boundingPoints() -> [Vector3] {
        var result = points
        let twoPi = 2.0 * Double.pi

        func positiveRemainder(_ angle: Double) -> Double {
            let value = angle.truncatingRemainder(dividingBy: twoPi)
            return value < 0 ? value + twoPi : value
        }

        for segment in 0..<segmentCount {
            guard let arc = arcParameters(forSegment: segment) else { continue }
            for quadrant in 0..<4 {
                let angle = Double(quadrant) * Double.pi / 2.0
                let distance = arc.sweep >= 0
                    ? positiveRemainder(angle - arc.startAngle)
                    : positiveRemainder(arc.startAngle - angle)
                if distance <= abs(arc.sweep) + 1e-12 {
                    result.append(Vector3(
                        x: arc.center.x + cos(angle) * arc.radius,
                        y: arc.center.y + sin(angle) * arc.radius,
                        z: arc.center.z))
                }
            }
        }
        return result
    }

    public var length: Double {
        var total = 0.0
        for segment in 0..<segmentCount {
            if let arc = arcParameters(forSegment: segment) {
                total += arc.radius * abs(arc.sweep)
            } else {
                let a = vertices[segment].position
                let b = vertices[endVertexIndex(forSegment: segment)].position
                total += hypot(b.x - a.x, b.y - a.y)
            }
        }
        return total
    }

    public func transformed(by transform: Transform3D) -> CADPolyline {
        let reversesOrientation = transform.scale.x * transform.scale.y < 0
        let widthScale = (abs(transform.scale.x) + abs(transform.scale.y)) * 0.5
        var result = self
        for index in result.vertices.indices {
            result.vertices[index].position = transform.transformPoint(result.vertices[index].position)
            result.vertices[index].startWidth *= widthScale
            result.vertices[index].endWidth *= widthScale
            if reversesOrientation {
                result.vertices[index].bulge = -result.vertices[index].bulge
            }
        }
        return result
    }
}

/// Geometric primitive types that can compose a block definition or local geometry.
/// Maps directly to what the rendering bridge can produce.
public enum CADPrimitive: Hashable, Sendable {
    case point(position: Vector3, color: ColorRGBA? = nil)
    case line(start: Vector3, end: Vector3, color: ColorRGBA? = nil)
    case rect(origin: Vector3, size: Vector3, color: ColorRGBA? = nil)     // width = size.x, height = size.y
    case fillRect(origin: Vector3, size: Vector3, color: ColorRGBA? = nil)
    case polygon(points: [Vector3], color: ColorRGBA? = nil)                // closed polygon outline
    case polyline(path: CADPolyline, color: ColorRGBA? = nil)
    case fillPolygon(points: [Vector3], color: ColorRGBA? = nil)            // closed filled polygon
    case fillComplexPolygon(outer: [Vector3], holes: [[Vector3]], color: ColorRGBA? = nil)
    case gradient(outer: [Vector3], holes: [[Vector3]], gradientName: String, angle: Double, color1: ColorRGBA, color2: ColorRGBA)
    case circle(center: Vector3, radius: Double, color: ColorRGBA? = nil)
    case arc(center: Vector3, radius: Double, startAngle: Double, endAngle: Double, color: ColorRGBA? = nil)
    case spline(controlPoints: [Vector3], knots: [Double], degree: Int, weights: [Double]?, color: ColorRGBA? = nil)
    case text(
        position: Vector3,
        text: String,
        height: Double,
        rotation: Double,
        style: String?,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?,
        color: ColorRGBA? = nil
    )
    case ellipse(center: Vector3, majorAxis: Vector3, minorRatio: Double, color: ColorRGBA? = nil)
    case hatch(boundary: [Vector3], pattern: String, scale: Double, angle: Double, color: ColorRGBA? = nil, backgroundColor: ColorRGBA? = nil)
    case ray(start: Vector3, direction: Vector3, color: ColorRGBA? = nil)
    case image(
        insertion: Vector3,
        uAxis: Vector3,
        vAxis: Vector3,
        imageName: String,
        clipBoundary: [Vector3]? = nil,
        tint: ColorRGBA? = nil
    )

    public static func polyline(
        points: [Vector3], color: ColorRGBA? = nil
    ) -> CADPrimitive {
        .polyline(path: CADPolyline(points: points), color: color)
    }
    /// Convenience initializer that creates an `.image` primitive from center, size, and rotation.
    /// The image is placed as a quad centered at `center`, with `width`×`height` in world units,
    /// rotated by `rotation` radians around its center.
    public static func image(
        center: Vector3,
        width: Double,
        height: Double,
        rotation: Double = 0,
        imageName: String,
        clipBoundary: [Vector3]? = nil,
        tint: ColorRGBA? = nil
    ) -> CADPrimitive {
        let halfW = width / 2
        let halfH = height / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let uAxis = Vector3(x: cosR * width, y: sinR * width, z: 0)
        let vAxis = Vector3(x: -sinR * height, y: cosR * height, z: 0)
        let insertion = Vector3(
            x: center.x - halfW * cosR + halfH * sinR,
            y: center.y - halfW * sinR - halfH * cosR,
            z: center.z
        )
        return .image(
            insertion: insertion,
            uAxis: uAxis,
            vAxis: vAxis,
            imageName: imageName,
            clipBoundary: clipBoundary,
            tint: tint
        )
    }
}

// =========================================================================
// MARK: - Layer
// =========================================================================

/// A drafting layer definition. Stored in the LayerTable.
public struct Layer: Hashable, Sendable {
    public let handle: UUID
    public var name: String
    public var isVisible: Bool
    public var lineWeight: Double          // mm
    public var color: ColorRGBA
    public var lineType: String
    /// Layer opacity 0.0 (fully transparent) to 1.0 (fully opaque).
    /// DXF group code 440. Rendered as an extra multiplier on color.a.
    public var opacity: Double

    public init(handle: UUID = UUID(),
                name: String,
                isVisible: Bool = true,
                lineWeight: Double = 0.25,
                color: ColorRGBA = .white,
                lineType: String = "CONTINUOUS",
                opacity: Double = 1.0) {
        self.handle = handle
        self.name = name
        self.isVisible = isVisible
        self.lineWeight = lineWeight
        self.color = color
        self.lineType = lineType
        self.opacity = max(0.0, min(1.0, opacity))
    }
}

// =========================================================================
// MARK: - CADBlock
// =========================================================================

/// A block definition — shared geometry referenced by entity instances.
public struct CADBlock: Hashable, Sendable {
    public let handle: UUID
    public var name: String
    public var geometry: [CADPrimitive]

    /// Computed ONCE when the block is created or its geometry changes.
    /// Entity instances transform 8 corners of this box instead of iterating raw geometry — O(1).
    public internal(set) var localBoundingBox: BoundingBox3D

    public init(handle: UUID = UUID(),
                name: String,
                geometry: [CADPrimitive]) {
        self.handle = handle
        self.name = name
        self.geometry = geometry
        self.localBoundingBox = CADBlock.computeBoundingBox(from: geometry)
    }

    /// Recompute the cached bounding box (call after mutating geometry).
    public mutating func updateBoundingBox() {
        self.localBoundingBox = CADBlock.computeBoundingBox(from: geometry)
    }

    /// Compute an AABB from block primitives — called once, never per-instance.
    static func computeBoundingBox(from primitives: [CADPrimitive]) -> BoundingBox3D {
        var points: [Vector3] = []
        for p in primitives {
            switch p {
            case .point(let pos, _):
                points.append(pos)
            case .line(let start, let end, _):
                points.append(start); points.append(end)
            case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
                points.append(origin)
                points.append(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
                points.append(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
                points.append(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            case .polygon(let pts, _), .fillPolygon(let pts, _):
                points.append(contentsOf: pts)
            case .polyline(let path, _):
                points.append(contentsOf: path.boundingPoints())
            case .fillComplexPolygon(let outer, _, _):
                points.append(contentsOf: outer)
            case .gradient(let outer, _, _, _, _, _):
                points.append(contentsOf: outer)
            case .circle(let center, let radius, _):
                // AABB of a circle: center ± radius
                points.append(Vector3(x: center.x - radius, y: center.y - radius, z: center.z))
                points.append(Vector3(x: center.x + radius, y: center.y + radius, z: center.z))
            case .arc(let center, let radius, _, _, _):
                // Conservative: full circle AABB
                points.append(Vector3(x: center.x - radius, y: center.y - radius, z: center.z))
                points.append(Vector3(x: center.x + radius, y: center.y + radius, z: center.z))
            case .spline(let controlPoints, _, _, _, _):
                // Conservative AABB from control points convex hull
                points.append(contentsOf: controlPoints)
            case .text(let pos, let text, let height, _, _, let alignH, let alignV, let mtextWidth, _):
                let bounds = CADEntity.estimateTextLocalBounds(
                    text: text,
                    height: height,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: mtextWidth
                )
                points.append(Vector3(x: pos.x + bounds.minX, y: pos.y + bounds.minY, z: pos.z))
                points.append(Vector3(x: pos.x + bounds.maxX, y: pos.y + bounds.maxY, z: pos.z))
            case .ellipse(let center, let majorAxis, let minorRatio, _):
                let halfMajor = majorAxis.magnitude
                let halfMinor = halfMajor * minorRatio
                // Correct AABB for rotated ellipse.
                // The extent along each axis is the projection of the ellipse radii
                // onto that axis: sqrt(a²cos²θ + b²sin²θ) for x, sqrt(a²sin²θ + b²cos²θ) for y.
                let angle = atan2(majorAxis.y, majorAxis.x)
                let cosA = cos(angle)
                let sinA = sin(angle)
                let extentX = sqrt(halfMajor * halfMajor * cosA * cosA + halfMinor * halfMinor * sinA * sinA)
                let extentY = sqrt(halfMajor * halfMajor * sinA * sinA + halfMinor * halfMinor * cosA * cosA)
                points.append(Vector3(x: center.x - extentX, y: center.y - extentY, z: center.z))
                points.append(Vector3(x: center.x + extentX, y: center.y + extentY, z: center.z))
            case .hatch(let boundary, _, _, _, _, _):
                points.append(contentsOf: boundary)
            case .ray(let start, _, _):
                points.append(start)
            case .image(let insertion, let uAxis, let vAxis, _, _, _):
                points.append(insertion)
                points.append(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
                points.append(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
                points.append(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            }
        }
        return points.isEmpty ? BoundingBox3D() : BoundingBox3D(from: points)
    }
}

// =========================================================================
// MARK: - CADEntity
// =========================================================================

/// A CAD entity instance. This is a **struct** — snapshots capture independent value copies,
/// guaranteeing undo/redo integrity. Conforms to Entity, Snappable, and AttributeAttachable.
///
/// ## World bounding-box cache
/// `worldBoundingBox` used to recompute `BoundingBox3D(transforming:by:)` on *every* access,
/// which dominated hit-testing and grid rebuilds at 153k entities. It is now cached in
/// `_cachedWorldBB` and refreshed automatically whenever `transform` or `localBoundingBox`
/// changes (via `didSet`). Because the cache is a deterministic function of those two stored
/// properties, value-semantic snapshots (undo/redo) remain correct: a copied entity carries a
/// correct, in-sync cache. Reading `worldBoundingBox` is now a single field load — safe to call
/// from `let`-bound iteration (`for entity in document.entitiesView`).
public struct CADEntity: Entity, Snappable, AttributeAttachable, Hashable, Sendable {
    public let handle: UUID
    public var layerID: UUID
    /// Non-nil = block instance (references BlockTable). Nil + localGeometry = raw loose geometry.
    public var blockID: UUID?
    /// Non-nil = raw loose geometry (used when blockID is nil).
    public var localGeometry: [CADPrimitive]?

    public var transform: Transform3D {
        didSet { refreshWorldBoundingBox() }
    }

    public var xdata: [String: XDataValue]

    /// Draw order for this entity. Lower values are drawn first (back), higher values
    /// are drawn later (front). `Int.max` (default) means "no explicit order" — the
    /// entity sorts after all entities with an explicit order.
    public var drawOrder: Int = Int.max

    // MARK: Spatial proxy (cached in local space, world-space derived via transform)

    /// Cached local-space bounding box — computed once at creation, never per-frame.
    public internal(set) var localBoundingBox: BoundingBox3D? {
        didSet { refreshWorldBoundingBox() }
    }

    /// Cached **world-space** bounding box. Derived from `localBoundingBox` × `transform`,
    /// refreshed by the `didSet` observers above. Never set directly.
    private var _cachedWorldBB: BoundingBox3D?

    /// Cached local-space anchor points.
    public private(set) var anchorPoints: [AnchorPoint]

    /// Estimate local space bounding box of text based on characters and alignment/wrapping.
    public static func estimateTextLocalBounds(
        text: String,
        height: Double,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?
    ) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        if text.isEmpty { return (0, 0, 0, 0) }
        
        let paragraphs = text.components(separatedBy: "\n")
        var numLines = paragraphs.count
        
        // If mtextWidth is provided, the text might wrap.
        // As a conservative estimate for wrapping, let's assume we might have more lines
        // if the total length exceeds the width.
        let avgCharWidth = height * 0.6
        let estimatedTotalWidth = avgCharWidth * Double(text.count)
        if let maxW = mtextWidth, maxW > 0 {
            let wrappedLines = Int(ceil(estimatedTotalWidth / maxW))
            numLines = max(numLines, wrappedLines)
        }
        
        let localLineSpacing = 1.666 * height
        let blockOffsetY: Double
        switch alignV {
        case 1: // Bottom
            blockOffsetY = Double(numLines - 1) * localLineSpacing + 0.2 * height
        case 2: // Middle
            blockOffsetY = 0.5 * Double(numLines - 1) * localLineSpacing - 0.4 * height
        case 3: // Top
            blockOffsetY = -height
        default: // Baseline (0)
            blockOffsetY = Double(numLines - 1) * localLineSpacing
        }
        
        let minY = -(blockOffsetY + height)
        let maxY = -(blockOffsetY - Double(numLines - 1) * localLineSpacing)
        
        let W = mtextWidth ?? estimatedTotalWidth
        let minX: Double
        let maxX: Double
        switch alignH {
        case 1, 4: // Center/Middle
            minX = -0.5 * W
            maxX = 0.5 * W
        case 2: // Right
            minX = -W
            maxX = 0
        default: // Left
            minX = 0
            maxX = W
        }
        
        return (minX, maxX, minY, maxY)
    }

    // MARK: Init

    public init(handle: UUID = UUID(),
                layerID: UUID,
                blockID: UUID? = nil,
                localGeometry: [CADPrimitive]? = nil,
                transform: Transform3D = .identity,
                xdata: [String: XDataValue] = [:],
                drawOrder: Int = Int.max,
                localBoundingBox: BoundingBox3D? = nil,
                anchorPoints: [AnchorPoint] = []) {
        self.handle = handle
        self.layerID = layerID
        self.blockID = blockID
        self.localGeometry = localGeometry
        self.transform = transform
        self.xdata = xdata
        self.drawOrder = drawOrder
        self.localBoundingBox = localBoundingBox ?? CADEntity.computeLocalBoundingBox(
            blockID: blockID, localGeometry: localGeometry)
        self.anchorPoints = anchorPoints

        // didSet does not fire during initialization, so seed the world-box cache explicitly
        // once all stored properties are initialized.
        self._cachedWorldBB = nil
        self._cachedWorldBB = self.localBoundingBox.map {
            BoundingBox3D(transforming: $0, by: self.transform)
        }

        if anchorPoints.isEmpty {
            self.updateAnchorCache()
        }
    }

    // MARK: World-space derived properties

    /// Recompute and store the world-space bounding box from the current
    /// `localBoundingBox` and `transform`. Cheap now that `transformPoint` is allocation-free.
    @inline(__always)
    private mutating func refreshWorldBoundingBox() {
        _cachedWorldBB = localBoundingBox.map {
            BoundingBox3D(transforming: $0, by: transform)
        }
    }

    /// World-space bounding box. O(1) cached read — transforms are folded in on mutation,
    /// not on access.
    public var worldBoundingBox: BoundingBox3D? { _cachedWorldBB }

    // MARK: Geometry resolution

    /// Effective geometry: resolves block definition or returns local primitives.
    public func resolvedGeometry(in document: CADDocument) -> [CADPrimitive]? {
        if let bid = blockID, let block = document.block(for: bid) {
            return block.geometry
        }
        return localGeometry
    }

    // MARK: Snappable

    public mutating func updateAnchorCache() {
        // Geometry-derived anchors: real endpoints, midpoints, centers, and
        // quadrants that actually lie ON the drawn geometry. The old
        // implementation derived anchors purely from the bounding box, which
        // only worked by coincidence for lines and rectangles (a line's
        // endpoints are two of its bbox corners). For arcs, none of the bbox
        // corners or edge midpoints lie on the curve, so arcs had no usable
        // snap points at all.
        if let geometry = localGeometry, !geometry.isEmpty {
            if geometry.count > 100 {
                updateAnchorCacheFromBoundingBox()
                return
            }
            anchorPoints = CADEntity.computeAnchorPoints(from: geometry)
            return
        }
        updateAnchorCacheFromBoundingBox()
    }

    /// Anchor generation from explicit geometry — used for block instances,
    /// whose geometry lives in the shared block definition (already in the
    /// instance's local space) rather than in `localGeometry`.
    public mutating func updateAnchorCache(from geometry: [CADPrimitive]) {
        guard !geometry.isEmpty else {
            updateAnchorCacheFromBoundingBox()
            return
        }
        if geometry.count > 100 {
            updateAnchorCacheFromBoundingBox()
            return
        }
        anchorPoints = CADEntity.computeAnchorPoints(from: geometry)
    }

    /// Legacy fallback: bounding-box derived anchors (corners, center, edge
    /// midpoints). Only used when no geometry is available.
    private mutating func updateAnchorCacheFromBoundingBox() {
        guard let local = localBoundingBox else {
            anchorPoints = []
            return
        }
        let corners = local.corners
        let c = local.center

        var pts: [AnchorPoint] = []
        // 4 corner vertices
        for i in 0..<4 {
            pts.append(.vertex(localPosition: corners[i], index: i))
        }
        // Center
        pts.append(.center(localPosition: c))
        // 4 edge midpoints (top, right, bottom, left edges in XY plane)
        let topMid = Vector3(x: c.x, y: local.max.y, z: c.z)
        let rightMid = Vector3(x: local.max.x, y: c.y, z: c.z)
        let bottomMid = Vector3(x: c.x, y: local.min.y, z: c.z)
        let leftMid = Vector3(x: local.min.x, y: c.y, z: c.z)
        pts.append(.midpoint(localPosition: topMid, segmentIndex: 0))
        pts.append(.midpoint(localPosition: rightMid, segmentIndex: 1))
        pts.append(.midpoint(localPosition: bottomMid, segmentIndex: 2))
        pts.append(.midpoint(localPosition: leftMid, segmentIndex: 3))
        // Insertion point = origin
        pts.append(.insertionPoint(localPosition: .zero))

        anchorPoints = pts
    }

    /// Compute snap anchors directly from primitive geometry (local space).
    /// Vertex and segment indices run continuously across the whole entity,
    /// matching the global indexing convention used by the grip system.
    internal static func computeAnchorPoints(from geometry: [CADPrimitive]) -> [AnchorPoint] {
        var pts: [AnchorPoint] = []
        var vertexIdx = 0
        var segmentIdx = 0

        func addVertex(_ p: Vector3) {
            pts.append(.vertex(localPosition: p, index: vertexIdx))
            vertexIdx += 1
        }
        func addMidpoint(_ p: Vector3) {
            pts.append(.midpoint(localPosition: p, segmentIndex: segmentIdx))
            segmentIdx += 1
        }
        /// Vertices + segment midpoints for a point chain. Closed chains also
        /// get the closing segment's midpoint.
        func addChain(_ chain: [Vector3], closed: Bool) {
            guard !chain.isEmpty else { return }
            for p in chain { addVertex(p) }
            guard chain.count >= 2 else { return }
            for i in 0..<(chain.count - 1) {
                addMidpoint(Vector3(
                    x: (chain[i].x + chain[i + 1].x) / 2,
                    y: (chain[i].y + chain[i + 1].y) / 2,
                    z: (chain[i].z + chain[i + 1].z) / 2))
            }
            if closed, chain.count >= 3, let first = chain.first, let last = chain.last {
                addMidpoint(Vector3(
                    x: (last.x + first.x) / 2,
                    y: (last.y + first.y) / 2,
                    z: (last.z + first.z) / 2))
            }
        }
        func pointOnCircle(_ center: Vector3, _ radius: Double, _ angle: Double) -> Vector3 {
            Vector3(x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z)
        }

        for prim in geometry {
            switch prim {
            case .point(let position, _):
                addVertex(position)

            case .line(let start, let end, _):
                addVertex(start)
                addVertex(end)
                addMidpoint(Vector3(x: (start.x + end.x) / 2,
                                    y: (start.y + end.y) / 2,
                                    z: (start.z + end.z) / 2))

            case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
                let corners = [
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                ]
                addChain(corners, closed: true)
                pts.append(.center(localPosition: Vector3(
                    x: origin.x + size.x / 2, y: origin.y + size.y / 2, z: origin.z)))

            case .polyline(let path, _):
                for vertex in path.vertices { addVertex(vertex.position) }
                for segment in 0..<path.segmentCount {
                    addMidpoint(path.segmentMidpoint(segment))
                }

            case .polygon(let points, _), .fillPolygon(let points, _):
                addChain(points, closed: true)

            case .fillComplexPolygon(let outer, let holes, _):
                addChain(outer, closed: true)
                for hole in holes { addChain(hole, closed: true) }

            case .gradient(let outer, let holes, _, _, _, _):
                addChain(outer, closed: true)
                for hole in holes { addChain(hole, closed: true) }

            case .circle(let center, let radius, _):
                pts.append(.center(localPosition: center))
                for q in 0..<4 {
                    pts.append(.quadrant(
                        localPosition: pointOnCircle(center, radius, Double(q) * .pi / 2),
                        index: q))
                }

            case .arc(let center, let radius, let startAngle, let endAngle, _):
                var span = endAngle - startAngle
                if span < 0 { span += 2.0 * .pi }
                addVertex(pointOnCircle(center, radius, startAngle))              // start
                addVertex(pointOnCircle(center, radius, startAngle + span))       // end
                addMidpoint(pointOnCircle(center, radius, startAngle + span / 2)) // arc midpoint
                pts.append(.center(localPosition: center))
                // Quadrant points (0°/90°/180°/270°) that lie on the sweep give
                // additional on-curve snaps, skipping ones that duplicate the
                // start/end anchors.
                for q in 0..<4 {
                    let qa = Double(q) * .pi / 2
                    guard CADGeometryMath.angleIsOnCCWSweep(
                        angle: qa, start: startAngle, end: startAngle + span) else { continue }
                    let twoPi = 2.0 * Double.pi
                    var fromStart = (qa - startAngle).truncatingRemainder(dividingBy: twoPi)
                    if fromStart < 0 { fromStart += twoPi }
                    if fromStart < 1e-6 || abs(fromStart - span) < 1e-6 { continue }
                    pts.append(.quadrant(
                        localPosition: pointOnCircle(center, radius, qa), index: q))
                }

            case .spline(let controlPoints, _, _, _, _):
                // Control points are the grip points; for clamped NURBS the
                // first and last lie on the curve.
                for cp in controlPoints { addVertex(cp) }

            case .text(let position, _, _, _, _, _, _, _, _):
                pts.append(.insertionPoint(localPosition: position))

            case .ellipse(let center, let majorAxis, let minorRatio, _):
                pts.append(.center(localPosition: center))
                let halfMajor = majorAxis.magnitude
                guard halfMajor > 1e-12 else { break }
                let dir = Vector3(x: majorAxis.x / halfMajor, y: majorAxis.y / halfMajor, z: 0)
                let perp = Vector3(x: -dir.y, y: dir.x, z: 0)
                let halfMinor = halfMajor * minorRatio
                pts.append(.quadrant(localPosition: Vector3(
                    x: center.x + dir.x * halfMajor, y: center.y + dir.y * halfMajor, z: center.z), index: 0))
                pts.append(.quadrant(localPosition: Vector3(
                    x: center.x + perp.x * halfMinor, y: center.y + perp.y * halfMinor, z: center.z), index: 1))
                pts.append(.quadrant(localPosition: Vector3(
                    x: center.x - dir.x * halfMajor, y: center.y - dir.y * halfMajor, z: center.z), index: 2))
                pts.append(.quadrant(localPosition: Vector3(
                    x: center.x - perp.x * halfMinor, y: center.y - perp.y * halfMinor, z: center.z), index: 3))

            case .hatch(let boundary, _, _, _, _, _):
                addChain(boundary, closed: true)

            case .ray(let start, _, _):
                addVertex(start)
            case .image(let insertion, let uAxis, let vAxis, _, _, _):
                pts.append(.insertionPoint(localPosition: insertion))
                // 4 corners
                let c0 = insertion
                let c1 = Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z)
                let c2 = Vector3(x: c1.x + vAxis.x, y: c1.y + vAxis.y, z: c1.z + vAxis.z)
                let c3 = Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z)
                addVertex(c0)
                addVertex(c1)
                addVertex(c2)
                addVertex(c3)
                // Center
                pts.append(.center(localPosition: Vector3(
                    x: (c0.x + c2.x) / 2, y: (c0.y + c2.y) / 2, z: (c0.z + c2.z) / 2)))
                // 4 edge midpoints
                addMidpoint(Vector3(x: (c0.x + c1.x) / 2, y: (c0.y + c1.y) / 2, z: (c0.z + c1.z) / 2))
                addMidpoint(Vector3(x: (c1.x + c2.x) / 2, y: (c1.y + c2.y) / 2, z: (c1.z + c2.z) / 2))
                addMidpoint(Vector3(x: (c2.x + c3.x) / 2, y: (c2.y + c3.y) / 2, z: (c2.z + c3.z) / 2))
                addMidpoint(Vector3(x: (c3.x + c0.x) / 2, y: (c3.y + c0.y) / 2, z: (c3.z + c0.z) / 2))
            }
        }

        return pts
    }

    // MARK: Utilities

    /// Recompute local bounding box when geometry changes (call from document mutations).
    /// Assigning `localBoundingBox` triggers the world-box cache refresh automatically.
    public mutating func updateLocalBoundingBox(fromBlock block: CADBlock?) {
        if let b = block, blockID == b.handle {
            localBoundingBox = b.localBoundingBox
        } else {
            localBoundingBox = CADEntity.computeLocalBoundingBox(
                blockID: blockID, localGeometry: localGeometry)
        }
    }

    public static func computeLocalBoundingBox(
        blockID: UUID?, localGeometry: [CADPrimitive]?) -> BoundingBox3D? {
        if let geom = localGeometry, !geom.isEmpty {
            return CADBlock.computeBoundingBox(from: geom)
        }
        // Block geometry is resolved elsewhere; localBoundingBox will be set from the block.
        return nil
    }
}