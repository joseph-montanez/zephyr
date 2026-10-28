import Foundation

// =========================================================================
// MARK: - MLINE styles (MLSTYLE) and bake math (MLINE draw)
// =========================================================================

/// One element of a multiline style: an offset from the centerline with
/// optional color/linetype overrides (DXF group 49/62/6).
public struct CADMlineElement: Hashable, Sendable, Codable {
    /// Offset in style units (group 49). Scaled by CMLSCALE at draw time.
    public var offset: Double
    /// ACI color (group 62). 256 = BYLAYER, 0 = BYBLOCK.
    public var colorACI: Int32
    /// Linetype name (group 6). Empty = BYLAYER.
    public var linetype: String

    public init(offset: Double, colorACI: Int32 = 256, linetype: String = "") {
        self.offset = offset
        self.colorACI = colorACI
        self.linetype = linetype
    }
}

/// A named multiline style (DXF MLINESTYLE object). Minimal v1 surface:
/// element offsets/colors/linetypes, fill, and cap angles.
public struct CADMlineStyle: Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    public var elements: [CADMlineElement]
    /// Fill on (MLINESTYLE flag bit 1).
    public var fillEnabled: Bool
    /// Fill ACI color (group 62 on the style). 256 = BYLAYER.
    public var fillColorACI: Int32
    /// Start/end cap angles in degrees (groups 51/52). 90 = straight caps.
    public var startAngle: Double
    public var endAngle: Double

    public init(
        name: String,
        description: String = "",
        elements: [CADMlineElement] = [],
        fillEnabled: Bool = false,
        fillColorACI: Int32 = 256,
        startAngle: Double = 90,
        endAngle: Double = 90
    ) {
        self.name = name
        self.description = description
        self.elements = elements
        self.fillEnabled = fillEnabled
        self.fillColorACI = fillColorACI
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    /// AutoCAD's STANDARD: two elements at +0.5/-0.5.
    public static let standard = CADMlineStyle(
        name: "Standard",
        description: "Standard",
        elements: [CADMlineElement(offset: 0.5), CADMlineElement(offset: -0.5)])
}

/// Pure multiline bake: centerline points become one line run per style
/// element (offset along the joint miter, scaled), plus straight end caps
/// and inner miter joints. Imported MLINEs keep their own bake path
/// (per-vertex file params); this math serves interactively drawn ones.
public enum MlineMath {
    /// Offsets shifted per justification: 0 top, 1 zero, 2 bottom.
    public static func justifiedOffsets(
        _ offsets: [Double], justification: Int
    ) -> [Double] {
        let shift: Double
        switch justification {
        case 0: shift = -(offsets.max() ?? 0)
        case 2: switch offsets.min() {
            case .some(let m): shift = -m
            case .none: shift = 0
            }
        default: shift = 0
        }
        return offsets.map { $0 + shift }
    }

    /// Bakes element line runs for a centerline. Points are model space;
    /// output matches the import bake's granularity (one `.line` per
    /// element per segment) so render/hit/snap behave identically.
    public static func bake(
        centerline: [Vector3],
        style: CADMlineStyle,
        scale: Double,
        justification: Int,
        closed: Bool
    ) -> [CADPrimitive] {
        guard centerline.count >= 2, !style.elements.isEmpty else { return [] }
        let offsets = justifiedOffsets(
            style.elements.map(\.offset), justification: justification
        ).map { $0 * scale }
        let points = closed ? (centerline + [centerline[0]]) : centerline
        let segmentCount = points.count - 1
        guard segmentCount >= 1 else { return [] }

        func normal(of direction: Vector3) -> Vector3 {
            let n = Vector3(x: -direction.y, y: direction.x, z: 0)
            return n.magnitudeSquared > 1e-18 ? n.normalized : Vector3(x: 0, y: 1, z: 0)
        }
        func miterDir(at index: Int) -> Vector3 {
            let prev = points[max(index - 1, 0)]
            let curr = points[index]
            let next = points[min(index + 1, points.count - 1)]
            let d0 = curr - prev
            let d1 = next - curr
            let n0 = d0.magnitudeSquared > 1e-18 ? normal(of: d0.normalized) : Vector3(x: 0, y: 1, z: 0)
            let n1 = d1.magnitudeSquared > 1e-18 ? normal(of: d1.normalized) : n0
            let sum = n0 + n1
            return sum.magnitudeSquared > 1e-18 ? sum.normalized : n0
        }
        // Element point rows: vertex -> element -> point.
        var rows: [[Vector3]] = []
        for i in points.indices {
            let miter = miterDir(at: i)
            let prev = points[max(i - 1, 0)]
            let curr = points[i]
            let next = points[min(i + 1, points.count - 1)]
            let refNormal: Vector3 = {
                let d = (i == 0 ? (next - curr) : (curr - prev))
                return d.magnitudeSquared > 1e-18 ? normal(of: d.normalized) : Vector3(x: 0, y: 1, z: 0)
            }()
            let cosHalf = max(abs(miter.dot(refNormal)), 1e-6)
            rows.append(offsets.map { curr + miter * ($0 / cosHalf) })
        }

        var primitives: [CADPrimitive] = []
        primitives.reserveCapacity(segmentCount * offsets.count + 4)
        for (elementIndex, element) in style.elements.enumerated() {
            let color: ColorRGBA? = (element.colorACI > 0 && element.colorACI < 256)
                ? DXFColorTable.aciToRGBA(element.colorACI, color24: -1)
                : nil
            for s in 0..<segmentCount {
                let a = rows[s][elementIndex]
                let b = rows[s + 1][elementIndex]
                if (b - a).magnitudeSquared > 1e-18 {
                    primitives.append(.line(start: a, end: b, color: color))
                }
            }
        }
        // Inner miter joints + straight end caps (arc caps deferred).
        if rows.count >= 2 {
            let first = rows[0], last = rows[rows.count - 1]
            if let lo = first.first, let hi = first.last,
               (hi - lo).magnitudeSquared > 1e-18, !closed {
                primitives.append(.line(start: lo, end: hi, color: nil))
            }
            if let lo = last.first, let hi = last.last,
               (hi - lo).magnitudeSquared > 1e-18, !closed {
                primitives.append(.line(start: lo, end: hi, color: nil))
            }
            if closed, let lo = first.first, let hi = first.last,
               (hi - lo).magnitudeSquared > 1e-18 {
                primitives.append(.line(start: lo, end: hi, color: nil))
            }
        }
        return primitives
    }

    /// Per-vertex export frame (direction/miter/normal) for MLINE DXF
    /// vertices. Shared by both writers so vertex math never diverges.
    public struct ExportFrame: Sendable {
        public var position: Vector3
        public var direction: Vector3
        public var miter: Vector3
    }

    public static func exportFrames(
        centerline: [Vector3], closed: Bool
    ) -> [ExportFrame] {
        guard centerline.count >= 2 else { return [] }
        func segDir(_ a: Vector3, _ b: Vector3) -> Vector3 {
            let d = b - a
            return d.magnitudeSquared > 1e-18 ? d.normalized
                : Vector3(x: 1, y: 0, z: 0)
        }
        func normal(of direction: Vector3) -> Vector3 {
            let n = Vector3(x: -direction.y, y: direction.x, z: direction.z)
            return n.magnitudeSquared > 1e-18 ? n.normalized
                : Vector3(x: 0, y: 1, z: 0)
        }
        let n = centerline.count
        return centerline.enumerated().map { i, p in
            let prev = centerline[(i + n - 1) % n]
            let next = centerline[(i + 1) % n]
            let dir: Vector3
            let miter: Vector3
            if closed {
                dir = segDir(p, next)
                let m = normal(of: segDir(prev, p)) + normal(of: dir)
                miter = m.magnitudeSquared > 1e-18 ? m.normalized
                    : normal(of: dir)
            } else if i == 0 {
                dir = segDir(p, next)
                miter = normal(of: dir)
            } else if i == n - 1 {
                dir = segDir(prev, p)
                miter = normal(of: dir)
            } else {
                dir = segDir(p, next)
                let m = normal(of: segDir(prev, p)) + normal(of: dir)
                miter = m.magnitudeSquared > 1e-18 ? m.normalized
                    : normal(of: dir)
            }
            return ExportFrame(position: p, direction: dir, miter: miter)
        }
    }

    /// Encodes a centerline for `dxf.mlineCenterline` xdata.
    public static func encodeCenterline(_ points: [Vector3]) -> String {
        points.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";")
    }

    /// Decodes `dxf.mlineCenterline` xdata; nil when malformed.
    public static func decodeCenterline(_ string: String) -> [Vector3]? {
        var points: [Vector3] = []
        for chunk in string.split(separator: ";") {
            let parts = chunk.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            points.append(Vector3(x: parts[0], y: parts[1], z: parts[2]))
        }
        return points.count >= 2 ? points : nil
    }
}
