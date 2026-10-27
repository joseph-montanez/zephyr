import Foundation

// =========================================================================
// MARK: - ConstraintSupport + AutoConstrain (Phase 2.4)
// =========================================================================
//
// Shared pick validation for the constraint commands plus AUTOCONSTRAIN
// tolerance detection. Detection is a pure function over world-space
// endpoints so it is directly testable; the command only gathers lines,
// stores the detected rows, and solves.
//

/// Shared pick validation for constraint commands.
public enum ConstraintSupport {
    /// World-space endpoints of a loose single-line entity; nil for
    /// block inserts, multi-primitive entities, and non-line geometry.
    /// The solver and every constraint command refuse anything else —
    /// constraining a baked multiline run or an insert would silently
    /// move only part of the picture.
    public static func worldEnds(
        of entity: CADEntity
    ) -> (a: Vector3, b: Vector3)? {
        guard entity.blockID == nil,
              let geom = entity.localGeometry, geom.count == 1,
              case .line(let a, let b, _) = geom[0] else { return nil }
        return (
            entity.transform.transformPoint(a),
            entity.transform.transformPoint(b))
    }
}

/// Tolerance-based constraint inference (AUTOCONSTRAIN).
public enum AutoConstrain {
    public struct LineInput: Sendable {
        public var handle: UUID
        public var a: Vector3
        public var b: Vector3
        public init(handle: UUID, a: Vector3, b: Vector3) {
            self.handle = handle; self.a = a; self.b = b
        }
    }

    /// Infers HORIZONTAL/VERTICAL (unary) plus COINCIDENT, PARALLEL,
    /// PERPENDICULAR, EQUAL (binary) within the given tolerances.
    /// Degenerate (zero-length) lines are skipped for angular checks.
    /// Output order is deterministic (handles sorted, pairs i < j).
    public static func detect(
        lines: [LineInput],
        angleTolerance: Double = 0.02,
        coincidenceTolerance: Double = 1e-4,
        lengthRelativeTolerance: Double = 0.001
    ) -> [CADConstraint] {
        let ordered = lines.sorted {
            $0.handle.uuidString < $1.handle.uuidString
        }
        var out: [CADConstraint] = []
        func normAngle(_ l: LineInput) -> Double? {
            let len = l.a.distance(to: l.b)
            guard len > 1e-12 else { return nil }
            let t = atan2(l.b.y - l.a.y, l.b.x - l.a.x)
            return t < 0 ? t + .pi : t
        }
        for line in ordered {
            guard let m = normAngle(line) else { continue }
            if min(m, .pi - m) <= angleTolerance {
                out.append(CADConstraint(type: .horizontal, entityA: line.handle))
            } else if abs(m - .pi / 2) <= angleTolerance {
                out.append(CADConstraint(type: .vertical, entityA: line.handle))
            }
        }
        for i in ordered.indices {
            for j in (i + 1)..<ordered.count {
                let a = ordered[i], b = ordered[j]
                if let ma = normAngle(a), let mb = normAngle(b) {
                    let raw = abs(ma - mb)
                    let between = raw > .pi / 2 ? .pi - raw : raw
                    if between <= angleTolerance {
                        out.append(CADConstraint(
                            type: .parallel, entityA: a.handle,
                            entityB: b.handle))
                    } else if abs(between - .pi / 2) <= angleTolerance {
                        out.append(CADConstraint(
                            type: .perpendicular, entityA: a.handle,
                            entityB: b.handle))
                    }
                }
                let endsA = [a.a, a.b], endsB = [b.a, b.b]
                for (ia, pa) in endsA.enumerated() {
                    for (ib, pb) in endsB.enumerated() {
                        if pa.distance(to: pb) <= coincidenceTolerance {
                            out.append(CADConstraint(
                                type: .coincident, entityA: a.handle,
                                entityB: b.handle,
                                subIndexA: UInt8(ia), subIndexB: UInt8(ib)))
                        }
                    }
                }
                let la = a.a.distance(to: a.b), lb = b.a.distance(to: b.b)
                let longest = max(la, lb)
                if longest > 1e-12,
                   abs(la - lb) <= lengthRelativeTolerance * longest {
                    out.append(CADConstraint(
                        type: .equal, entityA: a.handle, entityB: b.handle))
                }
            }
        }
        return out
    }
}
