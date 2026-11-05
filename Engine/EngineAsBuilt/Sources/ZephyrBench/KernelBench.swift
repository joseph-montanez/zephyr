import Foundation
import ZephyrCore
import ZephyrKernel

// =========================================================================
// MARK: - ZephyrKernel perf gates (PLAN-kernel-perf.md Step 3)
//
// Merge-gate bench cases for the kernel branch. Each reports wall time +
// peak RSS via the shared `measure` harness. Budgets:
//   * snap Tier 3 <= 2 ms p95 @10k entities (synthetic grid drawing)
//   * trim/offset kernel paths <= current explode-based equivalents
// Run: swift run -c release ZephyrBench kernel

extension Cases {
    /// Differential gate: kernel solvers must agree with the legacy
    /// ZephyrCore math they replace. Any mismatch is fatal (merge gate).
    static func kernelAgreementGate() {
        var checked = 0
        func agree(_ a: Double, _ b: Double, _ tol: Double, _ what: String) {
            checked += 1
            if abs(a - b) > tol { fatalError("kernel agreement FAILED: \(what) \(a) vs \(b)") }
        }
        // Line-line vs CADGeometryMath.segmentSegmentIntersection.
        for i in 0..<500 {
            let f = Double(i) * 0.37
            let a0 = Vector3(x: f, y: sin(f) * 10, z: 0)
            let a1 = Vector3(x: f + 20, y: cos(f) * 10, z: 0)
            let b0 = Vector3(x: f + 5, y: -30, z: 0)
            let b1 = Vector3(x: f + 5, y: 30, z: 0)
            let legacy = CADGeometryMath.segmentSegmentIntersection(a: a0, b: a1, c: b0, d: b1)
            let kern = Intersector2D.intersectLineLine(
                LineSeg2d(start: a0.point2d, end: a1.point2d),
                LineSeg2d(start: b0.point2d, end: b1.point2d),
                extendA: false, extendB: false)
            switch (legacy, kern.first) {
            case (nil, nil): break
            case (let l?, let k?):
                agree(l.t, k.paramA, 1e-9, "line-line t")
                agree(l.point.x, k.point.x, 1e-9, "line-line x")
            default:
                fatalError("kernel agreement FAILED: line-line hit mismatch")
            }
        }
        // Line-arc vs the legacy segment-circle quadratic (independent
        // reference: same closed form TrimGeometryEngine used pre-kernel).
        func legacySegmentCircle(_ a: Vector3, _ b: Vector3, c: Vector3, r: Double) -> [Vector3] {
            let dx = b.x - a.x, dy = b.y - a.y
            let fx = a.x - c.x, fy = a.y - c.y
            let qa = dx * dx + dy * dy
            let qb = 2.0 * (fx * dx + fy * dy)
            let qc = fx * fx + fy * fy - r * r
            let disc = qb * qb - 4.0 * qa * qc
            if disc < 0 { return [] }
            let sq = sqrt(disc)
            let t1 = (-qb - sq) / (2.0 * qa), t2 = (-qb + sq) / (2.0 * qa)
            var out: [Vector3] = []
            if t1 >= -1e-9 && t1 <= 1.0 + 1e-9 {
                out.append(Vector3(x: a.x + t1 * dx, y: a.y + t1 * dy, z: a.z))
            }
            if t2 >= -1e-9 && t2 <= 1.0 + 1e-9 && abs(t2 - t1) > 1e-12 {
                out.append(Vector3(x: a.x + t2 * dx, y: a.y + t2 * dy, z: a.z))
            }
            return out
        }
        for i in 0..<500 {
            let f = Double(i) * 1.13
            let c = Vector3(x: f, y: f * 0.5, z: 0)
            let legacy = legacySegmentCircle(
                Vector3(x: f - 20, y: f * 0.5 + 3, z: 0),
                Vector3(x: f + 20, y: f * 0.5 + 3, z: 0),
                c: c, r: 10)
            let kern = Intersector2D.intersectLineArc(
                LineSeg2d(start: Point2d(x: f - 20, y: f * 0.5 + 3),
                            end: Point2d(x: f + 20, y: f * 0.5 + 3)),
                Arc2d(center: c.point2d, radius: 10, startAngle: 0, sweep: 2.0 * .pi),
                extendLine: true, extendArc: false)
            guard legacy.count == kern.count else {
                fatalError("kernel agreement FAILED: line-circle count \(legacy.count) vs \(kern.count)")
            }
            for (l, k) in zip(legacy.sorted { $0.x < $1.x }, kern.sorted { $0.point.x < $1.point.x }) {
                agree(l.x, k.point.x, 1e-9, "line-circle x")
                agree(l.y, k.point.y, 1e-9, "line-circle y")
            }
        }
        // Spline: kernel De Boor vs NURBSEvaluator at 200 params.
        let cps3 = (0..<8).map { Vector3(x: Double($0) * 3, y: sin(Double($0)) * 4, z: 0) }
        let knots3 = [0, 0, 0, 0.2, 0.35, 0.5, 0.65, 0.8, 1, 1, 1]
        let kern3 = Spline2d(controlPoints: cps3.map { $0.point2d }, knots: knots3, degree: 2)
        for i in 0...200 {
            let u = Double(i) / 200.0
            let ref = NURBSEvaluator.evaluateAt(degree: 2, knots: knots3, controlPoints: cps3,
                                                weights: nil, at: u)
            let got = SplineEval.evaluate(kern3, at: u)
            switch (ref, got) {
            case (let r?, let g?):
                agree(r.x, g.x, 1e-9, "spline x")
                agree(r.y, g.y, 1e-9, "spline y")
            default:
                fatalError("kernel agreement FAILED: spline eval nil mismatch")
            }
        }
        // Line-spline: kernel vs legacy NURBSEvaluator sampler. Crossings
        // are interior to the cutter (away from ends) so both solvers must
        // agree on count and position; positions within chord tolerance.
        // Divergences print (not fatal) for diagnosis; the gate fails after.
        var splineMismatches = 0
        let splineBattery: [Spline2d] = [
            Spline2d(controlPoints: [.zero, Point2d(x: 5, y: 10), Point2d(x: 10, y: 0)],
                     knots: [0, 0, 0, 1, 1, 1], degree: 2),
            Spline2d(controlPoints: [Point2d(x: 0, y: 0), Point2d(x: 3, y: 8),
                                      Point2d(x: 7, y: -8), Point2d(x: 10, y: 0)],
                     knots: [0, 0, 0, 0, 1, 1, 1, 1], degree: 3),
            Spline2d(controlPoints: [Point2d(x: 0, y: 0), Point2d(x: 4, y: 6),
                                      Point2d(x: 8, y: 6), Point2d(x: 12, y: 0)],
                     knots: [0, 0, 0, 0, 1, 1, 1, 1], degree: 3),
        ]
        for (si, ks) in splineBattery.enumerated() {
            guard let (ku0, ku1) = SplineEval.domain(of: ks) else { continue }
            let kcps = ks.controlPoints.map { Vector3(x: $0.x, y: $0.y, z: 0) }
            for i in 0..<200 {
                let y = -4.0 + Double(i) * 0.09
                let x0 = -3.0 + Double((i * 7) % 13), x1 = x0 + 16.0
                let a = Vector3(x: x0, y: y, z: 0), b = Vector3(x: x1, y: y, z: 0)
                let legacy = NURBSEvaluator.findIntersectionParameters(
                    degree: ks.degree, knots: ks.knots, controlPoints: kcps,
                    weights: ks.weights, segmentA: a, segmentB: b, searchSegments: 96)
                let kern = Intersector2D.intersect(
                    .line(LineSeg2d(start: a.point2d, end: b.point2d)), .spline(ks))
                // Keep only interior crossings for the comparison (legacy
                // accepts 1e-4 past cutter ends; kernel is strict).
                let legIn = legacy.filter { p in
                    let t = ((p.point.x - x0) / max(x1 - x0, 1e-12))
                    return t > 1e-3 && t < 1 - 1e-3
                }
                guard legIn.count == kern.count else {
                    if splineMismatches < 10 {
                        print("DIVERGE count spline\(si) i\(i) legacy \(legIn.count) vs kernel \(kern.count)")
                        print("  line (\(x0),\(y))-(\(x1),\(y))")
                    }
                    splineMismatches += 1
                    continue
                }
                for l in legIn {
                    guard let k = kern.min(by: {
                        $0.point.distanceSquared(to: l.point.point2d) < $1.point.distanceSquared(to: l.point.point2d)
                    }) else { continue }
                    let dx = abs(k.point.x - l.point.x), dy = abs(k.point.y - l.point.y)
                    if dx > 1e-6 || dy > 1e-6 {
                        if splineMismatches < 10 {
                            print("DIVERGE pos spline\(si) i\(i) dx=\(dx) dy=\(dy)")
                        }
                        splineMismatches += 1
                    }
                    checked += 2
                }
                _ = (ku0, ku1)
            }
        }
        // Arc bulge: kernel fromBulge vs CADPolyline.arcParameters.
        if splineMismatches > 0 {
            fatalError("kernel agreement FAILED: \(splineMismatches) line-spline divergences")
        }
        for i in 0..<200 {
            let b = 0.02 + Double(i) * 0.01
            let p0 = Vector3(x: Double(i), y: 0, z: 0)
            let p1 = Vector3(x: Double(i) + 10, y: 5, z: 0)
            let pl = CADPolyline(points: [p0, p1])
            var pv = pl
            pv.vertices[0].bulge = b
            guard let ref = pv.arcParameters(forSegment: 0),
                  let got = Arc2d.fromBulge(start: p0.point2d, end: p1.point2d, bulge: b) else {
                fatalError("kernel agreement FAILED: bulge nil")
            }
            agree(ref.center.x, got.center.x, 1e-9, "bulge cx")
            agree(ref.center.y, got.center.y, 1e-9, "bulge cy")
            agree(ref.radius, got.radius, 1e-9, "bulge r")
            agree(ref.sweep, got.sweep, 1e-12, "bulge sweep")
        }
        print("kernel agreement gate: \(checked) comparisons passed")
        _ = checked
    }

    /// Screenshot-repro probe (Oct 2025): sweep click positions along a
    /// screenshot-like spline through the REAL TrimGeometryEngine.
    /// trimPrimitive and print kept-span signatures; hit positions show
    /// as discontinuities. Cutters derive from the curve itself so
    /// crossings are guaranteed; variants cover end-touch and extension.
    @MainActor
    static func kernelTrimDebugCheck() {        print("--- trim click-sweep probe (real trimPrimitive) ---")
        let cps = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 30, y: 70, z: 0),
                   Vector3(x: 90, y: 70, z: 0), Vector3(x: 115, y: 5, z: 0)]
        let knots = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]
        func sPoint(_ t: Double) -> Vector3 {
            NURBSEvaluator.evaluateAt(degree: 3, knots: knots, controlPoints: cps,
                                      weights: nil, at: t) ?? .zero
        }
        let splinePrim = CADPrimitive.spline(controlPoints: cps, knots: knots,
                                             degree: 3, weights: nil, color: nil)
        // Cutter A: chord S(0.30)->S(0.85), extended 8 units past the S(0.85)
        // end so it truly crosses the tail; end lands near the tail.
        let a0 = sPoint(0.30), a1 = sPoint(0.85)
        var d = Vector3(x: a1.x - a0.x, y: a1.y - a0.y, z: 0)
        let dl = hypot(d.x, d.y); d = Vector3(x: d.x / dl, y: d.y / dl, z: 0)
        let cutA: (Vector3, Vector3) = (
            Vector3(x: a0.x - d.x * 5, y: a0.y - d.y * 5, z: 0),
            Vector3(x: a1.x + d.x * 8, y: a1.y + d.y * 8, z: 0))
        // Cutter B: same chord but ENDING 6 units short of the tail
        // crossing (line end near tail, no touch).
        let cutB: (Vector3, Vector3) = (
            Vector3(x: a0.x - d.x * 5, y: a0.y - d.y * 5, z: 0),
            Vector3(x: a1.x - d.x * 6, y: a1.y - d.y * 6, z: 0))
        for (name, cutters) in [("A-extended", [cutA]), ("B-short", [cutB])] {
            print("cutter \(name): (\(cutters[0].0.x),\(cutters[0].0.y))-(\(cutters[0].1.x),\(cutters[0].1.y))")
            // Attribute hits: kernel path vs legacy sampler on the cutter.
            let ks = Spline2d(controlPoints: cps.map { $0.point2d },
                              knots: knots, degree: 3, weights: nil)
            let kHits = Intersector2D.intersect(
                .line(LineSeg2d(start: cutters[0].0.point2d, end: cutters[0].1.point2d)),
                .spline(ks))
            let lHits = NURBSEvaluator.findIntersectionParameters(
                degree: 3, knots: knots, controlPoints: cps, weights: nil,
                segmentA: cutters[0].0, segmentB: cutters[0].1, searchSegments: 96)
            print("  kernel hits: \(kHits.map { String(format: "u=%.4f", $0.paramB) })")
            print("  legacy hits: \(lHits.map { String(format: "t=%.4f", $0.t) })")
            var prevSig = ""
            for i in 1..<20 {
                let t = Double(i) / 20.0
                let click = sPoint(t)
                let res = TrimGeometryEngine.trimPrimitive(
                    primitive: splinePrim, transform: .identity,
                    criterion: .click(point: click),
                    cuttingSegments: cutters, exactLines: cutters)
                var sig = "unmodified"
                if res.modified, let prims = res.result {
                    var total = 0.0
                    for p in prims {
                        if case let .spline(cp, kn, deg, w, _) = p {
                            total += knotLength(controlPoints: cp, knots: kn, degree: deg, weights: w)
                        } else { total += -1 }
                    }
                    sig = "prims=\(prims.count) keptLen=\(String(format: "%.1f", total))"
                } else if res.modified {
                    sig = "deleted"
                }
                let mark = sig == prevSig ? "" : "  <-- change"
                print(String(format: "  click t=%.2f %@%@", t, sig, mark))
                prevSig = sig
            }
            if prevSig.isEmpty { fatalError("trim probe produced no output") }
        }
        // Gate: mid-span click on the double-crossed spline must split it.
        let midClick = sPoint(0.5)
        let midRes = TrimGeometryEngine.trimPrimitive(
            primitive: splinePrim, transform: .identity,
            criterion: .click(point: midClick),
            cuttingSegments: [cutA], exactLines: [cutA])
        guard midRes.modified, let mp = midRes.result, mp.count == 2 else {
            fatalError("trim probe FAILED: mid click should split spline in two")
        }
    }

    /// DXF-driven trim attributor: loads a drawing, runs every spline
    /// against every line cutter through the real trimPrimitive, and dumps
    /// per-source hit sets (kernel / legacy / endpoint-touch) plus kept
    /// spans for a click sweep. Usage: ZephyrBench trim-debug <file.dxf>
    @MainActor
    static func trimDxfDebug(path: String) throws {
        try trimDxfDebug(path: path, click: nil)
    }

    @MainActor
    static func trimDxfDebug(path: String, click: Vector3?) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            print("skipped: no such file \(path)")
            return
        }
        let imported = try DXFImporter.importDXF(filePath: path)
        print("entities: \(imported.entities.count)")
        trimAttributor(entities: imported.entities, click: click)
    }

    /// Same attribution over a native .eab archive.
    /// Optional: append a world-space click point to run one exact trim:
    ///   trim-eab <file.eab> click <x> <y>
    @MainActor
    static func trimEabDebug(path: String) throws {
        try trimEabDebug(path: path, click: nil)
    }

    @MainActor
    static func trimEabDebug(path: String, click: Vector3?) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            print("skipped: no such file \(path)")
            return
        }
        let views = try EABReader.readViews(from: URL(fileURLWithPath: path))
        guard let doc = views.first?.document else {
            print("no views in \(path)")
            return
        }
        for (vi, v) in views.enumerated() {
            print("view \(vi) '\(v.name)' cam=(\(v.cameraState.offsetX),\(v.cameraState.offsetY)) zoom=\(v.cameraState.zoom) rot=\(v.cameraState.rotation)")
        }
        let entities = Array(doc.entitiesView)
        print("views: \(views.count) entities: \(entities.count)")
        trimAttributor(entities: entities, click: click)
    }

    @MainActor
    static func trimAttributor(entities: [CADEntity], click: Vector3? = nil) {
        struct WSpline { let prim: CADPrimitive; let cps: [Vector3]; let knots: [Double]; let degree: Int; let w: [Double]? }
        var splines: [WSpline] = []
        var cutters: [(Vector3, Vector3)] = []
        for e in entities {
            guard let geom = e.localGeometry else { continue }
            for prim in geom {
                switch prim {
                case let .line(s, en, _):
                    cutters.append((e.transform.transformPoint(s), e.transform.transformPoint(en)))
                case let .spline(cps, knots, degree, weights, _):
                    splines.append(WSpline(prim: prim,
                                            cps: cps.map { e.transform.transformPoint($0) },
                                            knots: knots, degree: degree, w: weights))
                default: break
                }
            }
        }
        print("splines: \(splines.count) cutters: \(cutters.count)")
        for (si, sp) in splines.enumerated() {
            print("spline \(si): degree \(sp.degree) knots=\(sp.knots)")
            for (ci, cp) in sp.cps.enumerated() {
                print(String(format: "  cp%d (%.3f, %.3f, %.3f)", ci, cp.x, cp.y, cp.z))
            }
            guard sp.knots.count == sp.cps.count + sp.degree + 1 else {
                print("spline \(si): bad knot count, skipping")
                continue
            }
            let u0 = sp.knots[sp.degree], u1 = sp.knots[sp.cps.count]
            let w = sp.w ?? Array(repeating: 1.0, count: sp.cps.count)
            let worldPrim = CADPrimitive.spline(controlPoints: sp.cps, knots: sp.knots,
                                               degree: sp.degree, weights: sp.w, color: nil)
            let ks = Spline2d(controlPoints: sp.cps.map { $0.point2d },
                              knots: sp.knots, degree: sp.degree, weights: sp.w)
            for (ci, cut) in cutters.enumerated() {
                print("cutter \(ci): (\(cut.0.x),\(cut.0.y))-(\(cut.1.x),\(cut.1.y))")
                let kHits = Intersector2D.intersect(
                    .line(LineSeg2d(start: cut.0.point2d, end: cut.1.point2d)), .spline(ks))
                let lHits = NURBSEvaluator.findIntersectionParameters(
                    degree: sp.degree, knots: sp.knots, controlPoints: sp.cps,
                    weights: w, segmentA: cut.0, segmentB: cut.1, searchSegments: 96)
                print("  kernel: \(kHits.map { String(format: "u=%.9f", min(max(($0.paramB), 0), 1) * (u1 - u0) + u0) })")
                print("  kernel line-t: \(kHits.map { String(format: "tL=%.9f", $0.paramA) })")
                print("  legacy: \(lHits.map { String(format: "t=%.6f", $0.t) })")
                // Endpoint touch (legacy exactLines path): closest param of
                // each cutter endpoint, fired when within aperture.
                for (ei, ep) in [cut.0, cut.1].enumerated() {
                    let t = NURBSEvaluator.findClosestParameter(
                        degree: sp.degree, knots: sp.knots, controlPoints: sp.cps,
                        weights: w, to: ep, segments: 256)
                    if let p = NURBSEvaluator.evaluateAt(
                        degree: sp.degree, knots: sp.knots, controlPoints: sp.cps,
                        weights: w, at: t) {
                        let d = hypot(p.x - ep.x, p.y - ep.y)
                        print(String(format: "  endtouch e%d t=%.6f dist=%.6f", ei, t, d))
                    }
                }
                // Click sweep through the real trim.
                var prev = ""
                for i in 0...20 {
                    let u = u0 + (u1 - u0) * Double(i) / 20.0
                    guard let click = NURBSEvaluator.evaluateAt(
                        degree: sp.degree, knots: sp.knots, controlPoints: sp.cps,
                        weights: w, at: u) else { continue }
                    let res = TrimGeometryEngine.trimPrimitive(
                        primitive: worldPrim, transform: .identity,
                        criterion: .click(point: click),
                        cuttingSegments: [cut], exactLines: [cut])
                    var sig: String
                    if res.modified, let prims = res.result {
                        sig = prims.map { p in
                            if case let .spline(_, kn, _, _, _) = p {
                                return String(format: "[%.3f,%.3f]", kn.first ?? -1, kn.last ?? -1)
                            }
                            return "\(p)"
                        }.joined(separator: " ")
                    } else if res.modified {
                        sig = "deleted"
                    } else {
                        sig = "unmodified"
                    }
                    let mark = sig == prev ? "" : "  <--"
                    print(String(format: "  click u=%.4f %@%@", u, sig, mark))
                    prev = sig
                }
                // Off-curve click disc around the spline start (real user
                // clicks land off the curve): any click here must remove
                // only the first span. Reports tClick mapping + result.
                if let s0 = sp.cps.first {
                    print("  click-disc around spline start:")
                    for (dx, dy) in [(0.0, 0.0), (30.0, 0.0), (-30.0, 0.0), (0.0, 30.0), (0.0, -30.0),
                                      (60.0, -40.0), (-60.0, 40.0), (100.0, -80.0)] {
                        let qp = Vector3(x: s0.x + dx, y: s0.y + dy, z: 0)
                        let res = TrimGeometryEngine.trimPrimitive(
                            primitive: worldPrim, transform: .identity,
                            criterion: .click(point: qp),
                            cuttingSegments: [cut], exactLines: [cut])
                        var sig = "unmodified"
                        if res.modified, let prims = res.result {
                            sig = prims.map { p -> String in
                                if case let .spline(_, kn, _, _, _) = p {
                                    return String(format: "[%.3f,%.3f]", kn.first ?? -1, kn.last ?? -1)
                                }
                                return "?"
                            }.joined(separator: " ")
                        } else if res.modified {
                            sig = "deleted"
                        }
                        print(String(format: "    click (%.0f,%+.0f) -> %@", qp.x, qp.y - s0.y, sig))
                    }
                }
                // Round-trip check: trim each LINE entity against this exact
                // spline cutter (kernel path) and print kept spans.
                for (li, le) in entities.enumerated() {
                    guard let lg = le.localGeometry else { continue }
                    for lp in lg {
                        guard case let .line(ls, lend, _) = lp else { continue }
                        let wls = le.transform.transformPoint(ls)
                        let wle = le.transform.transformPoint(lend)
                        let exactCutter = Curve2d.spline(Spline2d(
                            controlPoints: sp.cps.map { $0.point2d },
                            knots: sp.knots, degree: sp.degree, weights: sp.w))
                        let mid = Vector3(x: 0.5 * (wls.x + wle.x),
                                        y: 0.5 * (wls.y + wle.y), z: 0)
                        let res = TrimGeometryEngine.trimPrimitive(
                            primitive: lp, transform: le.transform,
                            criterion: .click(point: mid),
                            cuttingSegments: [], exactLines: [],
                            exactCurves: [exactCutter])
                        // Direct fidelity check: re-intersect and compare the
                        // trim output endpoint params against the kernel's own
                        // parameters (separates trim error from measurement).
                        let wline = LineSeg2d(
                            start: le.transform.transformPoint(ls).point2d,
                            end: le.transform.transformPoint(lend).point2d)
                        let kh = Intersector2D.intersect(.line(wline), exactCutter)
                        var sig = "unmodified"
                        if res.modified, let prims = res.result {
                            sig = prims.map { p -> String in
                                if case let .line(a, b, _) = p {
                                    var extra = ""
                                    for e in [a.point2d, b.point2d] {
                                        let tl = CurveEval.paramAtPoint(.line(wline), point: e)
                                        if let near = kh.min(by: {
                                            abs($0.paramA - tl) < abs($1.paramA - tl) }) {
                                            let du = abs(near.paramA - tl)
                                            extra += String(format: " dparam=%.2e", du)
                                        }
                                    }
                                    return String(format: "[(%.2f,%.2f)-(%.2f,%.2f)]%@", a.x, a.y, b.x, b.y, extra)
                                }
                                return "\(p)"
                            }.joined(separator: " ")
                        } else if res.modified {
                            sig = "deleted"
                        }
                        print("  line \(li) vs exact spline: \(sig)")
                    }
                }
                // Exact user click (world coords): tClick mapping + result.
                if let qp = click {
                    let worldSpline = Spline2d(
                        controlPoints: sp.cps.map { $0.point2d },
                        knots: sp.knots, degree: sp.degree, weights: sp.w)
                    let allCutters = cutters.map {
                        Curve2d.line(LineSeg2d(start: $0.0.point2d, end: $0.1.point2d))
                    }
                    var allHits: [Double] = []
                    for c in allCutters {
                        for h in Intersector2D.intersect(.spline(worldSpline), c) {
                            allHits.append(h.paramA)
                        }
                    }
                    let tClick = CurveEval.paramAtPoint(.spline(worldSpline), point: qp.point2d)
                    let worldPrim = CADPrimitive.spline(controlPoints: sp.cps, knots: sp.knots,
                                                       degree: sp.degree, weights: sp.w, color: nil)
                    let rawSegs = cutters.map { ($0.0, $0.1) }
                    let res = TrimGeometryEngine.trimPrimitive(
                        primitive: worldPrim, transform: .identity,
                        criterion: .click(point: qp),
                        cuttingSegments: rawSegs, exactLines: rawSegs)
                    var sig = "unmodified"
                    if res.modified, let prims = res.result {
                        sig = prims.map { p -> String in
                            if case let .spline(_, kn, _, _, _) = p {
                                return String(format: "[%.4f,%.4f]", kn.first ?? -1, kn.last ?? -1)
                            }
                            return "?"
                        }.joined(separator: " ")
                    } else if res.modified {
                        sig = "deleted"
                    }
                    print(String(format: "  USERCLICK (%.2f,%.2f) tClick=%.4f hits=%@ -> %@",
                                 qp.x, qp.y, tClick,
                                 allHits.map { String(format: "%.4f", $0) }.joined(separator: ","), sig))
                }
            }
        }
    }

    /// Approximate knot-domain length of a spline (chord sum, 64 samples).
    static func knotLength(controlPoints: [Vector3], knots: [Double], degree: Int, weights: [Double]?) -> Double {
        var total = 0.0
        var prev: Vector3? = nil
        for i in 0...64 {
            let t = Double(i) / 64.0
            let u = knots[degree] + t * (knots[controlPoints.count] - knots[degree])
            if let p = NURBSEvaluator.evaluateAt(
                degree: degree, knots: knots, controlPoints: controlPoints, weights: weights, at: u) {
                if let q = prev { total += hypot(p.x - q.x, p.y - q.y) }
                prev = p
            }
        }
        return total
    }

    @MainActor
    static func kernel() {
        print("Kernel: Double-precision 2D solvers (ZephyrKernel)")
        kernelAgreementGate()
        kernelTrimDebugCheck()

        // 1. Bulge round-trip, 100k segments.
        measure("kernel bulge round-trip 100k") {
            var sink = 0.0
            for i in 0..<100_000 {
                let s = Point2d(x: Double(i) * 0.37, y: Double(i) * 0.11)
                let e = Point2d(x: s.x + 10.0, y: s.y + 3.0)
                let b = 0.05 + Double(i % 17) * 0.03
                if let arc = Arc2d.fromBulge(start: s, end: e, bulge: b) {
                    sink += arc.bulge + arc.radius
                }
            }
            if sink == 0 { fatalError("no arcs produced") }
        }

        // 2. Line-arc batch, 20k secant intersects at state-plane coords.
        measure("kernel line-arc 20k (state-plane)") {
            let ox = 2_450_192.8475, oy = 1_948_271.1250
            var hits = 0
            for i in 0..<20_000 {
                let cy = oy + Double(i % 401) - 200.0
                let arc = Arc2d(center: Point2d(x: ox, y: cy), radius: 100,
                                startAngle: 0, sweep: 2.0 * .pi)
                let line = LineSeg2d(start: Point2d(x: ox - 150, y: cy),
                                     end: Point2d(x: ox + 150, y: cy))
                hits += Intersector2D.intersectLineArc(line, arc, extendLine: false, extendArc: false).count
            }
            if hits != 40_000 { fatalError("expected 40000 hits, got \(hits)") }
        }

        // 3. Arc-arc batch, 20k.
        measure("kernel arc-arc 20k") {
            var hits = 0
            for i in 0..<20_000 {
                let off = Double(i % 97) * 0.5
                let a = Arc2d(center: Point2d(x: off, y: 0), radius: 5, startAngle: 0, sweep: 2.0 * .pi)
                let b = Arc2d(center: Point2d(x: off + 6, y: 0), radius: 5, startAngle: 0, sweep: 2.0 * .pi)
                hits += Intersector2D.intersectArcArc(a, b, extendA: false, extendB: false).count
            }
            if hits != 40_000 { fatalError("expected 40000 hits, got \(hits)") }
        }

        // 4. Spline-intersect batch, 2k line-vs-quadratic.
        measure("kernel line-spline 2k") {
            let s = Spline2d(controlPoints: [.zero, Point2d(x: 5, y: 10), Point2d(x: 10, y: 0)],
                             knots: [0, 0, 0, 1, 1, 1], degree: 2)
            var hits = 0
            for i in 0..<2_000 {
                let y = 5.0 + Double(i % 11) * 0.01
                let line = LineSeg2d(start: Point2d(x: -5, y: y), end: Point2d(x: 15, y: y))
                hits += Intersector2D.intersect(.line(line), .spline(s)).count
            }
            if hits == 0 { fatalError("no spline hits") }
        }

        // 5. Ellipse batch, 20k line-ellipse.
        measure("kernel line-ellipse 20k") {
            var hits = 0
            for i in 0..<20_000 {
                let cx = Double(i % 251) * 0.25
                let e = Ellipse2d(center: Point2d(x: cx, y: 0),
                                  majorAxis: Vec2d(x: 10, y: 0), minorRatio: 0.5)
                let line = LineSeg2d(start: Point2d(x: cx - 15, y: 0), end: Point2d(x: cx + 15, y: 0))
                hits += Intersector2D.intersect(.line(line), .ellipse(e)).count
            }
            if hits != 40_000 { fatalError("expected 40000 hits, got \(hits)") }
        }

        // 6. Polyline offset, 5k-vertex closed zigzag.
        measure("kernel offset 5k-vertex polyline") {
            var segs: [PolySegment2d] = []
            segs.reserveCapacity(5_000)
            for i in 0..<5_000 {
                let x0 = Double(i), y0 = Double((i % 2)) * 2.0
                let x1 = Double(i + 1), y1 = Double(((i + 1) % 2)) * 2.0
                segs.append(PolySegment2d(index: i, start: Point2d(x: x0, y: y0),
                                          end: Point2d(x: x1, y: y1), bulge: 0))
            }
            guard let out = Offset2D.offsetPolylineSegments(segs, isClosed: false, signedDistance: 1.0) else {
                fatalError("offset failed")
            }
            if out.isEmpty { fatalError("empty offset result") }
        }

        // 7. Synthetic snap queries: 10k and 50k entity grids, cursor parked
        // near one entity. Exercises Tier 1 AABB reject + Tier 3 on-curve.
        for count in [10_000, 50_000] {
            let layer = UUID()
            var entities: [CADEntity] = []
            entities.reserveCapacity(count)
            let cols = 100
            for i in 0..<count {
                let gx = Double(i % cols) * 50.0
                let gy = Double(i / cols) * 50.0
                let prim: CADPrimitive = (i % 5 == 0)
                    ? .circle(center: Vector3(x: gx, y: gy, z: 0), radius: 5)
                    : .line(start: Vector3(x: gx, y: gy, z: 0),
                            end: Vector3(x: gx + 20, y: gy + 5, z: 0))
                entities.append(CADEntity(layerID: layer, localGeometry: [prim]))
            }
            let engine = SnapEngine(threshold: 5.0)
            // Cursor near entity #4242's neighborhood.
            let qx = Double(4242 % cols) * 50.0 + 10.0
            let qy = Double(4242 / cols) * 50.0 + 2.0
            measure("kernel snap query \(count) entities", repeats: 5) {
                var found = 0
                for k in 0..<20 {
                    let r = engine.nearestSnap(
                        worldX: qx + Double(k) * 0.01, worldY: qy,
                        entities: entities, extensionSnapEnabled: false)
                    if r != nil { found += 1 }
                }
                if found != 20 { fatalError("snap missed (\(found)/20)") }
            }
        }
    }
}
