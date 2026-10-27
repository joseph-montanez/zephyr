import Foundation

// =========================================================================
// MARK: - ConstraintSolver (Phase 2.4)
// =========================================================================
//
// Sequential-projection (Gauss-Seidel) solver for the line-based geometric
// subset the commands ship: FIX, HORIZONTAL, VERTICAL, COINCIDENT,
// PARALLEL, PERPENDICULAR, EQUAL. Everything else in `ConstraintType`
// (TANGENT, CONCENTRIC, MIDPOINT, COLLINEAR, SYMMETRIC, OFFSET, DISTANCE,
// ANGLE) is honestly reported unsatisfied — no silent partial solves.
//
// Lines move in world space; the document writes results back through
// `Transform3D.inverse()` so entity transforms are preserved. Entities
// pinned by an enabled FIX constraint never move. Conflicting sets do
// not converge: iteration stops at `maxIterations` and the offending
// constraints report `satisfied == false` with a large residual.
//

public enum ConstraintSolver {

    /// Solved world-space endpoints per entity handle.
    public struct Outcome: Sendable {
        public var lines: [UUID: (a: Vector3, b: Vector3)]
        public var satisfied: [UUID: Bool]
        public var iterations: Int
        public var maxResidual: Double
    }

    /// Mutable per-line solve state (world space).
    private struct State {
        var a: Vector3
        var b: Vector3
        var fixed: Bool
    }

    /// Projects one constraint set onto world-space line endpoints.
    /// - `lines`: world-space endpoints keyed by entity handle.
    /// - `fixed`: entity handles pinned before solving (unioned with FIX).
    /// - `constraints`: only `.isEnabled` rows are enforced; `.isDriven`
    ///   rows are reference-only and report satisfied without moving.
    public static func solve(
        lines: [UUID: (a: Vector3, b: Vector3)],
        fixed: Set<UUID> = [],
        constraints: [CADConstraint],
        tolerance: Double = 1e-6,
        maxIterations: Int = 100
    ) -> Outcome {
        var states: [UUID: State] = Dictionary(
            uniqueKeysWithValues: lines.map {
                ($0.key, State(a: $0.value.a, b: $0.value.b,
                               fixed: fixed.contains($0.key)))
            })
        let ordered = constraints.sorted {
            $0.handle.uuidString < $1.handle.uuidString
        }
        // FIX pins before the first pass so nothing drags pinned lines.
        for c in ordered where c.type == .fix && c.isEnabled && !c.isDriven {
            if states[c.entityA] != nil { states[c.entityA]?.fixed = true }
        }

        var iterations = 0
        for _ in 0..<maxIterations {
            iterations += 1
            var moved = 0.0
            for c in ordered {
                moved = max(moved, project(c, states: &states))
            }
            if moved < tolerance { break }
        }

        var satisfied: [UUID: Bool] = [:]
        var maxResidual = 0.0
        for c in ordered {
            let r = residual(c, states: states)
            satisfied[c.handle] = r <= tolerance
            maxResidual = max(maxResidual, r)
        }
        return Outcome(
            lines: Dictionary(uniqueKeysWithValues: states.map {
                ($0.key, (a: $0.value.a, b: $0.value.b))
            }),
            satisfied: satisfied,
            iterations: iterations,
            maxResidual: maxResidual)
    }

    // MARK: - Projection

    /// One Gauss-Seidel pass for a single constraint. Returns the largest
    /// endpoint displacement it caused (0 when it moved nothing).
    private static func project(
        _ c: CADConstraint, states: inout [UUID: State]
    ) -> Double {
        guard c.isEnabled, !c.isDriven else { return 0 }
        switch c.type {
        case .fix:
            return 0
        case .horizontal:
            guard var s = states[c.entityA], !s.fixed else { return 0 }
            let mid = (s.a.y + s.b.y) / 2
            let move = max(abs(s.a.y - mid), abs(s.b.y - mid))
            s.a.y = mid; s.b.y = mid
            states[c.entityA] = s
            return move
        case .vertical:
            guard var s = states[c.entityA], !s.fixed else { return 0 }
            let mid = (s.a.x + s.b.x) / 2
            let move = max(abs(s.a.x - mid), abs(s.b.x - mid))
            s.a.x = mid; s.b.x = mid
            states[c.entityA] = s
            return move
        case .coincident:
            guard var sa = states[c.entityA],
                  var sb = states[c.entityB ?? c.entityA] else { return 0 }
            let pa = end(sa, c.subIndexA), pb = end(sb, c.subIndexB)
            if sa.fixed && sb.fixed { return 0 }
            if sa.fixed {
                let move = pb.distance(to: pa)
                setEnd(&sb, c.subIndexB, pa); states[c.entityB ?? c.entityA] = sb
                return c.entityB == nil ? 0 : move
            }
            if sb.fixed || c.entityB == nil {
                let move = pa.distance(to: pb)
                setEnd(&sa, c.subIndexA, pb); states[c.entityA] = sa
                return move
            }
            let mid = Vector3(
                x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2,
                z: (pa.z + pb.z) / 2)
            let move = max(pa.distance(to: mid), pb.distance(to: mid))
            setEnd(&sa, c.subIndexA, mid); setEnd(&sb, c.subIndexB, mid)
            states[c.entityA] = sa; states[c.entityB!] = sb
            return move
        case .parallel:
            return align(c, states: &states, offset: 0)
        case .perpendicular:
            return align(c, states: &states, offset: .pi / 2)
        case .equal:
            guard var sa = states[c.entityA],
                  var sb = states[c.entityB ?? c.entityA] else { return 0 }
            let la = sa.a.distance(to: sa.b), lb = sb.a.distance(to: sb.b)
            if sa.fixed && sb.fixed { return 0 }
            // The fixed length wins; otherwise A is the reference and B
            // is the follower.
            if !sb.fixed {
                return scaleToLength(&sb, la, states: &states,
                                     handle: c.entityB ?? c.entityA)
            }
            if !sa.fixed {
                return scaleToLength(&sa, lb, states: &states,
                                     handle: c.entityA)
            }
            return 0
        case .tangent, .concentric, .midpoint, .collinear, .symmetric,
             .offset, .distance, .angle:
            return 0
        }
    }

    /// Rotates the follower line about its midpoint toward the reference
    /// angle (+ offset). The reference is A unless A is fixed and B is
    /// not... actually B follows A; when B is fixed, A follows B.
    private static func align(
        _ c: CADConstraint, states: inout [UUID: State], offset: Double
    ) -> Double {
        guard var sa = states[c.entityA],
              var sb = states[c.entityB ?? c.entityA] else { return 0 }
        let la = sa.a.distance(to: sa.b), lb = sb.a.distance(to: sb.b)
        guard la > 1e-12, lb > 1e-12 else { return 0 }
        if sa.fixed && sb.fixed { return 0 }
        let angleA = atan2(sa.b.y - sa.a.y, sa.b.x - sa.a.x)
        if !sb.fixed {
            let target = angleA + offset
            let move = rotateToAngle(&sb, target)
            states[c.entityB ?? c.entityA] = sb
            return move
        }
        let angleB = atan2(sb.b.y - sb.a.y, sb.b.x - sb.a.x)
        let move = rotateToAngle(&sa, angleB - offset)
        states[c.entityA] = sa
        return move
    }

    private static func rotateToAngle(
        _ s: inout State, _ target: Double
    ) -> Double {
        let mid = Vector3(
            x: (s.a.x + s.b.x) / 2, y: (s.a.y + s.b.y) / 2,
            z: (s.a.z + s.b.z) / 2)
        let len = s.a.distance(to: s.b)
        guard len > 1e-12 else { return 0 }
        let half = len / 2
        let na = Vector3(
            x: mid.x - half * cos(target), y: mid.y - half * sin(target),
            z: s.a.z)
        let nb = Vector3(
            x: mid.x + half * cos(target), y: mid.y + half * sin(target),
            z: s.b.z)
        let move = max(s.a.distance(to: na), s.b.distance(to: nb))
        s.a = na; s.b = nb
        return move
    }

    private static func scaleToLength(
        _ s: inout State, _ target: Double,
        states: inout [UUID: State], handle: UUID
    ) -> Double {
        let len = s.a.distance(to: s.b)
        guard len > 1e-12, target.isFinite, target >= 0 else { return 0 }
        let mid = Vector3(
            x: (s.a.x + s.b.x) / 2, y: (s.a.y + s.b.y) / 2,
            z: (s.a.z + s.b.z) / 2)
        let dir = Vector3(
            x: (s.b.x - s.a.x) / len, y: (s.b.y - s.a.y) / len, z: 0)
        let na = Vector3(
            x: mid.x - dir.x * target / 2, y: mid.y - dir.y * target / 2,
            z: s.a.z)
        let nb = Vector3(
            x: mid.x + dir.x * target / 2, y: mid.y + dir.y * target / 2,
            z: s.b.z)
        let move = max(s.a.distance(to: na), s.b.distance(to: nb))
        s.a = na; s.b = nb
        states[handle] = s
        return move
    }

    // MARK: - Residuals

    /// Post-solve violation magnitude: world units for positional
    /// constraints, radians for angular, `.infinity` when unmeasurable
    /// (missing entity, degenerate line, unsupported type).
    private static func residual(
        _ c: CADConstraint, states: [UUID: State]
    ) -> Double {
        guard c.isEnabled else { return 0 }
        if c.isDriven { return 0 }
        switch c.type {
        case .fix:
            return states[c.entityA] == nil ? .infinity : 0
        case .horizontal:
            guard let s = states[c.entityA] else { return .infinity }
            return abs(s.a.y - s.b.y)
        case .vertical:
            guard let s = states[c.entityA] else { return .infinity }
            return abs(s.a.x - s.b.x)
        case .coincident:
            guard let sa = states[c.entityA],
                  let sb = states[c.entityB ?? c.entityA] else {
                return .infinity
            }
            return end(sa, c.subIndexA).distance(to: end(sb, c.subIndexB))
        case .parallel, .perpendicular:
            guard let sa = states[c.entityA],
                  let sb = states[c.entityB ?? c.entityA] else {
                return .infinity
            }
            let la = sa.a.distance(to: sa.b), lb = sb.a.distance(to: sb.b)
            guard la > 1e-12, lb > 1e-12 else { return .infinity }
            let aA = atan2(sa.b.y - sa.a.y, sa.b.x - sa.a.x)
            let aB = atan2(sb.b.y - sb.a.y, sb.b.x - sb.a.x)
            let want = c.type == .parallel ? 0.0 : Double.pi / 2
            return abs(atan2(sin(aB - aA - want), cos(aB - aA - want)))
        case .equal:
            guard let sa = states[c.entityA],
                  let sb = states[c.entityB ?? c.entityA] else {
                return .infinity
            }
            return abs(sa.a.distance(to: sa.b) - sb.a.distance(to: sb.b))
        case .tangent, .concentric, .midpoint, .collinear, .symmetric,
             .offset, .distance, .angle:
            return .infinity
        }
    }

    // MARK: - Endpoints

    private static func end(_ s: State, _ index: UInt8) -> Vector3 {
        index == 0 ? s.a : s.b
    }

    private static func setEnd(_ s: inout State, _ index: UInt8, _ p: Vector3) {
        if index == 0 { s.a = p } else { s.b = p }
    }
}
