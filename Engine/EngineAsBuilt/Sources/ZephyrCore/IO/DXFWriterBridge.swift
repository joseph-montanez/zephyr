import Foundation

/// Converts Zephyr CAD types to DXF format using pure Swift DXFWriter.
public enum DXFWriterBridge {

    /// Export a full CADDocument to DXF (convenience)
    public static func export(document: CADDocument, to url: URL) throws {
        try exportToDXF(layers: document.allLayers, blocks: document.allBlocks,
                       entities: document.allEntities, filePath: url.path)
    }

    public static func exportToDXF(
        layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
        filePath: String, dxfVersion: DXFVersion = .r2000
    ) throws {
        let writer = DXFWriter(); writer.version = dxfVersion

        for layer in layers {
            let dl = DXFLayerEntry()
            dl.name = layer.name; dl.lineType = layer.lineType; dl.plotFlag = layer.isVisible
            dl.color = DXFColorTable.rgbaToACI(layer.color)
            dl.color24 = DXFColorTable.rgbaToTrueColor(layer.color) ?? -1
            writer.addLayer(dl)
        }

        for entity in entities {
            guard let primitives = entity.localGeometry else { continue }
            let layerName = layers.first(where: { $0.handle == entity.layerID })?.name ?? "0"
            let combinedHatch = combinedHatchEntity(
                primitives: primitives,
                xdata: entity.xdata,
                transform: entity.transform)

            if let combinedHatch {
                combinedHatch.layer = layerName
                writer.addEntity(combinedHatch)
            }

            for prim in primitives {
                if combinedHatch != nil, isHatchComponent(prim) { continue }
                if var dxfEnt = primitiveToEntity(prim) {
                    dxfEnt.layer = layerName
                    applyTransform(entity.transform, to: &dxfEnt)
                    writer.addEntity(dxfEnt)
                }
            }
        }

        try writer.write(to: filePath)
    }


    private struct HatchRegion {
        var outer: CADPolyline
        var holes: [CADPolyline]
    }

    private static func combinedHatchEntity(
        primitives: [CADPrimitive],
        xdata: [String: XDataValue],
        transform: Transform3D
    ) -> DXFHatchEntity? {
        let hatchPaths = primitives.compactMap { primitive -> (region: HatchRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatchPath(let outer, let holes, let pattern, let scale, let angle, let color, let background) = primitive else {
                return nil
            }
            return (HatchRegion(outer: outer, holes: holes), pattern, scale, angle, color, background)
        }

        let legacyHatches = primitives.compactMap { primitive -> (region: HatchRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatch(let boundary, let pattern, let scale, let angle, let color, let background) = primitive else {
                return nil
            }
            return (
                HatchRegion(outer: CADPolyline(points: boundary, isClosed: true), holes: []),
                pattern, scale, angle, color, background)
        }

        let gradients = primitives.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], name: String, angle: Double, color1: ColorRGBA, color2: ColorRGBA)? in
            guard case .gradient(let outer, let holes, let name, let angle, let color1, let color2) = primitive else {
                return nil
            }
            return (outer, holes, name, angle, color1, color2)
        }

        let carriers = primitives.compactMap { primitive -> CADPolyline? in
            guard case .polyline(let path, _) = primitive, path.isHatchBoundaryCarrier else { return nil }
            return path
        }

        let solidRegions = primitives.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], color: ColorRGBA?)? in
            guard case .fillComplexPolygon(let outer, let holes, let color) = primitive else { return nil }
            return (outer, holes, color)
        }

        let hatch = DXFHatchEntity()
        hatch.associative = xdataInt(xdata, "dxf.hatchAssociative") ?? 0
        hatch.hStyle = xdataInt(xdata, "dxf.hatchStyle") ?? 0
        hatch.hPattern = xdataInt(xdata, "dxf.hatchPatternDefinitionType") ?? 1
        hatch.doubleFlag = xdataInt(xdata, "dxf.hatchDouble") ?? 0
        hatch.patternLines = patternLines(from: xdata)

        var regions: [HatchRegion] = []
        var primaryColor: ColorRGBA?

        if let firstGradient = gradients.first {
            hatch.name = "SOLID"
            hatch.solid = 1
            hatch.isGradient = 1
            hatch.gradientName = xdataString(xdata, "dxf.hatchGradientName")
                ?? (firstGradient.name.isEmpty ? "LINEAR" : firstGradient.name)
            let gradientAngleRadians = xdataDouble(xdata, "dxf.hatchGradientAngle") ?? firstGradient.angle
            hatch.gradientAngle = gradientAngleRadians * 180.0 / .pi
            hatch.gradientShift = xdataDouble(xdata, "dxf.hatchGradientShift") ?? 0.0
            hatch.gradientTint = xdataDouble(xdata, "dxf.hatchGradientTint") ?? 0.0
            hatch.singleColorGrad = xdataInt(xdata, "dxf.hatchGradientSingleColor") ?? 0
            hatch.gradientColors = gradientStops(from: xdata)
            if hatch.gradientColors.isEmpty {
                hatch.gradientColors = [
                    gradientStop(position: 0.0, color: firstGradient.color1),
                    gradientStop(position: 1.0, color: firstGradient.color2)
                ]
            }
            primaryColor = firstGradient.color1
            if !carriers.isEmpty {
                regions = classifyHatchPaths(carriers)
            } else {
                regions = gradients.map {
                    HatchRegion(
                        outer: CADPolyline(points: $0.outer, isClosed: true),
                        holes: $0.holes.map { CADPolyline(points: $0, isClosed: true) })
                }
            }
        } else if let first = hatchPaths.first {
            hatch.name = xdataString(xdata, "dxf.hatchPatternName")
                ?? (first.pattern.isEmpty ? "SOLID" : first.pattern)
            hatch.solid = hatch.name.uppercased() == "SOLID" ? 1 : 0
            hatch.scale = xdataDouble(xdata, "dxf.hatchScale") ?? first.scale
            let hatchAngleRadians = xdataDouble(xdata, "dxf.hatchAngle") ?? first.angle
            hatch.angle_p = hatchAngleRadians * 180.0 / .pi
            if xdata["dxf.hatchPatternDefinitionType"] == nil {
                hatch.hPattern = DXFHatchGenerator.predefinedPatterns[hatch.name.uppercased()] == nil ? 0 : 1
            }
            if let background = first.background ?? solidRegions.first?.color {
                hatch.bgColor = DXFColorTable.rgbaToACI(background)
            }
            primaryColor = first.color
            regions = hatchPaths.map(\.region)
        } else if let first = legacyHatches.first {
            hatch.name = xdataString(xdata, "dxf.hatchPatternName")
                ?? (first.pattern.isEmpty ? "SOLID" : first.pattern)
            hatch.solid = hatch.name.uppercased() == "SOLID" ? 1 : 0
            hatch.scale = xdataDouble(xdata, "dxf.hatchScale") ?? first.scale
            let hatchAngleRadians = xdataDouble(xdata, "dxf.hatchAngle") ?? first.angle
            hatch.angle_p = hatchAngleRadians * 180.0 / .pi
            if xdata["dxf.hatchPatternDefinitionType"] == nil {
                hatch.hPattern = DXFHatchGenerator.predefinedPatterns[hatch.name.uppercased()] == nil ? 0 : 1
            }
            if let background = first.background { hatch.bgColor = DXFColorTable.rgbaToACI(background) }
            primaryColor = first.color
            regions = legacyHatches.map(\.region)
        } else if !solidRegions.isEmpty {
            hatch.name = "SOLID"
            hatch.solid = 1
            primaryColor = solidRegions.first?.color
            if !carriers.isEmpty {
                regions = classifyHatchPaths(carriers)
            } else {
                regions = solidRegions.map {
                    HatchRegion(
                        outer: CADPolyline(points: $0.outer, isClosed: true),
                        holes: $0.holes.map { CADPolyline(points: $0, isClosed: true) })
                }
            }
        } else {
            return nil
        }

        for region in regions {
            if let outerLoop = makeHatchLoop(path: region.outer, isOuter: true, transform: transform) {
                hatch.loops.append(outerLoop)
            }
            for hole in region.holes {
                if let holeLoop = makeHatchLoop(path: hole, isOuter: false, transform: transform) {
                    hatch.loops.append(holeLoop)
                }
            }
        }
        guard !hatch.loops.isEmpty else { return nil }
        hatch.loopsNum = hatch.loops.count
        applyColor(primaryColor, to: hatch)
        return hatch
    }

    private static func isHatchComponent(_ primitive: CADPrimitive) -> Bool {
        switch primitive {
        case .hatch, .hatchPath, .gradient, .fillComplexPolygon:
            return true
        case .polyline(let path, _):
            return path.isHatchBoundaryCarrier
        default:
            return false
        }
    }

    private static func makeHatchLoop(
        path: CADPolyline,
        isOuter: Bool,
        transform: Transform3D
    ) -> DXFHatchLoop? {
        if !path.hatchEdges.isEmpty {
            let entities = path.hatchEdges.compactMap { hatchEdgeEntity($0, transform: transform) }
            if entities.count == path.hatchEdges.count {
                let loop = DXFHatchLoop(type: isOuter ? 1 : 0)
                loop.entities = entities
                loop.numEdges = entities.count
                return loop
            }
        }

        let sourcePath: CADPolyline
        if !path.hatchEdges.isEmpty {
            let points = cleanLoop(path.tessellatedPoints()).map { transform.transformPoint($0) }
            sourcePath = CADPolyline(points: points, isClosed: true)
        } else {
            sourcePath = path.transformed(by: transform)
        }
        guard sourcePath.vertices.count >= 2 else { return nil }

        let loop = DXFHatchLoop(type: (isOuter ? 1 : 0) | 2)
        let polyline = DXFLWPolylineEntity()
        polyline.flags = sourcePath.isClosed ? 1 : 0
        polyline.vertexCount = sourcePath.vertices.count
        for vertex in sourcePath.vertices {
            let value = DXFVertex2D()
            value.x = vertex.position.x
            value.y = vertex.position.y
            value.bulge = vertex.bulge
            value.startWidth = vertex.startWidth
            value.endWidth = vertex.endWidth
            polyline.vertices.append(value)
        }
        loop.entities = [polyline]
        loop.numEdges = sourcePath.vertices.count
        return loop
    }

    private static func hatchEdgeEntity(_ edge: CADHatchEdge, transform: Transform3D) -> DXFEntity? {
        let world = transformedHatchEdge(edge, by: transform)
        switch world {
        case .line(let start, let end):
            let line = DXFLineEntity()
            line.basePoint = toDXF(start)
            line.secPoint = toDXF(end)
            return line

        case .circularArc(let center, let radius, let startAngle, let sweep):
            guard radius > 1e-12, abs(sweep) > 1e-12 else { return nil }
            let arc = DXFArcEntity()
            arc.basePoint = toDXF(center)
            arc.radius = radius
            arc.startAngle = startAngle
            arc.endAngle = startAngle + sweep
            arc.isCCW = sweep >= 0 ? 1 : 0
            return arc

        case .ellipticalArc(let center, let axisU, let axisV, let startParam, let sweep):
            let uLength = axisU.magnitude
            let vLength = axisV.magnitude
            let denominator = max(uLength * vLength, 1e-12)
            guard uLength > 1e-12, vLength > 1e-12,
                  abs(axisU.dot(axisV)) / denominator < 1e-5 else { return nil }
            let ellipse = DXFEllipseEntity()
            ellipse.basePoint = toDXF(center)
            ellipse.secPoint = toDXF(axisU)
            ellipse.ratio = vLength / uLength
            ellipse.startParam = startParam
            ellipse.endParam = startParam + sweep
            ellipse.isCCW = sweep >= 0 ? 1 : 0
            return ellipse

        case .spline(let controlPoints, let knots, let degree, let weights, let closed, let periodic):
            guard controlPoints.count >= 2 else { return nil }
            let spline = DXFSplineEntity()
            spline.controlPoints = controlPoints.map(toDXF)
            spline.knots = knots
            spline.degree = degree
            spline.weights = weights ?? []
            spline.flags = (closed ? 1 : 0) | (periodic ? 2 : 0) | (weights == nil ? 0 : 4)
            spline.nControl = Int32(controlPoints.count)
            spline.nKnots = Int32(knots.count)
            return spline
        }
    }

    private static func transformedHatchEdge(_ edge: CADHatchEdge, by transform: Transform3D) -> CADHatchEdge {
        switch edge {
        case .circularArc(let center, let radius, let startAngle, let sweep):
            let worldCenter = transform.transformPoint(center)
            let axisU = transform.transformPoint(center + Vector3(x: radius, y: 0, z: 0)) - worldCenter
            let axisV = transform.transformPoint(center + Vector3(x: 0, y: radius, z: 0)) - worldCenter
            let lengthU = axisU.magnitude
            let lengthV = axisV.magnitude
            let denominator = max(lengthU * lengthV, 1e-12)
            if abs(lengthU - lengthV) <= max(lengthU, lengthV) * 1e-6,
               abs(axisU.dot(axisV)) / denominator < 1e-6 {
                let sourceStart = Vector3(
                    x: center.x + cos(startAngle) * radius,
                    y: center.y + sin(startAngle) * radius,
                    z: center.z)
                let worldStart = transform.transformPoint(sourceStart)
                let transformedStart = atan2(worldStart.y - worldCenter.y, worldStart.x - worldCenter.x)
                let orientation = axisU.cross(axisV).z >= 0 ? 1.0 : -1.0
                return .circularArc(
                    center: worldCenter,
                    radius: (lengthU + lengthV) * 0.5,
                    startAngle: transformedStart,
                    sweep: sweep * orientation)
            }
            return .ellipticalArc(
                center: worldCenter,
                axisU: axisU,
                axisV: axisV,
                startParam: startAngle,
                sweep: sweep)

        default:
            return transform == .identity ? edge : edge.transformed(by: transform)
        }
    }

    private static func classifyHatchPaths(_ paths: [CADPolyline]) -> [HatchRegion] {
        let candidates = paths.compactMap { path -> (path: CADPolyline, points: [Vector3], area: Double)? in
            let points = cleanLoop(path.tessellatedPoints())
            guard points.count >= 3 else { return nil }
            return (path, points, abs(signedArea(points)))
        }
        guard !candidates.isEmpty else { return [] }

        var parent = Array<Int?>(repeating: nil, count: candidates.count)
        for child in candidates.indices {
            let probe = loopProbe(candidates[child].points)
            var bestParent: Int?
            var bestArea = Double.infinity
            for possibleParent in candidates.indices where possibleParent != child {
                guard candidates[possibleParent].area > candidates[child].area + 1e-9 else { continue }
                let parentPoints = candidates[possibleParent].points
                guard pointInPolygon(probe, parentPoints)
                    || candidates[child].points.contains(where: { pointInPolygon($0, parentPoints) }) else { continue }
                if candidates[possibleParent].area < bestArea {
                    bestParent = possibleParent
                    bestArea = candidates[possibleParent].area
                }
            }
            parent[child] = bestParent
        }

        func depth(_ index: Int) -> Int {
            var value = 0
            var cursor = parent[index]
            var visited = Set<Int>()
            while let current = cursor, visited.insert(current).inserted {
                value += 1
                cursor = parent[current]
            }
            return value
        }

        let depths = candidates.indices.map(depth)
        var children = Array(repeating: [Int](), count: candidates.count)
        for index in candidates.indices {
            if let p = parent[index] { children[p].append(index) }
        }

        return candidates.indices
            .filter { depths[$0] % 2 == 0 }
            .sorted { candidates[$0].area > candidates[$1].area }
            .map { outerIndex in
                let holes = children[outerIndex]
                    .filter { depths[$0] == depths[outerIndex] + 1 }
                    .sorted { candidates[$0].area > candidates[$1].area }
                    .map { candidates[$0].path }
                return HatchRegion(outer: candidates[outerIndex].path, holes: holes)
            }
    }

    private static func patternLines(from xdata: [String: XDataValue]) -> [DXFHatchPatternLineData] {
        guard let json = xdataString(xdata, "dxf.hatchPatternLines"),
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return values.compactMap { value in
            guard let angle = (value["angle"] as? NSNumber)?.doubleValue,
                  let baseX = (value["baseX"] as? NSNumber)?.doubleValue,
                  let baseY = (value["baseY"] as? NSNumber)?.doubleValue,
                  let offsetX = (value["offsetX"] as? NSNumber)?.doubleValue,
                  let offsetY = (value["offsetY"] as? NSNumber)?.doubleValue else {
                return nil
            }
            let dashes = (value["dashes"] as? [NSNumber])?.map(\.doubleValue) ?? []
            return DXFHatchPatternLineData(
                angle: angle,
                base: Vector3(x: baseX, y: baseY, z: 0),
                offset: Vector3(x: offsetX, y: offsetY, z: 0),
                dashes: dashes)
        }
    }

    private static func gradientStops(from xdata: [String: XDataValue]) -> [(position: Double, aci: UInt16, rgb: Int32)] {
        guard let json = xdataString(xdata, "dxf.hatchGradientStops"),
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return values.compactMap { value in
            guard let position = (value["position"] as? NSNumber)?.doubleValue else { return nil }
            let aci = UInt16(clamping: (value["aci"] as? NSNumber)?.intValue ?? 0)
            let rgb = Int32((value["rgb"] as? NSNumber)?.intValue ?? -1)
            return (position, aci, rgb)
        }
    }

    private static func gradientStop(
        position: Double,
        color: ColorRGBA
    ) -> (position: Double, aci: UInt16, rgb: Int32) {
        let aciValue = DXFColorTable.rgbaToACI(color)
        return (
            position,
            UInt16(clamping: Int(aciValue)),
            DXFColorTable.rgbaToTrueColor(color) ?? -1)
    }

    private static func applyColor(_ color: ColorRGBA?, to entity: DXFEntity) {
        guard let color else { return }
        entity.color = DXFColorTable.rgbaToACI(color)
        entity.color24 = DXFColorTable.rgbaToTrueColor(color) ?? -1
    }

    private static func xdataString(_ xdata: [String: XDataValue], _ key: String) -> String? {
        guard case .string(let value)? = xdata[key] else { return nil }
        return value
    }

    private static func xdataDouble(_ xdata: [String: XDataValue], _ key: String) -> Double? {
        guard let value = xdata[key] else { return nil }
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    private static func xdataInt(_ xdata: [String: XDataValue], _ key: String) -> Int? {
        guard let value = xdata[key] else { return nil }
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    private static func cleanLoop(_ points: [Vector3]) -> [Vector3] {
        var result: [Vector3] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, last.distance(to: point) <= 1e-9 { continue }
            result.append(point)
        }
        if result.count > 2, let first = result.first, let last = result.last,
           first.distance(to: last) <= 1e-9 {
            result.removeLast()
        }
        return result
    }

    private static func signedArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            area += points[index].x * points[next].y - points[next].x * points[index].y
        }
        return area * 0.5
    }

    private static func loopProbe(_ points: [Vector3]) -> Vector3 {
        guard let first = points.first else { return .zero }
        let center = points.reduce(Vector3.zero, +) / Double(points.count)
        if pointInPolygon(center, points) { return center }
        guard points.count > 1 else { return first }
        return Vector3(
            x: first.x + (points[1].x - first.x) * 1e-6,
            y: first.y + (points[1].y - first.y) * 1e-6,
            z: first.z)
    }

    private static func pointInPolygon(_ point: Vector3, _ polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let denominator = abs(b.y - a.y) < 1e-15 ? 1e-15 : b.y - a.y
                let x = (b.x - a.x) * (point.y - a.y) / denominator + a.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    // MARK: - Primitive → DXFEntity

    private static func primitiveToEntity(_ p: CADPrimitive) -> DXFEntity? {
        switch p {
        case .point(let pos, _):
            return DXFPointEntity().with { $0.basePoint = toDXF(pos) }
        case .line(let s1, let e1, _):
            return DXFLineEntity().with { $0.basePoint = toDXF(s1); $0.secPoint = toDXF(e1) }
        case .circle(let c, let r, _):
            return DXFCircleEntity().with { $0.basePoint = toDXF(c); $0.radius = r }
        case .arc(let c, let r, let sa, let ea, _):
            return DXFArcEntity().with { $0.basePoint = toDXF(c); $0.radius = r; $0.startAngle = sa; $0.endAngle = ea }
        case .polygon(let pts, _):
            let lw = DXFLWPolylineEntity(); lw.flags = 1
            for pt in pts { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; lw.vertices.append(v) }
            return lw
        case .polyline(let path, _):
            if path.isHatchBoundaryCarrier { return nil }
            let lw = DXFLWPolylineEntity()
            for v in path.vertices {
                let dv = DXFVertex2D(); dv.x = v.position.x; dv.y = v.position.y
                dv.bulge = v.bulge; dv.startWidth = v.startWidth; dv.endWidth = v.endWidth
                lw.vertices.append(dv)
            }
            lw.flags = path.isClosed ? 1 : 0; return lw
        case .text(let pos, let txt, let ht, let rot, let st, let ah, let av, _, _):
            let t = DXFTextEntity()
            t.basePoint = toDXF(pos); t.text = txt; t.height = ht; t.angle_p = rot * 180.0 / .pi
            t.style = st ?? "STANDARD"; t.alignH = ah; t.alignV = av; return t
        case .spline(let cps, let knots, let deg, let weights, _):
            let sp = DXFSplineEntity()
            sp.controlPoints = cps.map { toDXF($0) }; sp.knots = knots; sp.degree = deg
            sp.weights = weights ?? []; sp.nControl = Int32(cps.count); sp.nKnots = Int32(knots.count)
            return sp
        case .ellipse(let c, let maj, let ratio, _):
            let el = DXFEllipseEntity(); el.basePoint = toDXF(c); el.secPoint = toDXF(maj); el.ratio = ratio; return el
        case .ray(let s1, let d, _):
            let r = DXFRayEntity(); r.basePoint = toDXF(s1); r.secPoint = toDXF(d); return r
        case .hatch(let boundary, let pattern, let scale, let angle, _, _):
            let h = DXFHatchEntity(); h.name = pattern; h.scale = scale; h.angle_p = angle
            h.solid = pattern.uppercased() == "SOLID" ? 1 : 0
            let loop = DXFHatchLoop(type: 0); let pl = DXFLWPolylineEntity()
            for pt in boundary { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; pl.vertices.append(v) }
            loop.entities.append(pl); h.loops.append(loop); return h
        case .hatchPath(let boundary, _, let pattern, let scale, let angle, _, _):
            let h = DXFHatchEntity(); h.name = pattern; h.scale = scale; h.angle_p = angle
            h.solid = pattern.uppercased() == "SOLID" ? 1 : 0
            let loop = DXFHatchLoop(type: 0); let pl = DXFLWPolylineEntity()
            for vertex in boundary.vertices {
                let v = DXFVertex2D(); v.x = vertex.position.x; v.y = vertex.position.y; v.bulge = vertex.bulge; pl.vertices.append(v)
            }
            pl.flags = boundary.isClosed ? 1 : 0
            loop.entities.append(pl); h.loops.append(loop); return h
        case .fillPolygon(let pts, _):
            let s = DXFSolidEntity()
            if pts.count >= 1 { s.basePoint = toDXF(pts[0]) }
            if pts.count >= 2 { s.secPoint = toDXF(pts[1]) }
            if pts.count >= 3 { s.thirdPoint = toDXF(pts[2]) }
            if pts.count >= 4 { s.fourPoint = toDXF(pts[3]) }
            return s
        case .fillComplexPolygon(let outer, _, _):
            let h = DXFHatchEntity(); h.name = "SOLID"; h.solid = 1
            let loop = DXFHatchLoop(type: 1); let pl = DXFLWPolylineEntity()
            for pt in outer { let v = DXFVertex2D(); v.x = pt.x; v.y = pt.y; pl.vertices.append(v) }
            loop.entities.append(pl); h.loops.append(loop); return h
        default: return nil
        }
    }

    /// Identity — Vector3 is canonical across the module.
    private static func toDXF(_ v: Vector3) -> Vector3 {
        v
    }

    private static func applyTransform(_ t: Transform3D, to e: inout DXFEntity) {
        if let pt = e as? DXFPointEntity { pt.basePoint = toDXF(t.transformPoint(z(pt.basePoint))) }
        if let ln = e as? DXFLineEntity {
            ln.basePoint = toDXF(t.transformPoint(z(ln.basePoint)))
            ln.secPoint = toDXF(t.transformPoint(z(ln.secPoint)))
        }
        if let ci = e as? DXFCircleEntity { ci.basePoint = toDXF(t.transformPoint(z(ci.basePoint))) }
        if let a = e as? DXFArcEntity { a.basePoint = toDXF(t.transformPoint(z(a.basePoint))) }
        if let lw = e as? DXFLWPolylineEntity {
            for v in lw.vertices {
                let p = t.transformPoint(Vector3(x: v.x, y: v.y, z: 0))
                v.x = p.x; v.y = p.y
            }
        }
        if let tx = e as? DXFTextEntity { tx.basePoint = toDXF(t.transformPoint(z(tx.basePoint))) }
        if let sp = e as? DXFSplineEntity {
            sp.controlPoints = sp.controlPoints.map { toDXF(t.transformPoint(z($0))) }
            sp.fitPoints = sp.fitPoints.map { toDXF(t.transformPoint(z($0))) }
        }
        if let el = e as? DXFEllipseEntity { el.basePoint = toDXF(t.transformPoint(z(el.basePoint))) }
        if let ry = e as? DXFRayEntity { ry.basePoint = toDXF(t.transformPoint(z(ry.basePoint))) }
    }

    /// Identity — Vector3 is canonical across the module.
    private static func z(_ v: Vector3) -> Vector3 {
        v
    }
}

// MARK: - Helper: configurable entity
private protocol With {}
extension DXFEntity: With {}
extension With where Self: DXFEntity {
    func with(_ configure: (inout Self) -> Void) -> Self {
        var copy = self; configure(&copy); return copy
    }
}