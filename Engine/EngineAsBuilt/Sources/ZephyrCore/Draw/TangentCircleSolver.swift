import Foundation

/// Infinite-line / full-circle support used for tangent-circle solves.
/// Finite-domain (segment / arc / ray) validation is applied after the
/// candidate centers are found, so the solver operates on infinite supports.
public enum TangentSupport2: Sendable, Equatable {
    case line(origin: Vector3, directionUnit: Vector3)
    case circle(center: Vector3, radius: Double)
}

/// Finite extent validation for a tangent pick.
public struct FiniteTangentSupport: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        case infiniteLine
        case segment(start: Vector3, end: Vector3)
        case ray(origin: Vector3, direction: Vector3)
        case fullCircle
        case arc(center: Vector3, radius: Double, start: Double, sweep: Double)
    }
    public var infinite: TangentSupport2
    public var shape: Shape

    public init(infinite: TangentSupport2, shape: Shape) {
        self.infinite = infinite
        self.shape = shape
    }

    public func containsTangentPoint(_ p: Vector3) -> Bool {
        switch shape {
        case .infiniteLine, .fullCircle:
            return true
        case .segment(let a, let b):
            let d = b - a
            let lenSq = d.x*d.x + d.y*d.y
            if lenSq < 1e-12 { return p.distance(to: a) < 1e-6 }
            let t = ((p.x - a.x)*d.x + (p.y - a.y)*d.y) / lenSq
            return t >= -1e-6 && t <= 1 + 1e-6
        case .ray(let o, let d):
            let t = (p.x - o.x)*d.x + (p.y - o.y)*d.y
            return t >= -1e-6
        case .arc(let c, _, let start, let sweep):
            let angle = atan2(p.y - c.y, p.x - c.x)
            // normalized sweep check
            let twoPi = 2*Double.pi
            func norm(_ v: Double) -> Double {
                var r = v.truncatingRemainder(dividingBy: twoPi)
                if r < 0 { r += twoPi }
                return r
            }
            if sweep >= 0 {
                let a = norm(angle - start)
                let e = norm(sweep)
                return a >= -1e-6 && a <= e + 1e-6
            } else {
                let a = norm(start - angle)
                let e = norm(-sweep)
                return a >= -1e-6 && a <= e + 1e-6
            }
        }
    }
}

/// Pure tangent solver for CIRCLE TTR (known radius) and Tan,Tan,Tan
/// (unknown radius). Supports infinite lines and full circles; callers
/// validate finite domains. Mirrors the FILLET offset-locus core.
public enum TangentCircleSolver {

    // MARK: - vector helpers (xy)

    private static func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x*b.x + a.y*b.y }
    private static func len(_ a: Vector3) -> Double { hypot(a.x, a.y) }
    private static func v(_ x: Double, _ y: Double) -> Vector3 { Vector3(x: x, y: y, z: 0) }

    private static func offsetLoci(for support: TangentSupport2, radius: Double) -> [TangentSupport2] {
        switch support {
        case .line(let o, let d):
            let n = v(-d.y, d.x)
            return [
                .line(origin: o + n * radius, directionUnit: d),
                .line(origin: o - n * radius, directionUnit: d),
            ]
        case .circle(let c, let R):
            let outer = R + radius
            var radii = [outer]
            let inner = abs(R - radius)
            if abs(inner - outer) > 1e-9 { radii.append(inner) }
            return radii.map { .circle(center: c, radius: $0) }
        }
    }

    private static func lineIntersection(_ a: TangentSupport2, _ b: TangentSupport2) -> [Vector3] {
        switch (a, b) {
        case (.line(let o1, let d1), .line(let o2, let d2)):
            let det = d1.x * d2.y - d1.y * d2.x
            if abs(det) < 1e-12 { return [] }
            let inv = 1.0 / det
            let rx = o2.x - o1.x, ry = o2.y - o1.y
            let t = ((rx * d2.y - ry * d2.x) * inv)
            return [o1 + d1 * t]
        case (.line(let o, let d), .circle(let c, let r)),
             (.circle(let c, let r), .line(let o, let d)):
            let rel = o - c
            let b = rel.x * d.x + rel.y * d.y
            let cc = rel.x*rel.x + rel.y*rel.y - r*r
            let disc = b*b - cc
            if disc < -1e-9 { return [] }
            let s = sqrt(max(0, disc))
            if s < 1e-9 { return [o + d * (-b)] }
            return [o + d * (-b - s), o + d * (-b + s)]
        case (.circle(let c1, let r1), .circle(let c2, let r2)):
            let dx = c2.x - c1.x, dy = c2.y - c1.y
            let d2x = dx*dx + dy*dy
            let d = sqrt(d2x)
            if d < 1e-12 { return [] }
            if d > r1 + r2 + 1e-9 || d < abs(r1 - r2) - 1e-9 { return [] }
            let a = (r1*r1 - r2*r2 + d2x) / (2*d)
            let h2 = r1*r1 - a*a
            let h = h2 <= 0 ? 0 : sqrt(h2)
            let mx = c1.x + a*dx/d, my = c1.y + a*dy/d
            let ox = -dy * h / d, oy = dx * h / d
            if h < 1e-9 { return [v(mx, my)] }
            return [v(mx + ox, my + oy), v(mx - ox, my - oy)]
        }
    }

    public static func tangentPointPublic(on support: TangentSupport2, center: Vector3, radius: Double) -> Vector3? {
        tangentPoint(on: support, center: center, radius: radius)
    }

    static func tangentPoint(on support: TangentSupport2, center: Vector3, radius: Double) -> Vector3? {
        switch support {
        case .line(let o, let d):
            let t = dot(center - o, d)
            return o + d * t
        case .circle(let c, let R):
            let delta = center - c
            let dist = len(delta)
            guard dist > 1e-9 else { return nil }
            let x = (dist*dist + R*R - radius*radius) / (2*dist)
            return c + delta / dist * x
        }
    }

    // MARK: - TTR (known radius)

    /// All circles of `radius` tangent to `first` and `second` (infinite supports),
    /// sorted so the one closest to `nearPicks` comes first.
    public static func circlesTangentTo(
        radius: Double,
        first: TangentSupport2,
        second: TangentSupport2,
        nearPicks: [Vector3] = []
    ) -> [Vector3] {
        guard radius > 1e-9 else { return [] }
        // Parallel lines special case: only r == half the inter-line distance works,
        // center anywhere on the midline.
        if case .line(let o1, let d1) = first,
           case .line(let o2, let d2) = second,
           abs(d1.x*d2.y - d1.y*d2.x) < 1e-9 {
            let n = v(-d1.y, d1.x)
            let dist = abs(dot(o2 - o1, n))
            guard abs(dist - 2*radius) < 1e-6 else { return [] }
            let mid1 = o1 + n * (dist/2)
            if nearPicks.isEmpty { return [mid1] }
            let avg = nearPicks.reduce(Vector3.zero, { $0 + $1 }) / Double(nearPicks.count)
            let t = dot(avg - mid1, d1)
            return [mid1 + d1 * t]
        }
        var candidates: [Vector3] = []
        for l1 in offsetLoci(for: first, radius: radius) {
            for l2 in offsetLoci(for: second, radius: radius) {
                candidates += lineIntersection(l1, l2)
            }
        }
        func score(_ c: Vector3) -> Double {
            guard !nearPicks.isEmpty else { return 0 }
            guard let t1 = tangentPoint(on: first, center: c, radius: radius),
                  let t2 = tangentPoint(on: second, center: c, radius: radius) else { return .infinity }
            var s: Double = 0
            for p in nearPicks {
                s += min(len(t1 - p), len(t2 - p))
            }
            return s
        }
        return candidates.sorted { score($0) < score($1) }
    }

    // MARK: - Tan Tan Tan (unknown radius)

    /// Circle tangent to three infinite lines/circles; picks break ties
    /// (closest tangent points). Returns nil when no solution.
    public static func circleTangentToThree(
        _ a: TangentSupport2,
        _ b: TangentSupport2,
        _ c: TangentSupport2,
        nearPicks: [Vector3] = []
    ) -> (center: Vector3, radius: Double)? {
        let candidates = allTangentToThree(a, b, c)
        guard !candidates.isEmpty else { return nil }
        if nearPicks.isEmpty { return candidates[0] }
        func score(_ cand: (center: Vector3, radius: Double)) -> Double {
            var s: Double = 0
            for support in [a, b, c] {
                guard let t = tangentPoint(on: support, center: cand.center, radius: cand.radius) else { return .infinity }
                s += nearPicks.map { len(t - $0) }.min() ?? 0
            }
            return s
        }
        return candidates.sorted { score($0) < score($1) }.first
    }

    private static func allTangentToThree(
        _ a: TangentSupport2, _ b: TangentSupport2, _ c: TangentSupport2
    ) -> [(center: Vector3, radius: Double)] {
        let lines = [a, b, c].filter { if case .line = $0 { return true }; return false }
        switch lines.count {
        case 3: return solveThreeLines(a: a, b: b, c: c)
        case 2: return solveTwoLinesOneCircle(a: a, b: b, c: c)
        case 1: return solveOneLineTwoCircles(a: a, b: b, c: c)
        default: return solveThreeCircles(a: a, b: b, c: c)
        }
    }

    private static func solveThreeLines(
        a: TangentSupport2, b: TangentSupport2, c: TangentSupport2
    ) -> [(Vector3, Double)] {
        let supports = [a, b, c]
        var lines: [(origin: Vector3, dir: Vector3)] = []
        for s in supports {
            if case .line(let o, let d) = s { lines.append((o, d)) }
        }
        guard lines.count == 3 else { return [] }
        var normals: [Vector3] = []
        var ds: [Double] = []
        for i in 0..<3 {
            let d = lines[i].dir
            let n = v(-d.y, d.x)
            normals.append(n)
            ds.append(dot(n, lines[i].origin))
        }
        var out: [(Vector3, Double)] = []
        for s1 in [-1.0, 1.0] {
            for s2 in [-1.0, 1.0] {
                for s3 in [-1.0, 1.0] {
                    let s = [s1, s2, s3]
                    let n1 = normals[0], n2 = normals[1]
                    let det = n1.x*n2.y - n1.y*n2.x
                    if abs(det) < 1e-9 { continue }
                    let inv = 1.0/det
                    let mInv = (a11: n2.y*inv, a12: -n1.y*inv, a21: -n2.x*inv, a22: n1.x*inv)
                    let P0 = v(mInv.a11*ds[0] + mInv.a12*ds[1], mInv.a21*ds[0] + mInv.a22*ds[1])
                    let A = v(mInv.a11*s[0] + mInv.a12*s[1], mInv.a21*s[0] + mInv.a22*s[1])
                    let n3 = normals[2]
                    let denom = dot(n3, A) - s[2]
                    if abs(denom) < 1e-9 { continue }
                    let r = (ds[2] - dot(n3, P0)) / denom
                    guard r > 1e-9 else { continue }
                    out.append((P0 + A * r, r))
                }
            }
        }
        return out
    }

    private static func solveTwoLinesOneCircle(
        a: TangentSupport2, b: TangentSupport2, c: TangentSupport2
    ) -> [(Vector3, Double)] {
        let supports = [a, b, c]
        var lines: [(origin: Vector3, dir: Vector3)] = []
        var circle: TangentSupport2? = nil
        for s in supports {
            if case .line(let o, let d) = s { lines.append((o, d)) } else { circle = s }
        }
        guard lines.count == 2, let circ = circle, case .circle(let cc, let R) = circ else { return [] }
        func normal(_ i: Int) -> Vector3 {
            let d = lines[i].dir
            return v(-d.y, d.x)
        }
        let n1 = normal(0), n2 = normal(1)
        let d1v = dot(n1, lines[0].origin), d2v = dot(n2, lines[1].origin)
        let det = n1.x*n2.y - n1.y*n2.x
        guard abs(det) > 1e-9 else { return [] }
        let inv = 1.0/det
        let mInv = (a11: n2.y*inv, a12: -n1.y*inv, a21: -n2.x*inv, a22: n1.x*inv)
        var out: [(Vector3, Double)] = []
        for s1 in [-1.0, 1.0] {
            for s2 in [-1.0, 1.0] {
                let P0 = v(mInv.a11*d1v + mInv.a12*d2v, mInv.a21*d1v + mInv.a22*d2v)
                let A = v(mInv.a11*s1 + mInv.a12*s2, mInv.a21*s1 + mInv.a22*s2)
                let v0 = P0 - cc
                for sR in [R, -R] {
                    let qa = dot(A, A) - 1
                    let qb = 2*(dot(v0, A) - sR)
                    let qc = dot(v0, v0) - sR*sR
                    for r in solveQuadratic(qa: qa, qb: qb, qc: qc) where r > 1e-9 {
                        out.append((P0 + A * r, r))
                    }
                }
            }
        }
        return out
    }

    private static func solveOneLineTwoCircles(
        a: TangentSupport2, b: TangentSupport2, c: TangentSupport2
    ) -> [(Vector3, Double)] {
        let supports = [a, b, c]
        var line: TangentSupport2? = nil
        var circles: [TangentSupport2] = []
        for s in supports {
            if case .line = s { line = s } else { circles.append(s) }
        }
        guard let line, circles.count == 2,
              case .line(let o, let d) = line,
              case .circle(let c1, let R1) = circles[0],
              case .circle(let c2, let R2) = circles[1] else { return [] }
        let n = v(-d.y, d.x)
        var out: [(Vector3, Double)] = []
        for sL in [-1.0, 1.0] {
            for s1 in [R1, -R1] {
                for s2 in [R2, -R2] {
                    let m = c2 - c1
                    let Ld = 2*dot(m, d)
                    if abs(Ld) < 1e-9 { continue }
                    let base = o
                    let coeffR = 2*dot(m, n)*sL - 2*(s1 - s2)
                    let const0 = 2*dot(m, base) + dot(c1,c1) - dot(c2,c2) - (s1*s1 - s2*s2)
                    let t0 = -const0/Ld
                    let t1 = -coeffR/Ld
                    let v0 = base - c1
                    let w = v0 + d * t0
                    let u = n * sL + d * t1
                    let qa = dot(u,u) - 1
                    let qb = 2*(dot(w,u) - s1)
                    let qc = dot(w,w) - s1*s1
                    for r in solveQuadratic(qa: qa, qb: qb, qc: qc) where r > 1e-9 {
                        let t = t1 * r + t0
                        out.append((base + n * (sL * r) + d * t, r))
                    }
                }
            }
        }
        return out
    }

    private static func solveThreeCircles(
        a: TangentSupport2, b: TangentSupport2, c: TangentSupport2
    ) -> [(Vector3, Double)] {
        let supports = [a, b, c]
        var centers: [Vector3] = []
        var radii: [Double] = []
        for s in supports {
            if case .circle(let cc, let rr) = s { centers.append(cc); radii.append(rr) }
        }
        guard centers.count == 3 else { return [] }
        var out: [(Vector3, Double)] = []
        for s1 in [radii[0], -radii[0]] {
            for s2 in [radii[1], -radii[1]] {
                for s3 in [radii[2], -radii[2]] {
                    let s = [s1, s2, s3]
                    let row1 = centers[1] - centers[0]
                    let row2 = centers[2] - centers[0]
                    let detR = row1.x*row2.y - row1.y*row2.x
                    if abs(detR) < 1e-9 { continue }
                    let cr1 = -2*(s[1]-s[0])
                    let c01 = dot(centers[0],centers[0]) - dot(centers[1],centers[1]) - (s[0]*s[0]-s[1]*s[1])
                    let cr2 = -2*(s[2]-s[0])
                    let c02 = dot(centers[0],centers[0]) - dot(centers[2],centers[2]) - (s[0]*s[0]-s[2]*s[2])
                    let rhsCoeff1 = -cr1/2, rhsConst1 = -c01/2
                    let rhsCoeff2 = -cr2/2, rhsConst2 = -c02/2
                    let inv = 1.0/detR
                    let mInv = (a11: row2.y*inv, a12: -row1.y*inv, a21: -row2.x*inv, a22: row1.x*inv)
                    let P0 = v(mInv.a11*rhsConst1 + mInv.a12*rhsConst2, mInv.a21*rhsConst1 + mInv.a22*rhsConst2)
                    let A = v(mInv.a11*rhsCoeff1 + mInv.a12*rhsCoeff2, mInv.a21*rhsCoeff1 + mInv.a22*rhsCoeff2)
                    let vv = P0 - centers[0]
                    let qa = dot(A,A) - 1
                    let qb = 2*(dot(vv,A) - s[0])
                    let qc = dot(vv,vv) - s[0]*s[0]
                    for r in solveQuadratic(qa: qa, qb: qb, qc: qc) where r > 1e-9 {
                        out.append((P0 + A * r, r))
                    }
                }
            }
        }
        return out
    }

    private static func solveQuadratic(qa: Double, qb: Double, qc: Double) -> [Double] {
        if abs(qa) < 1e-9 {
            if abs(qb) < 1e-9 { return [] }
            return [-qc/qb]
        }
        let disc = qb*qb - 4*qa*qc
        if disc < -1e-9 { return [] }
        let s = sqrt(max(0, disc))
        let r1 = (-qb - s)/(2*qa), r2 = (-qb + s)/(2*qa)
        if abs(r1 - r2) < 1e-9 { return [r1] }
        return [r1, r2]
    }
}
