import Foundation

// =========================================================================
// MARK: - PDFPrimitives
//
// Defines the PDF drawing primitive types used by the PDF exporter.
// Abstracts away from the raw PDF content stream generation, providing
// a clean interface for emitting lines, polygons, text, and fills.

// =========================================================================
// MARK: - PDFPrimitives
// =========================================================================

/// Maps each `CADPrimitive` variant to PDF content stream operators.
/// All path coordinates are in entity-local space; the entity-level CTM and
/// the page-level (Y-flipping) CTM handle placement and unit conversion.
///
/// ## Entity transform (IMPORTANT)
/// The entity CTM is built from the transform's **basis vectors**
/// (`transformPoint` of origin / x̂ / ŷ), not from the
/// position/rotation/scale decomposition. `Transform3D.scale` returns column
/// *magnitudes* — always positive — so the previous decomposition destroyed
/// the negative-Y-scale mirror that `DXFImporter.insertTransform` bakes in
/// for `(0,0,-1)`-extrusion (OCS-mirrored) block inserts, and
/// `rotation = atan2(m10, m00)` on a mirrored matrix returns the wrong
/// angle. Result: mirrored blocks (stoves, fixtures) rendered flipped and on
/// the wrong side. The basis-vector form reproduces the exact affine map the
/// renderer applies through `transformPoint`, including mirror and skew.
///
/// ## Text
/// Text never goes through a (possibly mirrored) entity CTM. Like the
/// renderer (`CADPrimitiveGenerator` `.text` case), placement is computed in
/// world space from transformed basis vectors with positive height/width
/// scales, keeping glyphs readable under mirrored placements (MIRRTEXT=0
/// behavior), then exploded via the same SHX font path the screen uses.
enum PDFPrimitives {

    // ---------------------------------------------------------------------
    // MARK: Entity writer
    // ---------------------------------------------------------------------

    /// Write a geometry entity's primitives (resolving block references).
    /// Fills are emitted before strokes within the entity, matching the
    /// renderer's z-ordering (`CADRendererBridge` draws fills below strokes).
    static func writeEntity(_ entity: CADEntity, in document: CADDocument,
                            entityColor: ColorRGBA, lineWeightMM: Double,
                            pageScale: Double, to cb: PDFContentBuilder) {
        guard let geometry = entity.resolvedGeometry(in: document), !geometry.isEmpty
        else { return }

        // Split: fills first (renderer parity), text handled outside the CTM.
        var fills: [CADPrimitive] = []
        var strokes: [CADPrimitive] = []
        var texts: [CADPrimitive] = []
        for prim in geometry {
            switch prim {
            case .fillPolygon, .fillComplexPolygon, .gradient, .hatch, .fillRect, .image:
                fills.append(prim)
            case .text:
                texts.append(prim)
            default:
                strokes.append(prim)
            }
        }

        // Full affine from basis vectors — preserves mirror and skew.
        let t = entity.transform
        let o  = t.transformPoint(Vector3(x: 0, y: 0, z: 0))
        let ex = t.transformPoint(Vector3(x: 1, y: 0, z: 0)) - o
        let ey = t.transformPoint(Vector3(x: 0, y: 1, z: 0)) - o

        if !fills.isEmpty || !strokes.isEmpty {
            cb.raw("q ")
            cb.num(ex.x); cb.num(ex.y); cb.num(ey.x); cb.num(ey.y)
            cb.num(o.x); cb.num(o.y); cb.raw("cm\n")

            // Stroke width: target device points, expressed in the local user
            // space active at stroke time (page scale × entity scale).
            let entScale = max((ex.magnitude + ey.magnitude) / 2, 1e-9)
            let weightPt = max(lineWeightMM, 0.05) * 72.0 / 25.4
            cb.num(weightPt / (pageScale * entScale)); cb.raw("w\n")

            var currentColor: ColorRGBA? = nil
            for prim in fills + strokes {
                setColorIfNeeded(primColor(prim) ?? entityColor, current: &currentColor, to: cb)
                writePrimitive(prim, to: cb)
            }
            cb.raw("Q\n")
        }

        // Text rides outside the entity CTM so glyphs stay readable under
        // mirrored transforms — exactly the renderer's policy.
        for prim in texts {
            writeTextPrimitive(prim, transform: t, document: document,
                               entityColor: entityColor, lineWeightMM: lineWeightMM,
                               pageScale: pageScale, to: cb)
        }
    }

    /// Write pre-exploded world-space primitives (SHX text strokes) with no
    /// entity transform.
    static func writeWorldPrimitives(_ prims: [CADPrimitive], defaultColor: ColorRGBA,
                                     lineWeightMM: Double, pageScale: Double,
                                     to cb: PDFContentBuilder) {
        guard !prims.isEmpty else { return }
        cb.raw("q\n")
        let weightPt = max(lineWeightMM, 0.05) * 72.0 / 25.4
        cb.num(weightPt / pageScale); cb.raw("w\n")
        var currentColor: ColorRGBA? = nil
        for prim in prims {
            if case .text = prim { continue }   // SHX explosion never yields nested text
            setColorIfNeeded(primColor(prim) ?? defaultColor, current: &currentColor, to: cb)
            writePrimitive(prim, to: cb)
        }
        cb.raw("Q\n")
    }

    // ---------------------------------------------------------------------
    // MARK: Text primitive (block / inline text)
    // ---------------------------------------------------------------------

    /// Renderer-parity text placement: transform the insertion point and the
    /// local X/Y basis through the FULL entity matrix, derive world rotation
    /// from the transformed X direction and positive height/width scales from
    /// the basis magnitudes, then explode through the same SHX font the
    /// renderer would pick (`textStyleFonts[style] ?? "simplex.shx"`).
    private static func writeTextPrimitive(_ prim: CADPrimitive, transform: Transform3D,
                                           document: CADDocument, entityColor: ColorRGBA,
                                           lineWeightMM: Double, pageScale: Double,
                                           to cb: PDFContentBuilder) {
        guard case .text(let pos, let text, let height, let rotation, let style,
                         let alignH, let alignV, let mtextWidth, let color) = prim
        else { return }
        guard !text.isEmpty else { return }

        let origin = transform.transformPoint(pos)
        let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
        let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
        let worldX = transform.transformPoint(pos + localX) - origin
        let worldY = transform.transformPoint(pos + localY) - origin

        let finalRotation = atan2(worldX.y, worldX.x)
        let heightScale = max(worldY.magnitude, 1e-12)
        let widthScale = max(worldX.magnitude, 1e-12)
        let finalHeight = height * heightScale
        let finalMaxWidth = mtextWidth.map { $0 * widthScale }

        let resolvedColor = color ?? entityColor
        let fontFile = style.flatMap { document.textStyleFonts[$0] } ?? "simplex.shx"

        if let font = CADFontManager.getOrLoadSHXFont(filename: fontFile) {
            let glyphPrims = font.renderText(
                text,
                origin: origin,
                height: finalHeight,
                rotation: finalRotation,
                alignH: alignH,
                alignV: alignV,
                maxWidth: finalMaxWidth)
            writeWorldPrimitives(glyphPrims, defaultColor: resolvedColor,
                                 lineWeightMM: lineWeightMM, pageScale: pageScale, to: cb)
        } else {
            cb.raw("q\n")
            setColor(resolvedColor, to: cb)
            writeFallbackText(text, position: origin, rotation: finalRotation,
                              height: finalHeight, to: cb)
            cb.raw("Q\n")
        }
    }

    /// Standard-14 Helvetica fallback (no SHX font available).
    ///
    /// Engine coordinates are Y-down and the page CTM flips Y, so the text
    /// matrix is pre-mirrored (negative determinant) to make the composed
    /// device matrix orientation-preserving — i.e. upright, readable glyphs.
    /// Height is baked into the matrix; alignment offsets are not applied
    /// (this path is a last resort; simplex.shx ships with the app).
    static func writeFallbackText(_ text: String, position: Vector3, rotation: Double,
                                  height: Double, to cb: PDFContentBuilder) {
        let c = cos(rotation); let s = sin(rotation)
        cb.raw("BT /F1 1 Tf ")
        cb.num(height * c);  cb.num(height * s)     // a, b
        cb.num(height * s);  cb.num(-height * c)    // c, d  (pre-flip)
        cb.num(position.x);  cb.num(position.y)     // e, f
        cb.raw("Tm (\(escapePDFText(text))) Tj ET\n")
    }

    // ---------------------------------------------------------------------
    // MARK: Per-primitive writers
    // ---------------------------------------------------------------------

    static func writePrimitive(_ p: CADPrimitive, to cb: PDFContentBuilder) {
        switch p {
        case .point(let pos, _):
            let r: Double = 2
            cb.num(pos.x - r); cb.num(pos.y - r); cb.num(r*2); cb.num(r*2); cb.raw("re B\n")

        case .line(let start, let end, _):
            cb.num(start.x); cb.num(start.y); cb.raw("m ")
            cb.num(end.x);   cb.num(end.y);   cb.raw("l S\n")

        case .rect(let o, let s, _):
            cb.num(o.x); cb.num(o.y); cb.num(s.x); cb.num(s.y); cb.raw("re S\n")
        case .fillRect(let o, let s, _):
            cb.num(o.x); cb.num(o.y); cb.num(s.x); cb.num(s.y); cb.raw("re f\n")

        case .polygon(let pts, _):
            subpath(pts, close: true, to: cb)
            cb.raw("S\n")
        case .polyline(let path, _):
            subpath(path.tessellatedPoints(), close: false, to: cb)
            cb.raw("S\n")
        case .fillPolygon(let pts, _):
            subpath(pts, close: true, to: cb)
            cb.raw("f\n")

        case .fillComplexPolygon(let outer, let holes, _):
            // Build ALL loops as subpaths of ONE path, then a single even-odd
            // fill. (The old code stroked each loop with `S` — which CLEARS
            // the current path — and then issued `f*` on an empty path; holes
            // never punched and the fill never painted.) Even-odd matches the
            // renderer's even-odd nesting tessellation.
            subpath(outer, close: true, to: cb)
            for hole in holes { subpath(hole, close: true, to: cb) }
            cb.raw("f*\n")

        case .circle(let c, let r, _):
            writeCircleArc(center: c, radius: r, start: 0, end: 2 * .pi, to: cb)

        case .arc(let c, let r, let start, let end, _):
            writeCircleArc(center: c, radius: r, start: start, end: end, to: cb)

        case .ellipse(let center, let major, let ratio, _):
            let mx = major.magnitude; let my = mx * ratio
            let rot = atan2(major.y, major.x)
            cb.raw("q ")
            cb.num(cos(rot)); cb.num(sin(rot)); cb.num(-sin(rot)); cb.num(cos(rot))
            cb.num(center.x); cb.num(center.y); cb.raw("cm\n")
            writeEllipseBezier(rx: mx, ry: my, to: cb)
            cb.raw("S Q\n")

        case .spline(let cps, let knots, let deg, let weights, _):
            let pts = NURBSEvaluator.evaluateByKnotSpans(
                degree: deg, knots: knots, controlPoints: cps,
                weights: weights ?? Array(repeating: 1.0, count: cps.count), segmentsPerSpan: 12)
            guard pts.count >= 2 else { break }
            subpath(pts, close: false, to: cb)
            cb.raw("S\n")

        case .hatch(let boundary, let pat, let hatchScale, let hatchAngle, _, _):
            guard boundary.count >= 3 else { break }
            if pat.uppercased() == "SOLID" || pat.isEmpty {
                subpath(boundary, close: true, to: cb)
                cb.raw("f\n")
            } else {
                // Patterned hatch: use the same AutoCAD-style pattern registry
                // as the renderer so ANSI31-ANSI38, scale, angle, and dash segments
                // match the screen path.
                let adaptiveMinimumSpacing = DXFHatchGenerator.adaptiveMinimumSpacing(for: boundary)
                let hatchLines = DXFHatchGenerator.generatePatternHatch(
                    polygon: boundary,
                    patternName: pat,
                    scale: hatchScale,
                    angleDegrees: hatchAngle * 180.0 / .pi,
                    minimumSpacing: adaptiveMinimumSpacing
                )
                for hline in hatchLines {
                    switch hline {
                    case .line(let s, let e, _):
                        cb.num(s.x); cb.num(s.y); cb.raw("m ")
                        cb.num(e.x); cb.num(e.y); cb.raw("l S\n")
                    case .point(let p, _):
                        cb.num(p.x); cb.num(p.y); cb.raw("m ")
                        cb.num(p.x + 0.01); cb.num(p.y); cb.raw("l S\n")
                    default:
                        break
                    }
                }
                subpath(boundary, close: true, to: cb)
                cb.raw("S\n")
            }

        case .ray(let start, let dir, _):
            let mag = dir.magnitude
            guard mag > 1e-12 else { break }
            // Same 100,000-unit extension as the renderer; the page MediaBox
            // clips it, as the viewport does on screen.
            let far = Vector3(x: start.x + dir.x / mag * 100_000,
                              y: start.y + dir.y / mag * 100_000, z: 0)
            cb.num(start.x); cb.num(start.y); cb.raw("m ")
            cb.num(far.x); cb.num(far.y); cb.raw("l S\n")

        case .gradient(let outer, let holes, _, _, let c1, _):
            // Flat-fill approximation of the gradient (axial /Sh shading is a
            // possible future upgrade). Fill color is c1; holes punch via
            // even-odd, matching the on-screen silhouette.
            guard outer.count >= 3 else { break }
            let r = Double(c1.r)/255; let g = Double(c1.g)/255; let b = Double(c1.b)/255
            cb.num(r); cb.num(g); cb.num(b); cb.raw("rg ")
            subpath(outer, close: true, to: cb)
            for hole in holes { subpath(hole, close: true, to: cb) }
            cb.raw("f*\n")

        case .text:
            // Text is intercepted in writeEntity / writeWorldPrimitives and
            // never reaches the path writer (it must not be drawn under a
            // possibly-mirrored entity CTM).
            break
        case .image:
            // Images are written via PDFExporter.collectItems/writeContent with
            // image XObjects, not through the path writer.
            break
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Shared geometry helpers
    // ---------------------------------------------------------------------

    /// Emit a subpath (m / l … / optional h) WITHOUT a painting operator, so
    /// multiple loops can be combined into one path for even-odd fills.
    private static func subpath(_ pts: [Vector3], close: Bool, to cb: PDFContentBuilder) {
        guard let first = pts.first else { return }
        cb.num(first.x); cb.num(first.y); cb.raw("m ")
        for pt in pts.dropFirst() { cb.num(pt.x); cb.num(pt.y); cb.raw("l ") }
        if close { cb.raw("h ") }
    }

    /// Circular arc as cubic beziers.
    ///
    /// DXF arcs are CCW; the sweep is normalized exactly like the render path
    /// (`CADPrimitiveGenerator`: `if span < 0 { span += 2π }`). The previous
    /// implementation skipped normalization AND clamped `sin(halfAngle)` with
    /// `max(s, 1e-9)`: for any arc with end < start (e.g. a door swing
    /// crossing 0°) the half-angle went negative, the clamp kicked in, and the
    /// bezier handle length blew up to ~radius·10¹⁰ — the stray lines shooting
    /// across the exported page. The handle length here is the exact
    /// `(4/3)·tan(δ/4)·r` form, well-defined for δ ≤ π/2 per segment.
    private static func writeCircleArc(center: Vector3, radius: Double,
                                       start: Double, end: Double, to cb: PDFContentBuilder) {
        var span = end - start
        if span < 0 { span += 2.0 * .pi }
        guard span > 1e-12, radius > 1e-12 else { return }

        let segs = max(1, Int(ceil(span / (.pi / 2))))
        let delta = span / Double(segs)
        let h = (4.0 / 3.0) * tan(delta / 4.0) * radius

        let x0 = center.x + radius * cos(start)
        let y0 = center.y + radius * sin(start)
        cb.num(x0); cb.num(y0); cb.raw("m ")

        for i in 0..<segs {
            let a0 = start + delta * Double(i)
            let a1 = a0 + delta
            let p1x = center.x + radius * cos(a1)
            let p1y = center.y + radius * sin(a1)
            // CCW tangents: (-sin a, cos a)
            cb.num(center.x + radius * cos(a0) - h * sin(a0))
            cb.num(center.y + radius * sin(a0) + h * cos(a0))
            cb.num(p1x + h * sin(a1))
            cb.num(p1y - h * cos(a1))
            cb.num(p1x); cb.num(p1y); cb.raw("c ")
        }
        cb.raw("S\n")
    }

    private static func writeEllipseBezier(rx: Double, ry: Double, to cb: PDFContentBuilder) {
        let k: Double = 0.5522847498
        cb.num(rx); cb.num(0); cb.raw("m ")
        cb.num(rx); cb.num(ry*k); cb.num(rx*k); cb.num(ry); cb.num(0); cb.num(ry); cb.raw("c ")
        cb.num(-rx*k); cb.num(ry); cb.num(-rx); cb.num(ry*k); cb.num(-rx); cb.num(0); cb.raw("c ")
        cb.num(-rx); cb.num(-ry*k); cb.num(-rx*k); cb.num(-ry); cb.num(0); cb.num(-ry); cb.raw("c ")
        cb.num(rx*k); cb.num(-ry); cb.num(rx); cb.num(-ry*k); cb.num(rx); cb.num(0); cb.raw("c ")
    }

    // ---------------------------------------------------------------------
    // MARK: Color / misc helpers
    // ---------------------------------------------------------------------

    /// Per-primitive color override, mirroring `CADPrimitiveGenerator`'s
    /// `finalColor = primColor ?? entityColor`.
    private static func primColor(_ p: CADPrimitive) -> ColorRGBA? {
        switch p {
        case .point(_, let c), .circle(_, _, let c), .ellipse(_, _, _, let c):
            return c
        case .line(_, _, let c), .rect(_, _, let c), .fillRect(_, _, let c):
            return c
        case .polygon(_, let c), .polyline(_, let c), .fillPolygon(_, let c):
            return c
        case .fillComplexPolygon(_, _, let c):
            return c
        case .arc(_, _, _, _, let c):
            return c
        case .spline(_, _, _, _, let c):
            return c
        case .text(_, _, _, _, _, _, _, _, let c):
            return c
        case .hatch(_, _, _, _, let c, _):
            return c
        case .ray(_, _, let c):
            return c
        case .gradient(_, _, _, _, let c1, _):
            return c1
        case .image(_, _, _, _, _, let c):
            return c
        }
    }

    static func setColor(_ color: ColorRGBA, to cb: PDFContentBuilder) {
        let r = Double(color.r)/255; let g = Double(color.g)/255; let b = Double(color.b)/255
        cb.num(r); cb.num(g); cb.num(b); cb.raw("RG ")
        cb.num(r); cb.num(g); cb.num(b); cb.raw("rg\n")
    }

    private static func setColorIfNeeded(_ color: ColorRGBA, current: inout ColorRGBA?,
                                         to cb: PDFContentBuilder) {
        guard current != color else { return }
        setColor(color, to: cb)
        current = color
    }

    fileprivate static func escapePDFText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "(", with: "\\(")
         .replacingOccurrences(of: ")", with: "\\)")
         .replacingOccurrences(of: "\r", with: "")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}