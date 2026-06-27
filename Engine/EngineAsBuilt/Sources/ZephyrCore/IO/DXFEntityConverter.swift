import Foundation

// =========================================================================
// MARK: - DXFEntityConverter
//
// Converts parsed DXF entity data (from DXFImporter) into CADPrimitive arrays.
// Maps DXF-specific structures (bulge arcs, polyline vertex sequences,
// hatch boundary loops) into the engine's unified CADPrimitive enum.
//
// This is the bridge between raw DXF parsing and the rendering pipeline.
import CDXFRW

@MainActor
public enum DXFEntityConverter {

    public static var simplifyPolylines: Bool = false

    /// Converts a raw libdxfrw entity into engine primitives.
    ///
    /// - Parameter bylayerColor: Resolved color to bake into the primitives when
    ///   the entity's own color is BYLAYER (256). Used for entities inside block
    ///   definitions, where the render path can't resolve BYLAYER against the
    ///   sub-entity's layer anymore (block geometry is flattened and only the
    ///   INSERT's layer survives). Top-level entities pass nil — their BYLAYER
    ///   colors resolve correctly at render time via the entity's own layer.
    ///   Explicit entity colors always win over this fallback.
    internal static func convertEntityToPrimitives(_ e: DXFRW_EntityData, arrowSize: Double, bylayerColor: ColorRGBA? = nil) -> [CADPrimitive] {
        let explicitColor: ColorRGBA? = (e.color24 >= 0 || (e.color > 0 && e.color < 256)) ? DXFColorTable.aciToRGBA(e.color, color24: e.color24) : nil
        // BYBLOCK (color == 0) must stay nil so it inherits the INSERT's
        // resolved color at render time; only BYLAYER (256) takes the fallback.
        let primColor: ColorRGBA? = explicitColor ?? (e.color == 256 ? bylayerColor : nil)

        switch e.type {
        case DXFRW_ET_POINT:
            return [.point(position: DXFImporter.toVector(e.basePoint), color: primColor)]

        case DXFRW_ET_LINE:
            return [.line(start: DXFImporter.toVector(e.basePoint), end: DXFImporter.toVector(e.secPoint), color: primColor)]

        case DXFRW_ET_CIRCLE:
            return [.circle(center: DXFImporter.toVector(e.basePoint), radius: e.radius, color: primColor)]

        case DXFRW_ET_ARC:
            // libdxfrw already converts these to radians in C++.
            // We only negate and swap them to map the CCW sweep to a Y-down space.
            return [.arc(
                center: DXFImporter.toVector(e.basePoint),
                radius: e.radius,
                startAngle: -e.endAngle,
                endAngle: -e.startAngle,
                color: primColor
            )]

        case DXFRW_ET_LWPOLYLINE, DXFRW_ET_POLYLINE:
            return convertPolyline(e, color: primColor)

        case DXFRW_ET_ELLIPSE:
            // Approximate ellipse as a polyline for now
            return convertEllipse(e, color: primColor)

        case DXFRW_ET_SPLINE:
            // Convert fit points or control points to line segments
            return convertSpline(e, color: primColor)

        case DXFRW_ET_TEXT, DXFRW_ET_MTEXT:
            let textVal = e.textValue.map { String(cString: $0) } ?? ""
            let cleaned = cleanMTextFormatting(textVal)
            let height = e.textHeight > 0 ? e.textHeight : 2.5
            let style = e.textStyle.map { String(cString: $0) }
            let isText = e.type == DXFRW_ET_TEXT
            // In DXF, if alignH is 1(Center), 2(Right), 4(Middle), or if alignV is non-zero,
            // the second alignment point (secPoint) specifies the actual alignment location.
            // (For alignH 3 and 5, secPoint is the endpoint, but basePoint is the start.)
            let useSecPoint = isText && (e.alignH == 1 || e.alignH == 2 || e.alignH == 4 || e.alignV != 0)
            
            let posX = DXFImporter.toVector(useSecPoint ? e.secPoint : e.basePoint).x
            let posY = DXFImporter.toVector(useSecPoint ? e.secPoint : e.basePoint).y
            var pos = Vector3(x: posX, y: posY, z: 0)

            let passAlignH = Int(e.alignH)
            let passAlignV = Int(e.alignV)

            var angle = -e.textAngle * .pi / 180.0
            // TEXT coordinates are in OCS, but libdxfrw's
            // DRW_Text::applyExtrusion() is an unimplemented TODO ("RLZ TODO"),
            // so TEXT is the one OCS entity type the C++ side does not convert
            // when reading with applyExt=true. Handle the planar mirrored case
            // here, using the same guard libdxfrw applies for arcs. MTEXT is
            // excluded: its insertion point is WCS per the DXF spec.
            // (Limitation: AutoCAD draws such text mirror-imaged; we render it
            // readable at the correct position and angle.)
            if isText,
               abs(e.extrusion.x) < 0.015625, abs(e.extrusion.y) < 0.015625,
               e.extrusion.z < 0 {
                // OCS (x, y) -> WCS (-x, y) -> engine (-x, -y).
                // toVector already produced (x, -y), so only x is negated here.
                pos = Vector3(x: -pos.x, y: pos.y, z: pos.z)
                // WCS angle mirrors to (180° - θ); the engine's Y-flip negates
                // angles, giving θ·π/180 - π.
                angle = e.textAngle * .pi / 180.0 - .pi
            }
            return [
                .text(
                    position: pos,
                    text: cleaned,
                    height: height,
                    rotation: angle,
                    style: style,
                    alignH: passAlignH,
                    alignV: passAlignV,
                    mtextWidth: e.type == DXFRW_ET_MTEXT && e.textWidthScale > 0 ? e.textWidthScale : nil,
                    color: primColor
                )
            ]

        case DXFRW_ET_INSERT:
            // INSERTS are handled at the entity level (block references),
            // not as primitives. Return empty.
            return []

        case DXFRW_ET_SOLID:
            return [
                .fillPolygon(points: [
                    DXFImporter.toVector(e.basePoint),
                    DXFImporter.toVector(e.secPoint),
                    DXFImporter.toVector(e.thirdPoint),
                    DXFImporter.toVector(e.fourPoint),
                ], color: primColor)
            ]

        case DXFRW_ET_3DFACE:
            return [
                .polygon(points: [
                    DXFImporter.toVector(e.basePoint),
                    DXFImporter.toVector(e.secPoint),
                    DXFImporter.toVector(e.thirdPoint),
                    DXFImporter.toVector(e.fourPoint),
                ], color: primColor)
            ]

        case DXFRW_ET_HATCH:
            var outerLoop: [Vector3] = []
            var holeLoops: [[Vector3]] = []
            var loopPolygons: [[Vector3]] = []

            var editLoopPolygons: [[Vector3]] = []

            if e.hatchLoopCount > 0, let loops = e.hatchLoops {
                var outerIndex = 0
                for i in 0..<Int(e.hatchLoopCount) {
                    if (loops[i].loopFlags & 0x01) != 0 {
                        outerIndex = i
                        break
                    }
                }

                for i in 0..<Int(e.hatchLoopCount) {
                    let loop = loops[i]
                    var pts: [Vector3] = []
                    if loop.vertexCount > 0, let vertices = loop.vertices {
                        for vIdx in 0..<Int(loop.vertexCount) {
                            pts.append(Vector3(x: vertices[vIdx].x, y: -vertices[vIdx].y, z: vertices[vIdx].z))
                        }
                    }

                    var editPts: [Vector3] = []
                    if loop.editVertexCount > 0, let editVertices = loop.editVertices {
                        for vIdx in 0..<Int(loop.editVertexCount) {
                            editPts.append(Vector3(x: editVertices[vIdx].x, y: -editVertices[vIdx].y, z: editVertices[vIdx].z))
                        }
                    }
                    if editPts.count < 2 { editPts = simplifiedGripLoop(from: pts) }

                    guard pts.count >= 3 else { continue }
                    loopPolygons.append(pts)
                    if editPts.count >= 2 { editLoopPolygons.append(editPts) }

                    if i == outerIndex {
                        outerLoop = pts
                    } else {
                        holeLoops.append(pts)
                    }
                }
            }

            let invisibleBoundaryColor = ColorRGBA(r: 0, g: 0, b: 0, a: 0)
            let editableBoundaryPrims = editLoopPolygons.map { CADPrimitive.polygon(points: $0, color: invisibleBoundaryColor) }
            
            if e.isGradient == 1 && !outerLoop.isEmpty {
                // Gradient hatch: build gradient primitive
                let gradName = e.gradientName.map { String(cString: $0) } ?? "LINEAR"
                let gradAngle = e.gradientAngle * .pi / 180.0  // DXF degrees → radians

                // color1 from entity color (or explicit)
                let c1: ColorRGBA
                if e.color1 >= 0 {
                    let r = UInt8((e.color1 >> 16) & 0xFF)
                    let g = UInt8((e.color1 >> 8) & 0xFF)
                    let b = UInt8(e.color1 & 0xFF)
                    c1 = ColorRGBA(r: r, g: g, b: b)
                } else {
                    c1 = primColor ?? .white
                }

                // color2 from gradient color stops
                let c2: ColorRGBA
                if e.color2 >= 0 {
                    let r = UInt8((e.color2 >> 16) & 0xFF)
                    let g = UInt8((e.color2 >> 8) & 0xFF)
                    let b = UInt8(e.color2 & 0xFF)
                    c2 = ColorRGBA(r: r, g: g, b: b)
                } else {
                    // fallback: lighter version of c1
                    c2 = ColorRGBA(r: min(255, c1.r + 60), g: min(255, c1.g + 60), b: min(255, c1.b + 60))
                }

                if c1 == c2 {
                    var prims: [CADPrimitive] = [.fillComplexPolygon(outer: outerLoop, holes: holeLoops, color: c1)]
                    prims.append(contentsOf: editableBoundaryPrims)
                    return prims
                }

                var prims: [CADPrimitive] = [.gradient(outer: outerLoop, holes: holeLoops,
                                  gradientName: gradName, angle: gradAngle,
                                  color1: c1, color2: c2)]
                prims.append(contentsOf: editableBoundaryPrims)
                return prims
            }

            if e.hatchSolid == 1 {
                if !outerLoop.isEmpty {
                    var prims: [CADPrimitive] = [.fillComplexPolygon(outer: outerLoop, holes: holeLoops, color: primColor)]
                    prims.append(contentsOf: editableBoundaryPrims)
                    return prims
                }
                return []
            } else {
                let patternName = e.hatchPatternName.map { String(cString: $0).uppercased() } ?? ""
                let scale = e.hatchScale > 0 ? e.hatchScale : 1.0
                let angle = e.hatchAngle
                var prims: [CADPrimitive] = []
                // Background fill color (DXF group 63)
                let bgColor: ColorRGBA? = {
                    if e.hatchBackgroundColor >= 0 {
                        let r = UInt8((e.hatchBackgroundColor >> 16) & 0xFF)
                        let g = UInt8((e.hatchBackgroundColor >> 8) & 0xFF)
                        let b = UInt8(e.hatchBackgroundColor & 0xFF)
                        return ColorRGBA(r: r, g: g, b: b)
                    }
                    return nil
                }()
                for poly in loopPolygons {
                    prims.append(.hatch(
                        boundary: poly,
                        pattern: patternName.isEmpty ? "SOLID" : patternName,
                        scale: scale,
                        angle: angle,
                        color: primColor,
                        backgroundColor: bgColor))
                }
                return editableBoundaryPrims + prims
            }

        case DXFRW_ET_DIMENSION:
            // Store dimension definition points as lines
            let def = DXFImporter.toVector(e.dimDefPoint)
            let txt = DXFImporter.toVector(e.dimTextPoint)
            if def != txt {
                return [.line(start: def, end: txt, color: primColor)]
            }
            return [.point(position: def, color: primColor)]

        case DXFRW_ET_LEADER:
            return convertLeader(e, arrowSize: arrowSize, color: primColor)

        case DXFRW_ET_IMAGE:
            return convertImage(e, color: primColor)

        default:
            return []
        }
    }

    /// Convert a DXF IMAGE entity to a CADPrimitive array.
    private static func convertImage(_ e: DXFRW_EntityData, color: ColorRGBA?) -> [CADPrimitive] {
        let insertion = DXFImporter.toVector(e.basePoint)
        // imageU/imageV are single-pixel vectors; scale by sizeU/sizeV for full extent
        let uSingle = DXFImporter.toVector(e.imageU)
        let vSingle = DXFImporter.toVector(e.imageV)
        let sizeU = e.imageSizeU > 0 ? e.imageSizeU : 1.0
        let sizeV = e.imageSizeV > 0 ? e.imageSizeV : 1.0
        let uAxis = Vector3(x: uSingle.x * sizeU, y: uSingle.y * sizeU, z: uSingle.z * sizeU)
        let vAxis = Vector3(x: vSingle.x * sizeV, y: vSingle.y * sizeV, z: vSingle.z * sizeV)

        // Get file path (might be nil if IMAGEDEF wasn't found)
        guard let filePathC = e.imageFilePath,
              let filePath = String(cString: filePathC, encoding: .utf8),
              !filePath.isEmpty else {
            // Missing external image — return a placeholder rectangle
            // Using a 100×100 unit rectangle with diagonal cross
            let size = 100.0
            let origin = Vector3(x: insertion.x, y: insertion.y - size, z: insertion.z)
            return [
                .rect(origin: origin, size: Vector3(x: size, y: size, z: 0), color: color),
                .line(start: origin, end: Vector3(x: origin.x + size, y: origin.y + size, z: origin.z), color: color),
                .line(start: Vector3(x: origin.x + size, y: origin.y, z: origin.z),
                      end: Vector3(x: origin.x, y: origin.y + size, z: origin.z), color: color),
            ]
        }

        // File path exists — but image data loading is deferred to ImageImporter
        // For now, store the file path in a temporary imageName (will be replaced
        // with sha256-based name when the file is actually loaded).
        let imageName = filePath

        let clipBoundary: [Vector3]?
        if e.imageClippingEnabled != 0 && e.imageClipVertexCount > 0,
           let clipVerts = e.imageClipVertices {
            var pts: [Vector3] = []
            for i in 0..<Int(e.imageClipVertexCount) {
                pts.append(Vector3(x: clipVerts[i].x, y: -clipVerts[i].y, z: 0))
            }
            clipBoundary = pts.isEmpty ? nil : pts
        } else {
            clipBoundary = nil
        }

        return [.image(
            insertion: insertion,
            uAxis: uAxis,
            vAxis: vAxis,
            imageName: imageName,
            clipBoundary: clipBoundary,
            tint: nil
        )]
    }



    internal static func simplifiedGripLoop(from pts: [Vector3]) -> [Vector3] {
        guard pts.count > 12 else { return pts }

        let closed = pts.first.map { first in pts.last.map { first.distance(to: $0) < 1e-6 } ?? false } ?? false
        let source = closed ? Array(pts.dropLast()) : pts
        guard source.count > 12 else { return source }

        let bb = BoundingBox3D(from: source)
        let diag = max(bb.size.x, bb.size.y)
        guard diag > 1e-9 else { return source }

        let c = bb.center
        let rx = max(abs(bb.max.x - c.x), abs(c.x - bb.min.x))
        let ry = max(abs(bb.max.y - c.y), abs(c.y - bb.min.y))
        if rx > 1e-9 && ry > 1e-9 {
            var maxErr = 0.0
            for p in source {
                let nx = (p.x - c.x) / rx
                let ny = (p.y - c.y) / ry
                maxErr = max(maxErr, abs(sqrt(nx * nx + ny * ny) - 1.0))
            }
            if maxErr < 0.08 {
                return [
                    Vector3(x: c.x + rx, y: c.y, z: c.z),
                    Vector3(x: c.x, y: c.y + ry, z: c.z),
                    Vector3(x: c.x - rx, y: c.y, z: c.z),
                    Vector3(x: c.x, y: c.y - ry, z: c.z)
                ]
            }
        }

        let tolerance = max(diag * 0.015, 0.01)
        let simplified = rdp(source, tolerance: tolerance)
        if simplified.count >= 2 { return simplified }
        return source
    }


    internal static func rdp(_ pts: [Vector3], tolerance: Double) -> [Vector3] {
        guard pts.count > 2 else { return pts }
        var keep = Array(repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true

        func perpendicularDistance(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
            let ab = b - a
            let ap = p - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            if len2 < 1e-12 { return p.distance(to: a) }
            let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
            let proj = Vector3(x: a.x + ab.x * t, y: a.y + ab.y * t, z: a.z + ab.z * t)
            return p.distance(to: proj)
        }

        func simplify(_ start: Int, _ end: Int) {
            guard end > start + 1 else { return }
            var maxDist = 0.0
            var maxIdx = start
            for i in (start + 1)..<end {
                let d = perpendicularDistance(pts[i], pts[start], pts[end])
                if d > maxDist {
                    maxDist = d
                    maxIdx = i
                }
            }
            if maxDist > tolerance {
                keep[maxIdx] = true
                simplify(start, maxIdx)
                simplify(maxIdx, end)
            }
        }

        simplify(0, pts.count - 1)
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }


    internal static func convertLeader(_ e: DXFRW_EntityData, arrowSize: Double, color: ColorRGBA?) -> [CADPrimitive] {
        let count = Int(e.vertexCount)
        guard count > 0, let vertices = e.vertices else { return [] }

        var points: [Vector3] = []
        for i in 0..<count {
            // Note: startWidth stores the Z coordinate
            points.append(Vector3(x: vertices[i].x, y: -vertices[i].y, z: vertices[i].startWidth))
        }

        if points.count < 2 {
            return []
        }

        var prims: [CADPrimitive] = []

        // Determine arrow size and arrowhead if enabled
        // flags stores data->arrow (0=disabled, 1=enabled)
        let hasArrow = e.flags != 0
        var startIdx = 0

        if hasArrow, points.count >= 2 {
            let v0 = points[0]
            let v1 = points[1]
            let dir = v1 - v0
            let len = dir.magnitude
            if len > 1e-6 {
                let d = dir.normalized
                // Use uniform drawingArrowSize, clamped to at most 50% of the first segment length
                let arrowLen = min(arrowSize, len * 0.5)
                let arrowHalfWidth = arrowLen * 0.25 // ~30 degree total angle

                // Arrow pointing towards v0 (the tip is at v0)
                // The perpendicular vector in XY plane (2D)
                let p = Vector3(x: -d.y, y: d.x, z: 0)

                let pRight = v0 + d * arrowLen + p * arrowHalfWidth
                let pLeft = v0 + d * arrowLen - p * arrowHalfWidth

                // Add the filled arrowhead triangle
                prims.append(.fillPolygon(points: [v0, pRight, pLeft], color: color))

                // The line segment starts at the back center of the arrowhead to look clean
                let arrowBackCenter = v0 + d * arrowLen
                prims.append(.line(start: arrowBackCenter, end: v1, color: color))
                startIdx = 1
            }
        }

        // Draw the remaining segments
        for i in startIdx..<(points.count - 1) {
            prims.append(.line(start: points[i], end: points[i + 1], color: color))
        }

        // Draw horizontal underline (landing extension) under the text if textWidthScale (textwidth) > 0
        if e.textWidthScale > 0 {
            let last = points[points.count - 1]
            let prev = points[points.count - 2]
            let dx = last.x - prev.x
            
            // Determine direction: if offset is non-zero, use it. Otherwise, use dx.
            let dirSign: Double
            if abs(e.leaderOffsettext.x) > 1e-5 {
                dirSign = e.leaderOffsettext.x >= 0 ? 1.0 : -1.0
            } else {
                dirSign = dx >= 0 ? 1.0 : -1.0
            }
            
            let underlineStart = last + Vector3(x: e.leaderOffsettext.x, y: 0, z: 0)
            let underlineEnd = underlineStart + Vector3(x: e.textWidthScale * dirSign, y: 0, z: 0)
            prims.append(.line(start: underlineStart, end: underlineEnd, color: color))
        }

        return prims
    }


    internal static func convertPolyline(_ e: DXFRW_EntityData, color: ColorRGBA?) -> [CADPrimitive] {
        let count = Int(e.vertexCount)
        guard count > 0, let vertices = e.vertices else { return [] }

        if count == 1 {
            return [.point(position: Vector3(x: vertices[0].x, y: -vertices[0].y, z: 0), color: color)]
        }

        let isClosed = (e.flags & 0x01) != 0
        var path = CADPolyline(
            vertices: (0..<count).map { index in
                let vertex = vertices[index]
                return CADPolylineVertex(
                    position: Vector3(x: vertex.x, y: -vertex.y, z: 0),
                    bulge: -vertex.bulge,
                    startWidth: vertex.startWidth,
                    endWidth: vertex.endWidth)
            },
            isClosed: isClosed,
            lineTypeGenerationEnabled: (e.flags & 0x80) != 0)

        if DXFEntityConverter.simplifyPolylines,
           !path.hasBulges,
           path.vertices.count > 200 {
            let originalPoints = path.points
            let bb = BoundingBox3D(from: originalPoints)
            let diag = max(bb.size.x, bb.size.y)
            let tolerance = max(diag * 0.002, 0.01)
            var simplified = rdp(originalPoints, tolerance: tolerance)
            let minimum = isClosed ? 3 : 2
            if simplified.count < minimum {
                simplified = isClosed
                    ? [bb.min,
                       Vector3(x: bb.max.x, y: bb.min.y, z: bb.min.z),
                       bb.max,
                       Vector3(x: bb.min.x, y: bb.max.y, z: bb.min.z)]
                    : [originalPoints.first!, originalPoints.last!]
            }
            path = CADPolyline(
                points: simplified,
                isClosed: isClosed,
                lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
        }

        return [.polyline(path: path, color: color)]
    }


    internal static func convertEllipse(_ e: DXFRW_EntityData, color: ColorRGBA?) -> [CADPrimitive] {
        let center = DXFImporter.toVector(e.basePoint)
        
        // The major axis vector is stored relative to the center
        // We do NOT use DXFImporter.toVector() here because it flips Y. We want the raw DXF vector first 
        // so we can calculate the true geometric angle, then we will transform it at the end.
        let rawMajorVec = Vector3(x: e.secPoint.x, y: e.secPoint.y, z: e.secPoint.z)
        let majorLen = rawMajorVec.magnitude
        let minorLen = majorLen * e.axisRatio

        guard majorLen > 1e-12, minorLen > 1e-12 else {
            return [.point(position: center, color: color)]
        }

        // DXF angles are in radians.
        //
        // NOTE: extrusion handling for ellipses now lives in libdxfrw
        // (dxfrw_bridge.cpp reads with applyExt=true). For (0,0,-1) extrusion,
        // DRW_Ellipse::applyExtrusion() already mirrors the major axis vector
        // and swaps/reverses the start/end parameters before this data
        // reaches Swift. Re-applying the swap here would cancel libdxfrw's
        // correction (the swap is an involution), so the values are used
        // exactly as delivered.
        let startParam = e.startAngle
        let endParam = e.endAngle

        let segments = 64
        let isFull = abs(abs(endParam - startParam) - .pi * 2) < 1e-5 || abs(endParam - startParam) < 1e-5
        
        var sweep = endParam - startParam
        if sweep < 0 && !isFull { sweep += .pi * 2.0 }

        // Find the rotation of the major axis relative to the X axis
        let ellipseRotation = atan2(rawMajorVec.y, rawMajorVec.x)
        
        let cosRot = cos(ellipseRotation)
        let sinRot = sin(ellipseRotation)

        var points: [Vector3] = []
        
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let param = startParam + sweep * t
            
            // Calculate point on a standard, unrotated ellipse at the origin
            let px = majorLen * cos(param)
            let py = minorLen * sin(param)
            
            // Rotate the point by the major axis angle
            let rx = px * cosRot - py * sinRot
            let ry = px * sinRot + py * cosRot
            
            // Translate to center and apply the engine's Y-down flip!
            let finalX = center.x + rx
            let finalY = center.y - ry // FLIP Y HERE!
            let finalZ = center.z
            
            points.append(Vector3(x: finalX, y: finalY, z: finalZ))
        }

        if isFull {
            return [.polygon(points: points, color: color)]
        } else {
            var prims: [CADPrimitive] = []
            for i in 0..<(points.count - 1) {
                prims.append(.line(start: points[i], end: points[i + 1], color: color))
            }
            return prims
        }
    }


    internal static func convertSpline(_ e: DXFRW_EntityData, color: ColorRGBA?) -> [CADPrimitive] {
        // Safely determine degree (AutoCAD defaults to 3 / Cubic if omitted)
        let rawDegree = Int(e.splineDegree)
        let degree = rawDegree > 0 ? rawDegree : 3

        // 1. Preserve NURBS spline as a first-class primitive using Control Points & Knots
        if e.splineNControl > 0 && e.splineNKnots > 0,
           let ctrlPts = e.splineControlPoints,
           let knotsPtr = e.splineKnots {

            let ctrlCount = Int(e.splineNControl)
            let knotCount = Int(e.splineNKnots)

            var vecs: [Vector3] = []
            for i in 0..<ctrlCount {
                let c = ctrlPts[i]
                vecs.append(Vector3(x: c.x, y: -c.y, z: c.z))
            }

            var weights: [Double] = []
            if e.splineWeightCount > 0, let wPts = e.splineWeights {
                weights = (0..<Int(e.splineWeightCount)).map { wPts[$0] }
            } else {
                weights = Array(repeating: 1.0, count: ctrlCount)
            }

            var knots = (0..<knotCount).map { knotsPtr[$0] }

            var finalCPs = vecs
            var finalWeights = weights
            let isClosed = (e.flags & 1) != 0 || (e.flags & 2) != 0

            if isClosed && knotCount == ctrlCount + 1 {
                let p = degree
                let period = knots.last! - knots.first!
                var newKnots = knots
                
                // Add p knots to the beginning
                if p > 0 {
                    for i in 1...p {
                        let idx = ctrlCount - i
                        let k = idx >= 0 ? knots[idx] - period : knots[0] - period
                        newKnots.insert(k, at: 0)
                    }
                }
                
                // Add p knots to the end
                if p > 0 {
                    for i in 1...p {
                        let idx = i
                        let k = idx < knots.count ? knots[idx] + period : knots.last! + period
                        newKnots.append(k)
                    }
                }
                knots = newKnots

                // Add p control points to the end
                if p > 0 {
                    for i in 0..<p {
                        finalCPs.append(finalCPs[i % ctrlCount])
                        finalWeights.append(finalWeights[i % ctrlCount])
                    }
                }
            } else {
                // Auto-fix omitted periodic control points:
                // AutoCAD often compacts closed splines. We wrap and pad them 
                // back in so the knot vector math lines up perfectly.
                let expectedCount = knots.count - degree - 1

                if finalCPs.count < expectedCount {
                    let missing = expectedCount - finalCPs.count
                    for i in 0..<missing {
                        finalCPs.append(vecs[i % vecs.count])
                        finalWeights.append(weights[i % weights.count])
                    }
                }
            }

            // Check if weights are non-uniform (all 1.0 = uniform)
            let hasWeights = finalWeights.contains(where: { abs($0 - 1.0) > 1e-9 })
            return [.spline(
                controlPoints: finalCPs,
                knots: knots,
                degree: degree,
                weights: hasWeights ? finalWeights : nil,
                color: color
            )]
        }

        // 2. Fallback to Fit Points (no NURBS data available)
        // Convert fit points to line segments since there's no parametric definition.
        if e.splineNFit > 0, let pts = e.splineFitPoints {
            let count = Int(e.splineNFit)
            var vecs: [Vector3] = []
            for i in 0..<count {
                let c = pts[i]
                vecs.append(Vector3(x: c.x, y: -c.y, z: c.z))
            }

            if vecs.count > 1 {
                var prims: [CADPrimitive] = []
                for i in 0..<(vecs.count - 1) {
                    prims.append(.line(start: vecs[i], end: vecs[i + 1], color: color))
                }
                return prims
            }
        }

        return []
    }


    /// Strip AutoCAD MTEXT formatting codes (e.g. {\fpxqc;\Farchquik.shx|c0;...} or \P, \L, etc.)
    /// and map backslash/Yen control characters appropriately.
    nonisolated public static func cleanMTextFormatting(_ text: String) -> String {
        var clean = ""
        var i = 0
        let chars = Array(text)
        
        while i < chars.count {
            let c = chars[i]
            
            // Check for backslash or Yen symbol (often a mapped backslash in Japanese/Asian codepages)
            if c == "\\" || c == "¥" {
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "P" {
                        // \P is paragraph/newline (uppercase only)
                        clean.append("\n")
                        i += 2
                        continue
                    } else if next == "L" || next == "l" {
                        // \L is underline start/stop. Toggle it using our custom underline prefix %%u.
                        clean.append("%%u")
                        i += 2
                        continue
                    } else if next == "O" || next == "o" {
                        // \O is overline. Strip it.
                        i += 2
                        continue
                    } else if next == "\\" || next == "¥" || next == "{" || next == "}" {
                        // Escaped backslash, Yen, or braces
                        clean.append(String(next))
                        i += 2
                        continue
                    } else {
                        // Check if it's one of the parameter codes that has a semicolon
                        let paramCodes: Set<Character> = ["f", "F", "c", "C", "h", "H", "s", "S", "t", "T", "w", "W", "a", "A", "q", "Q", "p"]
                        if paramCodes.contains(next) {
                            i += 2
                            while i < chars.count {
                                let curr = chars[i]
                                i += 1
                                if curr == ";" {
                                    break
                                }
                            }
                            continue
                        } else {
                            // Unknown code, just skip backslash/Yen and continue
                            i += 1
                            continue
                        }
                    }
                }
            } else if c == "{" || c == "}" {
                // Formatting groups: just skip the braces
                i += 1
                continue
            }
            
            clean.append(String(c))
            i += 1
        }
        
        return clean
    }
}