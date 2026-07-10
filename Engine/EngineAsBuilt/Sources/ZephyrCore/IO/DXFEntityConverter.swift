import Foundation

/// Converts DXF entity types into Zephyr CADPrimitive arrays.
public enum DXFEntityConverter {

    public nonisolated(unsafe) static var simplifyPolylines: Bool = false

    /// Convert a DXFEntity to CADPrimitives
    internal static func convertEntityToPrimitives(
        _ e: DXFEntity,
        arrowSize: Double = 1.0,
        bylayerColor: ColorRGBA? = nil
    ) -> [CADPrimitive] {
        let explicitColor: ColorRGBA? = resolveEntityColor(e)
        let primColor: ColorRGBA? = explicitColor ?? (e.color == 256 ? bylayerColor : nil)

        switch e.eType {
        case .pOINT:
            guard let p = e as? DXFPointEntity else { return [] }
            return [.point(position: cadPoint(p.basePoint, extrusion: p.haveExtrusion ? p.extrusion : nil), color: primColor)]
        case .lINE:
            guard let l = e as? DXFLineEntity else { return [] }
            return [.line(start: yflip(l.basePoint), end: yflip(l.secPoint), color: primColor)]
        case .cIRCLE:
            guard let c = e as? DXFCircleEntity else { return [] }
            return [.circle(center: cadPoint(c.basePoint, extrusion: c.haveExtrusion ? c.extrusion : nil), radius: c.radius, color: primColor)]
        case .aRC:
            guard let a = e as? DXFArcEntity else { return [] }
            let center = cadPoint(a.basePoint, extrusion: a.haveExtrusion ? a.extrusion : nil)
            var startAngle = -a.endAngle
            var endAngle = -a.startAngle
            if a.haveExtrusion && a.extrusion.z < 0 {
                startAngle = -a.startAngle
                endAngle = -a.endAngle
            }
            return [.arc(center: center, radius: a.radius,
                        startAngle: startAngle, endAngle: endAngle, color: primColor)]
        case .lWPOLYLINE, .pOLYLINE:
            return convertPolyline(e, color: primColor)
        case .eLLIPSE:
            return convertEllipse(e, color: primColor)
        case .sPLINE:
            return convertSpline(e, color: primColor)
        case .tEXT, .mTEXT:
            return convertText(e, color: primColor)
        case .iNSERT:
            return []
        case .sOLID:
            guard let s = e as? DXFSolidEntity else { return [] }
            let ext = s.haveExtrusion ? s.extrusion : nil
            return [.fillPolygon(points: [cadPoint(s.basePoint, extrusion: ext), cadPoint(s.secPoint, extrusion: ext),
                                         cadPoint(s.thirdPoint, extrusion: ext), cadPoint(s.fourPoint, extrusion: ext)], color: primColor)]
        case .e3DFACE:
            guard let f = e as? DXF3DFaceEntity else { return [] }
            let ext = f.haveExtrusion ? f.extrusion : nil
            return [.polygon(points: [cadPoint(f.basePoint, extrusion: ext), cadPoint(f.secPoint, extrusion: ext),
                                     cadPoint(f.thirdPoint, extrusion: ext), cadPoint(f.fourPoint, extrusion: ext)], color: primColor)]
        case .hATCH:
            return convertHatch(e, color: primColor)
        case .dIMENSION:
            guard let d = e as? DXFDimensionEntity else { return [] }
            let def = yflip(d.defPoint); let txt = yflip(d.textPoint)
            return def != txt ? [.line(start: def, end: txt, color: primColor)] : [.point(position: def, color: primColor)]
        case .lEADER:
            return convertLeader(e, arrowSize: arrowSize, color: primColor)
        case .iMAGE:
            return convertImage(e, color: primColor)
        case .xLINE:
            guard let x = e as? DXFXLineEntity else { return [] }
            let base = yflip(x.basePoint); let dir = yflip(x.secPoint)
            return [.line(start: base, end: Vector3(x: base.x + dir.x, y: base.y + dir.y, z: base.z + dir.z), color: primColor)]
        case .rAY:
            guard let r = e as? DXFRayEntity else { return [] }
            return [.ray(start: yflip(r.basePoint), direction: yflip(r.secPoint), color: primColor)]
        case .tRACE:
            guard let t = e as? DXFTraceEntity else { return [] }
            return [.line(start: yflip(t.basePoint), end: yflip(t.secPoint), color: primColor)]
        case .vIEWPORT, .tABLE, .bLOCK, .uNKNOWN:
            return []
        default:
            return []
        }
    }

    // MARK: - Polyline

    private static func convertPolyline(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        if let lw = e as? DXFLWPolylineEntity {
            guard !lw.vertices.isEmpty else { return [] }
            if lw.vertices.count == 1 {
                return [.point(position: cadLWPoint(lw.vertices[0], in: lw), color: color)]
            }
            let isClosed = (lw.flags & 0x01) != 0
            let mirrored = !isDefaultExtrusion(lw.extPoint) && lw.extPoint.z < 0
            let path = CADPolyline(
                vertices: lw.vertices.map { v in
                    var bulge = -v.bulge
                    if mirrored { bulge = -bulge }
                    return CADPolylineVertex(position: cadLWPoint(v, in: lw),
                                             bulge: bulge, startWidth: v.startWidth, endWidth: v.endWidth)
                }, isClosed: isClosed, lineTypeGenerationEnabled: (lw.flags & 0x80) != 0)
            return [.polyline(path: simplifyIfNeeded(path), color: color)]
        }
        if let pl = e as? DXFPolylineEntity {
            guard !pl.vertices.isEmpty else { return [] }
            let mirrored = pl.haveExtrusion && pl.extrusion.z < 0
            let path = CADPolyline(
                vertices: pl.vertices.map { v in
                    var bulge = -v.bulge
                    if mirrored { bulge = -bulge }
                    return CADPolylineVertex(position: cadPolylinePoint(v, in: pl),
                                             bulge: bulge, startWidth: v.startWidth, endWidth: v.endWidth)
                },
                isClosed: (pl.flags & 0x01) != 0,
                lineTypeGenerationEnabled: false)
            return [.polyline(path: simplifyIfNeeded(path), color: color)]
        }
        return []
    }

    // MARK: - Ellipse

    private static func convertEllipse(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let el = e as? DXFEllipseEntity else { return [] }
        let normalized = normalizedEllipse(el)
        if normalized.isFull {
            let majorAxis = Vector3(
                x: normalized.major.x,
                y: -normalized.major.y,
                z: normalized.major.z)
            guard majorAxis.magnitude > 1e-12,
                  normalized.ratio > 1e-12 else {
                return [.point(position: yflip(el.basePoint), color: color)]
            }
            return [.ellipse(
                center: yflip(el.basePoint),
                majorAxis: majorAxis,
                minorRatio: normalized.ratio,
                color: color)]
        }

        let pts = ellipsePoints(el, segments: 96, honorIsCCW: false)
        guard !pts.isEmpty else { return [.point(position: yflip(el.basePoint), color: color)] }
        return (0..<(pts.count - 1)).map { .line(start: pts[$0], end: pts[$0 + 1], color: color) }
    }

    // MARK: - Spline

    private static func convertSpline(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let sp = e as? DXFSplineEntity else { return [] }
        let degree = sp.degree > 0 ? sp.degree : 3
        if sp.nControl > 0, sp.nKnots > 0 {
            let cps = sp.controlPoints.map { yflip($0) }
            let weights = sp.weights.isEmpty ? Array(repeating: 1.0, count: cps.count) : sp.weights
            return [.spline(controlPoints: cps, knots: sp.knots, degree: degree,
                           weights: weights.contains { abs($0 - 1.0) > 1e-9 } ? weights : nil, color: color)]
        }
        if sp.nFit > 0 {
            let fpts = sp.fitPoints.map { yflip($0) }
            guard fpts.count > 1 else { return [] }
            return (0..<(fpts.count - 1)).map { .line(start: fpts[$0], end: fpts[$0 + 1], color: color) }
        }
        return []
    }

    // MARK: - Text

    private static func convertText(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let tx = e as? DXFTextEntity else { return [] }
        let cleaned = cleanMTextFormatting(tx.text)
        let height = tx.height > 0 ? tx.height : 2.5
        let isText = e.eType == .tEXT
        let isMText = e.eType == .mTEXT
        let useSec = isText && (tx.alignH != 0 || tx.alignV != 0)
        let ref = useSec ? tx.secPoint : tx.basePoint
        var pos = yflip(ref)
        var angle = -tx.angle_p * .pi / 180.0

        if isText && (tx.alignH == 3 || tx.alignH == 5) {
            let start = yflip(tx.basePoint)
            let end = yflip(tx.secPoint)
            let dx = end.x - start.x
            let dy = end.y - start.y
            if abs(dx) > 1e-12 || abs(dy) > 1e-12 {
                angle = atan2(dy, dx)
            }
        }

        if isText, abs(tx.extrusion.x) < 0.015625, abs(tx.extrusion.y) < 0.015625, tx.extrusion.z < 0 {
            pos = Vector3(x: -pos.x, y: pos.y, z: pos.z)
            angle = tx.angle_p * .pi / 180.0 - .pi
        }

        var alignH = tx.alignH
        var alignV = tx.alignV
        if isMText {
            switch tx.textGen {
            case 1, 4, 7: alignH = 0
            case 2, 5, 8: alignH = 1
            case 3, 6, 9: alignH = 2
            default: alignH = 0
            }

            switch tx.textGen {
            case 1...3: alignV = 3
            case 4...6: alignV = 2
            case 7...9: alignV = 1
            default: alignV = 3
            }
        }

        return [.text(position: pos, text: cleaned, height: height, rotation: angle,
                      style: tx.style, alignH: alignH, alignV: alignV,
                      mtextWidth: isMText && tx.widthScale > 0 ? tx.widthScale : nil, color: color)]
    }

    // MARK: - Hatch

    private static func convertHatch(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let h = e as? DXFHatchEntity else { return [] }
        let boundaryTransform = hatchBoundaryTransform(for: h)
        let pathRegions = extractHatchPathRegions(
            from: h,
            storedBoundaryTransform: boundaryTransform)
        guard !pathRegions.isEmpty else { return [] }

        let basePattern = h.name.isEmpty ? "SOLID" : h.name
        let scale = h.scale > 0 ? h.scale : 1.0
        let angle = transformedPlanarAngle(
            h.angle_p * .pi / 180.0,
            by: boundaryTransform)
        let pattern = hatchPatternName(
            for: h,
            fallback: basePattern,
            boundaryTransform: boundaryTransform,
            hatchAngle: angle)

        if h.isGradient == 1 {
            let colors = resolvedGradientColors(for: h, fallback: color ?? .white)
            let gradientName = h.gradientName.isEmpty ? "LINEAR" : h.gradientName
            var primitives = pathRegions.map { region -> CADPrimitive in
                let loops = tessellatedRegion(region)
                return .gradient(
                    outer: loops.outer,
                    holes: loops.holes,
                    gradientName: gradientName,
                    angle: transformedPlanarAngle(
                        h.gradientAngle * .pi / 180.0,
                        by: boundaryTransform),
                    color1: colors.0,
                    color2: colors.1)
            }
            primitives.append(contentsOf: hatchBoundaryCarriers(pathRegions))
            return primitives
        }

        if h.solid == 1 {
            var primitives = pathRegions.map { region -> CADPrimitive in
                let loops = tessellatedRegion(region)
                return .fillComplexPolygon(outer: loops.outer, holes: loops.holes, color: color)
            }
            primitives.append(contentsOf: hatchBoundaryCarriers(pathRegions))
            return primitives
        }

        let background = h.bgColor >= 0 ? DXFColorTable.aciToRGBA(h.bgColor, color24: -1) : nil
        return pathRegions.map { region in
            .hatchPath(boundary: region.outer, holes: region.holes, pattern: pattern,
                       scale: scale, angle: angle,
                       color: color, backgroundColor: background)
        }
    }

    internal static func hatchXData(from entity: DXFEntity) -> [String: XDataValue] {
        guard let hatch = entity as? DXFHatchEntity else { return [:] }
        var values: [String: XDataValue] = [
            "dxf.hatchPatternName": .string(hatch.name.isEmpty ? "SOLID" : hatch.name),
            "dxf.hatchScale": .double(hatch.scale),
            "dxf.hatchAngle": .double(hatch.angle_p * .pi / 180.0),
            "dxf.hatchStyle": .int(hatch.hStyle),
            "dxf.hatchPatternDefinitionType": .int(hatch.hPattern),
            "dxf.hatchDouble": .bool(hatch.doubleFlag != 0),
            "dxf.hatchAssociative": .bool(hatch.associative != 0),
            "dxf.hatchIsGradient": .bool(hatch.isGradient != 0)
        ]

        if !hatch.patternLines.isEmpty {
            let lines: [[String: Any]] = hatch.patternLines.map {
                [
                    "angle": $0.angle,
                    "baseX": $0.base.x,
                    "baseY": $0.base.y,
                    "offsetX": $0.offset.x,
                    "offsetY": $0.offset.y,
                    "dashes": $0.dashes
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: lines),
               let json = String(data: data, encoding: .utf8) {
                values["dxf.hatchPatternLines"] = .string(json)
            }
        }

        guard hatch.isGradient != 0 else { return values }

        values["dxf.hatchGradientName"] = .string(hatch.gradientName.isEmpty ? "LINEAR" : hatch.gradientName)
        values["dxf.hatchGradientAngle"] = .double(hatch.gradientAngle * .pi / 180.0)
        values["dxf.hatchGradientShift"] = .double(hatch.gradientShift)
        values["dxf.hatchGradientTint"] = .double(hatch.gradientTint)
        values["dxf.hatchGradientSingleColor"] = .bool(hatch.singleColorGrad != 0)

        let stops: [[String: Any]] = hatch.gradientColors.map {
            ["position": $0.position, "aci": Int($0.aci), "rgb": Int($0.rgb)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: stops),
           let json = String(data: data, encoding: .utf8) {
            values["dxf.hatchGradientStops"] = .string(json)
        }
        return values
    }

    private static func resolvedGradientColors(
        for hatch: DXFHatchEntity,
        fallback: ColorRGBA
    ) -> (ColorRGBA, ColorRGBA) {
        let sorted = hatch.gradientColors.sorted { $0.position < $1.position }

        func color(for stop: (position: Double, aci: UInt16, rgb: Int32)?) -> ColorRGBA? {
            guard let stop else { return nil }
            if stop.rgb >= 0 { return rgbToRGBA(stop.rgb) }
            if stop.aci > 0 { return DXFColorTable.aciToRGBA(Int32(stop.aci), color24: -1) }
            return nil
        }

        let first = color(for: sorted.first) ?? fallback
        if hatch.singleColorGrad != 0 {
            let tint = max(0.0, min(1.0, hatch.gradientTint))
            let second = ColorRGBA(
                r: UInt8(max(0, min(255, Int(round(Double(first.r) + (255.0 - Double(first.r)) * tint))))),
                g: UInt8(max(0, min(255, Int(round(Double(first.g) + (255.0 - Double(first.g)) * tint))))),
                b: UInt8(max(0, min(255, Int(round(Double(first.b) + (255.0 - Double(first.b)) * tint))))),
                a: first.a)
            return (first, second)
        }

        let second = color(for: sorted.last) ?? ColorRGBA(
            r: UInt8(min(255, Int(first.r) + 60)),
            g: UInt8(min(255, Int(first.g) + 60)),
            b: UInt8(min(255, Int(first.b) + 60)),
            a: first.a)
        return (first, second)
    }

    private static func hatchPatternName(
        for h: DXFHatchEntity,
        fallback: String,
        boundaryTransform: Transform3D,
        hatchAngle: Double
    ) -> String {
        guard h.solid == 0, !h.patternLines.isEmpty else { return fallback }
        let safeScale = max(abs(h.scale), 1e-9)
        let transformOrigin = boundaryTransform.transformPoint(.zero)

        func transformVector(_ value: Vector3) -> Vector3 {
            boundaryTransform.transformPoint(value) - transformOrigin
        }

        let lines = h.patternLines.map { line -> DXFHatchPatternLine in
            let sourceAngle = -line.angle * .pi / 180.0
            let sourceDirection = Vector3(
                x: cos(sourceAngle),
                y: sin(sourceAngle),
                z: 0)
            let transformedDirection = transformVector(sourceDirection)
            let cadAngle = transformedDirection.magnitude > 1e-12
                ? atan2(transformedDirection.y, transformedDirection.x)
                : sourceAngle
            let cosA = cos(-cadAngle)
            let sinA = sin(-cadAngle)

            func toLineSpace(_ p: Vector3, isVector: Bool = false) -> Vector3 {
                let source = Vector3(x: p.x, y: -p.y, z: 0)
                let cad = isVector
                    ? transformVector(source)
                    : boundaryTransform.transformPoint(source)
                return Vector3(
                    x: (cad.x * cosA - cad.y * sinA) / safeScale,
                    y: (cad.x * sinA + cad.y * cosA) / safeScale,
                    z: 0)
            }

            var offset = toLineSpace(line.offset, isVector: true)
            if offset.y < 0.0 {
                offset.x = -offset.x
                offset.y = -offset.y
            }

            return DXFHatchPatternLine(
                angleDegrees: (cadAngle - hatchAngle) * 180.0 / .pi,
                base: toLineSpace(line.base),
                offset: offset,
                dashes: line.dashes.map { $0 / safeScale })
        }

        return DXFHatchGenerator.registerImportedPatternDefinition(name: fallback, lines: lines)
    }

    private struct HatchPathRegion {
        var outer: CADPolyline
        var holes: [CADPolyline]
    }

    private static func tessellatedRegion(_ region: HatchPathRegion) -> (outer: [Vector3], holes: [[Vector3]]) {
        let outer = cleanAdjacentPoints(region.outer.tessellatedPoints())
        let holes = region.holes
            .map { cleanAdjacentPoints($0.tessellatedPoints()) }
            .filter { $0.count >= 3 }
        return (outer, holes)
    }

    private static func hatchBoundaryCarriers(_ regions: [HatchPathRegion]) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        for region in regions {
            for sourcePath in [region.outer] + region.holes {
                var path = sourcePath
                path.isHatchBoundaryCarrier = true
                primitives.append(.polyline(path: path, color: .transparent))
            }
        }
        return primitives
    }

    private static func extractHatchPathRegions(
        from h: DXFHatchEntity,
        storedBoundaryTransform: Transform3D
    ) -> [HatchPathRegion] {
        guard !h.loops.isEmpty else { return [] }

        let candidates: [(loop: DXFHatchLoop, path: CADPolyline, points: [Vector3], area: Double)] = h.loops.compactMap { loop in
            guard let path = buildHatchLoopPath(
                loop,
                storedBoundaryTransform: storedBoundaryTransform) else { return nil }
            let points = cleanAdjacentPoints(path.tessellatedPoints())
            guard points.count >= 3 else { return nil }
            return (loop: loop, path: path, points: points, area: abs(signedArea(points)))
        }
        guard !candidates.isEmpty else { return [] }

        var parent = Array<Int?>(repeating: nil, count: candidates.count)
        for child in candidates.indices {
            let probe = interiorProbe(candidates[child].points)
            var bestParent: Int?
            var bestArea = Double.infinity
            for possibleParent in candidates.indices where possibleParent != child {
                guard candidates[possibleParent].area > candidates[child].area + 1e-9 else { continue }
                let polygon = candidates[possibleParent].points
                guard pointInPolygon(probe, polygon)
                    || candidates[child].points.contains(where: { pointInPolygon($0, polygon) }) else { continue }
                if candidates[possibleParent].area < bestArea {
                    bestArea = candidates[possibleParent].area
                    bestParent = possibleParent
                }
            }
            parent[child] = bestParent
        }

        func depth(of index: Int) -> Int {
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
        var children: [[Int]] = Array(repeating: [], count: candidates.count)
        for index in candidates.indices {
            if let p = parent[index] { children[p].append(index) }
        }

        let outerIndices: [Int]
        switch h.hStyle {
        case 1, 2:
            outerIndices = candidates.indices.filter { depths[$0] == 0 }
        default:
            outerIndices = candidates.indices.filter { depths[$0] % 2 == 0 }
        }

        return outerIndices
            .sorted { candidates[$0].area > candidates[$1].area }
            .map { outerIndex in
                let holes: [CADPolyline]
                switch h.hStyle {
                case 2:
                    holes = []
                default:
                    holes = children[outerIndex]
                        .filter { depths[$0] == depths[outerIndex] + 1 }
                        .sorted { candidates[$0].area > candidates[$1].area }
                        .map { candidates[$0].path }
                }
                return HatchPathRegion(outer: candidates[outerIndex].path, holes: holes)
            }
    }

    private static func interiorProbe(_ points: [Vector3]) -> Vector3 {
        guard let first = points.first else { return .zero }
        let center = centroid(points)
        if pointInPolygon(center, points) { return center }
        guard points.count > 1 else { return first }
        return Vector3(
            x: first.x + (points[1].x - first.x) * 1e-6,
            y: first.y + (points[1].y - first.y) * 1e-6,
            z: first.z)
    }

    private static func buildHatchLoopPath(
        _ loop: DXFHatchLoop,
        storedBoundaryTransform: Transform3D
    ) -> CADPolyline? {
        let storedPath = buildHatchPath(from: loop.entities).map {
            storedBoundaryTransform == .identity
                ? $0
                : $0.transformed(by: storedBoundaryTransform)
        }
        guard !loop.sourceBoundaryEntities.isEmpty else { return storedPath }

        guard let sourcePath = buildHatchPath(from: loop.sourceBoundaryEntities) else {
            return storedPath
        }
        guard let storedPath else { return sourcePath }

        return hatchPathsAreEquivalent(sourcePath, storedPath) ? sourcePath : storedPath
    }

    private static func buildHatchPath(from entities: [DXFEntity]) -> CADPolyline? {
        var edges: [CADPolyline] = []
        edges.reserveCapacity(entities.count)

        for entity in entities {
            if let path = hatchEdgePath(entity), path.tessellatedPoints().count >= 2 {
                edges.append(path)
            }
        }

        if edges.count == 1 {
            var path = edges[0]
            let tessellated = path.tessellatedPoints()
            let points = cleanAdjacentPoints(tessellated)
            guard points.count >= 3 else { return nil }
            if let first = tessellated.first,
               let last = tessellated.last,
               first.distance(to: last) <= hatchClosureTolerance(for: tessellated) {
                path.isClosed = true
            }
            return path
        }

        return stitchHatchPaths(edges)
    }

    private static func hatchPathsAreEquivalent(_ lhs: CADPolyline, _ rhs: CADPolyline) -> Bool {
        let lhsPoints = cleanAdjacentPoints(lhs.tessellatedPoints(segmentsPerRadian: 12.0))
        let rhsPoints = cleanAdjacentPoints(rhs.tessellatedPoints(segmentsPerRadian: 12.0))
        guard lhsPoints.count >= 3, rhsPoints.count >= 3 else { return false }

        let rhsBounds = hatchBounds(rhsPoints)
        let lhsBounds = hatchBounds(lhsPoints)
        let diagonal = max(hypot(rhsBounds.maxX - rhsBounds.minX, rhsBounds.maxY - rhsBounds.minY), 1e-9)
        let tolerance = max(diagonal * 0.005, 1e-5)

        guard abs(lhsBounds.minX - rhsBounds.minX) <= tolerance,
              abs(lhsBounds.minY - rhsBounds.minY) <= tolerance,
              abs(lhsBounds.maxX - rhsBounds.maxX) <= tolerance,
              abs(lhsBounds.maxY - rhsBounds.maxY) <= tolerance else {
            return false
        }

        let lhsArea = abs(signedArea(lhsPoints))
        let rhsArea = abs(signedArea(rhsPoints))
        let areaTolerance = max(rhsArea * 0.02, diagonal * tolerance * 2.0)
        guard abs(lhsArea - rhsArea) <= areaTolerance else { return false }

        let toleranceSquared = tolerance * tolerance
        return maxDistanceSquared(from: lhsPoints, to: rhsPoints, closed: rhs.isClosed) <= toleranceSquared
            && maxDistanceSquared(from: rhsPoints, to: lhsPoints, closed: lhs.isClosed) <= toleranceSquared
    }

    private static func hatchBounds(_ points: [Vector3]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard let first = points.first else { return (0, 0, 0, 0) }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return (minX, minY, maxX, maxY)
    }

    private static func maxDistanceSquared(
        from points: [Vector3],
        to path: [Vector3],
        closed: Bool
    ) -> Double {
        guard points.count > 0, path.count > 1 else { return .infinity }
        let segmentCount = closed ? path.count : path.count - 1
        var maximum = 0.0
        for point in points {
            var minimum = Double.infinity
            for index in 0..<segmentCount {
                let next = (index + 1) % path.count
                minimum = min(minimum, pointSegmentDistanceSquared(point, path[index], path[next]))
            }
            maximum = max(maximum, minimum)
        }
        return maximum
    }

    private static func pointSegmentDistanceSquared(_ point: Vector3, _ start: Vector3, _ end: Vector3) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let lengthSquared = dx * dx + dy * dy + dz * dz
        if lengthSquared <= 1e-24 {
            let px = point.x - start.x
            let py = point.y - start.y
            let pz = point.z - start.z
            return px * px + py * py + pz * pz
        }
        let projection = ((point.x - start.x) * dx
            + (point.y - start.y) * dy
            + (point.z - start.z) * dz) / lengthSquared
        let t = max(0.0, min(1.0, projection))
        let px = point.x - (start.x + dx * t)
        let py = point.y - (start.y + dy * t)
        let pz = point.z - (start.z + dz * t)
        return px * px + py * py + pz * pz
    }

    private static func hatchEdgePath(_ ent: DXFEntity) -> CADPolyline? {
        if let lw = ent as? DXFLWPolylineEntity {
            return hatchLWPolylinePath(lw)
        }
        if let pl = ent as? DXFPolylineEntity {
            return hatchPolylinePath(pl)
        }
        if let arc = ent as? DXFArcEntity {
            return hatchArcPath(arc)
        }
        if let circle = ent as? DXFCircleEntity {
            return hatchCirclePath(circle)
        }
        if let ellipse = ent as? DXFEllipseEntity {
            return hatchEllipsePath(ellipse)
        }
        if let spline = ent as? DXFSplineEntity {
            return hatchSplinePath(spline)
        }
        if let line = ent as? DXFLineEntity {
            let start = yflip(line.basePoint)
            let end = yflip(line.secPoint)
            return CADPolyline(points: [start, end], hatchEdges: [.line(start: start, end: end)])
        }
        return nil
    }

    private static func hatchLWPolylinePath(_ polyline: DXFLWPolylineEntity) -> CADPolyline? {
        guard !polyline.vertices.isEmpty else { return nil }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if !isDefaultExtrusion(polyline.extPoint) && polyline.extPoint.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadLWPoint($0, in: polyline),
                                     bulge: bulge,
                                     startWidth: $0.startWidth,
                                     endWidth: $0.endWidth)
        }
        var path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        path.hatchEdges = analyticEdges(from: path)
        return path
    }

    private static func hatchPolylinePath(_ polyline: DXFPolylineEntity) -> CADPolyline? {
        guard !polyline.vertices.isEmpty else { return nil }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if polyline.haveExtrusion && polyline.extrusion.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadPolylinePoint($0, in: polyline),
                                     bulge: bulge,
                                     startWidth: $0.startWidth,
                                     endWidth: $0.endWidth)
        }
        var path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        path.hatchEdges = analyticEdges(from: path)
        return path
    }

    private static func analyticEdges(from path: CADPolyline) -> [CADHatchEdge] {
        guard path.segmentCount > 0 else { return [] }
        return (0..<path.segmentCount).map { segment in
            if let arc = path.arcParameters(forSegment: segment) {
                return .circularArc(center: arc.center, radius: arc.radius,
                                    startAngle: arc.startAngle, sweep: arc.sweep)
            }
            return .line(start: path.vertices[segment].position,
                         end: path.vertices[path.endVertexIndex(forSegment: segment)].position)
        }
    }

    private static func hatchArcPath(_ arc: DXFArcEntity) -> CADPolyline? {
        guard arc.radius > 1e-12 else { return nil }
        let center = yflip(arc.basePoint)
        let parameters = hatchCircularArcParameters(arc)
        let startAngle = parameters.startAngle
        let sweep = parameters.sweep
        guard abs(sweep) > 1e-12 else { return nil }

        let edge = CADHatchEdge.circularArc(
            center: center, radius: arc.radius, startAngle: startAngle, sweep: sweep)
        let start = edge.startPoint!

        if abs(abs(sweep) - .pi * 2.0) < 1e-7 {
            let midAngle = startAngle + sweep * 0.5
            let midpoint = Vector3(x: center.x + arc.radius * cos(midAngle),
                                   y: center.y + arc.radius * sin(midAngle), z: center.z)
            let halfBulge = tan(sweep * 0.125)
            return CADPolyline(
                vertices: [
                    CADPolylineVertex(position: start, bulge: halfBulge),
                    CADPolylineVertex(position: midpoint, bulge: halfBulge)
                ],
                isClosed: true,
                hatchEdges: [edge])
        }

        return CADPolyline(
            vertices: [
                CADPolylineVertex(position: start, bulge: tan(sweep * 0.25)),
                CADPolylineVertex(position: edge.endPoint!)
            ],
            hatchEdges: [edge])
    }

    private static func hatchCirclePath(_ circle: DXFCircleEntity) -> CADPolyline? {
        guard circle.radius > 1e-12 else { return nil }
        let center = yflip(circle.basePoint)
        let edge = CADHatchEdge.circularArc(
            center: center,
            radius: circle.radius,
            startAngle: 0.0,
            sweep: .pi * 2.0)
        let start = Vector3(
            x: center.x + circle.radius,
            y: center.y,
            z: center.z)
        let midpoint = Vector3(
            x: center.x - circle.radius,
            y: center.y,
            z: center.z)
        return CADPolyline(
            vertices: [
                CADPolylineVertex(position: start, bulge: 1.0),
                CADPolylineVertex(position: midpoint, bulge: 1.0)
            ],
            isClosed: true,
            hatchEdges: [edge])
    }

    private static func hatchEllipsePath(_ ellipse: DXFEllipseEntity) -> CADPolyline? {
        let normalized = normalizedEllipse(ellipse)
        let center = yflip(ellipse.basePoint)
        let majorLength = normalized.major.magnitude
        let minorLength = majorLength * normalized.ratio
        guard majorLength > 1e-12, minorLength > 1e-12 else { return nil }

        let rotation = atan2(normalized.major.y, normalized.major.x)
        let axisU = Vector3(x: majorLength * cos(rotation),
                            y: -majorLength * sin(rotation), z: 0)
        let axisV = Vector3(x: -minorLength * sin(rotation),
                            y: -minorLength * cos(rotation), z: 0)
        let sweep = normalizedHatchArcSweep(
            start: normalized.start,
            end: normalized.end,
            isCCW: ellipse.isCCW == 0)
        guard abs(sweep) > 1e-12 else { return nil }

        let edge = CADHatchEdge.ellipticalArc(
            center: center, axisU: axisU, axisV: axisV,
            startParam: normalized.start, sweep: sweep)
        let points = edge.tessellatedPoints(segmentsPerRadian: 4.0)
        guard let first = points.first, let last = points.last else { return nil }
        if normalized.isFull {
            return CADPolyline(points: [first, points[points.count / 2]], isClosed: true, hatchEdges: [edge])
        }
        return CADPolyline(points: [first, last], hatchEdges: [edge])
    }

    private static func hatchSplinePath(_ spline: DXFSplineEntity) -> CADPolyline? {
        let controlPoints: [Vector3]
        if spline.nControl > 0, !spline.controlPoints.isEmpty {
            controlPoints = spline.controlPoints.map { yflip($0) }
        } else if spline.nFit > 0, !spline.fitPoints.isEmpty {
            controlPoints = spline.fitPoints.map { yflip($0) }
        } else {
            return nil
        }

        let degree = spline.degree > 0 ? spline.degree : 3
        let declaredClosed = (spline.flags & 1) != 0
        let periodic = (spline.flags & 2) != 0
        let weights = spline.weights.isEmpty
            ? nil
            : normalizedSplineWeights(spline.weights, controlCount: controlPoints.count)
        var edge = CADHatchEdge.spline(
            controlPoints: controlPoints,
            knots: spline.knots,
            degree: degree,
            weights: weights,
            closed: declaredClosed || periodic,
            periodic: periodic)
        var points = edge.tessellatedPoints(segmentsPerRadian: 6.0)
        guard points.count >= 2 else { return nil }

        let geometricallyClosed: Bool
        if let first = points.first, let last = points.last {
            geometricallyClosed = first.distance(to: last) <= hatchClosureTolerance(for: points)
        } else {
            geometricallyClosed = false
        }

        if geometricallyClosed && !declaredClosed && !periodic {
            edge = .spline(
                controlPoints: controlPoints,
                knots: spline.knots,
                degree: degree,
                weights: weights,
                closed: true,
                periodic: false)
            points = edge.tessellatedPoints(segmentsPerRadian: 6.0)
        }

        if declaredClosed || periodic || geometricallyClosed {
            return CADPolyline(points: [points[0], points[points.count / 2]], isClosed: true, hatchEdges: [edge])
        }
        return CADPolyline(points: [points[0], points[points.count - 1]], hatchEdges: [edge])
    }

    private static func hatchCircularArcParameters(
        _ arc: DXFArcEntity
    ) -> (startAngle: Double, sweep: Double) {
        let dxfIsCCW = arc.isCCW != 0
        let startAngle = dxfIsCCW ? -arc.startAngle : arc.startAngle
        let endAngle = dxfIsCCW ? -arc.endAngle : arc.endAngle
        let sweep = normalizedHatchArcSweep(
            start: startAngle,
            end: endAngle,
            isCCW: !dxfIsCCW)
        return (startAngle, sweep)
    }

    private static func normalizedHatchArcSweep(
        start: Double,
        end: Double,
        isCCW: Bool
    ) -> Double {
        let twoPi = Double.pi * 2.0
        let raw = end - start
        let rawMagnitude = abs(raw)
        let wrappedMagnitude = rawMagnitude.truncatingRemainder(dividingBy: twoPi)
        let endpointDistance = min(wrappedMagnitude, abs(twoPi - wrappedMagnitude))

        let isFullCircle = rawMagnitude <= 1e-10
            || abs(rawMagnitude - twoPi) <= 1e-5
            || (rawMagnitude > Double.pi && endpointDistance <= 1e-7)
        if isFullCircle {
            return isCCW ? twoPi : -twoPi
        }

        var sweep = raw.truncatingRemainder(dividingBy: twoPi)
        if isCCW {
            if sweep <= 0.0 { sweep += twoPi }
        } else if sweep >= 0.0 {
            sweep -= twoPi
        }
        return sweep
    }

    private static func hatchClosureTolerance(for points: [Vector3]) -> Double {
        guard let first = points.first else { return 1e-9 }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(hypot(maxX - minX, maxY - minY) * 1e-8, 1e-9)
    }

    private static func stitchHatchPaths(_ paths: [CADPolyline]) -> CADPolyline? {
        guard !paths.isEmpty else { return nil }
        var used = Array(repeating: false, count: paths.count)
        var out = paths[0]
        used[0] = true
        var usedCount = 1
        let toleranceSquared = hatchPathStitchToleranceSquared(for: paths)

        func distSq(_ a: Vector3, _ b: Vector3) -> Double {
            let dx = a.x - b.x
            let dy = a.y - b.y
            let dz = a.z - b.z
            return dx * dx + dy * dy + dz * dz
        }

        while usedCount < paths.count {
            guard let tail = out.hatchEdges.last?.endPoint ?? out.vertices.last?.position else { break }
            var bestIndex: Int?
            var reverse = false
            var bestDistance = Double.infinity

            for index in paths.indices where !used[index] {
                let path = paths[index]
                guard let start = path.hatchEdges.first?.startPoint ?? path.vertices.first?.position,
                      let end = path.hatchEdges.last?.endPoint ?? path.vertices.last?.position else { continue }
                let startDistance = distSq(tail, start)
                if startDistance < bestDistance {
                    bestDistance = startDistance
                    bestIndex = index
                    reverse = false
                }
                let endDistance = distSq(tail, end)
                if endDistance < bestDistance {
                    bestDistance = endDistance
                    bestIndex = index
                    reverse = true
                }
            }

            guard let index = bestIndex, bestDistance <= toleranceSquared else { break }
            used[index] = true
            usedCount += 1
            appendHatchPath(reverse ? reversedHatchPath(paths[index]) : paths[index],
                            to: &out, toleranceSquared: toleranceSquared)
        }

        guard usedCount == paths.count else { return nil }
        closeHatchPath(&out, toleranceSquared: toleranceSquared)
        return out.tessellatedPoints().count >= 3 ? out : nil
    }

    private static func appendHatchPath(_ path: CADPolyline, to out: inout CADPolyline, toleranceSquared: Double) {
        guard !path.vertices.isEmpty else { return }
        guard !out.vertices.isEmpty else {
            out = path
            return
        }

        if nearlySamePoint(out.vertices.last!.position, path.vertices[0].position, toleranceSquared: toleranceSquared) {
            out.vertices[out.vertices.count - 1].bulge = path.vertices[0].bulge
            out.vertices[out.vertices.count - 1].endWidth = path.vertices[0].endWidth
            out.vertices.append(contentsOf: path.vertices.dropFirst())
        } else {
            out.vertices.append(contentsOf: path.vertices)
        }
        out.hatchEdges.append(contentsOf: path.hatchEdges)
    }

    private static func reversedHatchPath(_ path: CADPolyline) -> CADPolyline {
        guard !path.vertices.isEmpty else { return path }
        let old = path.vertices
        var reversed: [CADPolylineVertex] = []
        reversed.reserveCapacity(old.count)
        for newIndex in old.indices {
            let oldIndex = old.count - 1 - newIndex
            var vertex = old[oldIndex]
            if oldIndex > 0 {
                vertex.bulge = -old[oldIndex - 1].bulge
                vertex.startWidth = old[oldIndex - 1].endWidth
                vertex.endWidth = old[oldIndex - 1].startWidth
            } else {
                vertex.bulge = path.isClosed ? -old.last!.bulge : 0.0
            }
            reversed.append(vertex)
        }
        return CADPolyline(
            vertices: reversed,
            isClosed: path.isClosed,
            lineTypeGenerationEnabled: path.lineTypeGenerationEnabled,
            hatchEdges: path.hatchEdges.reversed().map { $0.reversed() },
            isHatchBoundaryCarrier: path.isHatchBoundaryCarrier)
    }

    private static func closeHatchPath(_ path: inout CADPolyline, toleranceSquared: Double) {
        let points = path.tessellatedPoints()
        guard points.count >= 3, let first = points.first, let last = points.last else { return }
        if nearlySamePoint(first, last, toleranceSquared: toleranceSquared) {
            if path.vertices.count > 2,
               let rawFirst = path.vertices.first?.position,
               let rawLast = path.vertices.last?.position,
               nearlySamePoint(rawFirst, rawLast, toleranceSquared: toleranceSquared) {
                path.vertices.removeLast()
            }
            path.isClosed = true
        } else if let edgeStart = path.hatchEdges.first?.startPoint,
                  let edgeEnd = path.hatchEdges.last?.endPoint,
                  nearlySamePoint(edgeStart, edgeEnd, toleranceSquared: toleranceSquared) {
            path.isClosed = true
        }
    }

    private static func hatchPathStitchToleranceSquared(for paths: [CADPolyline]) -> Double {
        let points = paths.flatMap { $0.tessellatedPoints(segmentsPerRadian: 2.0) }
        guard let first = points.first else { return 1e-4 }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let diagonal = sqrt(dx * dx + dy * dy)
        let tolerance = min(max(diagonal * 1e-3, 1e-2), 10.0)
        return tolerance * tolerance
    }

    private static func signedArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0.0 }
        var area = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area * 0.5
    }

    private static func centroid(_ points: [Vector3]) -> Vector3 {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(Vector3.zero) { $0 + $1 }
        return sum / Double(points.count)
    }

    private static func pointInPolygon(_ point: Vector3, _ polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let crosses = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) == 0.0 ? 1e-20 : (pj.y - pi.y)) + pi.x)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func hatchLWPolylineToPoints(_ polyline: DXFLWPolylineEntity) -> [Vector3] {
        guard !polyline.vertices.isEmpty else { return [] }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if !isDefaultExtrusion(polyline.extPoint) && polyline.extPoint.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadLWPoint($0, in: polyline),
                              bulge: bulge,
                              startWidth: $0.startWidth,
                              endWidth: $0.endWidth)
        }
        let path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        return path.hasBulges ? path.tessellatedPoints() : path.points
    }

    private static func hatchPolylineToPoints(_ polyline: DXFPolylineEntity) -> [Vector3] {
        guard !polyline.vertices.isEmpty else { return [] }
        let vertices = polyline.vertices.map {
            var bulge = -$0.bulge
            if polyline.haveExtrusion && polyline.extrusion.z < 0 { bulge = -bulge }
            return CADPolylineVertex(position: cadPolylinePoint($0, in: polyline),
                              bulge: bulge,
                              startWidth: $0.startWidth,
                              endWidth: $0.endWidth)
        }
        let path = CADPolyline(vertices: vertices, isClosed: (polyline.flags & 1) != 0)
        return path.hasBulges ? path.tessellatedPoints() : path.points
    }

    private static func stitchHatchEdges(_ edges: [[Vector3]]) -> [Vector3] {
        guard !edges.isEmpty else { return [] }
        var used = Array(repeating: false, count: edges.count)
        var out = edges[0]
        used[0] = true
        var usedCount = 1
        let toleranceSquared = hatchStitchToleranceSquared(for: edges)

        func distSq(_ a: Vector3, _ b: Vector3) -> Double {
            let dx = a.x - b.x
            let dy = a.y - b.y
            let dz = a.z - b.z
            return dx * dx + dy * dy + dz * dz
        }

        func appendEdge(_ edge: [Vector3]) {
            guard !edge.isEmpty else { return }
            if let tail = out.last, let first = edge.first, distSq(tail, first) <= toleranceSquared {
                out.append(contentsOf: edge.dropFirst())
            } else {
                out.append(contentsOf: edge)
            }
        }

        while usedCount < edges.count {
            guard let tail = out.last else { break }
            var bestIndex: Int?
            var reverse = false
            var bestDistance = Double.infinity

            for index in edges.indices where !used[index] && !edges[index].isEmpty {
                let edge = edges[index]
                let startDistance = distSq(tail, edge[0])
                if startDistance < bestDistance {
                    bestDistance = startDistance
                    bestIndex = index
                    reverse = false
                }
                if let end = edge.last {
                    let endDistance = distSq(tail, end)
                    if endDistance < bestDistance {
                        bestDistance = endDistance
                        bestIndex = index
                        reverse = true
                    }
                }
            }

            guard let index = bestIndex, bestDistance <= toleranceSquared else { break }
            used[index] = true
            usedCount += 1
            if reverse {
                appendEdge(Array(edges[index].reversed()))
            } else {
                appendEdge(edges[index])
            }
        }

        return out
    }

    private static func hatchStitchToleranceSquared(for edges: [[Vector3]]) -> Double {
        let points = edges.flatMap { $0 }
        guard let first = points.first else { return 1e-4 }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let diagonal = sqrt(dx * dx + dy * dy)
        let tolerance = min(max(diagonal * 1e-3, 1e-2), 10.0)
        return tolerance * tolerance
    }

    private static func cleanAdjacentPoints(_ points: [Vector3], toleranceSquared: Double = 1e-10) -> [Vector3] {
        var out: [Vector3] = []
        out.reserveCapacity(points.count)
        for point in points {
            if let last = out.last, nearlySamePoint(last, point, toleranceSquared: toleranceSquared) {
                continue
            }
            out.append(point)
        }
        if out.count > 1,
           let first = out.first,
           let last = out.last,
           nearlySamePoint(first, last, toleranceSquared: toleranceSquared) {
            out.removeLast()
        }
        return out
    }

    // MARK: - Boundary entity → polyline converters

    /// Convert a HATCH circular edge to a polyline approximation.
    private static func arcToPolyline(_ arc: DXFArcEntity, segments: Int = 64) -> [Vector3] {
        guard arc.radius > 1e-12 else { return [] }
        let center = yflip(arc.basePoint)
        let parameters = hatchCircularArcParameters(arc)
        let startAngle = parameters.startAngle
        let sweep = parameters.sweep
        guard abs(sweep) > 1e-12 else { return [] }

        let n = max(segments, 3)
        var pts: [Vector3] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let t = Double(i) / Double(n)
            let angle = startAngle + sweep * t
            pts.append(Vector3(x: center.x + arc.radius * cos(angle),
                               y: center.y + arc.radius * sin(angle), z: 0))
        }
        return pts
    }

    /// Convert an ellipse to a polyline approximation
    private static func ellipseToPolyline(_ ellipse: DXFEllipseEntity, segments: Int = 64) -> [Vector3] {
        ellipsePoints(ellipse, segments: segments, honorIsCCW: true)
    }

    private static func normalizedEllipse(_ ellipse: DXFEllipseEntity) -> (major: Vector3, ratio: Double, start: Double, end: Double, isFull: Bool) {
        let twoPi = Double.pi * 2.0
        var major = Vector3(x: ellipse.secPoint.x, y: ellipse.secPoint.y, z: ellipse.secPoint.z)
        var ratio = ellipse.ratio
        var start = ellipse.startParam
        var end = ellipse.endParam
        var isFull = abs(abs(end - start) - twoPi) < 1e-5 || abs(end - start) < 1e-5

        if abs(end - start) < 1e-10 {
            start = 0.0
            end = twoPi
            isFull = true
        }

        if ratio > 1.0 {
            let oldX = major.x
            major.x = -(major.y * ratio)
            major.y = oldX * ratio
            ratio = 1.0 / ratio
            if !isFull {
                let halfPi = Double.pi / 2.0
                if start < halfPi { start += twoPi }
                if end < halfPi { end += twoPi }
                end -= halfPi
                start -= halfPi
            }
        }

        if ellipse.haveExtrusion && ellipse.extrusion.z < 0.0 {
            let oldStart = start
            start = twoPi - end
            end = twoPi - oldStart
        }

        return (major, ratio, start, end, isFull)
    }

    private static func ellipsePoints(_ ellipse: DXFEllipseEntity, segments: Int, honorIsCCW: Bool) -> [Vector3] {
        let normalized = normalizedEllipse(ellipse)
        let center = yflip(ellipse.basePoint)
        let major = normalized.major
        let majorLen = major.magnitude
        let minorLen = majorLen * normalized.ratio
        guard majorLen > 1e-12, minorLen > 1e-12 else { return [] }

        let sweep: Double
        if honorIsCCW {
            sweep = normalizedHatchArcSweep(
                start: normalized.start,
                end: normalized.end,
                isCCW: ellipse.isCCW == 0)
        } else {
            sweep = normalizedHatchArcSweep(
                start: normalized.start,
                end: normalized.end,
                isCCW: true)
        }

        let angle = atan2(major.y, major.x)
        let cosR = cos(angle)
        let sinR = sin(angle)
        let n = max(segments, 3)
        var pts: [Vector3] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let t = Double(i) / Double(n)
            let param = normalized.start + sweep * t
            let px = majorLen * cos(param)
            let py = minorLen * sin(param)
            let rx = px * cosR - py * sinR
            let ry = px * sinR + py * cosR
            pts.append(Vector3(x: center.x + rx, y: center.y - ry, z: center.z))
        }
        return pts
    }

    /// Convert a spline to a polyline approximation using control points
    private static func splineToPolyline(_ spline: DXFSplineEntity, segments: Int = 64) -> [Vector3] {
        let degree = spline.degree > 0 ? spline.degree : 3
        let knots = spline.knots
        var cps: [Vector3]

        if spline.nControl > 0, !spline.controlPoints.isEmpty {
            cps = spline.controlPoints.map { yflip($0) }
        } else if spline.nFit > 0, !spline.fitPoints.isEmpty {
            return spline.fitPoints.map { yflip($0) }
        } else {
            return []
        }

        var weights = normalizedSplineWeights(spline.weights, controlCount: cps.count)
        let expectedControlCount = knots.count - degree - 1
        if expectedControlCount > cps.count, !cps.isEmpty {
            let baseCPs = cps
            let baseWeights = weights
            for i in 0..<(expectedControlCount - cps.count) {
                cps.append(baseCPs[i % baseCPs.count])
                weights.append(baseWeights[i % baseWeights.count])
            }
        }

        guard degree >= 1, cps.count > degree, knots.count == cps.count + degree + 1 else {
            return cps.count > 1 ? cps : []
        }

        var pts = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
            degree: degree,
            knots: knots,
            controlPoints: cps,
            weights: weights,
            chordTolerance: 0.01,
            maxDepth: 10,
            maxSegments: max(512, segments * 16)
        )

        if pts.count < 2 {
            pts = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: cps,
                weights: weights,
                segmentsPerSpan: 12
            )
        }

        if ((spline.flags & 1) != 0 || (spline.flags & 2) != 0),
           let first = pts.first, let last = pts.last,
           !nearlySamePoint(first, last) {
            pts.append(first)
        }

        return pts
    }

    private static func normalizedSplineWeights(_ raw: [Double], controlCount: Int) -> [Double] {
        guard controlCount > 0 else { return [] }
        if raw.count == controlCount {
            return raw.map { $0.isFinite && $0 > 0 ? $0 : 1.0 }
        }
        if raw.isEmpty {
            return Array(repeating: 1.0, count: controlCount)
        }
        var out = raw.prefix(controlCount).map { $0.isFinite && $0 > 0 ? $0 : 1.0 }
        while out.count < controlCount { out.append(1.0) }
        return out
    }

    private static func nearlySamePoint(_ a: Vector3, _ b: Vector3, toleranceSquared: Double = 1e-12) -> Bool {
        (a - b).magnitudeSquared <= toleranceSquared
    }

    // MARK: - Leader

    private static func convertLeader(_ e: DXFEntity, arrowSize: Double, color: ColorRGBA?) -> [CADPrimitive] {
        guard let ld = e as? DXFLeaderEntity, ld.vertices.count >= 2 else { return [] }
        let pts = ld.vertices.map { yflip($0) }
        var prims: [CADPrimitive] = []
        if ld.arrow != 0 {
            let v0 = pts[0]; let v1 = pts[1]
            let dir = (v1 - v0).normalized; let len = min(arrowSize, v0.distance(to: v1) * 0.5)
            let perp = Vector3(x: -dir.y, y: dir.x, z: 0); let wing = len * 0.25
            let tip = v0 + dir * len
            prims.append(.fillPolygon(points: [v0, tip + perp * wing, tip - perp * wing], color: color))
            prims.append(.line(start: tip, end: v1, color: color))
        }
        for i in (ld.arrow != 0 ? 1 : 0)..<(pts.count - 1) {
            prims.append(.line(start: pts[i], end: pts[i + 1], color: color))
        }
        return prims
    }

    // MARK: - Image

    private static func convertImage(_ e: DXFEntity, color: ColorRGBA?) -> [CADPrimitive] {
        guard let img = e as? DXFImageEntity else { return [] }
        let ins = yflip(img.basePoint)
        let u = yflip(img.secPoint) * (img.sizeU > 0 ? img.sizeU : 1.0)
        let v = yflip(img.vVector) * (img.sizeV > 0 ? img.sizeV : 1.0)
        let imageName = !img.imageFilePath.isEmpty ? img.imageFilePath : String(format: "%X", img.ref)
        return [.image(insertion: ins, uAxis: u, vAxis: v,
                      imageName: imageName, clipBoundary: nil, tint: nil)]
    }

    // MARK: - Helpers

    private static func resolveEntityColor(_ e: DXFEntity) -> ColorRGBA? {
        if e.color24 >= 0 || (e.color > 0 && e.color < 256) {
            return DXFColorTable.aciToRGBA(e.color, color24: e.color24)
        }
        return nil
    }

    public static func cleanMTextFormatting(_ text: String) -> String {
        var clean = ""; var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]; let nextI = text.index(after: i)
            guard nextI < text.endIndex else { clean.append(c); break }
            let next = text[nextI]
            if c == "\\" || c == "¥" {
                switch next {
                case "P": clean.append("\n"); i = text.index(after: nextI)
                case "L", "l": clean.append("%%u"); i = text.index(after: nextI)
                case "O", "o": i = text.index(after: nextI)
                case "\\", "¥", "{", "}": clean.append(String(next)); i = text.index(after: nextI)
                default:
                    if Set("fFcChHsStTwWaAqQp").contains(next) {
                        var j = text.index(after: nextI)
                        while j < text.endIndex, text[j] != ";" { j = text.index(after: j) }
                        i = j < text.endIndex ? text.index(after: j) : text.endIndex
                    } else { i = nextI }
                }
            } else if c == "{" || c == "}" { i = nextI }
            else { clean.append(c); i = nextI }
        }
        return clean
    }

    private static func simplifyIfNeeded(_ path: CADPolyline) -> CADPolyline {
        guard simplifyPolylines, !path.hasBulges, path.vertices.count > 200 else { return path }
        let bb = BoundingBox3D(from: path.points)
        let diag = max(bb.size.x, bb.size.y); let tol = max(diag * 0.002, 0.01)
        var simplified = rdp(path.points, tolerance: tol)
        let minPts = path.isClosed ? 3 : 2
        if simplified.count < minPts {
            simplified = path.isClosed ? [bb.min, Vector3(x: bb.max.x, y: bb.min.y), bb.max, Vector3(x: bb.min.x, y: bb.max.y)]
                                       : [path.points.first!, path.points.last!]
        }
        return CADPolyline(points: simplified, isClosed: path.isClosed, lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
    }

    internal static func rdp(_ pts: [Vector3], tolerance: Double) -> [Vector3] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        func perpDist(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
            let ab = b - a; let ap = p - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            guard len2 > 1e-12 else { return p.distance(to: a) }
            let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
            return p.distance(to: a + ab * t)
        }
        func simplify(_ start: Int, _ end: Int) {
            guard end > start + 1 else { return }
            var maxDist = 0.0; var maxIdx = start
            for i in (start + 1)..<end {
                let d = perpDist(pts[i], pts[start], pts[end])
                if d > maxDist { maxDist = d; maxIdx = i }
            }
            if maxDist > tolerance { keep[maxIdx] = true; simplify(start, maxIdx); simplify(maxIdx, end) }
        }
        simplify(0, pts.count - 1)
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func hatchBoundaryTransform(for hatch: DXFHatchEntity) -> Transform3D {
        let hasElevation = hatch.basePoint.magnitudeSquared > 1e-24
        let hasExtrusion = hatch.haveExtrusion && !isDefaultExtrusion(hatch.extrusion)
        guard hasElevation || hasExtrusion else { return .identity }

        var az = hasExtrusion ? hatch.extrusion : Vector3(x: 0, y: 0, z: 1)
        var magnitude = az.magnitude
        if magnitude < 1e-12 {
            az = Vector3(x: 0, y: 0, z: 1)
            magnitude = 1.0
        }
        az = az / magnitude

        var ax: Vector3
        if abs(az.x) < 0.015625 && abs(az.y) < 0.015625 {
            ax = Vector3(x: az.z, y: 0, z: -az.x)
        } else {
            ax = Vector3(x: -az.y, y: az.x, z: 0)
        }
        ax = ax.normalized
        let ay = az.cross(ax).normalized

        let elevation = yflip(ocsToWcs(hatch.basePoint, extrusion: az))
        return Transform3D(raw: [
             ax.x, -ay.x,  az.x, elevation.x,
            -ax.y,  ay.y, -az.y, elevation.y,
             ax.z, -ay.z,  az.z, elevation.z,
             0,     0,      0,    1
        ])
    }

    private static func transformedPlanarAngle(
        _ angle: Double,
        by transform: Transform3D
    ) -> Double {
        let origin = transform.transformPoint(.zero)
        let direction = transform.transformPoint(Vector3(
            x: cos(angle),
            y: sin(angle),
            z: 0)) - origin
        guard direction.magnitude > 1e-12 else { return angle }
        return atan2(direction.y, direction.x)
    }

    private static func cadLWPoint(_ vertex: DXFVertex2D, in polyline: DXFLWPolylineEntity) -> Vector3 {
        let raw = Vector3(x: vertex.x, y: vertex.y, z: polyline.elevation)
        let extrusion = isDefaultExtrusion(polyline.extPoint) ? nil : polyline.extPoint
        return cadPoint(raw, extrusion: extrusion)
    }

    private static func cadPolylinePoint(_ vertex: DXFVertexEntity, in polyline: DXFPolylineEntity) -> Vector3 {
        cadPoint(vertex.basePoint, extrusion: polyline.haveExtrusion ? polyline.extrusion : nil)
    }

    private static func cadPoint(_ point: Vector3, extrusion: Vector3?) -> Vector3 {
        guard let extrusion, !isDefaultExtrusion(extrusion) else { return yflip(point) }
        return yflip(ocsToWcs(point, extrusion: extrusion))
    }

    private static func isDefaultExtrusion(_ n: Vector3) -> Bool {
        abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && abs(n.z - 1.0) < 1e-12
    }

    private static func ocsToWcs(_ point: Vector3, extrusion n: Vector3) -> Vector3 {
        var az = n
        var mag = sqrt(az.x * az.x + az.y * az.y + az.z * az.z)
        if mag < 1e-12 {
            az = Vector3(x: 0, y: 0, z: 1)
            mag = 1.0
        }
        az.x /= mag; az.y /= mag; az.z /= mag

        var ax: Vector3
        if abs(az.x) < 0.015625 && abs(az.y) < 0.015625 {
            ax = Vector3(x: az.z, y: 0, z: -az.x)
        } else {
            ax = Vector3(x: -az.y, y: az.x, z: 0)
        }
        mag = sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z)
        if mag > 1e-12 { ax.x /= mag; ax.y /= mag; ax.z /= mag }

        var ay = Vector3(
            x: az.y * ax.z - az.z * ax.y,
            y: az.z * ax.x - az.x * ax.z,
            z: az.x * ax.y - az.y * ax.x)
        mag = sqrt(ay.x * ay.x + ay.y * ay.y + ay.z * ay.z)
        if mag > 1e-12 { ay.x /= mag; ay.y /= mag; ay.z /= mag }

        return Vector3(
            x: ax.x * point.x + ay.x * point.y + az.x * point.z,
            y: ax.y * point.x + ay.y * point.y + az.y * point.z,
            z: ax.z * point.x + ay.z * point.y + az.z * point.z)
    }

    /// Convert Vector3 → ZephyrCore.Vector3 with Y-flip
    private static func yflip(_ v: Vector3) -> Vector3 {
        Vector3(x: v.x, y: -v.y, z: v.z)
    }

    private static func rgbToRGBA(_ rgb: Int32) -> ColorRGBA {
        ColorRGBA(r: UInt8((rgb >> 16) & 0xFF), g: UInt8((rgb >> 8) & 0xFF), b: UInt8(rgb & 0xFF))
    }
}