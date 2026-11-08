import XCTest
import ZephyrKernel
import ZephyrLisp
@testable import ZephyrCore

/// PR0 mirror/reflection foundation.
///
/// Kernel-bridge round trips for reflected geometry (axis mirror and a
/// rotation-composed mirror, which the old `scale.x * scale.y` check
/// missed), plus the PR0 sysvar defaults and the `$MIRRTEXT` header wiring.
final class MirrorReflectionRoundTripTests: XCTestCase {

    // MARK: - Reflection fixtures

    /// Mirror across the Y axis: (x, y) -> (-x, y). Determinant -1.
    private var mirrorX: Transform3D {
        Transform3D(raw: [-1, 0, 0, 0,
                           0, 1, 0, 0,
                           0, 0, 1, 0,
                           0, 0, 0, 1])
    }

    /// Mirror composed with rotation (x/y swap): determinant -1, but every
    /// per-axis scale magnitude stays positive, so sign-product checks miss it.
    private var swapXY: Transform3D {
        Transform3D(raw: [0, 1, 0, 0,
                          1, 0, 0, 0,
                          0, 0, 1, 0,
                          0, 0, 0, 1])
    }

    // MARK: - Orientation check

    func testOrientationCheckDetectsMirrors() {
        XCTAssertTrue(mirrorX.reversesOrientation2D)
        XCTAssertTrue(swapXY.reversesOrientation2D)
        XCTAssertFalse(Transform3D.identity.reversesOrientation2D)
        XCTAssertFalse(Transform3D.rotated(by: .pi / 4).reversesOrientation2D)
        XCTAssertFalse(Transform3D.rotated(by: .pi).reversesOrientation2D)
        XCTAssertFalse(Transform3D.scaled(by: Vector3(x: 2, y: 2, z: 1)).reversesOrientation2D)
        // Double mirror is rotation-equivalent: orientation preserved.
        XCTAssertFalse(Transform3D.scaled(by: Vector3(x: -2, y: -2, z: 1)).reversesOrientation2D)
    }

    // MARK: - Reflected line

    func testReflectedLineRoundTrip() {
        let start = Vector3(x: 1, y: 2, z: 0)
        let end = Vector3(x: 5, y: 6, z: 0)
        for transform in [mirrorX, swapXY] {
            let worldStart = transform.transformPoint(start)
            let worldEnd = transform.transformPoint(end)
            let world: CADPrimitive = .line(start: worldStart, end: worldEnd, color: nil)
            let curves = world.toKernelCurves()
            XCTAssertEqual(curves.count, 1)
            guard case let .line(seg) = curves[0] else {
                XCTFail("expected kernel line")
                continue
            }
            XCTAssertEqual(seg.start.x, worldStart.x, accuracy: 1e-12)
            XCTAssertEqual(seg.start.y, worldStart.y, accuracy: 1e-12)
            XCTAssertEqual(seg.end.x, worldEnd.x, accuracy: 1e-12)
            XCTAssertEqual(seg.end.y, worldEnd.y, accuracy: 1e-12)
            guard case let .line(backStart, backEnd, _) = CADPrimitive.fromKernelCurve(
                curves[0], preservingColorFrom: world) else {
                XCTFail("expected rebuilt line")
                continue
            }
            XCTAssertEqual(backStart.x, worldStart.x, accuracy: 1e-12)
            XCTAssertEqual(backStart.y, worldStart.y, accuracy: 1e-12)
            XCTAssertEqual(backEnd.x, worldEnd.x, accuracy: 1e-12)
            XCTAssertEqual(backEnd.y, worldEnd.y, accuracy: 1e-12)
        }
    }

    // MARK: - Reflected arc

    func testReflectedArcRoundTrip() {
        let center = Vector3(x: 2, y: 1, z: 0)
        let radius = 5.0
        let startAngle = 0.3
        let endAngle = 1.3
        let localStart = Vector3(
            x: center.x + radius * cos(startAngle),
            y: center.y + radius * sin(startAngle), z: 0)
        let localEnd = Vector3(
            x: center.x + radius * cos(endAngle),
            y: center.y + radius * sin(endAngle), z: 0)
        let prim: CADPrimitive = .arc(
            center: center, radius: radius,
            startAngle: startAngle, endAngle: endAngle, color: nil)
        for transform in [mirrorX, swapXY] {
            let curves = TrimGeometryEngine.exactWorldCurves(for: prim, transform: transform)
            XCTAssertEqual(curves.count, 1)
            guard case let .arc(world) = curves[0] else {
                XCTFail("expected kernel arc")
                continue
            }
            let expectCenter = transform.transformPoint(center)
            XCTAssertEqual(world.center.x, expectCenter.x, accuracy: 1e-9)
            XCTAssertEqual(world.center.y, expectCenter.y, accuracy: 1e-9)
            XCTAssertEqual(world.radius, radius, accuracy: 1e-9)
            // Mirror flips the sweep handedness.
            XCTAssertEqual(world.sweep, -(endAngle - startAngle), accuracy: 1e-9)
            // World start is the image of the local start point.
            let worldStart = transform.transformPoint(localStart)
            XCTAssertEqual(world.startPoint.x, worldStart.x, accuracy: 1e-9)
            XCTAssertEqual(world.startPoint.y, worldStart.y, accuracy: 1e-9)

            // Round trip back through the bridge: the CW world arc must
            // come back as the same point set (CCW from the mirrored end
            // angle with the restored positive sweep), not its complement.
            guard case let .arc(center: rebuiltCenter, radius: rebuiltRadius, startAngle: rebuiltStart, endAngle: rebuiltEnd, color: _) = CADPrimitive.fromKernelCurve(
                curves[0], preservingColorFrom: prim) else {
                XCTFail("expected rebuilt arc")
                continue
            }
            XCTAssertEqual(rebuiltCenter.x, expectCenter.x, accuracy: 1e-9)
            XCTAssertEqual(rebuiltCenter.y, expectCenter.y, accuracy: 1e-9)
            XCTAssertEqual(rebuiltRadius, radius, accuracy: 1e-9)
            XCTAssertEqual(rebuiltEnd - rebuiltStart, endAngle - startAngle, accuracy: 1e-9)
            let worldEnd = transform.transformPoint(localEnd)
            let expectStartAngle = atan2(worldEnd.y - expectCenter.y, worldEnd.x - expectCenter.x)
            let expectEndAngle = atan2(worldStart.y - expectCenter.y, worldStart.x - expectCenter.x)
            XCTAssertEqual(rebuiltStart, expectStartAngle, accuracy: 1e-9)
            XCTAssertEqual(rebuiltEnd, expectEndAngle, accuracy: 1e-9)
        }
    }

    // MARK: - Reflected bulged polyline

    func testReflectedBulgedPolylineRoundTrip() {
        let local = CADPolyline(vertices: [
            CADPolylineVertex(
                position: Vector3(x: 0, y: 0, z: 0),
                bulge: 1.0, startWidth: 0, endWidth: 0),
            CADPolylineVertex(
                position: Vector3(x: 4, y: 0, z: 0),
                bulge: 0.0, startWidth: 0, endWidth: 0),
        ])
        // Independent oracle: midpoint of the local bulged edge.
        let localMid = local.point(onSegment: 0, t: 0.5)
        for transform in [mirrorX, swapXY] {
            let world = local.transformed(by: transform)
            // Mirror flips bulge handedness (the old scale-product check
            // never fired: magnitudes stay positive under any mirror).
            XCTAssertEqual(world.vertices[0].bulge, -1.0, accuracy: 1e-12)
            XCTAssertEqual(world.vertices[1].bulge, 0.0, accuracy: 1e-12)
            for (actual, want) in zip(world.points, local.points.map { transform.transformPoint($0) }) {
                XCTAssertEqual(actual.x, want.x, accuracy: 1e-12)
                XCTAssertEqual(actual.y, want.y, accuracy: 1e-12)
            }
            let segs = world.toKernelSegments()
            XCTAssertEqual(segs.count, 1)
            XCTAssertEqual(segs[0].bulge, -1.0, accuracy: 1e-12)
            guard case let .arc(arc) = segs[0].geometry else {
                XCTFail("expected kernel arc segment")
                continue
            }
            XCTAssertEqual(arc.radius, 2.0, accuracy: 1e-9)
            // Geometric oracle: arc midpoint is the mirrored local midpoint.
            let expectMid = transform.transformPoint(localMid)
            let midAngle = arc.startAngle + arc.sweep / 2
            XCTAssertEqual(
                arc.center.x + arc.radius * cos(midAngle), expectMid.x, accuracy: 1e-9)
            XCTAssertEqual(
                arc.center.y + arc.radius * sin(midAngle), expectMid.y, accuracy: 1e-9)
            // Full segment round trip preserves positions and bulges.
            let rebuilt = CADPolyline.fromKernelSegments(segs, isClosed: false, template: world)
            XCTAssertEqual(rebuilt.vertices.count, world.vertices.count)
            for (actual, want) in zip(rebuilt.vertices, world.vertices) {
                XCTAssertEqual(actual.position.x, want.position.x, accuracy: 1e-9)
                XCTAssertEqual(actual.position.y, want.position.y, accuracy: 1e-9)
                XCTAssertEqual(actual.bulge, want.bulge, accuracy: 1e-12)
            }
        }
    }

    // MARK: - Reflected spline

    func testReflectedSplineRoundTrip() {
        let controlPoints = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 1, y: 3, z: 0),
            Vector3(x: 4, y: 3, z: 0), Vector3(x: 5, y: 0, z: 0),
        ]
        let knots = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]
        let prim: CADPrimitive = .spline(
            controlPoints: controlPoints, knots: knots, degree: 3, weights: nil, color: nil)
        for transform in [mirrorX, swapXY] {
            let curves = TrimGeometryEngine.exactWorldCurves(for: prim, transform: transform)
            XCTAssertEqual(curves.count, 1)
            guard case let .spline(spline) = curves[0] else {
                XCTFail("expected kernel spline")
                continue
            }
            let mapped = controlPoints.map { transform.transformPoint($0).point2d }
            XCTAssertEqual(spline.controlPoints, mapped)
            XCTAssertEqual(spline.knots, knots)
            XCTAssertEqual(spline.degree, 3)
            XCTAssertNil(spline.weights)
            // The local-space bridge entry agrees on the mirrored primitive.
            let worldPrim: CADPrimitive = .spline(
                controlPoints: controlPoints.map { transform.transformPoint($0) },
                knots: knots, degree: 3, weights: nil, color: nil)
            XCTAssertEqual(worldPrim.toKernelCurves(), curves)
        }
    }

    // MARK: - PR0 sysvar foundation

    @MainActor
    private func makeHost() -> (LispCADHost, LispEnvironment) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        return (host, LispEnvironment())
    }

    @MainActor
    private func eval(_ source: String, host: LispCADHost, env: inout LispEnvironment) async throws -> LispValue {
        let forms = try LispReader().readAll(source)
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    @MainActor
    func testPR0SysvarDefaultsAndValidation() async throws {
        let (host, _) = makeHost()
        var env = LispEnvironment()
        do { let got = try await self.eval(#"(getvar "EDGEMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(0)) }
        do { let got = try await self.eval(#"(getvar "PROJMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
        do { let got = try await self.eval(#"(getvar "TRIMEXTENDMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
        do { let got = try await self.eval(#"(getvar "MIRRTEXT")"#, host: host, env: &env); XCTAssertEqual(got, .int(0)) }

        _ = try await self.eval(#"(setvar "EDGEMODE" 1)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "EDGEMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
        _ = try await self.eval(#"(setvar "PROJMODE" 2)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "PROJMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(2)) }
        _ = try await self.eval(#"(setvar "MIRRTEXT" 1)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "MIRRTEXT")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }

        // Out-of-range writes are rejected; stored values stay put.
        _ = try? await self.eval(#"(setvar "EDGEMODE" 2)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "EDGEMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
        _ = try? await self.eval(#"(setvar "PROJMODE" 5)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "PROJMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(2)) }
        _ = try? await self.eval(#"(setvar "MIRRTEXT" 5)"#, host: host, env: &env)
        do { let got = try await self.eval(#"(getvar "MIRRTEXT")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
    }

    @MainActor
    func testTrimExtendModeIsSingleSourceOfTruth() async throws {
        let savedMode = TrimCommand.preferredMode
        defer { TrimCommand.preferredMode = savedMode }
        let (host, _) = makeHost()
        var env = LispEnvironment()

        // Default is Quick on both surfaces (current AutoCAD default).
        TrimCommand.preferredMode = .quick
        XCTAssertEqual(TrimSettings.trimExtendMode, 1)
        do { let got = try await self.eval(#"(getvar "TRIMEXTENDMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }

        // setvar drives the command default ...
        _ = try await self.eval(#"(setvar "TRIMEXTENDMODE" 0)"#, host: host, env: &env)
        XCTAssertEqual(TrimCommand.preferredMode, .standard)
        // ... and the command default drives getvar back.
        TrimCommand.preferredMode = .quick
        do { let got = try await self.eval(#"(getvar "TRIMEXTENDMODE")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }

        // Out-of-range writes are rejected; the mode stays put.
        _ = try? await self.eval(#"(setvar "TRIMEXTENDMODE" 3)"#, host: host, env: &env)
        XCTAssertEqual(TrimCommand.preferredMode, .quick)
        XCTAssertEqual(TrimSettings.trimExtendMode, 1)
    }

    @MainActor
    func testPickFirstSysvarDefaultAndValidation() async throws {
        let savedPick = PickFirstSettings.pickFirst
        defer { PickFirstSettings.pickFirst = savedPick }
        let (host, _) = makeHost()
        var env = LispEnvironment()

        // Default is on (noun/verb selection).
        PickFirstSettings.pickFirst = 1
        do { let got = try await self.eval(#"(getvar "PICKFIRST")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }

        // setvar drives the shared backing ...
        _ = try await self.eval(#"(setvar "PICKFIRST" 0)"#, host: host, env: &env)
        XCTAssertEqual(PickFirstSettings.pickFirst, 0)
        do { let got = try await self.eval(#"(getvar "PICKFIRST")"#, host: host, env: &env); XCTAssertEqual(got, .int(0)) }
        _ = try await self.eval(#"(setvar "PICKFIRST" 1)"#, host: host, env: &env)
        XCTAssertEqual(PickFirstSettings.pickFirst, 1)

        // Out-of-range writes are rejected; the value stays put.
        _ = try? await self.eval(#"(setvar "PICKFIRST" 5)"#, host: host, env: &env)
        XCTAssertEqual(PickFirstSettings.pickFirst, 1)
        do { let got = try await self.eval(#"(getvar "PICKFIRST")"#, host: host, env: &env); XCTAssertEqual(got, .int(1)) }
    }

    // MARK: - $MIRRTEXT header wiring

    private func headerInt(_ dxf: String, _ name: String) -> String? {
        let lines = dxf.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let index = lines.firstIndex(of: name), index + 2 < lines.count else { return nil }
        return lines[index + 2]
    }

    func testWriterEmitsStoredMirrText() {
        let writer = DXFWriter()
        XCTAssertEqual(headerInt(writer.writeToString(), "$MIRRTEXT"), "0")
        writer.headerVars["$MIRRTEXT"] = 1
        XCTAssertEqual(headerInt(writer.writeToString(), "$MIRRTEXT"), "1")
        // Int32 storage (as the reader may hold) is honored too.
        writer.headerVars["$MIRRTEXT"] = Int32(0)
        XCTAssertEqual(headerInt(writer.writeToString(), "$MIRRTEXT"), "0")
    }

    func testReaderCapturesMirrText() throws {
        let dxf = """
            0
            SECTION
            2
            HEADER
            9
            $MIRRTEXT
            70
            1
            0
            ENDSEC
            0
            EOF
            """
        let reader = try DXFReader().readString(dxf)
        XCTAssertEqual(reader.header.headerVars["$MIRRTEXT"] as? Int, 1)
    }
}
