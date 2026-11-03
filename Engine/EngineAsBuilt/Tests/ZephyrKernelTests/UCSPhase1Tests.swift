import XCTest
@testable import ZephyrKernel

// =========================================================================
// MARK: - UCS Phase 1: planar UCS, angle conventions, point parser
//
// Focused gates for the new (Lisp-call-site-free) kernel inputs layer:
//   * UCSDefinition math: frame axes, forward/inverse transforms,
//     rotation, plan rotation, three-point validation, planarity
//     projection with degenerate fallbacks.
//   * AngleConvention: canonical/user orientation + delta mapping under
//     default and non-default ANGBASE/ANGDIR settings.
//   * UserPointParser: absolute / relative / dist<angle forms, plus
//     canonical decoupling via the injected orientation conversion.
// =========================================================================

final class UCSPhase1Tests: XCTestCase {

    // MARK: - UCS frame

    func testIdentityFrameAxes() {
        let ucs = UCSDefinition.identity
        XCTAssertEqual(ucs.angle, 0)
        XCTAssertEqual(ucs.xAxis.x, 1, accuracy: 1e-12)
        XCTAssertEqual(ucs.xAxis.y, 0, accuracy: 1e-12)
        XCTAssertEqual(ucs.yAxis.x, 0, accuracy: 1e-12)
        XCTAssertEqual(ucs.yAxis.y, 1, accuracy: 1e-12)
        XCTAssertEqual(UCSDefinition.worldAxis.z, 1, accuracy: 1e-12)
        XCTAssertEqual(ucs.planeNormal.z, 1, accuracy: 1e-12)
    }

    func testRotatedFrameAxesOrthonormal() {
        let ucs = UCSDefinition(angle: .pi / 6)
        XCTAssertEqual(ucs.xAxis.length, 1, accuracy: 1e-12)
        XCTAssertEqual(ucs.yAxis.length, 1, accuracy: 1e-12)
        XCTAssertEqual(ucs.xAxis.dot(ucs.yAxis), 0, accuracy: 1e-12)
        XCTAssertEqual(ucs.xAxis.x, cos(.pi / 6), accuracy: 1e-12)
        XCTAssertEqual(ucs.xAxis.y, sin(.pi / 6), accuracy: 1e-12)
    }

    func testAngleNormalization() {
        XCTAssertEqual(UCSDefinition(angle: 3 * .pi).angle, .pi, accuracy: 1e-12)
        XCTAssertEqual(UCSDefinition(angle: -.pi / 2).angle, 3 * .pi / 2, accuracy: 1e-12)
    }

    // MARK: - Forward / inverse transforms

    func testIdentityRoundTrip() {
        let ucs = UCSDefinition(origin: Point3d(x: 10, y: -4, z: 7))
        let local = Point2d(x: 3, y: 5)
        let world = ucs.toWorld(local)
        XCTAssertEqual(world.x, 13, accuracy: 1e-12)
        XCTAssertEqual(world.y, 1, accuracy: 1e-12)
        XCTAssertEqual(world.z, 7, accuracy: 1e-12)
        let back = ucs.toLocal(world)
        XCTAssertEqual(back.x, local.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, local.y, accuracy: 1e-12)
    }

    func testRotatedRoundTrip() {
        let ucs = UCSDefinition(origin: Point3d(x: -2, y: 8, z: 1.5), angle: .pi / 3)
        for p in [Point2d(x: 0, y: 0), Point2d(x: 4, y: -7), Point2d(x: -11, y: 2.5)] {
            let back = ucs.toLocal(ucs.toWorld(p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    func testDirectionTransformsIgnoreTranslation() {
        let ucs = UCSDefinition(origin: Point3d(x: 100, y: -50, z: 9), angle: .pi / 2)
        let w = ucs.toWorld(direction: Vec2d(x: 1, y: 0))
        XCTAssertEqual(w.x, 0, accuracy: 1e-12)
        XCTAssertEqual(w.y, 1, accuracy: 1e-12)
        XCTAssertEqual(w.z, 0, accuracy: 1e-12)
        let back = ucs.toLocal(direction: Vec3d(x: 0, y: 1, z: 0))
        XCTAssertEqual(back.x, 1, accuracy: 1e-12)
        XCTAssertEqual(back.y, 0, accuracy: 1e-12)
    }

    // MARK: - Rotation / plan rotation

    func testRotatedByCanonicalDelta() {
        let ucs = UCSDefinition(angle: .pi / 4).rotated(by: .pi / 4)
        XCTAssertEqual(ucs.angle, .pi / 2, accuracy: 1e-12)
        // Wrap-around composition.
        XCTAssertEqual(UCSDefinition(angle: 3 * .pi / 2).rotated(by: .pi).angle,
                       .pi / 2, accuracy: 1e-12)
    }

    func testPlanRotationDefaultConvention() {
        let ucs = UCSDefinition(angle: 0).planRotated(by: .pi / 2,
                                                     convention: .default)
        XCTAssertEqual(ucs.angle, .pi / 2, accuracy: 1e-12)
    }

    func testPlanRotationDecoupledUnderClockwiseNorthBase() {
        // ANGBASE = North (90 deg), ANGDIR = clockwise.
        let convention = AngleConvention(baseAngle: .pi / 2, clockwise: true)
        // A user +90 deg plan turn is a canonical -90 deg turn.
        let ucs = UCSDefinition(angle: 0).planRotated(by: .pi / 2,
                                                     convention: convention)
        XCTAssertEqual(ucs.angle, 3 * .pi / 2, accuracy: 1e-12)
        // Same canonical delta applied directly agrees.
        XCTAssertEqual(ucs.angle,
                       UCSDefinition(angle: 0).rotated(by: -.pi / 2).angle,
                       accuracy: 1e-12)
    }

    // MARK: - Three-point validation / construction

    func testThreePointsValid() {
        let origin = Point3d.zero
        let xPt = Point3d(x: 10, y: 0, z: 0)
        let yPt = Point3d(x: 0, y: 10, z: 0)
        XCTAssertTrue(UCSDefinition.validateThreePoints(origin: origin,
                                                         xPoint: xPt,
                                                         yPoint: yPt))
        let ucs = UCSDefinition.fromThreePoints(origin: origin,
                                                xPoint: xPt,
                                                yPoint: yPt)
        XCTAssertNotNil(ucs)
        XCTAssertEqual(ucs?.angle ?? -1, 0, accuracy: 1e-12)
    }

    func testThreePointsAngled() {
        let ucs = UCSDefinition.fromThreePoints(origin: .zero,
                                                xPoint: Point3d(x: 0, y: 5, z: 0),
                                                yPoint: Point3d(x: -5, y: 0, z: 0))
        XCTAssertEqual(ucs?.angle ?? -1, .pi / 2, accuracy: 1e-12)
    }

    func testThreePointsDegenerateRejected() {
        // Coincident X.
        XCTAssertFalse(UCSDefinition.validateThreePoints(origin: .zero,
                                                          xPoint: .zero,
                                                          yPoint: Point3d(x: 0, y: 1, z: 0)))
        // Coincident Y.
        XCTAssertFalse(UCSDefinition.validateThreePoints(origin: .zero,
                                                          xPoint: Point3d(x: 1, y: 0, z: 0),
                                                          yPoint: .zero))
        // Collinear.
        XCTAssertFalse(UCSDefinition.validateThreePoints(origin: .zero,
                                                          xPoint: Point3d(x: 5, y: 0, z: 0),
                                                          yPoint: Point3d(x: -3, y: 0, z: 0)))
        XCTAssertNil(UCSDefinition.fromThreePoints(origin: .zero,
                                                   xPoint: Point3d(x: 5, y: 0, z: 0),
                                                   yPoint: Point3d(x: -3, y: 0, z: 0)))
    }

    func testDegenerateFallbacksPreservePlanarity() {
        // Degenerate X direction falls back to the given angle.
        let fellBack = UCSDefinition.fromThreePointsAllowingDegenerate(
            origin: Point3d(x: 1, y: 2, z: 3),
            xPoint: Point3d(x: 1, y: 2, z: 3),
            yPoint: Point3d(x: 9, y: 9, z: 9),
            fallbackAngle: .pi / 4)
        XCTAssertEqual(fellBack.angle, .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(fellBack.origin.z, 3, accuracy: 1e-12)
        // Collinear Y side keeps the X-derived angle with Y at +90 CCW.
        let collinear = UCSDefinition.fromThreePointsAllowingDegenerate(
            origin: .zero,
            xPoint: Point3d(x: 4, y: 0, z: 5),
            yPoint: Point3d(x: -2, y: 0, z: -7))
        XCTAssertEqual(collinear.angle, 0, accuracy: 1e-12)
        XCTAssertEqual(collinear.yAxis.x, 0, accuracy: 1e-12)
        XCTAssertEqual(collinear.yAxis.y, 1, accuracy: 1e-12)
        // Tilted (off-elevation) inputs project onto the plane: X angle is
        // set by the XY projection, elevation stays at the origin.
        let tilted = UCSDefinition.fromThreePointsAllowingDegenerate(
            origin: Point3d(x: 0, y: 0, z: 10),
            xPoint: Point3d(x: 3, y: 4, z: -2),
            yPoint: Point3d(x: -4, y: 3, z: 99))
        XCTAssertEqual(tilted.angle, atan2(4, 3), accuracy: 1e-12)
        XCTAssertEqual(tilted.origin.z, 10, accuracy: 1e-12)
    }

    // MARK: - Planarity projection

    func testProjectToPlaneIsIdempotent() {
        let ucs = UCSDefinition(origin: Point3d(x: 1, y: 2, z: 3), angle: .pi / 4)
        let tilted = Point3d(x: -5, y: 7, z: 42)
        let once = ucs.projectToPlane(tilted)
        XCTAssertEqual(once.z, 3, accuracy: 1e-12)
        let twice = ucs.projectToPlane(once)
        XCTAssertEqual(twice.x, once.x, accuracy: 1e-12)
        XCTAssertEqual(twice.y, once.y, accuracy: 1e-12)
        XCTAssertEqual(twice.z, once.z, accuracy: 1e-12)
        // Round-trip identity: toWorld(toLocal(p)) == projectToPlane(p).
        let rt = ucs.toWorld(ucs.toLocal(tilted))
        XCTAssertEqual(rt.x, once.x, accuracy: 1e-9)
        XCTAssertEqual(rt.y, once.y, accuracy: 1e-9)
        XCTAssertEqual(rt.z, once.z, accuracy: 1e-12)
    }

    // MARK: - AngleConvention

    func testDefaultConventionIsIdentity() {
        let c = AngleConvention.default
        XCTAssertEqual(c.canonicalOrientation(fromUser: 1.0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(c.userOrientation(fromCanonical: 1.0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(c.canonicalDelta(fromUserDelta: -0.5), -0.5, accuracy: 1e-12)
    }

    func testBaseAngleShiftsOrientationsNotDeltas() {
        let c = AngleConvention(baseAngle: .pi / 2, clockwise: false)
        XCTAssertEqual(c.canonicalOrientation(fromUser: 0), .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(c.userOrientation(fromCanonical: .pi / 2), 0, accuracy: 1e-12)
        // Deltas are base-free.
        XCTAssertEqual(c.canonicalDelta(fromUserDelta: 0.7), 0.7, accuracy: 1e-12)
        XCTAssertEqual(c.userDelta(fromCanonicalDelta: 0.7), 0.7, accuracy: 1e-12)
    }

    func testClockwiseFlipsSense() {
        let c = AngleConvention(baseAngle: 0, clockwise: true)
        XCTAssertEqual(c.canonicalOrientation(fromUser: .pi / 4),
                       AngleConvention.normalize(-.pi / 4), accuracy: 1e-12)
        XCTAssertEqual(c.canonicalDelta(fromUserDelta: .pi / 4),
                       -.pi / 4, accuracy: 1e-12)
    }

    func testOrientationRoundTrip() {
        let conventions = [
            AngleConvention.default,
            AngleConvention(baseAngle: .pi / 2, clockwise: false),
            AngleConvention(baseAngle: .pi, clockwise: true),
            AngleConvention(baseAngle: 1.234, clockwise: true),
        ]
        for c in conventions {
            for u in [0.0, 0.3, 1.0, 2.5, 5.9] {
                let back = c.userOrientation(
                    fromCanonical: c.canonicalOrientation(fromUser: u))
                XCTAssertEqual(back, AngleConvention.normalize(u), accuracy: 1e-9)
            }
        }
    }

    // MARK: - UserPointParser

    func testParseAbsolute() {
        guard case .absolute(let x, let y, let z)? = UserPointParser.parse("3,4") else {
            return XCTFail("expected absolute")
        }
        XCTAssertEqual(x, 3); XCTAssertEqual(y, 4); XCTAssertNil(z)
        guard case .absolute(let x3, _, let z3)? = UserPointParser.parse(" 1.5 , -2.5 , 7 ") else {
            return XCTFail("expected 3D absolute")
        }
        XCTAssertEqual(x3, 1.5, accuracy: 1e-12)
        XCTAssertEqual(z3 ?? -1, 7, accuracy: 1e-12)
    }

    func testParseRelative() {
        guard case .relative(let dx, let dy, let dz)? = UserPointParser.parse("@5,-2") else {
            return XCTFail("expected relative")
        }
        XCTAssertEqual(dx, 5); XCTAssertEqual(dy, -2); XCTAssertNil(dz)
        guard case .relative(_, _, let dz3)? = UserPointParser.parse("@1,2,0.5") else {
            return XCTFail("expected 3D relative")
        }
        XCTAssertEqual(dz3 ?? -1, 0.5, accuracy: 1e-12)
    }

    func testParsePolar() {
        guard case .polar(let d, let a)? = UserPointParser.parse("10<45") else {
            return XCTFail("expected polar")
        }
        XCTAssertEqual(d, 10); XCTAssertEqual(a, 45)
    }

    func testParseRejectsMalformed() {
        for bad in ["", "   ", "abc", "1", "1,2,3,4", "@", "@1",
                    "1,,2", "1,2,", "10<", "<45", "10<<45", "1<2,3",
                    "@1<2", "1<2<3", "nan,2", "1,inf", "10<nan"] {
            XCTAssertNil(UserPointParser.parse(bad), "should reject: \(bad)")
        }
    }

    func testResolveAbsoluteUsesBaseElevation() {
        let base = Point3d(x: 9, y: 9, z: 4)
        let xy = UserPointParser.resolve(.absolute(x: 1, y: 2, z: nil),
                                         from: base,
                                         userAngleToCanonical: { $0 })
        XCTAssertEqual(xy.z, 4, accuracy: 1e-12)
        let xyz = UserPointParser.resolve(.absolute(x: 1, y: 2, z: 6),
                                          from: base,
                                          userAngleToCanonical: { $0 })
        XCTAssertEqual(xyz.z, 6, accuracy: 1e-12)
    }

    func testResolvePolarIdentityConvention() {
        let base = Point3d(x: 1, y: 1, z: 0)
        let p = UserPointParser.resolve(.polar(distance: 10, userAngleDegrees: 0),
                                        from: base,
                                        userAngleToCanonical: { $0 })
        XCTAssertEqual(p.x, 11, accuracy: 1e-9)
        XCTAssertEqual(p.y, 1, accuracy: 1e-9)
    }

    func testResolvePolarDecoupledUnderNonDefaultConvention() {
        // ANGBASE = North, ANGDIR = clockwise: user 0 deg means +Y.
        let convention = AngleConvention(baseAngle: .pi / 2, clockwise: true)
        let convert = { (userRadians: Double) in
            convention.canonicalOrientation(fromUser: userRadians)
        }
        let base = Point3d(x: 1, y: 2, z: 3)
        guard case .polar? = UserPointParser.parse("10<0") else {
            return XCTFail("expected polar")
        }
        let p = UserPointParser.resolve(
            UserPointParser.parse("10<0")!,
            from: base,
            userAngleToCanonical: convert)
        XCTAssertEqual(p.x, 1, accuracy: 1e-9)
        XCTAssertEqual(p.y, 12, accuracy: 1e-9)
        XCTAssertEqual(p.z, 3, accuracy: 1e-12)
        // Canonical math cross-check: user 90 deg CW-from-North is +X.
        let east = UserPointParser.resolve(
            UserPointParser.parse("10<90")!,
            from: base,
            userAngleToCanonical: convert)
        XCTAssertEqual(east.x, 11, accuracy: 1e-9)
        XCTAssertEqual(east.y, 2, accuracy: 1e-9)
    }

    func testResolveRelative() {
        let base = Point3d(x: 1, y: 2, z: 3)
        let p = UserPointParser.resolve(.relative(dx: 5, dy: -1, dz: nil),
                                        from: base,
                                        userAngleToCanonical: { $0 })
        XCTAssertEqual(p.x, 6, accuracy: 1e-12)
        XCTAssertEqual(p.y, 1, accuracy: 1e-12)
        XCTAssertEqual(p.z, 3, accuracy: 1e-12)
    }
}
