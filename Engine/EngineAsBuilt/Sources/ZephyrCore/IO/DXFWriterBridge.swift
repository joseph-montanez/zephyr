import Foundation
import CDXFRW

// =========================================================================
// MARK: - DXFWriterBridge
//
// Uses libdxfrw's writer (via the CDXFRW C bridge) to export a CADDocument
// to a valid DXF file. Converts CADEntity primitives → DXFRW_EntityData
// structs, then calls dxfrw_write() which produces a complete DXF with
// proper subclass markers, handles, tables, blocks, and objects sections.

public enum DXFWriterBridge {

    public static func export(document: CADDocument, to url: URL) throws {
        let tempPath = NSTemporaryDirectory() + "zephyr_dxf_\(UUID().uuidString).dxf"
        let success = writeDocument(document, to: tempPath)
        guard success else {
            throw DXFExportError.writeFailed("libdxfrw write failed")
        }
        // Move to final URL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(atPath: tempPath, toPath: url.path)
    }

    // MARK: - Internal

    private static func writeDocument(_ doc: CADDocument, to path: String) -> Bool {
        // Collect layers
        var layers: [DXFRW_LayerData] = []
        var hadLayer0 = false
        for layer in doc.allLayers {
            var l = DXFRW_LayerData()
            l.name = strdup(layer.name)
            l.color = Int32(DXFColorTable.rgbaToACI(layer.color))
            l.color24 = DXFColorTable.rgbaToTrueColor24(layer.color)
            l.lineWeight = layer.lineWeight
            l.lineTypeName = strdup(layer.lineType)
            l.plotFlag = layer.isVisible ? 1 : 0
            l.transparency = Int32(((1.0 - layer.opacity) * 100).rounded())
            layers.append(l)
            if layer.name == "0" { hadLayer0 = true }
        }
        if !hadLayer0 {
            var l = DXFRW_LayerData()
            l.name = strdup("0")
            l.color = 7
            l.color24 = -1
            l.lineWeight = 0.25
            l.lineTypeName = strdup("CONTINUOUS")
            l.plotFlag = 1
            l.transparency = -1
            layers.append(l)
        }

        // Collect blocks
        var blocks: [DXFRW_BlockData] = []
        for block in doc.allBlocks {
            var b = DXFRW_BlockData()
            b.name = strdup(block.name)
            b.flags = 0
            blocks.append(b)
        }

        // Collect entities
        var entities: [DXFRW_EntityData] = []
        for entity in doc.allEntities {
            let layerName = doc.layer(for: entity.layerID)?.name ?? "0"
            guard let geom = entity.localGeometry, !geom.isEmpty else { continue }

            // Handle block references (INSERT)
            if let blockID = entity.blockID, let block = doc.block(for: blockID) {
                var e = DXFRW_EntityData()
                e.type = DXFRW_ET_INSERT
                e.layerName = strdup(layerName)
                let pos = entity.transform.position
                e.basePoint = DXFRW_Coord(x: pos.x, y: -pos.y, z: pos.z)
                e.blockName = strdup(block.name)
                e.xscale = entity.transform.scale.x
                e.yscale = entity.transform.scale.y
                e.zscale = entity.transform.scale.z
                e.insertAngle = entity.transform.rotation
                e.colCount = 1
                e.rowCount = 1
                entities.append(e)
                continue
            }

            for prim in geom {
                let converted = convertPrimitive(prim, transform: entity.transform, layerName: layerName)
                entities.append(contentsOf: converted)
            }
        }

        // Call the C bridge
        let result = layers.withUnsafeBufferPointer { lPtr in
            blocks.withUnsafeBufferPointer { bPtr in
                entities.withUnsafeBufferPointer { ePtr in
                    dxfrw_write(
                        path,
                        ePtr.baseAddress, Int32(entities.count),
                        lPtr.baseAddress, Int32(layers.count),
                        bPtr.baseAddress, Int32(blocks.count)
                    )
                }
            }
        }

        // Free allocated strings
        for i in 0..<layers.count {
            free(layers[i].name)
            free(layers[i].lineTypeName)
        }
        for i in 0..<blocks.count {
            free(blocks[i].name)
        }
        for i in 0..<entities.count {
            let e = entities[i]
            free(e.layerName)
            free(e.textValue)
            free(e.textStyle)
            free(e.blockName)
            free(e.hatchPatternName)
            free(e.parentBlockName)
        }

        return result != 0
    }

    // MARK: - Primitive Conversion

    private static func convertPrimitive(_ p: CADPrimitive, transform: Transform3D,
                                          layerName: String) -> [DXFRW_EntityData] {
        let t = transform

        // Extract color
        let primColor: ColorRGBA?
        switch p {
        case .point(_, let c): primColor = c
        case .line(_, _, let c): primColor = c
        case .rect(_, _, let c): primColor = c
        case .fillRect(_, _, let c): primColor = c
        case .polygon(_, let c): primColor = c
        case .polyline(_, let c): primColor = c
        case .fillPolygon(_, let c): primColor = c
        case .fillComplexPolygon(_, _, let c): primColor = c
        case .gradient: primColor = nil
        case .circle(_, _, let c): primColor = c
        case .arc(_, _, _, _, let c): primColor = c
        case .spline(_, _, _, _, let c): primColor = c
        case .text(_, _, _, _, _, _, _, _, let c): primColor = c
        case .ellipse(_, _, _, let c): primColor = c
        case .hatch(_, _, _, _, let c, _): primColor = c
        case .ray(_, _, let c): primColor = c
        case .image: primColor = nil
        }

        if let c = primColor, c.a == 0 { return [] }

        var e = DXFRW_EntityData()
        e.layerName = strdup(layerName)
        e.color = Int32(DXFColorTable.rgbaToACI(primColor ?? .white))
        e.color24 = primColor.map { DXFColorTable.rgbaToTrueColor24($0) } ?? -1
        e.lineWeight = -1 // ByLayer

        switch p {
        case .point(let pos, _):
            let wp = t.transformPoint(pos)
            e.type = DXFRW_ET_POINT
            e.basePoint = DXFRW_Coord(x: wp.x, y: -wp.y, z: wp.z)
            return [e]

        case .line(let start, let end, _):
            let ws = t.transformPoint(start)
            let we = t.transformPoint(end)
            e.type = DXFRW_ET_LINE
            e.basePoint = DXFRW_Coord(x: ws.x, y: -ws.y, z: ws.z)
            e.secPoint = DXFRW_Coord(x: we.x, y: -we.y, z: we.z)
            return [e]

        case .rect(let origin, let size, _):
            return convertRectOrPolygon(origin: origin, size: size, transform: t,
                                         closed: true, layerName: layerName, color: primColor)
        case .fillRect(let origin, let size, _):
            return convertRectOrPolygon(origin: origin, size: size, transform: t,
                                         closed: true, layerName: layerName, color: primColor)

        case .polygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            e.type = DXFRW_ET_LWPOLYLINE
            e.flags = 1 // closed
            e.vertexCount = Int32(wp.count)
            e.vertices = allocateVertices(wp)
            return [e]

        case .polyline(let path, _):
            let exportPath: CADPolyline
            if path.hasBulges && abs(abs(t.scale.x) - abs(t.scale.y)) > 1e-9 {
                var pts = path.tessellatedPoints().map { t.transformPoint($0) }
                if path.isClosed, pts.count > 1 { pts.removeLast() }
                exportPath = CADPolyline(points: pts, isClosed: path.isClosed)
            } else {
                exportPath = path.transformed(by: t)
            }
            guard exportPath.vertices.count >= 2 else { return [] }
            e.type = DXFRW_ET_LWPOLYLINE
            e.flags = exportPath.isClosed ? 1 : 0
            e.vertexCount = Int32(exportPath.vertices.count)
            e.vertices = UnsafeMutablePointer<DXFRW_Vertex>.allocate(
                capacity: exportPath.vertices.count)
            for (i, v) in exportPath.vertices.enumerated() {
                e.vertices![i] = DXFRW_Vertex(
                    x: v.position.x, y: -v.position.y,
                    startWidth: v.startWidth, endWidth: v.endWidth,
                    bulge: -v.bulge)
            }
            return [e]

        case .fillPolygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            guard wp.count >= 3 else { return [] }
            e.type = DXFRW_ET_SOLID
            e.basePoint = DXFRW_Coord(x: wp[0].x, y: -wp[0].y, z: 0)
            e.secPoint = DXFRW_Coord(x: wp[1].x, y: -wp[1].y, z: 0)
            e.thirdPoint = DXFRW_Coord(x: wp[2].x, y: -wp[2].y, z: 0)
            let p4 = wp.count >= 4 ? wp[3] : wp[2]
            e.fourPoint = DXFRW_Coord(x: p4.x, y: -p4.y, z: 0)
            return [e]

        case .fillComplexPolygon(let outer, let holes, _):
            return convertHatch(outer: outer, holes: holes, solid: true,
                                pattern: "SOLID", scale: 1, angle: 0,
                                transform: t, layerName: layerName, color: primColor)

        case .circle(let center, let radius, _):
            let wc = t.transformPoint(center)
            let r = radius * max(t.scale.x, t.scale.y)
            e.type = DXFRW_ET_CIRCLE
            e.basePoint = DXFRW_Coord(x: wc.x, y: -wc.y, z: wc.z)
            e.radius = r
            return [e]

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let wc = t.transformPoint(center)
            let r = radius * max(t.scale.x, t.scale.y)
            e.type = DXFRW_ET_ARC
            e.basePoint = DXFRW_Coord(x: wc.x, y: -wc.y, z: wc.z)
            e.radius = r
            // DXF expects CCW angles in radians; negate and swap due to Y inversion
            e.startAngle = -endAngle
            e.endAngle = -startAngle
            return [e]

        case .spline(let pts, let knots, let degree, let weights, _):
            let wp = pts.map { t.transformPoint($0) }
            e.type = DXFRW_ET_SPLINE
            e.splineDegree = Int32(degree)
            e.splineNKnots = Int32(knots.count)
            e.splineNControl = Int32(wp.count)
            e.splineKnots = UnsafeMutablePointer<Double>.allocate(capacity: knots.count)
            for (i, k) in knots.enumerated() { e.splineKnots![i] = k }
            e.splineControlPoints = UnsafeMutablePointer<DXFRW_Coord>.allocate(capacity: wp.count)
            for (i, pt) in wp.enumerated() {
                e.splineControlPoints![i] = DXFRW_Coord(x: pt.x, y: -pt.y, z: pt.z)
            }
            if let w = weights {
                e.splineWeightCount = Int32(w.count)
                e.splineWeights = UnsafeMutablePointer<Double>.allocate(capacity: w.count)
                for (i, v) in w.enumerated() { e.splineWeights![i] = v }
            }
            e.flags = 8 // planar
            return [e]

        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
            let wp = t.transformPoint(pos)
            let rotDeg = (rotation + t.rotation) * 180.0 / .pi
            let isMText = mtextWidth != nil || text.contains("\n")
            if isMText {
                e.type = DXFRW_ET_MTEXT
            } else {
                e.type = DXFRW_ET_TEXT
            }
            e.basePoint = DXFRW_Coord(x: wp.x, y: -wp.y, z: wp.z)
            e.textValue = strdup(text)
            e.textHeight = height
            e.textAngle = -rotDeg
            e.textStyle = style.map { strdup($0) } ?? strdup("Standard")
            e.alignH = Int32(alignH)
            e.alignV = Int32(alignV)
            if let mw = mtextWidth { e.textWidthScale = mw }
            return [e]

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let wc = t.transformPoint(center)
            let majorEnd = t.transformPoint(
                Vector3(x: center.x + majorAxis.x, y: center.y + majorAxis.y, z: center.z))
            e.type = DXFRW_ET_ELLIPSE
            e.basePoint = DXFRW_Coord(x: wc.x, y: -wc.y, z: wc.z)
            // secPoint is the endpoint of the major axis relative to center
            e.secPoint = DXFRW_Coord(
                x: majorEnd.x - wc.x, y: -(majorEnd.y - wc.y), z: majorEnd.z - wc.z)
            e.axisRatio = minorRatio
            e.startAngle = 0
            e.endAngle = 2 * .pi // full ellipse
            return [e]

        case .hatch(let boundary, let pattern, let scale, let angle, _, let bgColor):
            return convertHatch(outer: boundary, holes: [], solid: false,
                                pattern: pattern, scale: scale, angle: angle,
                                transform: t, layerName: layerName, color: primColor)

        case .ray(let start, let direction, _):
            let ws = t.transformPoint(start)
            let wd = t.transformPoint(Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            e.type = DXFRW_ET_LINE // ray → xline not exposed by bridge, use line
            e.basePoint = DXFRW_Coord(x: ws.x, y: -ws.y, z: ws.z)
            e.secPoint = DXFRW_Coord(x: wd.x, y: -wd.y, z: wd.z)
            return [e]

        case .gradient(let outer, let holes, _, _, _, _):
            return convertHatch(outer: outer, holes: holes, solid: false,
                                pattern: "SOLID", scale: 1, angle: 0,
                                transform: t, layerName: layerName, color: primColor)

        case .image:
            return []
        }
    }

    // MARK: - Helpers

    private static func convertRectOrPolygon(origin: Vector3, size: Vector3,
                                              transform: Transform3D,
                                              closed: Bool, layerName: String,
                                              color: ColorRGBA?) -> [DXFRW_EntityData] {
        let t = transform
        let o = t.transformPoint(origin)
        let sx = size.x * t.scale.x
        let sy = size.y * t.scale.y
        let cr = cos(t.rotation)
        let sr = sin(t.rotation)
        let cx = o.x + sx * 0.5
        let cy = o.y + sy * 0.5

        let rawVerts: [(Double, Double)] = [
            (o.x, o.y), (o.x + sx, o.y), (o.x + sx, o.y + sy), (o.x, o.y + sy)
        ]
        let rverts = rawVerts.map { (vx, vy) -> (Double, Double) in
            let rx = vx - cx, ry = vy - cy
            return (cx + rx * cr - ry * sr, cy + rx * sr + ry * cr)
        }

        var e = DXFRW_EntityData()
        e.type = DXFRW_ET_LWPOLYLINE
        e.layerName = strdup(layerName)
        e.color = Int32(DXFColorTable.rgbaToACI(color ?? .white))
        e.color24 = color.map { DXFColorTable.rgbaToTrueColor24($0) } ?? -1
        e.flags = closed ? 1 : 0
        e.vertexCount = 4
        e.vertices = UnsafeMutablePointer<DXFRW_Vertex>.allocate(capacity: 4)
        for (i, (vx, vy)) in rverts.enumerated() {
            e.vertices![i] = DXFRW_Vertex(x: vx, y: -vy, startWidth: 0, endWidth: 0, bulge: 0)
        }
        return [e]
    }

    private static func allocateVertices(_ pts: [Vector3]) -> UnsafeMutablePointer<DXFRW_Vertex> {
        let ptr = UnsafeMutablePointer<DXFRW_Vertex>.allocate(capacity: pts.count)
        for (i, pt) in pts.enumerated() {
            ptr[i] = DXFRW_Vertex(x: pt.x, y: -pt.y, startWidth: 0, endWidth: 0, bulge: 0)
        }
        return ptr
    }

    private static func convertHatch(outer: [Vector3], holes: [[Vector3]],
                                      solid: Bool, pattern: String,
                                      scale: Double, angle: Double,
                                      transform: Transform3D,
                                      layerName: String,
                                      color: ColorRGBA?) -> [DXFRW_EntityData] {
        let wOuter = outer.map { transform.transformPoint($0) }
        guard wOuter.count >= 3 else { return [] }

        var e = DXFRW_EntityData()
        e.type = DXFRW_ET_HATCH
        e.layerName = strdup(layerName)
        e.color = Int32(DXFColorTable.rgbaToACI(color ?? .white))
        e.color24 = color.map { DXFColorTable.rgbaToTrueColor24($0) } ?? -1
        e.hatchSolid = solid ? 1 : 0
        e.hatchPatternName = strdup(pattern)
        e.hatchScale = scale > 0 ? scale : 1.0
        e.hatchAngle = angle
        e.hatchLoopCount = Int32(1 + holes.count)
        e.hatchLoops = UnsafeMutablePointer<DXFRW_HatchLoopData>.allocate(capacity: 1 + holes.count)

        // Outer loop
        e.hatchLoops![0].loopFlags = 1 // external
        e.hatchLoops![0].vertexCount = Int32(wOuter.count)
        e.hatchLoops![0].vertices = UnsafeMutablePointer<DXFRW_Coord>.allocate(capacity: wOuter.count)
        for (i, pt) in wOuter.enumerated() {
            e.hatchLoops![0].vertices![i] = DXFRW_Coord(x: pt.x, y: -pt.y, z: 0)
        }

        // Hole loops
        for (hi, hole) in holes.enumerated() {
            let wHole = hole.map { transform.transformPoint($0) }
            e.hatchLoops![hi + 1].loopFlags = 0 // internal
            e.hatchLoops![hi + 1].vertexCount = Int32(wHole.count)
            e.hatchLoops![hi + 1].vertices = UnsafeMutablePointer<DXFRW_Coord>.allocate(capacity: wHole.count)
            for (i, pt) in wHole.enumerated() {
                e.hatchLoops![hi + 1].vertices![i] = DXFRW_Coord(x: pt.x, y: -pt.y, z: 0)
            }
        }

        return [e]
    }
}

// MARK: - DXFColorTable helpers for export

extension DXFColorTable {
    /// Convert RGBA to ACI index (used for export).
    static func rgbaToACI(_ color: ColorRGBA) -> Int {
        let (r, g, b) = (color.r, color.g, color.b)
        switch (r, g, b) {
        case (255, 0,   0):   return 1
        case (255, 255, 0):   return 2
        case (0,   255, 0):   return 3
        case (0,   255, 255): return 4
        case (0,   0,   255): return 5
        case (255, 0,   255): return 6
        case (255, 255, 255): return 7
        case (0,   0,   0):   return 250
        default:              return 256
        }
    }

    /// If non-standard, return packed 24-bit RGB; otherwise -1.
    static func rgbaToTrueColor24(_ color: ColorRGBA) -> Int32 {
        let (r, g, b) = (color.r, color.g, color.b)
        switch (r, g, b) {
        case (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255),
             (0, 0, 255), (255, 0, 255), (255, 255, 255), (0, 0, 0):
            return -1
        default:
            return Int32(Int(r) << 16 | Int(g) << 8 | Int(b))
        }
    }
}
