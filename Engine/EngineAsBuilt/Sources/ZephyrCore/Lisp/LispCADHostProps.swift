import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Lisp CAD Host: properties + transforms (Wave B)
// =========================================================================
//
// getpropertyvalue/setpropertyvalue/ispropertyreadonly/dumpallproperties,
// trans, and textbox. Angles are RADIANS (the COM convention these APIs
// mirror); coordinates are WORLD (callers never see local geometry).
// Every setter funnels through replaceEntity: one call, one undo entry.

// UNISOLATED by design (see LispCADHost): property access runs on the
// eval task, which cannot hop to MainActor under the unpumped SDL loop.
extension LispCADHost {
    enum PropAccess {
        case readOnly, readWrite
    }

    /// Property access table. Common properties apply to every entity;
    /// geometry properties depend on the DXF type name. Get, set, and the
    /// read-only probe all consult this table, so the three can never drift.
    static func propAccess(_ property: String, type: String) -> PropAccess? {
        switch property {
        case "HANDLE", "OBJECTNAME", "ENTITYTYPE", "VISIBILITY", "LINETYPE":
            return .readOnly
        case "LAYER", "COLOR":
            return .readWrite
        default:
            break
        }
        switch type {
        case "LINE":
            switch property {
            case "STARTPOINT", "ENDPOINT": return .readWrite
            case "LENGTH", "ANGLE": return .readOnly
            default: return nil
            }
        case "CIRCLE":
            switch property {
            case "CENTER", "RADIUS": return .readWrite
            case "AREA", "CIRCUMFERENCE": return .readOnly
            default: return nil
            }
        case "ARC":
            switch property {
            case "CENTER", "RADIUS", "STARTANGLE", "ENDANGLE": return .readWrite
            case "TOTALANGLE", "ARCLENGTH", "AREA": return .readOnly
            default: return nil
            }
        case "LWPOLYLINE":
            switch property {
            case "COORDINATES", "CLOSED": return .readWrite
            case "AREA", "LENGTH": return .readOnly
            default: return nil
            }
        case "TEXT", "MTEXT":
            switch property {
            case "TEXTSTRING", "HEIGHT", "ROTATION", "STYLE", "POSITION": return .readWrite
            default: return nil
            }
        case "ELLIPSE":
            switch property {
            case "CENTER", "RADIUSRATIO": return .readWrite
            case "MAJORAXIS", "MINORAXIS": return .readOnly
            default: return nil
            }
        case "POINT":
            return property == "POSITION" ? .readWrite : nil
        case "HATCH":
            switch property {
            case "PATTERNNAME", "PATTERNANGLE", "PATTERNSCALE": return .readWrite
            case "AREA": return .readOnly
            default: return nil
            }
        case "SPLINE":
            switch property {
            case "CONTROLPOINTS": return .readWrite
            case "DEGREE": return .readOnly
            default: return nil
            }
        case "RAY":
            switch property {
            case "BASEPOINT", "DIRECTIONVECTOR": return .readWrite
            default: return nil
            }
        case "IMAGE":
            return property == "INSERTIONPOINT" ? .readWrite : nil
        case "ACAD_TABLE":
            return property == "POSITION" ? .readWrite : nil
        case "INSERT":
            switch property {
            case "NAME": return .readOnly
            case "INSERTIONPOINT", "ROTATION", "XSCALE", "YSCALE", "ZSCALE": return .readWrite
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Reads

    func propertyValue(
        _ handle: String, property: String, index: Int?
    ) async throws -> LispValue {
        let entity = try entityForProp(handle: handle, property: property)
        let type = LispEntityAdapter.dxfTypeName(entity: entity, document: document)
        let prop = property.uppercased()
        guard Self.propAccess(prop, type: type) != nil else {
            throw LispError.hostError(
                "getpropertyvalue: unknown property \"\(property)\" for \(type)")
        }
        if let common = commonProp(prop, entity: entity) { return common }
        return try geometryProp(prop, entity: entity, type: type, index: index)
    }

    private func commonProp(_ prop: String, entity: CADEntity) -> LispValue? {
        switch prop {
        case "HANDLE":
            return .string(entity.handle.uuidString)
        case "OBJECTNAME", "ENTITYTYPE":
            return .string(LispEntityAdapter.dxfTypeName(entity: entity, document: document))
        case "LAYER":
            return .string(LispEntityAdapter.layerName(entity: entity, document: document))
        case "COLOR":
            return .int(LispEntityAdapter.entityACI(entity: entity))
        case "LINETYPE":
            return .string(
                document.layer(for: entity.layerID)?.lineType ?? "CONTINUOUS")
        case "VISIBILITY":
            let visible = document.layer(for: entity.layerID)?.isVisible ?? true
            return visible ? .t : .nilValue
        default:
            return nil
        }
    }

    private func geometryProp(
        _ prop: String, entity: CADEntity, type: String, index: Int?
    ) throws -> LispValue {
        let t = entity.transform
        if type == "INSERT" {
            return try insertProp(prop, entity: entity)
        }
        guard let prim = entity.localGeometry?.first else {
            throw LispError.hostError("getpropertyvalue: entity has no geometry")
        }
        switch prim {
        case let .line(start, end, _):
            let a = t.transformPoint(start), b = t.transformPoint(end)
            switch prop {
            case "STARTPOINT": return LispEntityAdapter.pointValue(a)
            case "ENDPOINT": return LispEntityAdapter.pointValue(b)
            case "LENGTH": return .real(dist3(a, b))
            case "ANGLE": return .real(atan2(b.y - a.y, b.x - a.x))
            default: break
            }
        case let .circle(center, radius, _):
            switch prop {
            case "CENTER": return LispEntityAdapter.pointValue(t.transformPoint(center))
            case "RADIUS": return .real(radius * t.scale.x)
            case "AREA": return .real(Double.pi * radius * radius * t.scale.x * t.scale.y)
            case "CIRCUMFERENCE": return .real(2 * Double.pi * radius * t.scale.x)
            default: break
            }
        case let .arc(center, radius, startAngle, endAngle, _):
            let span = endAngle - startAngle
            switch prop {
            case "CENTER": return LispEntityAdapter.pointValue(t.transformPoint(center))
            case "RADIUS": return .real(radius * t.scale.x)
            case "STARTANGLE": return .real(startAngle + t.rotation)
            case "ENDANGLE": return .real(endAngle + t.rotation)
            case "TOTALANGLE": return .real(span)
            case "ARCLENGTH": return .real(abs(span) * radius * t.scale.x)
            case "AREA": return .real(0.5 * radius * radius * abs(span))
            default: break
            }
        case let .polyline(path, _):
            return try polylineProp(prop, path: path, t: t, index: index)
        case let .polygon(points, _):
            return try polylineProp(
                prop,
                path: CADPolyline(
                    vertices: points.map {
                        CADPolylineVertex(position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                    }, isClosed: true),
                t: t, index: index)
        case let .penStroke(vertices, _, _):
            return try polylineProp(
                prop,
                path: CADPolyline(
                    vertices: vertices.map {
                        CADPolylineVertex(
                            position: $0.position, bulge: 0, startWidth: 0, endWidth: 0)
                    }, isClosed: false),
                t: t, index: index)
        case let .text(position, text, height, rotation, style, _, _, _, _):
            switch prop {
            case "TEXTSTRING": return .string(text)
            case "HEIGHT": return .real(height * t.scale.x)
            case "ROTATION": return .real(rotation + t.rotation)
            case "STYLE": return .string(style ?? "Standard")
            case "POSITION": return LispEntityAdapter.pointValue(t.transformPoint(position))
            default: break
            }
        case let .ellipse(center, majorAxis, minorRatio, _):
            switch prop {
            case "CENTER": return LispEntityAdapter.pointValue(t.transformPoint(center))
            case "RADIUSRATIO": return .real(minorRatio)
            case "MAJORAXIS":
                return LispEntityAdapter.pointValue(worldDir(majorAxis, at: center, t))
            case "MINORAXIS":
                let major = worldDir(majorAxis, at: center, t)
                let length = (major.x * major.x + major.y * major.y).squareRoot()
                guard length > 1e-12 else {
                    return LispEntityAdapter.pointValue(Vector3(x: 0, y: 0, z: 0))
                }
                return LispEntityAdapter.pointValue(Vector3(
                    x: -major.y / length * length * minorRatio,
                    y: major.x / length * length * minorRatio,
                    z: 0))
            default: break
            }
        case let .point(position, _):
            if prop == "POSITION" {
                return LispEntityAdapter.pointValue(t.transformPoint(position))
            }
        case let .hatch(boundary, pattern, scale, angle, _, _):
            return try hatchProp(
                prop: prop, boundary: boundary, pattern: pattern, scale: scale,
                angle: angle, t: t)
        case let .hatchPath(boundary, _, pattern, scale, angle, _, _):
            return try hatchProp(
                prop: prop, boundary: boundary.vertices.map(\.position),
                pattern: pattern, scale: scale, angle: angle, t: t)
        case .fillRect, .fillPolygon, .fillComplexPolygon, .gradient:
            // SOLID fills: AREA only; pattern props do not apply.
            if prop == "AREA" {
                return .real(polygonArea(worldBoundary(entity: entity, t: t)))
            }
            throw LispError.hostError(
                "getpropertyvalue: \"\(prop)\" does not apply to SOLID hatch")
        case let .spline(controlPoints, _, degree, _, _):
            switch prop {
            case "DEGREE": return .int(degree)
            case "CONTROLPOINTS":
                let world = controlPoints.map { t.transformPoint($0) }
                if let index {
                    guard index >= 0, index < world.count else {
                        throw LispError.hostError(
                            "getpropertyvalue: CONTROLPOINTS index \(index) out of range")
                    }
                    return LispEntityAdapter.pointValue(world[index])
                }
                return LispEntityAdapter.lispList(world.map(LispEntityAdapter.pointValue))
            default: break
            }
        case let .ray(start, direction, _):
            switch prop {
            case "BASEPOINT": return LispEntityAdapter.pointValue(t.transformPoint(start))
            case "DIRECTIONVECTOR":
                return LispEntityAdapter.pointValue(worldDir(direction, at: start, t))
            default: break
            }
        case let .xline(point, direction, _):
            switch prop {
            case "BASEPOINT": return LispEntityAdapter.pointValue(t.transformPoint(point))
            case "DIRECTIONVECTOR":
                return LispEntityAdapter.pointValue(worldDir(direction, at: point, t))
            default: break
            }
        case let .image(insertion, _, _, _, _, _):
            if prop == "INSERTIONPOINT" {
                return LispEntityAdapter.pointValue(t.transformPoint(insertion))
            }
        case let .table(_, origin, _):
            if prop == "POSITION" {
                return LispEntityAdapter.pointValue(t.transformPoint(origin))
            }
        case let .rect(origin, size, _):
            return try polylineProp(
                prop,
                path: CADPolyline(
                    vertices: [
                        origin,
                        Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                        Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                        Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                    ].map {
                        CADPolylineVertex(
                            position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                    }, isClosed: true),
                t: t, index: index)
        }
        throw LispError.hostError(
            "getpropertyvalue: unknown property \"\(prop)\" for \(type)")
    }

    private func insertProp(_ prop: String, entity: CADEntity) throws -> LispValue {
        let t = entity.transform
        switch prop {
        case "NAME":
            guard let blockID = entity.blockID,
                  let block = document.block(for: blockID)
            else {
                throw LispError.hostError("getpropertyvalue: INSERT has no block")
            }
            return .string(block.name)
        case "INSERTIONPOINT": return LispEntityAdapter.pointValue(t.position)
        case "ROTATION": return .real(t.rotation)
        case "XSCALE": return .real(t.scale.x)
        case "YSCALE": return .real(t.scale.y)
        case "ZSCALE": return .real(t.scale.z)
        default:
            throw LispError.hostError(
                "getpropertyvalue: unknown property \"\(prop)\" for INSERT")
        }
    }

    private func polylineProp(
        _ prop: String, path: CADPolyline, t: Transform3D, index: Int?
    ) throws -> LispValue {
        let world = path.vertices.map { t.transformPoint($0.position) }
        switch prop {
        case "COORDINATES":
            if let index {
                guard index >= 0, index < world.count else {
                    throw LispError.hostError(
                        "getpropertyvalue: COORDINATES index \(index) out of range")
                }
                return LispEntityAdapter.pointValue(world[index])
            }
            return LispEntityAdapter.lispList(world.map(LispEntityAdapter.pointValue))
        case "AREA":
            return .real(polygonArea(world))
        case "LENGTH":
            return .real(polyLength(world, closed: path.isClosed))
        case "CLOSED":
            return path.isClosed ? .t : .nilValue
        default:
            throw LispError.hostError(
                "getpropertyvalue: unknown property \"\(prop)\" for LWPOLYLINE")
        }
    }

    private func hatchProp(
        prop: String, boundary: [Vector3], pattern: String, scale: Double,
        angle: Double, t: Transform3D
    ) throws -> LispValue {
        switch prop {
        case "PATTERNNAME": return .string(pattern)
        case "PATTERNANGLE": return .real(angle + t.rotation)
        case "PATTERNSCALE": return .real(scale * t.scale.x)
        case "AREA": return .real(polygonArea(boundary.map { t.transformPoint($0) }))
        default:
            throw LispError.hostError(
                "getpropertyvalue: unknown property \"\(prop)\" for HATCH")
        }
    }

    // MARK: - Writes

    func setPropertyValue(
        _ handle: String, property: String, value: LispValue
    ) async throws -> LispValue {
        var entity = try entityForProp(handle: handle, property: property)
        let type = LispEntityAdapter.dxfTypeName(entity: entity, document: document)
        let prop = property.uppercased()
        guard Self.propAccess(prop, type: type) == .readWrite else {
            if Self.propAccess(prop, type: type) == .readOnly {
                throw LispError.hostError(
                    "setpropertyvalue: \"\(property)\" is read-only")
            }
            throw LispError.hostError(
                "setpropertyvalue: unknown property \"\(property)\" for \(type)")
        }
        switch prop {
        case "LAYER":
            guard case let .string(name) = value,
                  let layer = document.findLayer(named: name)
            else {
                throw LispError.hostError("setpropertyvalue: unknown layer")
            }
            entity.layerID = layer.handle
            document.replaceEntity(entity)
            return value
        case "COLOR":
            let color: ColorRGBA?
            switch value {
            case let .int(aci) where aci == 256:
                color = nil
            case let .int(aci) where (1...255).contains(aci):
                color = DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
            case let .string(s) where s.uppercased() == "BYLAYER":
                color = nil
            default:
                throw LispError.hostError(
                    "setpropertyvalue: COLOR needs ACI 1..256 or BYLAYER")
            }
            document.replaceEntity(LispEntityAdapter.withPrimitiveColor(entity, color))
            return value
        default:
            break
        }
        let t = entity.transform
        if type == "INSERT" {
            try setInsertProp(prop, entity: &entity, value: value)
            document.replaceEntity(entity)
            return value
        }
        guard var prim = entity.localGeometry?.first else {
            throw LispError.hostError("setpropertyvalue: entity has no geometry")
        }
        try setGeometryProp(prop, prim: &prim, value: value, t: t)
        entity.localGeometry = [prim]
        document.replaceEntity(entity)
        return value
    }

    private func setPolyPath(
        _ path: CADPolyline, prop: String, value: LispValue, t: Transform3D
    ) throws -> CADPolyline {
        var path = path
        switch prop {
        case "CLOSED":
            path.isClosed = value.isTrue
        case "COORDINATES":
            guard let items = value.properList else {
                throw LispError.hostError("setpropertyvalue: COORDINATES needs a point list")
            }
            var vertices: [CADPolylineVertex] = []
            for (index, item) in items.enumerated() {
                guard let coords = item.asPoint, coords.count >= 2 else {
                    throw LispError.hostError(
                        "setpropertyvalue: COORDINATES needs a point list")
                }
                let world = Vector3(
                    x: coords[0], y: coords[1],
                    z: coords.count > 2 ? coords[2] : 0)
                let old = index < path.vertices.count ? path.vertices[index] : nil
                vertices.append(CADPolylineVertex(
                    position: localPoint(world, t),
                    bulge: old?.bulge ?? 0,
                    startWidth: old?.startWidth ?? 0,
                    endWidth: old?.endWidth ?? 0))
            }
            path.vertices = vertices
        default:
            throw LispError.hostError(
                "setpropertyvalue: unknown property \"\(prop)\" for LWPOLYLINE")
        }
        return path
    }

    private func setInsertProp(
        _ prop: String, entity: inout CADEntity, value: LispValue
    ) throws {
        var t = entity.transform
        switch prop {
        case "INSERTIONPOINT":
            t.position = try propPoint(value, property: prop)
        case "ROTATION":
            guard let radians = value.asDouble else {
                throw LispError.hostError("setpropertyvalue: ROTATION needs a number (radians)")
            }
            t.rotation = radians
        case "XSCALE":
            t.scale = Vector3(
                x: try propDouble(value, property: prop), y: t.scale.y, z: t.scale.z)
        case "YSCALE":
            t.scale = Vector3(
                x: t.scale.x, y: try propDouble(value, property: prop), z: t.scale.z)
        case "ZSCALE":
            t.scale = Vector3(
                x: t.scale.x, y: t.scale.y, z: try propDouble(value, property: prop))
        default:
            throw LispError.hostError(
                "setpropertyvalue: unknown property \"\(prop)\" for INSERT")
        }
        entity.transform = t
    }

    private func setGeometryProp(
        _ prop: String, prim: inout CADPrimitive, value: LispValue, t: Transform3D
    ) throws {
        switch prim {
        case let .line(start, end, color):
            switch prop {
            case "STARTPOINT":
                prim = .line(start: localPoint(try propPoint(value, property: prop), t), end: end, color: color)
            case "ENDPOINT":
                prim = .line(start: start, end: localPoint(try propPoint(value, property: prop), t), color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for LINE")
            }
        case let .circle(center, radius, color):
            switch prop {
            case "CENTER":
                prim = .circle(
                    center: localPoint(try propPoint(value, property: prop), t),
                    radius: radius, color: color)
            case "RADIUS":
                prim = .circle(
                    center: center,
                    radius: try propPositiveDouble(value, property: prop) / max(t.scale.x, 1e-12),
                    color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for CIRCLE")
            }
        case let .arc(center, radius, startAngle, endAngle, color):
            switch prop {
            case "CENTER":
                prim = .arc(
                    center: localPoint(try propPoint(value, property: prop), t),
                    radius: radius, startAngle: startAngle, endAngle: endAngle,
                    color: color)
            case "RADIUS":
                prim = .arc(
                    center: center,
                    radius: try propPositiveDouble(value, property: prop) / max(t.scale.x, 1e-12),
                    startAngle: startAngle, endAngle: endAngle, color: color)
            case "STARTANGLE":
                prim = .arc(
                    center: center, radius: radius,
                    startAngle: try propDouble(value, property: prop) - t.rotation,
                    endAngle: endAngle, color: color)
            case "ENDANGLE":
                prim = .arc(
                    center: center, radius: radius, startAngle: startAngle,
                    endAngle: try propDouble(value, property: prop) - t.rotation,
                    color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for ARC")
            }
        case let .polyline(path, color):
            prim = .polyline(
                path: try setPolyPath(path, prop: prop, value: value, t: t),
                color: color)
        case let .polygon(points, color):
            // Setting on polygon/rect/penStroke converts to LWPOLYLINE.
            prim = .polyline(
                path: try setPolyPath(
                    CADPolyline(
                        vertices: points.map {
                            CADPolylineVertex(
                                position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                        }, isClosed: true),
                    prop: prop, value: value, t: t),
                color: color)
        case let .rect(origin, size, color):
            prim = .polyline(
                path: try setPolyPath(
                    CADPolyline(
                        vertices: [
                            origin,
                            Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                            Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                            Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                        ].map {
                            CADPolylineVertex(
                                position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                        }, isClosed: true),
                    prop: prop, value: value, t: t),
                color: color)
        case let .penStroke(vertices, _, color):
            prim = .polyline(
                path: try setPolyPath(
                    CADPolyline(
                        vertices: vertices.map {
                            CADPolylineVertex(
                                position: $0.position, bulge: 0, startWidth: 0, endWidth: 0)
                        }, isClosed: false),
                    prop: prop, value: value, t: t),
                color: color)
        case let .text(position, text, height, rotation, style, alignH, alignV, mtextWidth, color):
            switch prop {
            case "TEXTSTRING":
                guard case let .string(newText) = value else {
                    throw LispError.hostError("setpropertyvalue: TEXTSTRING needs a string")
                }
                prim = .text(
                    position: position, text: newText, height: height,
                    rotation: rotation, style: style, alignH: alignH,
                    alignV: alignV, mtextWidth: mtextWidth, color: color)
            case "HEIGHT":
                prim = .text(
                    position: position, text: text,
                    height: try propPositiveDouble(value, property: prop) / max(t.scale.x, 1e-12),
                    rotation: rotation, style: style, alignH: alignH,
                    alignV: alignV, mtextWidth: mtextWidth, color: color)
            case "ROTATION":
                prim = .text(
                    position: position, text: text, height: height,
                    rotation: try propDouble(value, property: prop) - t.rotation,
                    style: style, alignH: alignH, alignV: alignV,
                    mtextWidth: mtextWidth, color: color)
            case "STYLE":
                guard case let .string(styleName) = value,
                      document.textStyles[styleName] != nil
                else {
                    throw LispError.hostError("setpropertyvalue: unknown text style")
                }
                prim = .text(
                    position: position, text: text, height: height,
                    rotation: rotation, style: styleName, alignH: alignH,
                    alignV: alignV, mtextWidth: mtextWidth, color: color)
            case "POSITION":
                prim = .text(
                    position: localPoint(try propPoint(value, property: prop), t),
                    text: text, height: height, rotation: rotation,
                    style: style, alignH: alignH, alignV: alignV,
                    mtextWidth: mtextWidth, color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for TEXT")
            }
        case let .ellipse(center, majorAxis, minorRatio, color):
            switch prop {
            case "CENTER":
                prim = .ellipse(
                    center: localPoint(try propPoint(value, property: prop), t),
                    majorAxis: majorAxis, minorRatio: minorRatio, color: color)
            case "RADIUSRATIO":
                let ratio = try propDouble(value, property: prop)
                guard ratio > 0, ratio <= 1 else {
                    throw LispError.hostError(
                        "setpropertyvalue: RADIUSRATIO needs (0, 1]")
                }
                prim = .ellipse(
                    center: center, majorAxis: majorAxis, minorRatio: ratio,
                    color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for ELLIPSE")
            }
        case .point:
            guard prop == "POSITION" else {
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for POINT")
            }
            if case let .point(_, color) = prim {
                prim = .point(
                    position: localPoint(try propPoint(value, property: prop), t),
                    color: color)
            }
        case let .hatch(boundary, pattern, scale, angle, color, background):
            switch prop {
            case "PATTERNNAME":
                guard case let .string(name) = value, !name.isEmpty else {
                    throw LispError.hostError("setpropertyvalue: PATTERNNAME needs a string")
                }
                prim = .hatch(
                    boundary: boundary, pattern: name.uppercased(), scale: scale,
                    angle: angle, color: color, backgroundColor: background)
            case "PATTERNANGLE":
                prim = .hatch(
                    boundary: boundary, pattern: pattern, scale: scale,
                    angle: try propDouble(value, property: prop) - t.rotation,
                    color: color, backgroundColor: background)
            case "PATTERNSCALE":
                prim = .hatch(
                    boundary: boundary, pattern: pattern,
                    scale: try propPositiveDouble(value, property: prop) / max(t.scale.x, 1e-12),
                    angle: angle, color: color, backgroundColor: background)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for HATCH")
            }
        case let .hatchPath(boundary, holes, pattern, scale, angle, color, background):
            switch prop {
            case "PATTERNNAME":
                guard case let .string(name) = value, !name.isEmpty else {
                    throw LispError.hostError("setpropertyvalue: PATTERNNAME needs a string")
                }
                prim = .hatchPath(
                    boundary: boundary, holes: holes, pattern: name.uppercased(),
                    scale: scale, angle: angle, color: color,
                    backgroundColor: background)
            case "PATTERNANGLE":
                prim = .hatchPath(
                    boundary: boundary, holes: holes, pattern: pattern,
                    scale: scale,
                    angle: try propDouble(value, property: prop) - t.rotation,
                    color: color, backgroundColor: background)
            case "PATTERNSCALE":
                prim = .hatchPath(
                    boundary: boundary, holes: holes, pattern: pattern,
                    scale: try propPositiveDouble(value, property: prop) / max(t.scale.x, 1e-12),
                    angle: angle, color: color, backgroundColor: background)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for HATCH")
            }
        case let .spline(_, knots, degree, weights, color):
            guard prop == "CONTROLPOINTS" else {
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for SPLINE")
            }
            guard let items = value.properList, !items.isEmpty else {
                throw LispError.hostError("setpropertyvalue: CONTROLPOINTS needs a point list")
            }
            var cps: [Vector3] = []
            for item in items {
                guard let coords = item.asPoint, coords.count >= 2 else {
                    throw LispError.hostError(
                        "setpropertyvalue: CONTROLPOINTS needs a point list")
                }
                cps.append(localPoint(
                    Vector3(
                        x: coords[0], y: coords[1],
                        z: coords.count > 2 ? coords[2] : 0), t))
            }
            prim = .spline(
                controlPoints: cps, knots: knots, degree: degree,
                weights: weights, color: color)
        case let .ray(start, direction, color):
            switch prop {
            case "BASEPOINT":
                prim = .ray(
                    start: localPoint(try propPoint(value, property: prop), t),
                    direction: direction, color: color)
            case "DIRECTIONVECTOR":
                let world = try propPoint(value, property: prop)
                prim = .ray(start: start, direction: localDirVec(world, t), color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for RAY")
            }
        case let .xline(point, direction, color):
            switch prop {
            case "BASEPOINT":
                prim = .xline(
                    point: localPoint(try propPoint(value, property: prop), t),
                    direction: direction, color: color)
            case "DIRECTIONVECTOR":
                let world = try propPoint(value, property: prop)
                prim = .xline(point: point, direction: localDirVec(world, t), color: color)
            default:
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for XLINE")
            }
        case let .image(_, uAxis, vAxis, imageName, clipBoundary, tint):
            guard prop == "INSERTIONPOINT" else {
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for IMAGE")
            }
            prim = .image(
                insertion: localPoint(try propPoint(value, property: prop), t),
                uAxis: uAxis, vAxis: vAxis, imageName: imageName,
                clipBoundary: clipBoundary, tint: tint)
        case let .table(data, _, color):
            guard prop == "POSITION" else {
                throw LispError.hostError(
                    "setpropertyvalue: unknown property \"\(prop)\" for ACAD_TABLE")
            }
            prim = .table(
                data: data,
                origin: localPoint(try propPoint(value, property: prop), t),
                color: color)
        default:
            throw LispError.hostError(
                "setpropertyvalue: \"\(prop)\" cannot be set on this entity")
        }
    }

    // MARK: - Probe + dump

    func isPropertyReadOnly(_ handle: String, property: String) async throws -> Bool {
        let entity = try entityForProp(handle: handle, property: property)
        let type = LispEntityAdapter.dxfTypeName(entity: entity, document: document)
        guard let access = Self.propAccess(property.uppercased(), type: type) else {
            throw LispError.hostError(
                "ispropertyreadonly: unknown property \"\(property)\" for \(type)")
        }
        return access == .readOnly
    }

    func dumpProperties(_ handle: String) async throws {
        let entity = try entityForProp(handle: handle, property: "dump")
        let type = LispEntityAdapter.dxfTypeName(entity: entity, document: document)
        var names = ["HANDLE", "OBJECTNAME", "ENTITYTYPE", "LAYER", "COLOR", "LINETYPE", "VISIBILITY"]
        switch type {
        case "LINE": names += ["STARTPOINT", "ENDPOINT", "LENGTH", "ANGLE"]
        case "CIRCLE": names += ["CENTER", "RADIUS", "AREA", "CIRCUMFERENCE"]
        case "ARC": names += ["CENTER", "RADIUS", "STARTANGLE", "ENDANGLE", "TOTALANGLE", "ARCLENGTH", "AREA"]
        case "LWPOLYLINE": names += ["COORDINATES", "AREA", "LENGTH", "CLOSED"]
        case "TEXT", "MTEXT": names += ["TEXTSTRING", "HEIGHT", "ROTATION", "STYLE", "POSITION"]
        case "ELLIPSE": names += ["CENTER", "RADIUSRATIO", "MAJORAXIS", "MINORAXIS"]
        case "POINT": names += ["POSITION"]
        case "HATCH": names += ["PATTERNNAME", "PATTERNANGLE", "PATTERNSCALE", "AREA"]
        case "SPLINE": names += ["CONTROLPOINTS", "DEGREE"]
        case "RAY": names += ["BASEPOINT", "DIRECTIONVECTOR"]
        case "IMAGE": names += ["INSERTIONPOINT"]
        case "ACAD_TABLE": names += ["POSITION"]
        case "INSERT": names += ["NAME", "INSERTIONPOINT", "ROTATION", "XSCALE", "YSCALE", "ZSCALE"]
        default: break
        }
        for name in names {
            if let value = try? await propertyValue(handle, property: name, index: nil) {
                await write("\(name): \(value.prin1String)\n")
            }
        }
    }

    // MARK: - trans + textbox

    func transPoint(
        _ point: [Double], from: LispValue, to: LispValue, disp: Bool
    ) async throws -> [Double] {
        let fromT = try transFrame(from, role: "from")
        let toT = try transFrame(to, role: "to")
        let p = Vector3(x: point[0], y: point[1], z: point.count > 2 ? point[2] : 0)
        // To world, then to target.
        let world: Vector3
        if let fromT {
            world = disp ? worldDirVec(p, fromT) : fromT.transformPoint(p)
        } else {
            world = p
        }
        let out: Vector3
        if let toT {
            out = disp ? localDirVec(world, toT) : localPoint(world, toT)
        } else {
            out = world
        }
        return [out.x, out.y, out.z]
    }

    /// Resolves a trans frame: nil = WCS/UCS (identical here), or an
    /// entity transform. Codes 2/3 (display/paperspace) are unsupported.
    private func transFrame(_ value: LispValue, role: String) throws -> Transform3D? {
        switch value {
        case let .int(code) where code == 0 || code == 1:
            return nil
        case let .real(code) where code == 0 || code == 1:
            return nil
        case let .int(code):
            throw LispError.hostError(
                "trans: \(role) code \(code) unsupported (0=WCS, 1=UCS, ename=entity)")
        case let .real(code):
            throw LispError.hostError(
                "trans: \(role) code \(code) unsupported (0=WCS, 1=UCS, ename=entity)")
        case let .entityName(handle):
            guard let uuid = LispEntityAdapter.handle(fromEname: handle),
                  let entity = document.entity(for: uuid)
            else {
                throw LispError.hostError("trans: invalid entity name")
            }
            return entity.transform
        default:
            throw LispError.hostError("trans: invalid \(role) coordinate system")
        }
    }

    func textBox(_ dxfList: LispValue) async throws -> LispValue? {
        let assoc = try LispEntityAdapter.parseAssoc(dxfList, name: "textbox")
        guard assoc.string(0)?.uppercased() == "TEXT"
            || assoc.string(0)?.uppercased() == "MTEXT"
        else {
            return nil
        }
        // Entity path (-1 present) or bare assoc (temp entity).
        let entity: CADEntity
        let prim: CADPrimitive
        if case let .entityName(handle) = assoc.first(-1),
           let uuid = LispEntityAdapter.handle(fromEname: handle),
           let found = document.entity(for: uuid),
           case let .text(_, text, height, rotation, _, alignH, alignV, mtextWidth, _) = found.localGeometry?.first
        {
            entity = found
            prim = .text(
                position: Vector3(x: 0, y: 0, z: 0), text: text, height: height,
                rotation: rotation, style: nil, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: nil)
        } else if assoc.first(-1) != nil {
            throw LispError.hostError("textbox: invalid entity name")
        } else {
            entity = try LispEntityAdapter.makeEntity(
                from: assoc, document: document, name: "textbox")
            guard case let .text(_, text, height, rotation, _, alignH, alignV, mtextWidth, _) = entity.localGeometry?.first else {
                return nil
            }
            prim = .text(
                position: Vector3(x: 0, y: 0, z: 0), text: text, height: height,
                rotation: rotation, style: nil, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: nil)
        }
        guard case let .text(_, text, height, rotation, _, alignH, alignV, mtextWidth, _) = prim else {
            return nil
        }
        let t = entity.transform
        let bounds = CADEntity.estimateTextLocalBounds(
            text: text, height: height * t.scale.x,
            alignH: alignH, alignV: alignV, mtextWidth: mtextWidth)
        let total = rotation + t.rotation
        let cosR = cos(total), sinR = sin(total)
        let corners = [
            (bounds.minX, bounds.minY), (bounds.maxX, bounds.minY),
            (bounds.maxX, bounds.maxY), (bounds.minX, bounds.maxY),
        ].map { (x, y) -> Vector3 in
            let rx = x * cosR - y * sinR, ry = x * sinR + y * cosR
            // Local bounds are relative to the primitive position.
            let local: Vector3
            if case let .text(position, _, _, _, _, _, _, _, _) = entity.localGeometry?.first {
                local = Vector3(x: position.x + rx, y: position.y + ry, z: position.z)
            } else {
                local = Vector3(x: rx, y: ry, z: 0)
            }
            return t.transformPoint(local)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return LispEntityAdapter.lispList([
            LispEntityAdapter.lispList([.real(xs.min() ?? 0), .real(ys.min() ?? 0), .real(0)]),
            LispEntityAdapter.lispList([.real(xs.max() ?? 0), .real(ys.max() ?? 0), .real(0)]),
        ])
    }

    // MARK: - Shared helpers

    private func entityForProp(handle: String, property: String) throws -> CADEntity {
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              let entity = document.entity(for: uuid)
        else {
            throw LispError.hostError("invalid entity name")
        }
        _ = property
        return entity
    }

    private func propPoint(_ value: LispValue, property: String) throws -> Vector3 {
        guard let coords = value.asPoint, coords.count >= 2 else {
            throw LispError.hostError("setpropertyvalue: \(property) needs a point")
        }
        return Vector3(
            x: coords[0], y: coords[1],
            z: coords.count > 2 ? coords[2] : 0)
    }

    private func propDouble(_ value: LispValue, property: String) throws -> Double {
        guard let number = value.asDouble else {
            throw LispError.hostError("setpropertyvalue: \(property) needs a number")
        }
        return number
    }

    private func propPositiveDouble(_ value: LispValue, property: String) throws -> Double {
        let number = try propDouble(value, property: property)
        guard number > 0 else {
            throw LispError.hostError("setpropertyvalue: \(property) needs a positive number")
        }
        return number
    }

    /// World point to entity-local (inverse TRS; no-shear assumption).
    private func localPoint(_ world: Vector3, _ t: Transform3D) -> Vector3 {
        let dx = world.x - t.position.x
        let dy = world.y - t.position.y
        let c = cos(-t.rotation), s = sin(-t.rotation)
        let rx = dx * c - dy * s, ry = dx * s + dy * c
        return Vector3(
            x: rx / max(t.scale.x, 1e-12),
            y: ry / max(t.scale.y, 1e-12),
            z: (world.z - t.position.z) / max(t.scale.z, 1e-12))
    }

    /// Local direction to world (rotation + scale, no translation).
    private func worldDir(_ v: Vector3, at c: Vector3, _ t: Transform3D) -> Vector3 {
        let wc = t.transformPoint(c)
        let wv = t.transformPoint(Vector3(x: c.x + v.x, y: c.y + v.y, z: c.z + v.z))
        return Vector3(x: wv.x - wc.x, y: wv.y - wc.y, z: wv.z - wc.z)
    }

    /// World direction to local.
    private func localDirVec(_ w: Vector3, _ t: Transform3D) -> Vector3 {
        let c = cos(-t.rotation), s = sin(-t.rotation)
        return Vector3(
            x: (w.x * c - w.y * s) / max(t.scale.x, 1e-12),
            y: (w.x * s + w.y * c) / max(t.scale.y, 1e-12),
            z: w.z / max(t.scale.z, 1e-12))
    }

    /// Local direction to world (bare vector form).
    private func worldDirVec(_ v: Vector3, _ t: Transform3D) -> Vector3 {
        let c = cos(t.rotation), s = sin(t.rotation)
        return Vector3(
            x: (v.x * c - v.y * s) * t.scale.x,
            y: (v.x * s + v.y * c) * t.scale.y,
            z: v.z * t.scale.z)
    }

    private func worldBoundary(entity: CADEntity, t: Transform3D) -> [Vector3] {
        guard let prim = entity.localGeometry?.first else { return [] }
        let local: [Vector3]
        switch prim {
        case let .fillPolygon(points, _): local = points
        case let .fillComplexPolygon(outer, _, _): local = outer
        case let .gradient(outer, _, _, _, _, _): local = outer
        case let .fillRect(origin, size, _):
            local = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ]
        default: return []
        }
        return local.map { t.transformPoint($0) }
    }

    private func dist3(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func polygonArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in 0..<points.count {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private func polyLength(_ points: [Vector3], closed: Bool) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(points.count - 1) {
            total += dist3(points[index], points[index + 1])
        }
        if closed {
            total += dist3(points.last!, points.first!)
        }
        return total
    }
}
