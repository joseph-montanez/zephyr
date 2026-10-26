import Foundation

// =========================================================================
// MARK: - PDFExporter
//
// Exports a CAD document to PDF format. Converts entities to PDF drawing
// operations using the PDFWriter and PDFPrimitives abstractions.
// Supports line weights, colors, and basic entity types.

// =========================================================================
// MARK: - PDFExporter
// =========================================================================

/// Exports a `CADDocument` as a PDF 1.7 file with vector geometry, FlateDecode
/// (zlib) content stream compression, and a /Measure dictionary for real-world
/// measurement tools (Bluebeam Revu compatible).
///
/// ## Coordinate convention (IMPORTANT)
/// The engine stores all geometry in **Y-down** space: `DXFImporter.toVector`
/// negates DXF Y on import, and the renderer draws in Y-down screen space.
/// PDF user space is **Y-up**. The page-level CTM therefore flips Y
/// (`s 0 0 -s tx ty cm`). Without this flip the entire drawing renders
/// vertically mirrored — flipped text, mirrored title block, items on the
/// wrong side. This was the primary export bug.
///
/// ## Draw order
/// Entities are sorted by `xdata["dxf.drawOrder"]` with the same comparator
/// as `CADRendererBridge.computeSpecs`, so PDF stacking matches the screen.
/// (The previous implementation iterated `allLayers` — an unordered
/// dictionary — producing nondeterministic stacking.)
///
/// ## Text entities
/// Standalone TEXT/MTEXT entities carry their position/rotation in BOTH
/// `entity.transform` AND the `.text` primitive in `localGeometry` (see
/// `DXFImporter` entity creation). The renderer draws these from xdata +
/// transform and *skips* the geometry (`CADRendererBridge` `continue`s).
/// The old PDF path rendered the geometry under the entity CTM — a double
/// transform that placed every label at 2× its distance from the origin.
/// This exporter mirrors the renderer: text entities are exploded through
/// the same SHX font path (`CADFontManager` + `SHXShapeFont.renderText`)
/// into world-space line primitives, which also makes alignment, MTEXT
/// wrapping, and mirrored-placement behavior identical to the screen.
public enum PDFExporter {

    /// Acrobat / Bluebeam Revu hard page-size limit (200 in = 14,400 pt).
    /// Pages larger than this are silently clipped or rejected by viewers.
    private static let maxPagePoints: Double = 14_400

    // ---------------------------------------------------------------------
    // MARK: Render items (pre-pass output)
    // ---------------------------------------------------------------------

    /// A drawable unit in screen-parity order.
    enum RenderItem {
        /// Geometry entity (lines, arcs, blocks, hatches, …) drawn under its
        /// full affine transform.
        case geometry(entity: CADEntity, color: ColorRGBA, lineWeightMM: Double)
        /// Standalone TEXT/MTEXT entity pre-exploded to world-space SHX
        /// stroke primitives (renderer parity).
        case textStrokes(prims: [CADPrimitive], color: ColorRGBA)
        /// Standalone TEXT/MTEXT entity for which no SHX font could be
        /// loaded — emitted as a Standard-14 Helvetica text object.
        case textFallback(text: String, position: Vector3, rotation: Double,
                          height: Double, color: ColorRGBA)
    }

    // ---------------------------------------------------------------------
    // MARK: Public entry point
    // ---------------------------------------------------------------------

    /// Export the document to a PDF file. Page size is auto-computed from the
    /// drawing's bounding box and capped to the 14,400 pt viewer limit (the
    /// /Measure dictionary is kept consistent with the effective scale, so
    /// Bluebeam auto-calibration remains correct even when the page is
    /// fit-scaled down).
    public static func export(document: CADDocument, to url: URL, backgroundColor: ColorRGBA? = nil) throws {
        let pdfData = try generatePDF(document: document, backgroundColor: backgroundColor)
        try pdfData.write(to: url, options: .atomic)
    }

    /// Background-save: export from a snapshot with progress and cancellation.
    public static func export(snapshot: CADDocumentSnapshot, to url: URL,
                               backgroundColor: ColorRGBA? = nil,
                               progress: ((Float) -> Void)? = nil) throws {
        try Task.checkCancellation()
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)
        let pdfData = try generatePDF(document: tempDoc, backgroundColor: backgroundColor)
        try Task.checkCancellation()
        progress?(0.95)
        try atomicWrite(data: pdfData, to: url)
        progress?(0.99)
    }

    private static func atomicWrite(data: Data, to targetURL: URL) throws {
        let tmpURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try data.write(to: tmpURL, options: .atomic)

#if os(Windows)
        // replaceItemAt is not implemented in Foundation on Windows.
        // Fall back to remove-then-move (not atomic, but safe).
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)
#else
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        }
#endif
    }

    /// Generate PDF data from a document (extracted for reuse by both sync and async paths).
    static func generatePDF(document: CADDocument, backgroundColor: ColorRGBA?) throws -> Data {
        // Background and contrast adjustment:
        // Default PDF page background in viewers is white.
        let pageBg = backgroundColor ?? ColorRGBA.white
        let bgRf = Double(pageBg.r) / 255.0
        let bgGf = Double(pageBg.g) / 255.0
        let bgBf = Double(pageBg.b) / 255.0
        let bgLuminance = 0.2126 * bgRf + 0.7152 * bgGf + 0.0722 * bgBf
        let isLightBackground = bgLuminance >= 0.5

        // ---- Pre-pass: collect drawables in screen-parity order ----------
        let items = collectItems(document: document, isLightBackground: isLightBackground)

        // ---- World bounding box (engine Y-down space) ---------------------
        // Text-entity bounds come from the exploded glyph strokes; the cached
        // `worldBoundingBox` for those entities double-counts the position
        // (transform × absolute-position primitive) and would inflate the page.
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var hasGeom = false

        func grow(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            hasGeom = true
        }

        for item in items {
            switch item {
            case .geometry(let entity, _, _):
                if let bb = entity.worldBoundingBox {
                    grow(bb.min.x, bb.min.y); grow(bb.max.x, bb.max.y)
                }
            case .textStrokes(let prims, _):
                if let bb = primsBounds(prims) {
                    grow(bb.minX, bb.minY); grow(bb.maxX, bb.maxY)
                }
            case .textFallback(let text, let position, _, let height, _):
                // Rough extent: baseline-left origin, ~0.6·h average advance.
                let w = Double(text.count) * height * 0.6
                grow(position.x, position.y - height)
                grow(position.x + w, position.y + height)
            }
        }
        if !hasGeom { minX = 0; minY = 0; maxX = 100; maxY = 100 }

        let worldW = max(maxX - minX, 1e-9)
        let worldH = max(maxY - minY, 1e-9)
        let scale: Double
        let pageW: Double
        let pageH: Double
        let margin: Double

        if let layout = document.layoutSettings, layout.paperWidthMM > 0, layout.paperHeightMM > 0 {
            var pw = layout.paperWidthMM * 72.0 / 25.4
            var ph = layout.paperHeightMM * 72.0 / 25.4
            if layout.plotRotation == 1 || layout.plotRotation == 3 {
                swap(&pw, &ph)
            }
            pageW = max(pw, 10.0)
            pageH = max(ph, 10.0)
            margin = 0.0
            scale = min(pageW / worldW, pageH / worldH)
        } else {
            margin = 36.0
            (scale, pageW, pageH) = Self.pageScaleAndSize(
                worldW: worldW, worldH: worldH,
                pointsPerUnit: document.unit.pointsPerUnit, margin: margin)
        }
        let pw = Int(round(pageW)); let ph = Int(round(pageH))

        // /Measure conversion: world units per point at the *effective* scale.
        let measC = String(format: "%.6f", 1.0 / scale)
        let unitLabel = document.unit.description

        let w = PDFByteWriter()

        // PDF 1.7 header with binary marker bytes (required per spec)
        w.write("%PDF-1.7\n")
        // At least 4 binary bytes with high bit set to flag binary content
        w.write("%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")

        // Catalog (obj 1) with PDF 1.7 UseOutlines viewer preference
        w.beginObject(1)
        w.write("<< /Type /Catalog /Pages 3 0 R")
        w.write(" /ViewerPreferences << /PrintScaling /None /UseOutlines >> >>\n")
        w.endObject()

        // Page (obj 2)
        w.beginObject(2)
        w.write("<< /Type /Page /Parent 3 0 R /MediaBox [0 0 \(pw) \(ph)]")
        w.write(" /VP [ << /Type /Viewport /BBox [0 0 \(pw) \(ph)]")
        w.write("   /Measure << /Type /Measure /Subtype /RL")
        w.write("     /R (\(unitLabel))")
        w.write("     /X [ << /Type /NumberFormat /U (\(unitLabel)) /C \(measC) >> ]")
        w.write("   >> >> ]")
        w.write(" /Contents 4 0 R")
        w.write(" /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>\n")
        w.endObject()

        // Pages tree (obj 3)
        w.beginObject(3)
        w.write("<< /Type /Pages /Kids [2 0 R] /Count 1 >>\n")
        w.endObject()

        // Content stream (obj 4) — FlateDecode compressed via zlib-ng
        let content = PDFContentBuilder()
        if let bg = backgroundColor {
            content.raw("q\n")
            let r = Double(bg.r) / 255.0
            let g = Double(bg.g) / 255.0
            let b = Double(bg.b) / 255.0
            content.num(r); content.num(g); content.num(b); content.raw("rg\n")
            content.num(0); content.num(0); content.num(pageW); content.num(pageH); content.raw("re f\n")
            content.raw("Q\n")
        }
        writeContent(items: items, document: document, scale: scale, margin: margin,
                     minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                     pageW: pageW, pageH: pageH, isLightBackground: isLightBackground, to: content)
        w.beginObject(4)
        w.writeCompressedStream(content.build())
        w.endObject()

        // Fonts (obj 5, 6) — Standard 14 references
        writeFontRef(w, obj: 5, name: "Helvetica")
        writeFontRef(w, obj: 6, name: "Courier")

        return w.finalize(rootObj: 1)
    }

    // ---------------------------------------------------------------------
    // MARK: Page scale and size
    // ---------------------------------------------------------------------

    /// Page scale (points per world unit) and page size for a drawing extent.
    ///
    /// Starts at true unit scale (`pointsPerUnit`), scales DOWN so oversized
    /// drawings fit the viewer page limit, and scales UP so sub-letter
    /// drawings fill the minimum page instead of landing as a speck in the
    /// corner of a 612x792 sheet (paper-space layouts already at sheet size
    /// are unaffected — they already fill the page). Aspect ratio is always
    /// preserved; the `/Measure` dictionary is computed from the returned
    /// scale, so measurement calibration stays exact.
    static func pageScaleAndSize(worldW: Double, worldH: Double, pointsPerUnit: Double,
                                 margin: Double = 36)
        -> (scale: Double, pageW: Double, pageH: Double) {
        let minPageW = 612.0, minPageH = 792.0
        let w = max(worldW, 1e-9), h = max(worldH, 1e-9)
        var scale = pointsPerUnit
        if w * scale + margin * 2 > maxPagePoints || h * scale + margin * 2 > maxPagePoints {
            scale *= min((maxPagePoints - margin * 2) / (w * scale),
                         (maxPagePoints - margin * 2) / (h * scale))
        }
        if w * scale + margin * 2 < minPageW || h * scale + margin * 2 < minPageH {
            scale *= min((minPageW - margin * 2) / (w * scale),
                         (minPageH - margin * 2) / (h * scale))
        }
        return (scale,
                max(minPageW, w * scale + margin * 2),
                max(minPageH, h * scale + margin * 2))
    }

    // ---------------------------------------------------------------------
    // MARK: Pre-pass — entity collection (renderer parity)
    // ---------------------------------------------------------------------

    /// Sort entities exactly like `CADRendererBridge.computeSpecs`, resolve the
    /// per-entity color the same way (`dxf.color` xdata → layer color), and
    /// pre-explode text entities through the SHX path.
    static func collectItems(document: CADDocument, isLightBackground: Bool = false) -> [RenderItem] {
        let sortedEntities = document.entitiesView.sorted { e1, e2 in
            let o1 = e1.drawOrder
            let o2 = e2.drawOrder
            if o1 != o2 { return o1 < o2 }
            return e1.handle.uuidString < e2.handle.uuidString
        }

        var items: [RenderItem] = []
        items.reserveCapacity(sortedEntities.count)

        for entity in sortedEntities {
            guard let layer = document.layer(for: entity.layerID), layer.isVisible
            else { continue }

            // Entity color: explicit dxf.color override, else layer color.
            // (The old exporter scanned the first colored primitive — wrong
            // precedence, and wrong for multi-color blocks.)
            let rawColor: ColorRGBA
            if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv,
               let c = ColorRGBA(hex: hex) {
                rawColor = c
            } else {
                rawColor = layer.color
            }
            let entityColor = rawColor.displayAdjusted(forLightBackground: isLightBackground)

            // Explicit entity lineweight (mm), else layer lineweight.
            let lineWeightMM: Double
            if let lw = entity.xdata["dxf.lineWeight"], case .double(let v) = lw, v > 0 {
                lineWeightMM = v
            } else {
                lineWeightMM = layer.lineWeight
            }

            // ---- Standalone TEXT/MTEXT entity (renderer's visibleText path) ----
            if let tv = entity.xdata["dxf.text"], case .string(let text) = tv, !text.isEmpty {
                let formatted: FormattedText?
                if let ftJSON = entity.xdata["dxf.formattedText"], case .string(let jsonStr) = ftJSON,
                   let jsonData = jsonStr.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(FormattedText.self, from: jsonData) {
                    formatted = decoded
                } else {
                    formatted = nil
                }
                let displayText = formatted?.toPlainText() ?? text
                let height: Double
                if let th = entity.xdata["dxf.textHeight"], case .double(let v) = th { height = v }
                else { height = 2.5 }

                let styleName: String?
                if let ts = entity.xdata["dxf.textStyle"], case .string(let value) = ts {
                    styleName = value
                } else {
                    styleName = nil
                }
                let fontFile = CADFontManager.resolveTextStyleFont(
                    styleName: styleName,
                    textStyleFonts: document.textStyleFonts)
                let formattedSHXFont = CADFontManager.resolveFormattedSHXFont(
                    formatted,
                    styleName: styleName,
                    textStyleFonts: document.textStyleFonts)
                let shapeFont = formattedSHXFont
                    ?? CADFontManager.getOrLoadSHXFont(filename: fontFile)

                let alignH: Int
                if let ah = entity.xdata["dxf.alignH"], case .int(let v) = ah { alignH = v }
                else { alignH = 0 }
                let alignV: Int
                if let av = entity.xdata["dxf.alignV"], case .int(let v) = av { alignV = v }
                else { alignV = 0 }
                let mtextWidth: Double?
                if let mw = entity.xdata["dxf.mtextWidth"], case .double(let v) = mw { mtextWidth = v }
                else { mtextWidth = nil }

                if let font = shapeFont {
                    let lineSpacingFactor: Double
                    if let spacing = entity.xdata["dxf.mtextLineSpacing"],
                       case .double(let value) = spacing,
                       value > 0 {
                        lineSpacingFactor = value
                    } else {
                        lineSpacingFactor = 1.0
                    }
                    let lineSpacingStyle: Int
                    if let style = entity.xdata["dxf.mtextLineSpacingStyle"],
                       case .int(let value) = style,
                       value == 2 {
                        lineSpacingStyle = 2
                    } else {
                        lineSpacingStyle = 1
                    }
                    let prims: [CADPrimitive]
                    if let formatted {
                        prims = font.renderFormattedText(
                            formatted,
                            origin: entity.transform.position,
                            rotation: entity.transform.rotation,
                            alignH: alignH,
                            alignV: alignV,
                            maxWidth: mtextWidth,
                            lineSpacingFactor: lineSpacingFactor,
                            lineSpacingStyle: lineSpacingStyle,
                            textStyleFonts: document.textStyleFonts)
                    } else {
                        prims = font.renderText(
                            displayText,
                            origin: entity.transform.position,
                            height: height,
                            rotation: entity.transform.rotation,
                            alignH: alignH,
                            alignV: alignV,
                            maxWidth: mtextWidth)
                    }
                    items.append(.textStrokes(prims: prims, color: entityColor))
                } else {
                    items.append(.textFallback(
                        text: displayText,
                        position: entity.transform.position,
                        rotation: entity.transform.rotation,
                        height: height,
                        color: entityColor))
                }
                continue   // NEVER fall through to geometry — the .text primitive
                           // in localGeometry duplicates position/rotation.
            }

            guard entity.resolvedGeometry(in: document)?.isEmpty == false else { continue }
            if let array = entity.arrayData {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: document)
                let sourceBox = entity.blockID.flatMap { document.block(for: $0)?.localBoundingBox }
                for instance in array.evaluatedInstances(pathPoints: path) {
                    let virtual = CADEntity(
                        handle: entity.handle,
                        layerID: entity.layerID,
                        blockID: entity.blockID,
                        localGeometry: entity.localGeometry,
                        dimensionMetadata: entity.dimensionMetadata,
                        leaderData: entity.leaderData,
                        transform: entity.transform.multiplying(by: instance.transform),
                        xdata: entity.xdata,
                        drawOrder: entity.drawOrder,
                        localBoundingBox: sourceBox)
                    items.append(.geometry(
                        entity: virtual,
                        color: entityColor,
                        lineWeightMM: lineWeightMM))
                }
            } else {
                items.append(.geometry(entity: entity, color: entityColor, lineWeightMM: lineWeightMM))
            }
        }
        return items
    }

    // ---------------------------------------------------------------------
    // MARK: Content stream assembly
    // ---------------------------------------------------------------------

    static func writeContent(
        items: [RenderItem], document: CADDocument, scale: Double, margin: Double,
        minX: Double, maxX: Double = 0, minY: Double = 0, maxY: Double,
        pageW: Double = 0, pageH: Double = 0, isLightBackground: Bool = false,
        to cb: PDFContentBuilder
    ) {
        // Y-FLIPPING page CTM: engine Y-down → PDF Y-up.
        //   device.x =  scale * world.x + tx
        //   device.y = -scale * world.y + ty
        // World maxY (engine "bottom" of bbox) maps to the page bottom margin.
        let contentW = (maxX - minX) * scale
        let contentH = (maxY - minY) * scale
        let offsetX = margin > 0 ? margin : max(0.0, (pageW - contentW) * 0.5)
        let offsetY = margin > 0 ? margin : max(0.0, (pageH - contentH) * 0.5)
        let tx = offsetX - minX * scale
        let ty = offsetY + maxY * scale
        cb.num(scale); cb.num(0); cb.num(0); cb.num(-scale); cb.num(tx); cb.num(ty); cb.raw("cm\n")

        for item in items {
            switch item {
            case .geometry(let entity, let color, let lineWeightMM):
                PDFPrimitives.writeEntity(entity, in: document, entityColor: color,
                                          lineWeightMM: lineWeightMM, pageScale: scale,
                                          isLightBackground: isLightBackground, to: cb)
            case .textStrokes(let prims, let color):
                PDFPrimitives.writeWorldPrimitives(prims, defaultColor: color,
                                                   lineWeightMM: 0.25, pageScale: scale,
                                                   isLightBackground: isLightBackground, to: cb)
            case .textFallback(let text, let position, let rotation, let height, let color):
                cb.raw("q\n")
                PDFPrimitives.setColor(color.displayAdjusted(forLightBackground: isLightBackground), to: cb)
                PDFPrimitives.writeFallbackText(text, position: position, rotation: rotation,
                                                height: height, to: cb)
                cb.raw("Q\n")
            }
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Helpers
    // ---------------------------------------------------------------------

    /// Conservative world-space bounds over a primitive list. Used for
    /// exploded text strokes (lines / polygons / arcs).
    static func primsBounds(_ prims: [CADPrimitive])
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false

        func grow(_ v: Vector3) {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            any = true
        }

        for p in prims {
            switch p {
            case .point(let pos, _): grow(pos)
            case .line(let s, let e, _): grow(s); grow(e)
            case .rect(let o, let s, _), .fillRect(let o, let s, _):
                grow(o); grow(Vector3(x: o.x + s.x, y: o.y + s.y, z: o.z))
            case .polygon(let pts, _), .fillPolygon(let pts, _):
                for pt in pts { grow(pt) }
            case .polyline(let path, _):
                for point in path.boundingPoints() { grow(point) }
            case .fillComplexPolygon(let outer, let holes, _):
                for pt in outer { grow(pt) }
                for hole in holes { for pt in hole { grow(pt) } }
            case .circle(let c, let r, _), .arc(let c, let r, _, _, _):
                grow(Vector3(x: c.x - r, y: c.y - r, z: c.z))
                grow(Vector3(x: c.x + r, y: c.y + r, z: c.z))
            case .spline(let cps, _, _, _, _):
                for pt in cps { grow(pt) }
            case .penStroke(let vertices, _, _):
                for v in vertices { grow(v.position) }
            case .ellipse(let c, let major, _, _):
                let m = major.magnitude
                grow(Vector3(x: c.x - m, y: c.y - m, z: c.z))
                grow(Vector3(x: c.x + m, y: c.y + m, z: c.z))
            case .hatch(let boundary, _, _, _, _, _):
                for pt in boundary { grow(pt) }
            case .hatchPath(let boundary, let holes, _, _, _, _, _):
                for pt in boundary.boundingPoints() { grow(pt) }
                for hole in holes { for pt in hole.boundingPoints() { grow(pt) } }
            case .gradient(let outer, _, _, _, _, _):
                for pt in outer { grow(pt) }
            case .text(let pos, _, let h, _, _, _, _, _, _):
                grow(Vector3(x: pos.x - h, y: pos.y - h, z: pos.z))
                grow(Vector3(x: pos.x + h, y: pos.y + h, z: pos.z))
            case .ray(let start, _, _):
                grow(start)
            case .xline(let point, _, _):
                grow(point)
            case .table: break
            case .image(let insertion, let uAxis, let vAxis, _, _, _):
                grow(insertion)
                grow(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
                grow(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
                grow(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            }
        }
        return any ? (minX, minY, maxX, maxY) : nil
    }

    private static func writeFontRef(_ w: PDFByteWriter, obj: Int, name: String) {
        w.beginObject(obj)
        w.write("<< /Type /Font /Subtype /Type1 /BaseFont /\(name) >>\n")
        w.endObject()
    }
}