import Foundation
import ZephyrKernel

// =========================================================================
// MARK: - RegionMass (Step 3: MASSPROP engineering data)
// =========================================================================
//
// Closed-form polygon moments over tessellated loops (bulge arcs are
// linearized at `RegionBoolean.chordTolerance`, matching AREA semantics).
// Every integral is taken about the given UCS frame's origin: Ix = ∫y²dA,
// Iy = ∫x²dA, Pxy = ∫xy dA — the AutoCAD convention where the reported
// Ix/Iy/Pxy ride the current UCS and moving the UCS origin to the
// centroid yields centroidal values. Holes subtract. Multiple solids add
// (integrals are linear), so one pass serves single and multi-region
// reports. Principal moments transfer to the centroid first.

public struct RegionMassReport: Sendable {
    public var area: Double
    public var perimeter: Double
    public var centroid: Vector3
    public var bboxMin: Vector3
    public var bboxMax: Vector3
    /// Moments about the UCS origin: Ix = ∫y²dA, Iy = ∫x²dA.
    public var ixx: Double
    public var iyy: Double
    /// Product of inertia about the UCS origin: Pxy = ∫xy dA.
    public var ixy: Double
    /// Centroidal second moments and product.
    public var ixc: Double
    public var iyc: Double
    public var pxyc: Double
    /// Radii of gyration about the UCS axes: Rx = √(Ix/A).
    public var rxx: Double
    public var ryy: Double
    /// Principal moments about the centroid and the principal-axis angle
    /// (radians, CCW from the UCS X axis) of the I-maximum axis.
    public var princI: Double
    public var princJ: Double
    public var princAngle: Double

    public init(
        area: Double = 0, perimeter: Double = 0,
        centroid: Vector3 = .zero, bboxMin: Vector3 = .zero,
        bboxMax: Vector3 = .zero, ixx: Double = 0, iyy: Double = 0,
        ixy: Double = 0, ixc: Double = 0, iyc: Double = 0,
        pxyc: Double = 0, rxx: Double = 0, ryy: Double = 0,
        princI: Double = 0, princJ: Double = 0, princAngle: Double = 0
    ) {
        self.area = area
        self.perimeter = perimeter
        self.centroid = centroid
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
        self.ixx = ixx
        self.iyy = iyy
        self.ixy = ixy
        self.ixc = ixc
        self.iyc = iyc
        self.pxyc = pxyc
        self.rxx = rxx
        self.ryy = ryy
        self.princI = princI
        self.princJ = princJ
        self.princAngle = princAngle
    }
}

public enum RegionMass {

    /// Full mass report for one or more solids, expressed in `ucs`.
    /// Callers enforce the LT gates (region-only input, shared plane,
    /// coplanar-with-UCS for the inertia suite); this function integrates
    /// whatever closed loops it is given.
    public static func analyze(
        solids: [BooleanSolid], ucs: UCSDefinition
    ) -> RegionMassReport {
        var area2 = 0.0
        var fx = 0.0, fy = 0.0
        var ixx = 0.0, iyy = 0.0, ixy = 0.0
        var perimeter = 0.0
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var anyPoint = false

        func addRing(_ world: CADPolyline, sign: Double) {
            perimeter += RegionBoolean.exactPerimeter(of: world)
            let worldPts = RegionBoolean.tessellateRing(world)
            guard worldPts.count >= 3 else { return }
            // To UCS frame (planar rotation + translation).
            let pts = worldPts.map { w -> Vector3 in
                let local = ucs.toLocal(Point3d(x: w.x, y: w.y, z: w.z))
                return Vector3(x: local.x, y: local.y, z: 0)
            }
            var ring2 = 0.0
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                ring2 += p.x * q.y - q.x * p.y
            }
            guard abs(ring2) > 1e-18 else { return }
            // Positive-definite contribution regardless of winding.
            let orient: Double = ring2 >= 0 ? sign : -sign
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                let cross = (p.x * q.y - q.x * p.y) * orient
                area2 += cross
                fx += cross * (p.x + q.x)
                fy += cross * (p.y + q.y)
                ixx += cross * (p.y * p.y + p.y * q.y + q.y * q.y)
                iyy += cross * (p.x * p.x + p.x * q.x + q.x * q.x)
                ixy += cross
                    * (p.x * q.y + 2.0 * p.x * p.y
                        + 2.0 * q.x * q.y + q.x * p.y)
            }
            for p in pts {
                anyPoint = true
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
        }

        for solid in solids {
            addRing(solid.outer, sign: 1.0)
            for hole in solid.holes { addRing(hole, sign: -1.0) }
        }

        let area = max(0, area2 / 2.0)
        guard area > 1e-18, anyPoint else {
            return RegionMassReport()
        }
        let cx = fx / (3.0 * area2)
        let cy = fy / (3.0 * area2)
        let ix = ixx / 12.0
        let iy = iyy / 12.0
        let pxy = ixy / 24.0
        // Parallel-axis transfer to the centroid.
        let ixc = max(0, ix - area * cy * cy)
        let iyc = max(0, iy - area * cx * cx)
        let pxyc = pxy - area * cx * cy
        let rxx = sqrt(max(0, ix / area))
        let ryy = sqrt(max(0, iy / area))
        // Principal moments about the centroid.
        let avg = (ixc + iyc) / 2.0
        let half = (ixc - iyc) / 2.0
        let radius = (half * half + pxyc * pxyc).squareRoot()
        return RegionMassReport(
            area: area, perimeter: perimeter,
            centroid: Vector3(x: cx, y: cy, z: 0),
            bboxMin: Vector3(x: minX, y: minY, z: 0),
            bboxMax: Vector3(x: maxX, y: maxY, z: 0),
            ixx: ix, iyy: iy, ixy: pxy,
            ixc: ixc, iyc: iyc, pxyc: pxyc,
            rxx: rxx, ryy: ryy,
            princI: avg + radius, princJ: avg - radius,
            princAngle: 0.5 * atan2(-2.0 * pxyc, ixc - iyc))
    }

    /// Partition solids into the coplanar-with-first set (reported) and
    /// the skipped remainder, mirroring the LT multi-region rule.
    public static func partitionCoplanar(
        _ solids: [BooleanSolid]
    ) -> (kept: [BooleanSolid], skipped: Int) {
        guard let first = solids.first else { return ([], 0) }
        let firstZ = first.outer.vertices.first?.position.z ?? 0
        var kept: [BooleanSolid] = []
        var skipped = 0
        for solid in solids {
            let z = solid.outer.vertices.first?.position.z ?? 0
            if abs(z - firstZ) <= RegionBuilder.planarTolerance {
                kept.append(solid)
            } else {
                skipped += 1
            }
        }
        return (kept, skipped)
    }
}
