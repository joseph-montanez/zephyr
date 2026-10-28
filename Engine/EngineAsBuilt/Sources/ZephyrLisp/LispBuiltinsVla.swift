// VlaBuiltins: the minimal ActiveX underpinning (step 3).
//
// The seed corpus's entire Tier-2 surface is four functions: vl-load-com
// (called for effect at the top of every file), vlax-ename->vla-object,
// vla-getboundingbox (via vl-catch-all-apply with quoted out-symbols), and
// vlax-safearray->list. These four are implemented for real — the bounding
// box is computed from entity geometry — while the rest of vla-*/vlax-*
// stays deferred Tier 2. None of the four are in the 305-entry inventory;
// they are documented extensions pinned by LispVlaTests.

import ZephyrKernel

enum VlaBuiltins {
    static let table: [String: LispBuiltin] = [
        "VL-LOAD-COM": vlLoadCom,
        "VLAX-ENAME->VLA-OBJECT": vlaxEnameToVlaObject,
        "VLA-GETBOUNDINGBOX": vlaGetBoundingBox,
        "VLAX-SAFEARRAY->LIST": vlaxSafearrayToList,
        "VLA-INTERSECTWITH": vlaIntersectWith,
        "VLAX-CURVE-GETCLOSESTPOINTTO": vlaxCurveGetClosestPointTo,
    ]

    /// (vl-load-com): ActiveX startup hook. Zephyr has no COM runtime, so
    /// this is a no-op returning T — scripts call it defensively.
    private static func vlLoadCom(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vl-load-com", args, min: 0, max: 0)
        return .t
    }

    private static func vlaxEnameToVlaObject(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vlax-ename->vla-object", args, 1)
        switch args[0] {
        case let .entityName(handle): return .vlaObject(handle)
        case .vlaObject: return args[0] // Idempotent.
        default:
            throw LispError.typeMismatch(
                name: "vlax-ename->vla-object",
                expected: "entity name", got: args[0])
        }
    }

    /// (vla-getboundingbox obj 'minSym 'maxSym): binds the two out-symbols
    /// to 3D point lists and returns T. Throws when the entity is unknown
    /// (callers use vl-catch-all-apply and test the symbols after).
    private static func vlaGetBoundingBox(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vla-getboundingbox", args, 3)
        let handle: String
        switch args[0] {
        case let .vlaObject(h): handle = h
        case let .entityName(h): handle = h // Lenient: bare enames work too.
        default:
            throw LispError.typeMismatch(
                name: "vla-getboundingbox",
                expected: "VLA-OBJECT", got: args[0])
        }
        let minSym = try BuiltinArgs.symbol("vla-getboundingbox", args[1])
        let maxSym = try BuiltinArgs.symbol("vla-getboundingbox", args[2])
        let box = try await host.vlaBoundingBox(handle)
        _ = try env.assign(minSym, LispValue(list: box.min.map(LispValue.real)))
        _ = try env.assign(maxSym, LispValue(list: box.max.map(LispValue.real)))
        return .t
    }

    /// (vlax-safearray->list arr): Zephyr safearrays ARE lists (see
    /// vla-getboundingbox), so this validates and returns its argument.
    private static func vlaxSafearrayToList(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vlax-safearray->list", args, 1)
        guard args[0].properList != nil else {
            throw LispError.typeMismatch(
                name: "vlax-safearray->list",
                expected: "safearray (list)", got: args[0])
        }
        return args[0]
    }

    // MARK: - Kernel-backed curve queries (ZephyrKernel)

    private static func vlaHandle(_ name: String, _ value: LispValue) throws -> String {
        switch value {
        case let .vlaObject(h): return h
        case let .entityName(h): return h
        default:
            throw LispError.typeMismatch(name: name, expected: "VLA-OBJECT", got: value)
        }
    }

    /// (vla-intersectwith obj1 obj2 [mode]): all intersections of two
    /// entities' analytical curves. Mode mirrors acExtend*: 0 none
    /// (default), 1 extend this, 2 extend other, 3 extend both.
    /// Returns a list of 3D points (elevation of the first entity).
    private static func vlaIntersectWith(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vla-intersectwith", args, min: 2, max: 3)
        let h1 = try vlaHandle("vla-intersectwith", args[0])
        let h2 = try vlaHandle("vla-intersectwith", args[1])
        var mode = 0
        if args.count == 3 {
            guard let m = args[2].asDouble, m == m.rounded() else {
                throw LispError.typeMismatch(
                    name: "vla-intersectwith", expected: "extend mode (0-3)", got: args[2])
            }
            mode = Int(m)
        }
        guard (0...3).contains(mode) else {
            throw LispError.typeMismatch(
                name: "vla-intersectwith", expected: "extend mode (0-3)", got: args[2])
        }
        let (curves1, z1) = try await kernelCurves(for: h1, host: host, name: "vla-intersectwith")
        let (curves2, _) = try await kernelCurves(for: h2, host: host, name: "vla-intersectwith")
        let extendA = (mode == 1 || mode == 3)
        let extendB = (mode == 2 || mode == 3)
        var pts: [Point2d] = []
        for c1 in curves1 {
            for c2 in curves2 {
                for hit in Intersector2D.intersect(c1, c2, extendA: extendA, extendB: extendB) {
                    pts.append(hit.point)
                }
            }
        }
        // Global dedupe: polyline edges share vertices.
        var clean: [Point2d] = []
        for p in pts {
            if !clean.contains(where: { $0.distanceSquared(to: p) <= 1e-18 }) {
                clean.append(p)
            }
        }
        return LispValue(list: clean.map {
            LispValue(list: [.real($0.x), .real($0.y), .real(z1)])
        })
    }

    /// (vlax-curve-getclosestpointto obj point [extend]): closest point on
    /// the entity's analytical curves to the given point.
    private static func vlaxCurveGetClosestPointTo(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vlax-curve-getclosestpointto", args, min: 2, max: 3)
        let handle = try vlaHandle("vlax-curve-getclosestpointto", args[0])
        let given = try BuiltinArgs.point("vlax-curve-getclosestpointto", args[1])
        let extend = args.count == 3 ? args[2].isTrue : false
        let (curves, z) = try await kernelCurves(for: handle, host: host,
                                                 name: "vlax-curve-getclosestpointto")
        let query = Point2d(x: given[0], y: given[1])
        var best: CurveProjection2d? = nil
        for curve in curves {
            let proj = Projector2D.closestPointOnCurve(curve, to: query, clamped: !extend)
            if best == nil || proj.distance < best!.distance { best = proj }
        }
        guard let found = best else { return .nilValue }
        return LispValue(list: [.real(found.point.x), .real(found.point.y), .real(z)])
    }

    /// Analytical kernel curves for an entity, parsed from its entget assoc
    /// list (world coordinates). Supports LINE, CIRCLE, ARC, LWPOLYLINE,
    /// ELLIPSE, RAY, XLINE. SPLINE and anything else throw a clean error
    /// rather than a silently wrong answer.
    private static func kernelCurves(
        for handle: String, host: any LispHost, name: String
    ) async throws -> ([Curve2d], Double) {
        let assoc = try await host.entGet(handle)
        guard let pairs = assoc.properList else {
            throw LispError.typeMismatch(name: name, expected: "entget assoc list", got: assoc)
        }
        var codes: [(Int, LispValue)] = []
        for pair in pairs {
            if case let .cons(head: .int(code), tail: value) = pair {
                codes.append((code, value))
            }
        }
        func first(_ code: Int) -> LispValue? {
            codes.first { $0.0 == code }?.1
        }
        func point3(_ code: Int) throws -> [Double] {
            guard let v = first(code), let p = v.asPoint, p.count == 3 else {
                throw LispError.typeMismatch(name: name, expected: "3D point (group \(code))",
                                            got: first(code) ?? .nilValue)
            }
            return p
        }
        func real(_ code: Int, default d: Double = 0) throws -> Double {
            guard let v = first(code), let r = v.asDouble else {
                if first(code) == nil { return d }
                throw LispError.typeMismatch(name: name, expected: "real (group \(code))",
                                            got: first(code) ?? .nilValue)
            }
            return r
        }
        func int(_ code: Int, default d: Int = 0) -> Int {
            guard let v = first(code), let r = v.asDouble else { return d }
            return Int(r)
        }
        guard case let .string(etype) = first(0) else {
            throw LispError.typeMismatch(name: name, expected: "entity type (group 0)",
                                        got: first(0) ?? .nilValue)
        }
        func pt2(_ p: [Double]) -> Point2d { Point2d(x: p[0], y: p[1]) }
        let deg2rad = Double.pi / 180.0
        switch etype {
        case "LINE":
            let a = try point3(10), b = try point3(11)
            return ([.line(LineSeg2d(start: pt2(a), end: pt2(b)))], a[2])
        case "CIRCLE":
            let c = try point3(10)
            return ([.circle(Circle2d(center: pt2(c), radius: try real(40)))], c[2])
        case "ARC":
            let c = try point3(10)
            let arc = Arc2d.fromDXFAngles(center: pt2(c), radius: try real(40),
                                          startAngle: try real(50) * deg2rad,
                                          endAngle: try real(51) * deg2rad)
            return ([.arc(arc)], c[2])
        case "LWPOLYLINE":
            let closed = (int(70) & 1) != 0
            var verts: [(p: Point2d, z: Double, bulge: Double, w0: Double, w1: Double)] = []
            var cur: (p: Point2d, z: Double, bulge: Double, w0: Double, w1: Double)? = nil
            func flush() {
                if let c = cur { verts.append(c) }
                cur = nil
            }
            for (code, value) in codes {
                switch code {
                case 10:
                    flush()
                    guard let p = value.asPoint, p.count == 3 else {
                        throw LispError.typeMismatch(name: name, expected: "3D vertex (group 10)", got: value)
                    }
                    cur = (pt2(p), p[2], 0, 0, 0)
                case 42:
                    guard let r = value.asDouble else {
                        throw LispError.typeMismatch(name: name, expected: "bulge (group 42)", got: value)
                    }
                    cur?.bulge = r
                case 40:
                    guard let r = value.asDouble else {
                        throw LispError.typeMismatch(name: name, expected: "width (group 40)", got: value)
                    }
                    cur?.w0 = r
                case 41:
                    guard let r = value.asDouble else {
                        throw LispError.typeMismatch(name: name, expected: "width (group 41)", got: value)
                    }
                    cur?.w1 = r
                default: break
                }
            }
            flush()
            guard verts.count >= 2 else {
                throw LispError.typeMismatch(name: name, expected: "2+ vertices", got: .nilValue)
            }
            let n = closed ? verts.count : verts.count - 1
            var curves: [Curve2d] = []
            curves.reserveCapacity(n)
            for i in 0..<n {
                let a = verts[i], b = verts[(i + 1) % verts.count]
                curves.append(.polySegment(PolySegment2d(
                    index: i, start: a.p, end: b.p, bulge: a.bulge,
                    startWidth: a.w0, endWidth: a.w1)))
            }
            return (curves, verts[0].z)
        case "ELLIPSE":
            let c = try point3(10)
            let m = try point3(11)
            let e = Ellipse2d(center: pt2(c),
                              majorAxis: Vec2d(x: m[0], y: m[1]),
                              minorRatio: try real(40))
            return ([.ellipse(e)], c[2])
        case "RAY":
            let s = try point3(10)
            let d = try point3(11)
            return ([.ray(Ray2d(origin: pt2(s), direction: Vec2d(x: d[0], y: d[1])))], s[2])
        case "XLINE":
            let s = try point3(10)
            let d = try point3(11)
            return ([.xline(XLine2d(origin: pt2(s), direction: Vec2d(x: d[0], y: d[1])))], s[2])
        default:
            throw LispError.unsupportedStub("\(name): unsupported entity type \(etype)")
        }
    }
}
