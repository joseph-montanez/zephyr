import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Lisp Entity Adapter (ename + DXF group-code assoc lists)
// =========================================================================
//
// Bridges `CADEntity` and the AutoLISP entity functions (entget/entmod/
// entmake/entdel/entnext/entlast/handent, ssget filters).
//
// Entity names: the entity UUID string, e.g.
// `<Entity name: 550E8400-E29B-...>`; group code 5 carries the same string,
// so handent round-trips. UUID strings are `read`-safe symbol constituents
// (letters, digits, hyphens), which corpus scripts rely on when they build
// symbols from handle strings.
//
// Type mapping: entities created by scripted commands and entmake carry a
// single primitive, which maps 1:1 to a DXF type name. Multi-primitive
// entities (imported geometry, dimensions, leaders) report their FIRST
// primitive's type — an accepted step-3 gap, documented at `dxfTypeName`.
// Angles are degrees in DXF codes (50/51) and radians internally.

enum LispEntityAdapter {

    // MARK: - Names

    static func ename(for handle: UUID) -> String { handle.uuidString }

    static func handle(fromEname name: String) -> UUID? { UUID(uuidString: name) }

    static func entityName(for handle: UUID) -> LispValue {
        .entityName(handle.uuidString)
    }

    // MARK: - List builders

    static func lispList(_ items: [LispValue]) -> LispValue {
        var out: LispValue = .nilValue
        for item in items.reversed() {
            out = .cons(head: item, tail: out)
        }
        return out
    }

    static func dotted(_ car: LispValue, _ cdr: LispValue) -> LispValue {
        .cons(head: car, tail: cdr)
    }

    static func pointValue(_ p: Vector3) -> LispValue {
        lispList([.real(p.x), .real(p.y), .real(p.z)])
    }

    // MARK: - entget

    static func entGetAssoc(entity: CADEntity, document: CADDocument) -> LispValue {
        var pairs: [LispValue] = [
            dotted(.int(-1), entityName(for: entity.handle)),
            dotted(.int(0), .string(dxfTypeName(entity: entity, document: document))),
            dotted(.int(5), .string(entity.handle.uuidString)),
            dotted(.int(8), .string(layerName(entity: entity, document: document))),
            dotted(.int(62), .int(entityACI(entity: entity))),
        ]
        let layer = document.layer(for: entity.layerID)
        let effectiveLineType: String? = {
            if let ltv = entity.xdata["dxf.lineType"], case .string(let s) = ltv { return s }
            return layer?.lineType
        }()
        if let lineType = effectiveLineType, lineType.uppercased() != "CONTINUOUS" {
            pairs.append(dotted(.int(6), .string(lineType)))
        }
        if let ltScale = entity.xdata["dxf.lineTypeScale"], case .double(let s) = ltScale {
            pairs.append(dotted(.int(48), .real(s)))
        }
        if let lw = entity.xdata["dxf.lineWeight"], case .double(let w) = lw {
            pairs.append(dotted(.int(370), .int(Int((w * 100.0).rounded()))))
        }
        if let c24 = entity.xdata["dxf.color24"], case .int(let val) = c24 {
            pairs.append(dotted(.int(420), .int(val)))
        }
        pairs += geometryPairs(entity: entity, document: document)
        return lispList(pairs)
    }

    /// DXF type name for ssget filters and (assoc 0 ...).
    ///
    /// - INSERT (blockID set) reports "INSERT" regardless of geometry.
    /// - Single-primitive entities report the primitive's type.
    /// - Multi-primitive entities report the FIRST primitive's type.
    ///   Generated dimension/leader geometry therefore reports as LINE /
    ///   LWPOLYLINE, not DIMENSION — accepted step-3 gap (reconstructing
    ///   dimension definitions from generated geometry is out of scope).
    static func dxfTypeName(entity: CADEntity, document: CADDocument) -> String {
        if entity.blockID != nil { return "INSERT" }
        guard let first = entity.localGeometry?.first else { return "UNKNOWN" }
        switch first {
        case .point: return "POINT"
        case .line: return "LINE"
        case .rect, .polygon, .polyline, .penStroke: return "LWPOLYLINE"
        case .fillRect, .fillPolygon, .fillComplexPolygon, .gradient: return "HATCH"
        case .circle: return "CIRCLE"
        case .arc: return "ARC"
        case .spline: return "SPLINE"
        case .text: return "TEXT"
        case .ellipse: return "ELLIPSE"
        case .hatch, .hatchPath: return "HATCH"
        case .ray: return "RAY"
        case .xline: return "XLINE"
        case .image: return "IMAGE"
        case .table: return "ACAD_TABLE"
        }
    }

    /// AutoCAD color index: explicit primitive color mapped through the ACI
    /// table, else 256 (BYLAYER).
    ///
    /// Exact-reverse first: colors that came from an ACI (entmake, scripted
    /// commands with CECOLOR) round-trip bit-for-bit. Nearest-match
    /// (`rgbaToACI`) is only the fallback for foreign RGB colors, which it
    /// can map to a different index than a human would pick.
    static func entityACI(entity: CADEntity) -> Int {
        for prim in entity.localGeometry ?? [] {
            if let color = primitiveColor(prim) {
                for aci in 1...255 {
                    if DXFColorTable.aciToRGBA(Int32(aci), color24: -1) == color {
                        return aci
                    }
                }
                return Int(DXFColorTable.rgbaToACI(color))
            }
        }
        return 256
    }

    static func layerName(entity: CADEntity, document: CADDocument) -> String {
        document.layer(for: entity.layerID)?.name ?? "0"
    }

    /// Returns the entity with every primitive color payload set to
    /// `color` (nil = BYLAYER). Mirrors `primitiveColor` payloads exactly
    /// so COLOR set/get round-trips.
    static func withPrimitiveColor(_ entity: CADEntity, _ color: ColorRGBA?) -> CADEntity {
        var copy = entity
        copy.localGeometry = entity.localGeometry?.map { recolored($0, color) }
        return copy
    }

    private static func recolored(_ prim: CADPrimitive, _ color: ColorRGBA?) -> CADPrimitive {
        switch prim {
        case let .point(position, _): return .point(position: position, color: color)
        case let .line(start, end, _): return .line(start: start, end: end, color: color)
        case let .rect(origin, size, _): return .rect(origin: origin, size: size, color: color)
        case let .fillRect(origin, size, _):
            return .fillRect(origin: origin, size: size, color: color)
        case let .polygon(points, _): return .polygon(points: points, color: color)
        case let .polyline(path, _): return .polyline(path: path, color: color)
        case let .fillPolygon(points, _):
            return .fillPolygon(points: points, color: color)
        case .fillComplexPolygon, .gradient: return prim // No color payload.
        case let .circle(center, radius, _):
            return .circle(center: center, radius: radius, color: color)
        case let .arc(center, radius, startAngle, endAngle, _):
            return .arc(
                center: center, radius: radius, startAngle: startAngle,
                endAngle: endAngle, color: color)
        case let .spline(controlPoints, knots, degree, weights, _):
            return .spline(
                controlPoints: controlPoints, knots: knots, degree: degree,
                weights: weights, color: color)
        case let .penStroke(vertices, baseLineWeight, _):
            return .penStroke(
                vertices: vertices, baseLineWeight: baseLineWeight, color: color)
        case let .text(position, text, height, rotation, style, alignH, alignV, mtextWidth, _):
            return .text(
                position: position, text: text, height: height,
                rotation: rotation, style: style, alignH: alignH,
                alignV: alignV, mtextWidth: mtextWidth, color: color)
        case let .ellipse(center, majorAxis, minorRatio, _):
            return .ellipse(
                center: center, majorAxis: majorAxis, minorRatio: minorRatio,
                color: color)
        case let .hatch(boundary, pattern, scale, angle, _, background):
            return .hatch(
                boundary: boundary, pattern: pattern, scale: scale,
                angle: angle, color: color, backgroundColor: background)
        case let .hatchPath(boundary, holes, pattern, scale, angle, _, background):
            return .hatchPath(
                boundary: boundary, holes: holes, pattern: pattern,
                scale: scale, angle: angle, color: color,
                backgroundColor: background)
        case let .ray(start, direction, _):
            return .ray(start: start, direction: direction, color: color)
        case let .xline(point, direction, _):
            return .xline(point: point, direction: direction, color: color)
        case let .image(insertion, uAxis, vAxis, imageName, clipBoundary, _):
            return .image(
                insertion: insertion, uAxis: uAxis, vAxis: vAxis,
                imageName: imageName, clipBoundary: clipBoundary, tint: color)
        case let .table(data, origin, _):
            return .table(data: data, origin: origin, color: color)
        }
    }

    static func primitiveColor(_ prim: CADPrimitive) -> ColorRGBA? {
        switch prim {
        case let .point(_, c): return c
        case let .line(_, _, c): return c
        case let .rect(_, _, c): return c
        case let .fillRect(_, _, c): return c
        case let .polygon(_, c): return c
        case let .polyline(_, c): return c
        case let .fillPolygon(_, c): return c
        case .fillComplexPolygon, .gradient: return nil
        case let .circle(_, _, c): return c
        case let .arc(_, _, _, _, c): return c
        case let .spline(_, _, _, _, c): return c
        case let .penStroke(_, _, c): return c
        case let .text(_, _, _, _, _, _, _, _, c): return c
        case let .ellipse(_, _, _, c): return c
        case let .hatch(_, _, _, _, c, _): return c
        case let .hatchPath(_, _, _, _, _, c, _): return c
        case let .ray(_, _, c): return c
        case let .xline(_, _, c): return c
        case .image(_, _, _, _, _, let tint): return tint
        case let .table(_, _, c): return c
        }
    }

    /// World-space point through the entity transform.
    private static func world(_ p: Vector3, _ t: Transform3D) -> Vector3 {
        t.transformPoint(p)
    }

    /// World-space direction vector (rotation + scale, no translation),
    /// computed by transforming two points so any affine content applies.
    private static func worldVector(_ v: Vector3, at c: Vector3, _ t: Transform3D) -> Vector3 {
        let wc = t.transformPoint(c)
        let wv = t.transformPoint(Vector3(x: c.x + v.x, y: c.y + v.y, z: c.z + v.z))
        return Vector3(x: wv.x - wc.x, y: wv.y - wc.y, z: wv.z - wc.z)
    }

    private static func geometryPairs(entity: CADEntity, document: CADDocument) -> [LispValue] {
        let t = entity.transform
        if let blockID = entity.blockID,
           let block = document.block(for: blockID)
        {
            return [
                dotted(.int(2), .string(block.name)),
                dotted(.int(10), pointValue(t.position)),
                dotted(.int(41), .real(t.scale.x)),
                dotted(.int(42), .real(t.scale.y)),
                dotted(.int(43), .real(t.scale.z)),
                dotted(.int(50), .real(t.rotation * 180 / Double.pi)),
            ]
        }
        guard let prim = entity.localGeometry?.first else { return [] }
        // All coordinates below are WORLD (local geometry × transform), so
        // entget after MOVE/ROTATE/COPY reports where geometry actually is.
        let rotDeg = t.rotation * 180 / Double.pi
        let sx = t.scale.x // Size groups assume uniform scale (exact for MOVE/ROTATE/COPY).
        switch prim {
        case let .point(position, _):
            return [dotted(.int(10), pointValue(world(position, t)))]
        case let .line(start, end, _):
            return [
                dotted(.int(10), pointValue(world(start, t))),
                dotted(.int(11), pointValue(world(end, t))),
            ]
        case let .circle(center, radius, _):
            return [
                dotted(.int(10), pointValue(world(center, t))),
                dotted(.int(40), .real(radius * sx)),
            ]
        case let .arc(center, radius, startAngle, endAngle, _):
            return [
                dotted(.int(10), pointValue(world(center, t))),
                dotted(.int(40), .real(radius * sx)),
                dotted(.int(50), .real(startAngle * 180 / Double.pi + rotDeg)),
                dotted(.int(51), .real(endAngle * 180 / Double.pi + rotDeg)),
            ]
        case let .polyline(path, _):
            return lwpolylinePairs(
                vertices: worldVertices(path.vertices, t),
                closed: path.isClosed, scale: sx)
        case let .polygon(points, _):
            return lwpolylinePairs(
                vertices: worldVertices(points.map {
                    CADPolylineVertex(position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                }, t), closed: true, scale: sx)
        case let .rect(origin, size, _):
            return lwpolylinePairs(
                vertices: worldVertices([
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                ].map {
                    CADPolylineVertex(position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                }, t), closed: true, scale: sx)
        case let .penStroke(vertices, _, _):
            return lwpolylinePairs(
                vertices: worldVertices(vertices.map {
                    CADPolylineVertex(position: $0.position, bulge: 0, startWidth: 0, endWidth: 0)
                }, t), closed: false, scale: sx)
        case let .text(position, text, height, rotation, style, alignH, alignV, _, _):
            return [
                dotted(.int(10), pointValue(world(position, t))),
                dotted(.int(40), .real(height * sx)),
                dotted(.int(1), .string(text)),
                dotted(.int(50), .real(rotation * 180 / Double.pi + rotDeg)),
                dotted(.int(7), .string(style ?? "Standard")),
                dotted(.int(72), .int(alignH)),
                dotted(.int(73), .int(alignV)),
            ]
        case let .ellipse(center, majorAxis, minorRatio, _):
            // majorAxis is a center-relative vector, matching DXF group 11.
            return [
                dotted(.int(10), pointValue(world(center, t))),
                dotted(.int(11), pointValue(worldVector(majorAxis, at: center, t))),
                dotted(.int(40), .real(minorRatio)),
            ]
        case let .spline(controlPoints, _, degree, _, _):
            var pairs: [LispValue] = [dotted(.int(71), .int(degree))]
            for cp in controlPoints {
                pairs.append(dotted(.int(10), pointValue(world(cp, t))))
            }
            return pairs
        case let .hatch(boundary, pattern, scale, angle, _, _):
            return hatchPairs(
                boundary: boundary.map { world($0, t) },
                pattern: pattern, scale: scale, angle: angle)
        case let .hatchPath(boundary, _, pattern, scale, angle, _, _):
            return hatchPairs(
                boundary: boundary.vertices.map { world($0.position, t) },
                pattern: pattern, scale: scale, angle: angle)
        case let .fillRect(origin, size, _):
            return hatchPairs(
                boundary: [
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                ].map { world($0, t) }, pattern: "SOLID", scale: 1, angle: 0)
        case let .fillPolygon(points, _):
            return hatchPairs(
                boundary: points.map { world($0, t) },
                pattern: "SOLID", scale: 1, angle: 0)
        case let .fillComplexPolygon(outer, _, _):
            return hatchPairs(
                boundary: outer.map { world($0, t) },
                pattern: "SOLID", scale: 1, angle: 0)
        case let .gradient(outer, _, name, angle, c1, c2):
            var pairs = hatchPairs(
                boundary: outer.map { world($0, t) },
                pattern: "SOLID", scale: 1, angle: 0)
            let rgb1 = (Int(c1.r) << 16) | (Int(c1.g) << 8) | Int(c1.b)
            let rgb2 = (Int(c2.r) << 16) | (Int(c2.g) << 8) | Int(c2.b)
            pairs.append(dotted(.int(450), .int(1)))
            pairs.append(dotted(.int(452), .int(0)))
            pairs.append(dotted(.int(460), .real(angle)))
            pairs.append(dotted(.int(470), .string(name.isEmpty ? "LINEAR" : name)))
            pairs.append(dotted(.int(421), .int(rgb1)))
            pairs.append(dotted(.int(421), .int(rgb2)))
            return pairs
        case let .ray(start, direction, _):
            return [
                dotted(.int(10), pointValue(world(start, t))),
                dotted(.int(11), pointValue(worldVector(direction, at: start, t))),
            ]
        case let .xline(point, direction, _):
            return [
                dotted(.int(10), pointValue(world(point, t))),
                dotted(.int(11), pointValue(worldVector(direction, at: point, t))),
            ]
        case let .image(insertion, _, _, imageName, _, _):
            return [
                dotted(.int(10), pointValue(world(insertion, t))),
                dotted(.int(1), .string(imageName)),
            ]
        case let .table(_, origin, _):
            return [dotted(.int(10), pointValue(world(origin, t)))]
        }
    }

    private static func worldVertices(
        _ vertices: [CADPolylineVertex], _ t: Transform3D
    ) -> [CADPolylineVertex] {
        vertices.map { v in
            CADPolylineVertex(
                position: world(v.position, t),
                bulge: v.bulge, startWidth: v.startWidth, endWidth: v.endWidth)
        }
    }

    private static func lwpolylinePairs(vertices: [CADPolylineVertex], closed: Bool, scale: Double = 1) -> [LispValue] {
        var pairs: [LispValue] = [
            dotted(.int(90), .int(vertices.count)),
            dotted(.int(70), .int(closed ? 1 : 0)),
        ]
        for v in vertices {
            pairs.append(dotted(.int(10), pointValue(v.position)))
            if v.bulge != 0 { pairs.append(dotted(.int(42), .real(v.bulge))) }
            if v.startWidth != 0 { pairs.append(dotted(.int(40), .real(v.startWidth * scale))) }
            if v.endWidth != 0 { pairs.append(dotted(.int(41), .real(v.endWidth * scale))) }
        }
        return pairs
    }

    private static func hatchPairs(boundary: [Vector3], pattern: String, scale: Double, angle: Double) -> [LispValue] {
        var pairs: [LispValue] = [
            dotted(.int(10), pointValue(boundary.first ?? Vector3(x: 0, y: 0, z: 0))),
            dotted(.int(2), .string(pattern)),
            dotted(.int(41), .real(scale)),
            dotted(.int(52), .real(angle * 180 / Double.pi)),
        ]
        for pt in boundary.dropFirst() {
            pairs.append(dotted(.int(11), pointValue(pt)))
        }
        return pairs
    }

    // MARK: - Assoc parsing (entmake/entmod)

    struct DxfAssoc {
        var pairs: [(code: Int, value: LispValue)]

        func first(_ code: Int) -> LispValue? {
            pairs.first { $0.code == code }?.value
        }

        func all(_ code: Int) -> [LispValue] {
            pairs.filter { $0.code == code }.map(\.value)
        }

        func string(_ code: Int) -> String? {
            guard case let .string(s) = first(code) else { return nil }
            return s
        }

        func int(_ code: Int) -> Int? {
            guard let v = first(code) else { return nil }
            switch v {
            case let .int(i): return i
            case let .real(r): return Int(r)
            default: return nil
            }
        }

        func double(_ code: Int) -> Double? {
            first(code)?.asDouble
        }

        func point(_ code: Int) -> Vector3? {
            guard let coords = first(code)?.asPoint, coords.count >= 2 else { return nil }
            return Vector3(
                x: coords[0], y: coords[1],
                z: coords.count > 2 ? coords[2] : 0)
        }

        func points(_ code: Int) -> [Vector3] {
            all(code).compactMap { value -> Vector3? in
                guard let coords = value.asPoint, coords.count >= 2 else { return nil }
                return Vector3(
                    x: coords[0], y: coords[1],
                    z: coords.count > 2 ? coords[2] : 0)
            }
        }
    }

    static func parseAssoc(_ list: LispValue, name: String) throws -> DxfAssoc {
        guard let items = list.properList else {
            throw LispError.typeMismatch(name: name, expected: "association list", got: list)
        }
        var pairs: [(Int, LispValue)] = []
        for item in items {
            guard case let .cons(head, tail) = item,
                  case let .int(code) = head
            else {
                throw LispError.typeMismatch(
                    name: name, expected: "dotted pair with integer code", got: item)
            }
            pairs.append((code, tail))
        }
        return DxfAssoc(pairs: pairs)
    }

    // MARK: - entmake/entmod construction

    /// Builds a CADEntity from a DXF assoc list.
    ///
    /// - `keepHandle`: when set (entmod), the new entity reuses the existing
    ///   handle; otherwise (entmake) a fresh handle is minted.
    /// - Entity-level linetype (6), lineweight (370), linetype scale (48),
    ///   and visibility (60) overrides fail closed: `CADEntity` carries no
    ///   per-entity override fields, and silently dropping them would
    ///   corrupt entget→entmod round-trips. (Layer-level values apply.)
    /// - Old-style POLYLINE/VERTEX/SEQEND sequences are rejected with a
    ///   pointer to LWPOLYLINE.
    static func makeEntity(
        from assoc: DxfAssoc, document: CADDocument, name: String, keepHandle: UUID? = nil
    ) throws -> CADEntity {
        var xdata: [String: XDataValue] = [:]
        if let lineType = assoc.string(6) {
            let canon = lineType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if canon != "BYLAYER" && !canon.isEmpty {
                xdata["dxf.lineType"] = .string(canon)
            }
        }
        if let ltScale = assoc.double(48) {
            xdata["dxf.lineTypeScale"] = .double(ltScale)
        }
        if let lw = assoc.int(370) {
            xdata["dxf.lineWeight"] = .double(Double(lw) / 100.0)
        }
        if let rgb = assoc.int(420), rgb >= 0 {
            xdata["dxf.color24"] = .int(rgb)
            xdata["dxf.isTrueColor"] = .int(1)
        }
        guard let typeName = assoc.string(0)?.uppercased() else {
            throw LispError.hostError("\(name): missing (0 . type) group")
        }
        if typeName == "POLYLINE" || typeName == "VERTEX" || typeName == "SEQEND" {
            throw LispError.hostError(
                "\(name): old-style \(typeName) sequences are not supported; use LWPOLYLINE")
        }
        let layerID: UUID
        if let layerName = assoc.string(8) {
            guard let layer = document.findLayer(named: layerName) else {
                throw LispError.hostError("\(name): unknown layer \"\(layerName)\"")
            }
            layerID = layer.handle
        } else if let active = document.activeLayerID {
            layerID = active
        } else if let first = document.allLayers.first {
            layerID = first.handle
        } else {
            throw LispError.hostError("\(name): drawing has no layers")
        }
        let color = try colorFromAssoc(assoc, name: name)

        if typeName == "INSERT" {
            guard let blockName = assoc.string(2) else {
                throw LispError.hostError("\(name): INSERT missing (2 . block-name) group")
            }
            guard let block = document.allBlocks.first(where: { $0.name == blockName }) else {
                throw LispError.hostError("\(name): unknown block \"\(blockName)\"")
            }
            let insertion = assoc.point(10) ?? Vector3(x: 0, y: 0, z: 0)
            let rotationDeg = assoc.double(50) ?? 0
            var transform = Transform3D()
            transform.position = insertion
            transform.rotation = rotationDeg * Double.pi / 180
            transform.scale = Vector3(
                x: assoc.double(41) ?? 1,
                y: assoc.double(42) ?? 1,
                z: assoc.double(43) ?? 1)
            _ = color // INSERT color override: accepted gap (block geometry keeps its colors).
            return CADEntity(
                handle: keepHandle ?? UUID(),
                layerID: layerID,
                blockID: block.handle,
                transform: transform)
        }

        guard let primitive = try geometryFromAssoc(
            assoc, typeName: typeName, color: color, name: name)
        else {
            throw LispError.hostError("\(name): unsupported entity type \"\(typeName)\"")
        }
        return CADEntity(
            handle: keepHandle ?? UUID(),
            layerID: layerID,
            localGeometry: [primitive],
            xdata: xdata)
    }

    private static func colorFromAssoc(_ assoc: DxfAssoc, name: String) throws -> ColorRGBA? {
        if let rgb = assoc.int(420), rgb >= 0 {
            return ColorRGBA(
                r: UInt8((rgb >> 16) & 0xFF),
                g: UInt8((rgb >> 8) & 0xFF),
                b: UInt8(rgb & 0xFF),
                a: 255)
        }
        guard let aci = assoc.int(62) else { return nil }
        if aci == 256 || aci == 0 { return nil } // BYLAYER (0 accepted as layer color).
        guard aci >= 1, aci <= 255 else {
            throw LispError.hostError("\(name): color index \(aci) out of range 1..256")
        }
        return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
    }

    private static func geometryFromAssoc(
        _ assoc: DxfAssoc, typeName: String, color: ColorRGBA?, name: String
    ) throws -> CADPrimitive? {
        switch typeName {
        case "POINT":
            guard let p = assoc.point(10) else {
                throw LispError.hostError("\(name): POINT missing (10 . position) group")
            }
            return .point(position: p, color: color)
        case "LINE":
            guard let a = assoc.point(10), let b = assoc.point(11) else {
                throw LispError.hostError("\(name): LINE needs (10 . start) and (11 . end) groups")
            }
            return .line(start: a, end: b, color: color)
        case "CIRCLE":
            guard let c = assoc.point(10), let r = assoc.double(40) else {
                throw LispError.hostError("\(name): CIRCLE needs (10 . center) and (40 . radius) groups")
            }
            return .circle(center: c, radius: r, color: color)
        case "ARC":
            guard let c = assoc.point(10), let r = assoc.double(40),
                  let s = assoc.double(50), let e = assoc.double(51)
            else {
                throw LispError.hostError("\(name): ARC needs 10/40/50/51 groups")
            }
            return .arc(
                center: c, radius: r,
                startAngle: s * Double.pi / 180, endAngle: e * Double.pi / 180,
                color: color)
        case "LWPOLYLINE":
            let count = assoc.int(90) ?? assoc.points(10).count
            let flags = assoc.int(70) ?? 0
            let positions = assoc.points(10)
            guard !positions.isEmpty else {
                throw LispError.hostError("\(name): LWPOLYLINE needs (10 . vertex) groups")
            }
            let bulges = assoc.all(42).compactMap(\.asDouble)
            let widths0 = assoc.all(40).compactMap(\.asDouble)
            let widths1 = assoc.all(41).compactMap(\.asDouble)
            var vertices: [CADPolylineVertex] = []
            for (index, position) in positions.prefix(count).enumerated() {
                vertices.append(CADPolylineVertex(
                    position: position,
                    bulge: index < bulges.count ? bulges[index] : 0,
                    startWidth: index < widths0.count ? widths0[index] : 0,
                    endWidth: index < widths1.count ? widths1[index] : 0))
            }
            return .polyline(
                path: CADPolyline(vertices: vertices, isClosed: flags & 1 != 0),
                color: color)
        case "TEXT", "MTEXT":
            guard let position = assoc.point(10) else {
                throw LispError.hostError("\(name): TEXT missing (10 . position) group")
            }
            return .text(
                position: position,
                text: assoc.string(1) ?? "",
                height: assoc.double(40) ?? 1,
                rotation: (assoc.double(50) ?? 0) * Double.pi / 180,
                style: assoc.string(7),
                alignH: assoc.int(72) ?? 0,
                alignV: assoc.int(73) ?? 0,
                mtextWidth: typeName == "MTEXT" ? (assoc.double(41) ?? 0) : nil,
                color: color)
        case "ELLIPSE":
            guard let c = assoc.point(10), let axis = assoc.point(11),
                  let ratio = assoc.double(40)
            else {
                throw LispError.hostError("\(name): ELLIPSE needs 10/11/40 groups")
            }
            return .ellipse(center: c, majorAxis: axis, minorRatio: ratio, color: color)
        case "SPLINE":
            let points = assoc.points(10)
            guard !points.isEmpty else {
                throw LispError.hostError("\(name): SPLINE needs (10 . control-point) groups")
            }
            return .spline(
                controlPoints: points, knots: [], degree: assoc.int(71) ?? 3,
                weights: nil, color: color)
        case "RAY":
            guard let start = assoc.point(10), let dir = assoc.point(11) else {
                throw LispError.hostError("\(name): RAY needs (10 . start) and (11 . direction) groups")
            }
            return .ray(start: start, direction: dir, color: color)
        case "XLINE":
            guard let point = assoc.point(10), let dir = assoc.point(11) else {
                throw LispError.hostError("\(name): XLINE needs (10 . point) and (11 . direction) groups")
            }
            return .xline(point: point, direction: dir, color: color)
        case "SOLID":
            let corners = [assoc.point(10), assoc.point(11), assoc.point(12), assoc.point(13)]
                .compactMap { $0 }
            guard corners.count >= 3 else {
                throw LispError.hostError("\(name): SOLID needs at least 3 corner groups (10/11/12)")
            }
            return .fillPolygon(points: corners, color: color)
        case "HATCH":
            var boundary = assoc.points(10)
            let extra11 = assoc.points(11)
            if boundary.count == 1, !extra11.isEmpty {
                boundary.append(contentsOf: extra11)
            } else if let vertexCount = assoc.int(93), vertexCount >= 3, boundary.count == vertexCount + 1 {
                // Standard DXF HATCH has a header (10 0 0 0) elevation point before the loop vertices.
                boundary.removeFirst()
            }
            guard !boundary.isEmpty else {
                throw LispError.hostError("\(name): HATCH needs (10 . boundary-point) groups")
            }
            let isGradient = (assoc.int(450) ?? 0) == 1 || assoc.string(470) != nil
            if isGradient {
                let rawGradName = assoc.string(470) ?? assoc.string(2) ?? "LINEAR"
                let gradName = LispScriptedCommands.normalizedGradientName(rawGradName) ?? "LINEAR"
                // DXF group 460 is gradient angle in radians; fallback to group 52 (degrees).
                let angleRad = assoc.double(460) ?? ((assoc.double(52) ?? 0) * Double.pi / 180)
                let trueColors = assoc.all(421).compactMap { v -> ColorRGBA? in
                    guard let rgb = v.asDouble.map({ Int($0) }), rgb >= 0 else { return nil }
                    return ColorRGBA(
                        r: UInt8((rgb >> 16) & 0xFF),
                        g: UInt8((rgb >> 8) & 0xFF),
                        b: UInt8(rgb & 0xFF),
                        a: 255)
                }
                let aciColors = assoc.all(63).compactMap { v -> ColorRGBA? in
                    guard let aci = v.asDouble.map({ Int($0) }), (1...255).contains(aci) else { return nil }
                    return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
                }
                let c1 = trueColors.first ?? aciColors.first ?? color ?? ColorRGBA.white
                let c2 = (trueColors.count > 1 ? trueColors[1] : nil)
                    ?? (aciColors.count > 1 ? aciColors[1] : nil)
                    ?? ColorRGBA.black
                return .gradient(
                    outer: boundary, holes: [], gradientName: gradName,
                    angle: angleRad, color1: c1, color2: c2)
            }
            return .hatch(
                boundary: boundary, pattern: assoc.string(2) ?? "SOLID",
                scale: assoc.double(41) ?? 1, angle: (assoc.double(52) ?? 0) * Double.pi / 180,
                color: color)
        default:
            return nil
        }
    }
}
