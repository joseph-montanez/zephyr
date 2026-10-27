import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.4 parametric constraints (spike-gated): the line solver
/// projects FIX/HORIZONTAL/VERTICAL/COINCIDENT/PARALLEL/PERPENDICULAR/
/// EQUAL honestly (conflicts and unsupported types report unsatisfied,
/// never silently), document apply is single-undo write-back,
/// AUTOCONSTRAIN detects within tolerance, and EAB section 4 round-trips
/// constraints at full fidelity.
@MainActor
final class ConstraintSolverTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func lineEntity(
        _ document: CADDocument, _ ax: Double, _ ay: Double,
        _ bx: Double, _ by: Double
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: zeroID(document),
            localGeometry: [.line(
                start: Vector3(x: ax, y: ay, z: 0),
                end: Vector3(x: bx, y: by, z: 0), color: nil)])
        document.addEntity(entity)
        return entity
    }

    // MARK: - Projection

    func testHorizontalVerticalProjection() {
        let h = UUID(), v = UUID()
        let hc = CADConstraint(type: .horizontal, entityA: h)
        let vc = CADConstraint(type: .vertical, entityA: v)
        let outcome = ConstraintSolver.solve(
            lines: [
                h: (Vector3(x: 0, y: 1, z: 0), Vector3(x: 10, y: 3, z: 0)),
                v: (Vector3(x: 1, y: 0, z: 0), Vector3(x: 3, y: 10, z: 0)),
            ],
            constraints: [hc, vc])
        XCTAssertTrue(outcome.satisfied[hc.handle] ?? false)
        XCTAssertTrue(outcome.satisfied[vc.handle] ?? false)
        let hs = try! XCTUnwrap(outcome.lines[h])
        XCTAssertEqual(hs.a.y, 2, accuracy: 1e-9)
        XCTAssertEqual(hs.b.y, 2, accuracy: 1e-9)
        let vs = try! XCTUnwrap(outcome.lines[v])
        XCTAssertEqual(vs.a.x, 2, accuracy: 1e-9)
        XCTAssertEqual(vs.b.x, 2, accuracy: 1e-9)
    }

    func testCoincidentMeetsAtMidpointUnlessFixed() {
        let a = UUID(), b = UUID()
        let lines: [UUID: (a: Vector3, b: Vector3)] = [
            a: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)),
            b: (Vector3(x: 0, y: 5, z: 0), Vector3(x: 10, y: 6, z: 0)),
        ]
        let join = CADConstraint(
            type: .coincident, entityA: a, entityB: b,
            subIndexA: 1, subIndexB: 0)
        let free = ConstraintSolver.solve(lines: lines, constraints: [join])
        XCTAssertTrue(free.satisfied[join.handle] ?? false)
        let fa = try! XCTUnwrap(free.lines[a])
        let fb = try! XCTUnwrap(free.lines[b])
        XCTAssertEqual(fa.b.x, 5, accuracy: 1e-9)
        XCTAssertEqual(fa.b.y, 2.5, accuracy: 1e-9)
        XCTAssertEqual(fb.a.x, 5, accuracy: 1e-9)
        XCTAssertEqual(fb.a.y, 2.5, accuracy: 1e-9)

        // FIX on B: B never moves, A travels the whole way.
        let pin = CADConstraint(type: .fix, entityA: b)
        let pinned = ConstraintSolver.solve(lines: lines, constraints: [pin, join])
        XCTAssertTrue(pinned.satisfied[join.handle] ?? false)
        let pb = try! XCTUnwrap(pinned.lines[b])
        XCTAssertEqual(pb.a.x, 0, accuracy: 1e-12)
        XCTAssertEqual(pb.a.y, 5, accuracy: 1e-12)
        let pa = try! XCTUnwrap(pinned.lines[a])
        XCTAssertEqual(pa.b.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pa.b.y, 5, accuracy: 1e-9)
    }

    func testParallelPerpendicularRotateFollower() {
        let a = UUID(), b = UUID(), c = UUID()
        let lines: [UUID: (a: Vector3, b: Vector3)] = [
            a: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)),
            b: (Vector3(x: 0, y: 5, z: 0), Vector3(x: 5, y: 10, z: 0)),
            c: (Vector3(x: 0, y: 20, z: 0), Vector3(x: 5, y: 25, z: 0)),
        ]
        let outcome = ConstraintSolver.solve(
            lines: lines,
            constraints: [
                CADConstraint(type: .parallel, entityA: a, entityB: b),
                CADConstraint(type: .perpendicular, entityA: a, entityB: c),
            ])
        XCTAssertTrue(outcome.satisfied.values.allSatisfy { $0 })
        let sb = try! XCTUnwrap(outcome.lines[b])
        let angleB = atan2(sb.b.y - sb.a.y, sb.b.x - sb.a.x)
        XCTAssertEqual(angleB, 0, accuracy: 1e-6)
        // Length and midpoint preserved by pure rotation.
        XCTAssertEqual(sb.a.distance(to: sb.b), 5 * sqrt(2.0), accuracy: 1e-9)
        XCTAssertEqual((sb.a.x + sb.b.x) / 2, 2.5, accuracy: 1e-9)
        let sc = try! XCTUnwrap(outcome.lines[c])
        let angleC = atan2(sc.b.y - sc.a.y, sc.b.x - sc.a.x)
        XCTAssertEqual(abs(angleC), Double.pi / 2, accuracy: 1e-6)
    }

    func testEqualMatchesFollowerToReference() {
        let a = UUID(), b = UUID()
        let outcome = ConstraintSolver.solve(
            lines: [
                a: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)),
                b: (Vector3(x: 0, y: 5, z: 0), Vector3(x: 4, y: 5, z: 0)),
            ],
            constraints: [CADConstraint(type: .equal, entityA: a, entityB: b)])
        XCTAssertTrue(outcome.satisfied.values.allSatisfy { $0 })
        let sb = try! XCTUnwrap(outcome.lines[b])
        XCTAssertEqual(sb.a.distance(to: sb.b), 10, accuracy: 1e-9)
        XCTAssertEqual((sb.a.x + sb.b.x) / 2, 2, accuracy: 1e-9)
    }

    // MARK: - Honest failure

    func testConflictReportsUnsatisfied() {
        let a = UUID(), b = UUID()
        let fixed: Set<UUID> = [b]
        let toStart = CADConstraint(
            type: .coincident, entityA: a, entityB: b,
            subIndexA: 0, subIndexB: 0)
        let toEnd = CADConstraint(
            type: .coincident, entityA: a, entityB: b,
            subIndexA: 0, subIndexB: 1)
        let outcome = ConstraintSolver.solve(
            lines: [
                a: (Vector3(x: 0, y: 5, z: 0), Vector3(x: 1, y: 5, z: 0)),
                b: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)),
            ],
            fixed: fixed, constraints: [toStart, toEnd], maxIterations: 5)
        XCTAssertEqual(outcome.iterations, 5)
        // Gauss-Seidel always satisfies the last pass's winner, so a
        // fighting pair can never report both satisfied — and the loser
        // keeps a large residual. (Which one wins depends on handle
        // order, so only the conjunction is asserted.)
        let both = (outcome.satisfied[toStart.handle] ?? false)
            && (outcome.satisfied[toEnd.handle] ?? false)
        XCTAssertFalse(both)
        XCTAssertGreaterThan(outcome.maxResidual, 1)

        // Two pinned lines that disagree: deterministically unsatisfied.
        let fa = UUID(), fb = UUID()
        let frozen = CADConstraint(type: .fix, entityA: fa)
        let frozenB = CADConstraint(type: .fix, entityA: fb)
        let apart = CADConstraint(
            type: .coincident, entityA: fa, entityB: fb,
            subIndexA: 0, subIndexB: 0)
        let stuck = ConstraintSolver.solve(
            lines: [
                fa: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 1, y: 0, z: 0)),
                fb: (Vector3(x: 5, y: 0, z: 0), Vector3(x: 6, y: 0, z: 0)),
            ],
            constraints: [frozen, frozenB, apart])
        XCTAssertFalse(stuck.satisfied[apart.handle] ?? true)
        XCTAssertGreaterThan(stuck.maxResidual, 1)
    }

    func testUnsupportedDisabledAndMissing() {
        let a = UUID(), b = UUID()
        let tangent = CADConstraint(type: .tangent, entityA: a, entityB: b)
        var off = CADConstraint(type: .horizontal, entityA: a)
        off.isEnabled = false
        let ghost = CADConstraint(type: .fix, entityA: UUID())
        let outcome = ConstraintSolver.solve(
            lines: [
                a: (Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)),
                b: (Vector3(x: 0, y: 5, z: 0), Vector3(x: 10, y: 5, z: 0)),
            ],
            constraints: [tangent, off, ghost])
        XCTAssertFalse(outcome.satisfied[tangent.handle] ?? true)
        XCTAssertTrue(outcome.satisfied[off.handle] ?? false)
        XCTAssertFalse(outcome.satisfied[ghost.handle] ?? true)
        // Disabled rows never move geometry.
        let sa = try! XCTUnwrap(outcome.lines[a])
        XCTAssertEqual(sa.a.y, 0, accuracy: 1e-12)
    }

    // MARK: - Document apply

    func testDocumentSolveWritesBackAndUndoes() {
        let document = makeDocument()
        let a = lineEntity(document, 0, 0, 10, 0)
        let b = lineEntity(document, 0, 5, 10, 6)
        document.addConstraint(CADConstraint(type: .fix, entityA: a.handle))
        document.addConstraint(CADConstraint(
            type: .coincident, entityA: b.handle, entityB: a.handle,
            subIndexA: 0, subIndexB: 1))

        let outcome = document.solveConstraints()
        XCTAssertTrue(outcome.satisfied.values.allSatisfy { $0 })
        // B's start travelled to A's fixed end (10, 0).
        let moved = try! XCTUnwrap(document.entity(for: b.handle))
        guard case .line(let start, _, _) = moved.localGeometry?.first else {
            return XCTFail("expected line geometry")
        }
        XCTAssertEqual(start.x, 10, accuracy: 1e-9)
        XCTAssertEqual(start.y, 0, accuracy: 1e-9)
        // A never moved.
        let pinned = try! XCTUnwrap(document.entity(for: a.handle))
        guard case .line(let pa, let pb, _) = pinned.localGeometry?.first else {
            return XCTFail("expected line geometry")
        }
        XCTAssertEqual(pa.x, 0, accuracy: 1e-12)
        XCTAssertEqual(pb.x, 10, accuracy: 1e-12)

        // One undo restores the pre-solve geometry (single snapshot).
        document.undo()
        let restored = try! XCTUnwrap(document.entity(for: b.handle))
        guard case .line(let rs, _, _) = restored.localGeometry?.first else {
            return XCTFail("expected line geometry")
        }
        XCTAssertEqual(rs.x, 0, accuracy: 1e-12)
        XCTAssertEqual(rs.y, 5, accuracy: 1e-12)
    }

    func testSolvableLinesSkipsNonLines() {
        let document = makeDocument()
        let line = lineEntity(document, 0, 0, 10, 0)
        // Baked two-line run: solver-ineligible.
        document.addEntity(CADEntity(
            layerID: zeroID(document),
            localGeometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 1, y: 0, z: 0), color: nil),
                .line(start: Vector3(x: 1, y: 0, z: 0),
                      end: Vector3(x: 2, y: 0, z: 0), color: nil),
            ]))
        // Circle: solver-ineligible.
        document.addEntity(CADEntity(
            layerID: zeroID(document),
            localGeometry: [.circle(
                center: Vector3(x: 5, y: 5, z: 0), radius: 2, color: nil)]))
        let solvable = document.solvableLines()
        XCTAssertEqual(Set(solvable.keys), [line.handle])
        XCTAssertNil(ConstraintSupport.worldEnds(of: document.allEntities.first {
            ($0.localGeometry?.count ?? 0) > 1
        }!))
    }

    func testConstraintsAffectingAndRemoval() {
        let document = makeDocument()
        let a = lineEntity(document, 0, 0, 10, 0)
        let b = lineEntity(document, 0, 5, 10, 5)
        let c1 = CADConstraint(type: .horizontal, entityA: a.handle)
        let c2 = CADConstraint(
            type: .parallel, entityA: a.handle, entityB: b.handle)
        document.addConstraint(c1)
        document.addConstraint(c2)
        XCTAssertEqual(
            Set(document.constraintsAffecting(a.handle).map(\.handle)),
            [c1.handle, c2.handle])
        XCTAssertEqual(
            document.constraintsAffecting(b.handle).map(\.handle),
            [c2.handle])

        document.removeConstraint(handle: c2.handle)
        XCTAssertEqual(document.constraintsAffecting(a.handle).count, 1)
        document.undo()
        XCTAssertEqual(document.constraintsAffecting(a.handle).count, 2)
    }

    // MARK: - AUTOCONSTRAIN

    func testAutoDetectFindsSubset() {
        let h = UUID(), v = UUID(), p = UUID(), q = UUID()
        let detected = AutoConstrain.detect(
            lines: [
                .init(handle: h,
                      a: Vector3(x: 0, y: 0, z: 0), b: Vector3(x: 10, y: 0, z: 0)),
                .init(handle: v,
                      a: Vector3(x: 10, y: 0, z: 0), b: Vector3(x: 10, y: 8, z: 0)),
                .init(handle: p,
                      a: Vector3(x: 0, y: 20, z: 0), b: Vector3(x: 10, y: 20, z: 0)),
                .init(handle: q,
                      a: Vector3(x: 30, y: 30, z: 0), b: Vector3(x: 33, y: 34, z: 0)),
            ],
            coincidenceTolerance: 1e-9)
        func has(_ type: ConstraintType, _ handles: Set<UUID>) -> Bool {
            detected.contains {
                $0.type == type &&
                Set([$0.entityA, $0.entityB].compactMap { $0 }) == handles
            }
        }
        XCTAssertTrue(has(.horizontal, [h]))
        XCTAssertTrue(has(.vertical, [v]))
        XCTAssertTrue(has(.coincident, [h, v]))
        XCTAssertTrue(has(.parallel, [h, p]))
        XCTAssertTrue(has(.equal, [h, p]))
        XCTAssertTrue(has(.perpendicular, [h, v]))
        // Nothing invented for the odd line out.
        XCTAssertFalse(detected.contains {
            $0.entityA == q || $0.entityB == q
        })
    }

    // MARK: - Badges + persistence

    func testBadgeAnchors() {
        let document = makeDocument()
        XCTAssertFalse(document.showConstraintBadges)
        let a = lineEntity(document, 0, 0, 10, 4)
        XCTAssertTrue(ConstraintBadgeRenderer.badgeAnchors(document: document).isEmpty)
        document.addConstraint(CADConstraint(type: .fix, entityA: a.handle))
        let anchors = ConstraintBadgeRenderer.badgeAnchors(document: document)
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors[0].x, 5, accuracy: 1e-9)
        XCTAssertEqual(anchors[0].y, 4, accuracy: 1e-9)
        XCTAssertEqual(anchors[0].count, 1)
    }

    func testEABRoundTripPreservesConstraints() throws {
        let document = makeDocument()
        let a = lineEntity(document, 0, 0, 10, 0)
        let b = lineEntity(document, 0, 5, 10, 5)
        // Non-default sub-entities: a field-order swap in the codec
        // must fail loudly, never hide behind zero defaults.
        let constraint = CADConstraint(
            type: .coincident, entityA: a.handle, entityB: b.handle,
            subEntityA: .point, subIndexA: 1,
            subEntityB: .point, subIndexB: 0,
            params: [0.5], isEnabled: true, isDriven: false)
        document.addConstraint(constraint)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("constraints-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: document, to: url)

        let views = try EABReader.readViews(from: url)
        let restored = try XCTUnwrap(views.first?.document)
        let roundTripped = try XCTUnwrap(restored.allConstraints.first)
        XCTAssertEqual(restored.allConstraints.count, 1)
        XCTAssertEqual(roundTripped.handle, constraint.handle)
        XCTAssertEqual(roundTripped.type, .coincident)
        XCTAssertEqual(roundTripped.entityA, a.handle)
        XCTAssertEqual(roundTripped.entityB, b.handle)
        XCTAssertEqual(roundTripped.subEntityA, .point)
        XCTAssertEqual(roundTripped.subIndexA, 1)
        XCTAssertEqual(roundTripped.subEntityB, .point)
        XCTAssertEqual(roundTripped.subIndexB, 0)
        XCTAssertEqual(roundTripped.params, [0.5])
        XCTAssertTrue(roundTripped.isEnabled)
    }
}
