import Foundation

// =========================================================================
// MARK: - DXFExporter
//
// Exports a Zephyr CAD document to AutoCAD DXF format.
// Converts entities, layers, and blocks back to DXF group-code format.
// Supports polyline simplification, text style preservation, and
// block reference (INSERT) export with proper transform decomposition.

// =========================================================================
// MARK: - DXFExporter
// =========================================================================

/// Pure Swift DXF writer — serializes a `CADDocument` to ASCII DXF format.
/// DXF ASCII uses group codes (integers) followed by values on alternating lines.
public enum DXFExporter {

    // MARK: - Public API

    /// Export the document to a DXF file at the given URL.
    /// - Parameters:
    ///   - document: The CAD document to export.
    ///   - url: Destination file URL.
    /// - Throws: An error if writing fails.
    public static func export(document: CADDocument, to url: URL) throws {
        var output = ""
        writeHeader(unit: document.unit, into: &output)
        writeTables(document: document, into: &output)
        writeBlocks(document: document, into: &output)
        writeEntities(document: document, into: &output)
        writeEOF(into: &output)

        // Ensure CRLF line endings (DXF standard)
        let dxfContent = output.replacingOccurrences(of: "\n", with: "\r\n")
        try dxfContent.write(to: url, atomically: true, encoding: .ascii)
    }

    /// Background-save: export from a snapshot with progress and cancellation.
    public static func export(snapshot: CADDocumentSnapshot, to url: URL,
                               progress: ((Float) -> Void)? = nil) throws {
        try Task.checkCancellation()

        let estimatedSize = estimateDXFSize(snapshot: snapshot)

        // Reconstruct a temporary document
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)

        var output = ""
        writeHeader(unit: tempDoc.unit, into: &output)
        try Task.checkCancellation()
        writeTables(document: tempDoc, into: &output)
        try Task.checkCancellation()
        writeBlocks(document: tempDoc, into: &output)
        try Task.checkCancellation()
        writeEntities(document: tempDoc, into: &output)
        try Task.checkCancellation()
        writeEOF(into: &output)

        let dxfContent = output.replacingOccurrences(of: "\n", with: "\r\n")
        let progressFraction = min(0.99, Float(dxfContent.utf8.count) / Float(max(estimatedSize, 1)))
        progress?(progressFraction)

        try atomicWrite(data: Data(dxfContent.utf8), to: url)
    }

    private static func estimateDXFSize(snapshot: CADDocumentSnapshot) -> Int {
        // Rough: ~200 bytes per entity in DXF ASCII
        return 2000 + snapshot.entities.count * 200 + snapshot.blocks.count * 150
    }

    private static func atomicWrite(data: Data, to targetURL: URL) throws {
        let tmpURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try data.write(to: tmpURL, options: .atomic)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        }
    }

    // MARK: - HEADER Section

    private static func writeHeader(unit: CADUnit, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nHEADER\r\n"
        output += "  9\r\n$ACADVER\r\n"
        output += "  1\r\nAC1021\r\n"  // AutoCAD 2007
        // Units: inches = 1, mm = 4
        output += "  9\r\n$INSUNITS\r\n"
        output += " 70\r\n\(unit.dxfINSUNITS)\r\n"
        output += "  0\r\nENDSEC\r\n"
    }

    // MARK: - TABLES Section

    private static func writeTables(document: CADDocument, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nTABLES\r\n"

        // LAYER table
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nLAYER\r\n"
        output += " 70\r\n\(document.layerCount)\r\n"

        for layer in document.allLayers {
            writeLayer(layer, into: &output)
        }

        output += "  0\r\nENDTAB\r\n"
        output += "  0\r\nENDSEC\r\n"
    }

    private static func writeLayer(_ layer: Layer, into output: inout String) {
        output += "  0\r\nLAYER\r\n"
        output += "  5\r\n\(layerHash(handle: layer.handle))\r\n"  // handle
        output += "  2\r\n\(dxfEscape(layer.name))\r\n"             // name
        output += " 70\r\n0\r\n"                                    // flags (0 = thawed)
        output += " 62\r\n\(rgbaToACI(layer.color))\r\n"            // color (ACI)
        // True color if not a standard ACI color
        if let tc = rgbaToTrueColor(layer.color) {
            output += "420\r\n\(tc)\r\n"
        }
        output += "  6\r\nCONTINUOUS\r\n"                           // linetype
        output += "370\r\n\(lineWeightToDXF(layer.lineWeight))\r\n"  // lineweight
        // Layer transparency (DXF group 440). Only emit when non-opaque.
        if layer.opacity < 1.0 {
            output += "440\r\n\(opacityToDXF(layer.opacity))\r\n"
        }
    }

    // MARK: - BLOCKS Section

    private static func writeBlocks(document: CADDocument, into output: inout String) {
        let blocks = document.allBlocks
        guard !blocks.isEmpty else { return }

        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nBLOCKS\r\n"

        for block in blocks {
            writeBlock(block, into: &output)
        }

        output += "  0\r\nENDSEC\r\n"
    }

    private static func writeBlock(_ block: CADBlock, into output: inout String) {
        output += "  0\r\nBLOCK\r\n"
        output += "  5\r\n\(blockHash(handle: block.handle))\r\n"
        output += "  2\r\n\(dxfEscape(block.name))\r\n"  // block name
        output += " 70\r\n0\r\n"                          // flags
        output += " 10\r\n0.0\r\n"                        // base X
        output += " 20\r\n0.0\r\n"                        // base Y
        output += " 30\r\n0.0\r\n"                        // base Z
        output += "  3\r\n\(dxfEscape(block.name))\r\n"  // block name again

        // Write block geometry as entities within the block
        for primitive in block.geometry {
            writePrimitive(primitive, into: &output)
        }

        output += "  0\r\nENDBLK\r\n"
        output += "  5\r\n\(blockEndHash(handle: block.handle))\r\n"
    }

    // MARK: - ENTITIES Section

    private static func writeEntities(document: CADDocument, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nENTITIES\r\n"

        for entity in document.allEntities {
            writeEntity(entity, document: document, into: &output)
        }

        output += "  0\r\nENDSEC\r\n"
    }

    private static func writeEntity(_ entity: CADEntity, document: CADDocument,
                                    into output: inout String) {
        // Resolve layer name from document
        let layerName = document.layer(for: entity.layerID)?.name ?? "0"

        // Handle block instances (INSERT)
        if let blockID = entity.blockID, let block = document.block(for: blockID) {
            writeInsert(entity: entity, blockName: block.name, layerName: layerName, into: &output)
            return
        }

        // Handle raw geometry
        guard let geometry = entity.localGeometry, !geometry.isEmpty else { return }

        // Text entities with xdata get special handling for formatting round-trip.
        if let _ = entity.xdata["dxf.text"],
           let prim = geometry.first,
           case .text(let pos, _, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color) = prim {
            let formattedJSON: String?
            if case .string(let s) = entity.xdata["dxf.formattedText"] { formattedJSON = s }
            else { formattedJSON = nil }
            let rawMText: String?
            if case .string(let s) = entity.xdata["dxf.mtextRaw"] { rawMText = s }
            else { rawMText = nil }
            let plainText: String?
            if case .string(let s) = entity.xdata["dxf.text"] { plainText = s }
            else { plainText = nil }
            let textToWrite = resolveTextForExport(
                formattedJSON: formattedJSON,
                rawMText: rawMText,
                plainText: plainText,
                position: pos, height: height, rotation: rotation,
                style: style, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: color,
                transform: entity.transform, layerName: layerName,
                into: &output
            )
            if !textToWrite {
                // Fallback: write the primitive normally
                writePrimitive(prim, transform: entity.transform,
                               layerName: layerName, into: &output)
            }
            return
        }

        for primitive in geometry {
            writePrimitive(primitive, transform: entity.transform,
                           layerName: layerName,
                           into: &output)
        }
    }

    // MARK: - INSERT Entity

    private static func writeInsert(entity: CADEntity, blockName: String, layerName: String,
                                    into output: inout String) {
        output += "  0\r\nINSERT\r\n"
        output += "  5\r\n\(entityHash(handle: entity.handle))\r\n"
        output += "  8\r\n\(dxfEscape(layerName))\r\n"
        output += "  2\r\n\(dxfEscape(blockName))\r\n"

        let pos = entity.transform.position
        output += " 10\r\n\(dxfDouble(pos.x))\r\n"
        output += " 20\r\n\(dxfDouble(-pos.y))\r\n"
        output += " 30\r\n\(dxfDouble(pos.z))\r\n"

        let scale = entity.transform.scale
        if scale.x != 1.0 { output += " 41\r\n\(dxfDouble(scale.x))\r\n" }
        if scale.y != 1.0 { output += " 42\r\n\(dxfDouble(scale.y))\r\n" }
        if scale.z != 1.0 { output += " 43\r\n\(dxfDouble(scale.z))\r\n" }

        let rotDeg = entity.transform.rotation * 180.0 / .pi
        if rotDeg != 0.0 { output += " 50\r\n\(dxfDouble(-rotDeg))\r\n" }
    }

    // MARK: - Primitive Writers

    private static func writePrimitive(_ p: CADPrimitive, transform: Transform3D? = nil,
                                       layerName: String = "0",
                                       into output: inout String) {
        let t = transform ?? .identity
        let layer = layerName

        // Extract color override if present on the primitive
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
        case .gradient(_, _, _, _, _, _): primColor = nil
        case .circle(_, _, let c): primColor = c
        case .arc(_, _, _, _, let c): primColor = c
        case .spline(_, _, _, _, let c): primColor = c
        case .text(_, _, _, _, _, _, _, _, let c): primColor = c
        case .ellipse(_, _, _, let c): primColor = c
        case .hatch(_, _, _, _, let c, _): primColor = c
        case .ray(_, _, let c): primColor = c
        case .image(_, _, _, _, _, let c): primColor = c
        }

        if let c = primColor, c.a == 0 {
            return
        }

        let appendColor = { (out: inout String) in
            if let c = primColor {
                out += " 62\r\n\(rgbaToACI(c))\r\n"
                if let tc = rgbaToTrueColor(c) {
                    out += "420\r\n\(tc)\r\n"
                }
            }
        }

        switch p {
        case .point(let pos, _):
            let wp = t.transformPoint(pos)
            output += "  0\r\nPOINT\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"

        case .line(let start, let end, _):
            let ws = t.transformPoint(start)
            let we = t.transformPoint(end)
            output += "  0\r\nLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(ws.x))\r\n"
            output += " 20\r\n\(dxfDouble(-ws.y))\r\n"
            output += " 30\r\n\(dxfDouble(ws.z))\r\n"
            output += " 11\r\n\(dxfDouble(we.x))\r\n"
            output += " 21\r\n\(dxfDouble(-we.y))\r\n"
            output += " 31\r\n\(dxfDouble(we.z))\r\n"

        case .rect(let origin, let size, _):
            // Export as closed LWPOLYLINE with 4 vertices
            let o = t.transformPoint(origin)
            let sx = size.x * t.scale.x
            let sy = size.y * t.scale.y

            let verts: [(Double, Double)] = [
                (o.x, o.y),
                (o.x + sx, o.y),
                (o.x + sx, o.y + sy),
                (o.x, o.y + sy),
            ]

            // Apply rotation if needed
            let cr = cos(t.rotation)
            let sr = sin(t.rotation)
            let cx = o.x + sx * 0.5
            let cy = o.y + sy * 0.5

            let rverts: [(Double, Double)] = verts.map { (vx, vy) in
                let rx = vx - cx
                let ry = vy - cy
                return (cx + rx * cr - ry * sr, cy + rx * sr + ry * cr)
            }

            output += "  0\r\nLWPOLYLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 90\r\n4\r\n"
            output += " 70\r\n1\r\n"  // closed
            for (vx, vy) in rverts {
                output += " 10\r\n\(dxfDouble(vx))\r\n"
                output += " 20\r\n\(dxfDouble(-vy))\r\n"
            }

        case .fillRect(let origin, let size, _):
            // Export as closed LWPOLYLINE (same as rect but filled appearance)
            // DXF doesn't have a native "fill rect" — use SOLID or closed polyline
            let o = t.transformPoint(origin)
            let sx = size.x * t.scale.x
            let sy = size.y * t.scale.y

            let verts: [(Double, Double)] = [
                (o.x, o.y),
                (o.x + sx, o.y),
                (o.x + sx, o.y + sy),
                (o.x, o.y + sy),
            ]

            let cr = cos(t.rotation)
            let sr = sin(t.rotation)
            let cx = o.x + sx * 0.5
            let cy = o.y + sy * 0.5

            let rverts: [(Double, Double)] = verts.map { (vx, vy) in
                let rx = vx - cx
                let ry = vy - cy
                return (cx + rx * cr - ry * sr, cy + rx * sr + ry * cr)
            }

            // Use SOLID entity for filled rectangles
            output += "  0\r\nSOLID\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(rverts[0].0))\r\n"
            output += " 20\r\n\(dxfDouble(-rverts[0].1))\r\n"
            output += " 30\r\n0.0\r\n"
            output += " 11\r\n\(dxfDouble(rverts[1].0))\r\n"
            output += " 21\r\n\(dxfDouble(-rverts[1].1))\r\n"
            output += " 31\r\n0.0\r\n"
            output += " 12\r\n\(dxfDouble(rverts[2].0))\r\n"
            output += " 22\r\n\(dxfDouble(-rverts[2].1))\r\n"
            output += " 32\r\n0.0\r\n"
            output += " 13\r\n\(dxfDouble(rverts[3].0))\r\n"
            output += " 23\r\n\(dxfDouble(-rverts[3].1))\r\n"
            output += " 33\r\n0.0\r\n"

        case .polygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            let closed = (points.count > 2 && points.first == points.last)
                || points.count > 2

            output += "  0\r\nLWPOLYLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 90\r\n\(wp.count)\r\n"
            output += " 70\r\n\(closed ? 1 : 0)\r\n"
            for pt in wp {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }

        case .polyline(let path, _):
            let nonUniformScale = abs(abs(t.scale.x) - abs(t.scale.y)) > 1e-9
            let exportPath: CADPolyline
            if path.hasBulges && nonUniformScale {
                var points = path.tessellatedPoints().map { t.transformPoint($0) }
                if path.isClosed, points.count > 1 { points.removeLast() }
                exportPath = CADPolyline(
                    points: points,
                    isClosed: path.isClosed,
                    lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
            } else {
                exportPath = path.transformed(by: t)
            }
            guard exportPath.vertices.count >= 2 else { break }

            output += "  0\r\nLWPOLYLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 90\r\n\(exportPath.vertices.count)\r\n"
            let flags = (exportPath.isClosed ? 1 : 0)
                | (exportPath.lineTypeGenerationEnabled ? 128 : 0)
            output += " 70\r\n\(flags)\r\n"
            for vertex in exportPath.vertices {
                output += " 10\r\n\(dxfDouble(vertex.position.x))\r\n"
                output += " 20\r\n\(dxfDouble(-vertex.position.y))\r\n"
                if vertex.startWidth != 0 {
                    output += " 40\r\n\(dxfDouble(vertex.startWidth))\r\n"
                }
                if vertex.endWidth != 0 {
                    output += " 41\r\n\(dxfDouble(vertex.endWidth))\r\n"
                }
                if vertex.bulge != 0 {
                    output += " 42\r\n\(dxfDouble(-vertex.bulge))\r\n"
                }
            }

        case .fillPolygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            guard wp.count >= 3 else { break }
            let p1 = wp[0]
            let p2 = wp[1]
            let p3 = wp[2]
            let p4 = wp.count >= 4 ? wp[3] : p3
            output += "  0\r\nSOLID\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(p1.x))\r\n"
            output += " 20\r\n\(dxfDouble(-p1.y))\r\n"
            output += " 30\r\n0.0\r\n"
            output += " 11\r\n\(dxfDouble(p2.x))\r\n"
            output += " 21\r\n\(dxfDouble(-p2.y))\r\n"
            output += " 31\r\n0.0\r\n"
            output += " 12\r\n\(dxfDouble(p3.x))\r\n"
            output += " 22\r\n\(dxfDouble(-p3.y))\r\n"
            output += " 32\r\n0.0\r\n"
            output += " 13\r\n\(dxfDouble(p4.x))\r\n"
            output += " 23\r\n\(dxfDouble(-p4.y))\r\n"
            output += " 33\r\n0.0\r\n"

        case .fillComplexPolygon(let outer, let holes, _):
            let wOuter = outer.map { t.transformPoint($0) }
            guard wOuter.count >= 3 else { break }
            
            output += "  0\r\nHATCH\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += "  2\r\nSOLID\r\n"
            output += " 70\r\n1\r\n" // Solid
            output += " 71\r\n0\r\n" // Associativity
            output += " 91\r\n\(1 + holes.count)\r\n" // Total loops
            
            // Outer Loop Boundary
            output += " 92\r\n1\r\n" // External
            output += " 93\r\n\(wOuter.count)\r\n"
            for pt in wOuter {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }
            
            // Inner Island Loops
            for hole in holes {
                let wHole = hole.map { t.transformPoint($0) }
                output += " 92\r\n0\r\n" // Internal/Island
                output += " 93\r\n\(wHole.count)\r\n"
                for pt in wHole {
                    output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                    output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
                }
            }
            output += " 75\r\n0\r\n"
            output += " 76\r\n1\r\n"
            output += " 47\r\n1.0\r\n"
            output += " 98\r\n0\r\n"

        case .gradient(let outer, let holes, let name, let angle, let color1, let color2):
            let wOuter = outer.map { t.transformPoint($0) }
            guard wOuter.count >= 3 else { break }

            output += "  0\r\nHATCH\r\n"
            output += "  8\r\n\(layer)\r\n"
            // color1 → entity color (62 ACI / 420 true-color)
            output += " 62\r\n\(rgbaToACI(color1))\r\n"
            if let tc1 = rgbaToTrueColor(color1) {
                output += "420\r\n\(tc1)\r\n"
            }
            output += "  2\r\nSOLID\r\n"
            output += " 70\r\n1\r\n" // Solid
            output += " 71\r\n0\r\n" // Associativity
            // Gradient data
            output += "450\r\n1\r\n"    // Linear gradient
            output += "452\r\n\(dxfDouble(angle * 180.0 / .pi))\r\n" // radians → degrees
            output += "453\r\n0.0\r\n"
            output += "460\r\n0\r\n"    // Two-color gradient
            output += "462\r\n0.0\r\n"
            output += "470\r\n\(name)\r\n"
            // color2 → gradient color (63 ACI / 421 true-color)
            output += " 63\r\n\(rgbaToACI(color2))\r\n"
            if let tc2 = rgbaToTrueColor(color2) {
                output += "421\r\n\(tc2)\r\n"
            }
            output += " 91\r\n\(1 + holes.count)\r\n" // Total loops

            // Outer Loop Boundary
            output += " 92\r\n1\r\n" // External
            output += " 93\r\n\(wOuter.count)\r\n"
            for pt in wOuter {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }

            // Inner Island Loops
            for hole in holes {
                let wHole = hole.map { t.transformPoint($0) }
                output += " 92\r\n0\r\n" // Internal/Island
                output += " 93\r\n\(wHole.count)\r\n"
                for pt in wHole {
                    output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                    output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
                }
            }
            output += " 75\r\n0\r\n"
            output += " 76\r\n1\r\n"
            output += " 47\r\n1.0\r\n"
            output += " 98\r\n0\r\n"

        case .circle(let center, let radius, _):
            let wc = t.transformPoint(center)
            let scaledRadius = radius * max(t.scale.x, t.scale.y)
            output += "  0\r\nCIRCLE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(scaledRadius))\r\n"

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let wc = t.transformPoint(center)
            let scaledRadius = radius * max(t.scale.x, t.scale.y)
            output += "  0\r\nARC\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(scaledRadius))\r\n"
            // DXF angles in degrees (negated and swapped due to Y inversion)
            output += " 50\r\n\(dxfDouble(-endAngle * 180.0 / .pi))\r\n"
            output += " 51\r\n\(dxfDouble(-startAngle * 180.0 / .pi))\r\n"

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            // Write SPLINE entity (degree, knots, control points, optional weights)
            output += "  0\r\nSPLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 70\r\n\(degree == 3 ? 8 : 4)\r\n"  // 4=rational, 8=planar
            output += " 71\r\n\(degree)\r\n"
            let nKnots = knots.count
            let nCtrl = controlPoints.count
            output += " 72\r\n\(nKnots)\r\n"
            output += " 73\r\n\(nCtrl)\r\n"
            // Knots (group code 40)
            for k in knots {
                output += " 40\r\n\(dxfDouble(k))\r\n"
            }
            // Control points (group codes 10, 20, 30)
            for cp in controlPoints {
                let wp = t.transformPoint(cp)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            }
            // Weights (group code 41) — only write if present (rational spline)
            if let w = weights {
                for weight in w {
                    output += " 41\r\n\(dxfDouble(weight))\r\n"
                }
            }

        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
            let wp = t.transformPoint(pos)
            let rotDeg = (rotation + t.rotation) * 180.0 / .pi

            let isMText = mtextWidth != nil || text.contains("\\P") || text.contains("\n")
            if isMText {
                output += "  0\r\nMTEXT\r\n"
                output += "  8\r\n\(layer)\r\n"
                appendColor(&output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                if let mw = mtextWidth {
                    output += " 41\r\n\(dxfDouble(mw))\r\n"
                }
                output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if let s = style {
                    output += "  7\r\n\(dxfEscape(s))\r\n"
                }
            } else {
                output += "  0\r\nTEXT\r\n"
                output += "  8\r\n\(layer)\r\n"
                appendColor(&output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if rotDeg != 0.0 {
                    output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                }
                if let s = style {
                    output += "  7\r\n\(dxfEscape(s))\r\n"
                }
                if alignH != 0 || alignV != 0 {
                    output += " 72\r\n\(alignH)\r\n"
                    output += " 73\r\n\(alignV)\r\n"
                    output += " 11\r\n\(dxfDouble(wp.x))\r\n"
                    output += " 21\r\n\(dxfDouble(-wp.y))\r\n"
                    output += " 31\r\n\(dxfDouble(wp.z))\r\n"
                }
            }

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let wc = t.transformPoint(center)
            let majorEnd = t.transformPoint(Vector3(x: center.x + majorAxis.x, y: center.y + majorAxis.y, z: center.z))
            output += "  0\r\nELLIPSE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 11\r\n\(dxfDouble(majorEnd.x - wc.x))\r\n"
            output += " 21\r\n\(dxfDouble(-(majorEnd.y - wc.y)))\r\n"
            output += " 31\r\n\(dxfDouble(majorEnd.z - wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(minorRatio))\r\n"
            output += " 41\r\n0.0\r\n"  // start parameter
            output += " 42\r\n\(dxfDouble(2.0 * .pi))\r\n"  // end parameter (full ellipse)

        case .hatch(let boundary, let pattern, let hatchScale, let hatchAngle, _, let backgroundColor):
            let wBoundary = boundary.map { t.transformPoint($0) }
            guard wBoundary.count >= 3 else { break }
            output += "  0\r\nHATCH\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            if pattern.uppercased() == "SOLID" || pattern.isEmpty {
                output += "  2\r\nSOLID\r\n"
                output += " 70\r\n1\r\n"
            } else {
                output += "  2\r\n\(pattern)\r\n"
                output += " 70\r\n0\r\n"
            }
            output += " 71\r\n0\r\n"
            output += " 91\r\n1\r\n"
            output += " 92\r\n1\r\n"
            output += " 93\r\n\(wBoundary.count)\r\n"
            for pt in wBoundary {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }
            output += " 75\r\n0\r\n"
            // 76 is hatch pattern type: 1 = predefined, 0 = user/custom.
            // This keeps AutoCAD's Properties panel from treating ANSI names
            // as anonymous custom patterns after round-trip export.
            let hatchPatternType = DXFHatchGenerator.predefinedPatterns[pattern.uppercased()] == nil ? 0 : 1
            output += " 76\r\n\(hatchPatternType)\r\n"
            if hatchScale > 0 {
                // DXF group 41 is hatch pattern scale.  The old exporter used
                // 47, which is pixel size for associative hatch calculations
                // and does not round-trip the Properties > Scale value.
                output += " 41\r\n\(dxfDouble(hatchScale))\r\n"
            }
            if hatchAngle != 0 {
                output += " 52\r\n\(dxfDouble(hatchAngle * 180.0 / .pi))\r\n"
            }
            // DXF group 63 = hatch background fill color (ACI index).
            // Writes the 24-bit RGB as a negative DXF colour; positive ACI
            // mapping requires a nearestACI utility (not yet implemented).
            // Even without group 63, EAB roundtrip preserves backgroundColor
            // via the CADPrimitive enum field.
            if let bg = backgroundColor {
                let rgb24 = Int32((Int32(bg.r) << 16) | (Int32(bg.g) << 8) | Int32(bg.b))
                output += " 63\r\n\(-rgb24)\r\n"
            }
            output += " 98\r\n0\r\n"

        case .ray(let start, let direction, _):
            let ws = t.transformPoint(start)
            let wd = t.transformPoint(Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            // Export as XLINE (infinite construction line)
            output += "  0\r\nXLINE\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(ws.x))\r\n"
            output += " 20\r\n\(dxfDouble(-ws.y))\r\n"
            output += " 30\r\n\(dxfDouble(ws.z))\r\n"
            output += " 11\r\n\(dxfDouble(wd.x))\r\n"
            output += " 21\r\n\(dxfDouble(-wd.y))\r\n"
            output += " 31\r\n\(dxfDouble(wd.z))\r\n"
        case .image:
            // DXF IMAGE export not yet implemented; skip
            break
        }
    }

    // MARK: - Text Export Resolution

    /// Resolves text content for export. Returns true if text was written.
    /// Strategy:
    ///   1. If `dxf.mtextRaw` exists and `dxf.formattedText` is absent → user hasn't
    ///      edited formatting; emit raw MTEXT unchanged for perfect round-trip.
    ///   2. If `dxf.formattedText` exists → user edited; serialize from structured form.
    ///   3. Fallback: emit plain text as TEXT entity.
    private static func resolveTextForExport(
        formattedJSON: String?,
        rawMText: String?,
        plainText: String?,
        position: Vector3, height: Double, rotation: Double,
        style: String?, alignH: Int, alignV: Int,
        mtextWidth: Double?, color: ColorRGBA?,
        transform: Transform3D, layerName: String,
        into output: inout String
    ) -> Bool {
        let wp = transform.transformPoint(position)
        let rotDeg = (rotation + transform.rotation) * 180.0 / .pi
        let layer = layerName

        let appendColor = { (out: inout String) in
            if let c = color, c.a > 0 {
                out += " 62\r\n\(rgbaToACI(c))\r\n"
                if let tc = rgbaToTrueColor(c) {
                    out += "420\r\n\(tc)\r\n"
                }
            }
        }

        // Case 1: Raw MTEXT preserved (unedited)
        if let raw = rawMText, formattedJSON == nil, !raw.isEmpty {
            output += "  0\r\nMTEXT\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            output += " 40\r\n\(dxfDouble(height))\r\n"
            if let mw = mtextWidth, mw > 0 {
                output += " 41\r\n\(dxfDouble(mw))\r\n"
            }
            output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
            output += "  1\r\n\(raw)\r\n"
            if let s = style {
                output += "  7\r\n\(dxfEscape(s))\r\n"
            }
            return true
        }

        // Case 2: Structured formatted text (edited)
        if let jsonStr = formattedJSON,
           let jsonData = jsonStr.data(using: .utf8),
           let formatted = try? JSONDecoder().decode(FormattedText.self, from: jsonData) {
            let mtextStr = MTEXTFormatter.serialize(formatted)
            output += "  0\r\nMTEXT\r\n"
            output += "  8\r\n\(layer)\r\n"
            appendColor(&output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            output += " 40\r\n\(dxfDouble(height))\r\n"
            if let mw = mtextWidth, mw > 0 {
                output += " 41\r\n\(dxfDouble(mw))\r\n"
            }
            output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
            output += "  1\r\n\(mtextStr)\r\n"
            if let s = style {
                output += "  7\r\n\(dxfEscape(s))\r\n"
            }
            return true
        }

        // Case 3: Fallback — plain TEXT
        if let text = plainText, !text.isEmpty {
            let isMText = mtextWidth != nil || text.contains("\\P") || text.contains("\n")
            if isMText {
                output += "  0\r\nMTEXT\r\n"
                output += "  8\r\n\(layer)\r\n"
                appendColor(&output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                if let mw = mtextWidth {
                    output += " 41\r\n\(dxfDouble(mw))\r\n"
                }
                output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if let s = style {
                    output += "  7\r\n\(dxfEscape(s))\r\n"
                }
            } else {
                output += "  0\r\nTEXT\r\n"
                output += "  8\r\n\(layer)\r\n"
                appendColor(&output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if rotDeg != 0.0 {
                    output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                }
                if let s = style {
                    output += "  7\r\n\(dxfEscape(s))\r\n"
                }
                if alignH != 0 || alignV != 0 {
                    output += " 72\r\n\(alignH)\r\n"
                    output += " 73\r\n\(alignV)\r\n"
                    output += " 11\r\n\(dxfDouble(wp.x))\r\n"
                    output += " 21\r\n\(dxfDouble(-wp.y))\r\n"
                    output += " 31\r\n\(dxfDouble(wp.z))\r\n"
                }
            }
            return true
        }

        return false
    }

    // MARK: - EOF

    private static func writeEOF(into output: inout String) {
        output += "  0\r\nEOF\r\n"
    }

    // MARK: - Helpers

    /// Format a Double in a DXF-friendly way (up to 6 decimal places, no trailing zeros).
    private static func dxfDouble(_ value: Double) -> String {
        // Use 6 decimal places, remove trailing zeros
        let str = String(format: "%.6f", value)
        // Trim trailing zeros and decimal point
        var result = str
        while result.hasSuffix("0") {
            result.removeLast()
        }
        if result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }

    /// Escape DXF special characters in a string.
    private static func dxfEscape(_ s: String) -> String {
        // DXF group code values are generally safe ASCII, but commas and
        // certain control characters can cause issues.
        s.replacingOccurrences(of: "\r", with: "")
         .replacingOccurrences(of: "\n", with: "\\P")
    }

    /// Convert a ColorRGBA to an AutoCAD Color Index (ACI).
    /// Returns 256 (ByLayer) for white (the default — layer color overrides).
    private static func rgbaToACI(_ color: ColorRGBA) -> Int {
        let (r, g, b) = (color.r, color.g, color.b)

        // Standard ACI colors (1-9): Red, Yellow, Green, Cyan, Blue, Magenta, White
        switch (r, g, b) {
        case (255, 0,   0):   return 1   // Red
        case (255, 255, 0):   return 2   // Yellow
        case (0,   255, 0):   return 3   // Green
        case (0,   255, 255): return 4   // Cyan
        case (0,   0,   255): return 5   // Blue
        case (255, 0,   255): return 6   // Magenta
        case (255, 255, 255): return 7   // White
        case (0,   0,   0):   return 250 // Black → dark gray
        default:
            // Non-standard color → use 256 (ByLayer) + true color
            return 256
        }
    }

    /// If the color is non-standard, return the 24-bit integer representation
    /// for DXF group code 420. Returns nil for standard ACI colors.
    private static func rgbaToTrueColor(_ color: ColorRGBA) -> Int? {
        let (r, g, b) = (color.r, color.g, color.b)
        // Only emit true color if it's not a standard ACI color
        switch (r, g, b) {
        case (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255),
             (0, 0, 255), (255, 0, 255), (255, 255, 255), (0, 0, 0):
            return nil  // Standard ACI — don't emit true color
        default:
            return (Int(r) << 16) | (Int(g) << 8) | Int(b)
        }
    }

    /// Convert line weight in mm to DXF integer (1/100 mm).
    private static func lineWeightToDXF(_ lw: Double) -> Int {
        if lw <= 0 { return -3 }  // Default
        return Int(lw * 100.0)
    }

    /// Convert opacity 0.0–1.0 to DXF transparency code 440.
    /// 1.0 (opaque) → 0, nearer 0.0 → nearer 90 (percentage).
    private static func opacityToDXF(_ opacity: Double) -> Int {
        let pct = Int(((1.0 - opacity) * 100.0).rounded())
        return max(0, min(90, pct))
    }

    /// Generate a hex handle from a UUID (used for DXF handles).
    private static func uuidToHex(_ uuid: UUID) -> String {
        // Use first 8 bytes of UUID as handle
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let hex = bytes[0..<min(8, bytes.count)].map { String(format: "%02X", $0) }.joined()
        return hex
    }

    private static func layerHash(handle: UUID) -> String { uuidToHex(handle) }
    private static func blockHash(handle: UUID) -> String { uuidToHex(handle) }
    private static func blockEndHash(handle: UUID) -> String { uuidToHex(handle) + "E" }
    private static func entityHash(handle: UUID) -> String { uuidToHex(handle) }
}

// =========================================================================
// MARK: - DXFExportError
// =========================================================================

public enum DXFExportError: Error {
    case writeFailed(String)
}