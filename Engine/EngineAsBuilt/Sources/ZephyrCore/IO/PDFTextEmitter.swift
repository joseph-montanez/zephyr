import Foundation

// =========================================================================
// MARK: - PDFTextEmitter
//
// Shared TrueType text pipeline for PDF export: resolution, layout, and
// emission. Both standalone TEXT/MTEXT entities (`PDFExporter.collectItems`)
// and block-nested `.text` primitives (`PDFPrimitives.writeTextPrimitive`)
// flow through here so the PDF wraps, aligns, and spaces text exactly one
// way — measured with real TTF advances via `CADTrueTypeFont`.
//
// Layout reuses `CADTextFormatter.layout` with the same inputs the screen
// renderer uses (formatted paragraphs, reference width, alignment, line
// spacing), so line breaks match the canvas. Emission is live,
// per-line PDF text (`Tj`) against embedded or referenced CID fonts.

enum PDFTextEmitter {

    // ---------------------------------------------------------------------
    // MARK: Resolved faces
    // ---------------------------------------------------------------------

    /// A TTF face file selected for a run of text.
    struct ResolvedFace: Sendable {
        var font: CADTrueTypeFont
        var path: String
        /// True when the requested face was missing and a look-alike file
        /// (e.g. Arial for Arial Narrow) was substituted. The export must
        /// warn, and reference (not embed) under the requested name.
        var substituted: Bool
        /// True when bold was requested but no bold face file exists;
        /// emission double-strikes the run instead.
        var simulatedBold: Bool
    }

    /// Stem keys identify the same face across AutoCAD display names
    /// ("Arial Narrow") and file names ("ARIALN.TTF"): extensions are
    /// stripped, width words compress to initials, and style words drop.
    /// "Arial" vs "Arial Narrow" must NOT match (different families), so
    /// compression (not prefix chopping) drives the comparison.
    private static func isSameFace(requested: String, resolvedFile: String) -> Bool {
        func stemKey(_ s: String) -> String {
            var w = s.lowercased().filter { $0.isLetter || $0.isNumber }
            for ext in ["ttf", "otf", "ttc"] where w.hasSuffix(ext) {
                w = String(w.dropLast(ext.count))
                break
            }
            w = w.replacingOccurrences(of: "narrow", with: "n")
            w = w.replacingOccurrences(of: "condensed", with: "c")
            for style in ["bolditalic", "bold", "italic", "regular"] where w.hasSuffix(style) {
                w = String(w.dropLast(style.count))
            }
            // Known vendor abbreviations.
            if w == "lucidaconsole" { return "lucon" }
            return w
        }
        let want = stemKey(requested)
        let got = stemKey(resolvedFile)
        return !want.isEmpty && want == got
    }

    /// Resolve a font reference (MTEXT `\f` name, style name, or file name)
    /// to a loadable TTF face, following the style map first.
    static func resolveFace(
        reference: String?,
        styleName: String?,
        textStyleFonts: [String: String],
        bold: Bool = false,
        italic: Bool = false
    ) -> ResolvedFace? {
        let ref: String
        if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ref = reference
        } else if let styleName, !styleName.isEmpty {
            ref = styleName
        } else {
            return nil
        }
        let filename = CADFontManager.resolveFontReference(
            ref, textStyleFonts: textStyleFonts, fallback: "")
        guard !filename.isEmpty else { return nil }
        // Try the literal name, then spaceless/file-like variants so
        // display names ("Arial Narrow") resolve to the same file as
        // DXF file names ("ARIALN.TTF") instead of embedding both.
        var queries = [filename]
        let compact = filename.filter { $0.isLetter || $0.isNumber }
        if !compact.isEmpty, compact.caseInsensitiveCompare(filename) != .orderedSame {
            queries.append(compact)
            queries.append(compact + ".TTF")
        }
        let compactLower = compact.lowercased()
        if compactLower.hasPrefix("arialn") {
            queries.append("ARIALN.TTF")
        } else if compactLower.hasPrefix("lucon") || compactLower.hasPrefix("lucidaconsole") {
            queries.append("lucon.TTF")
        }
        // Two passes: an exact face match for ANY query spelling wins
        // over a substitute file for an earlier spelling.
        var path: String? = nil
        var exact = false
        for query in queries {
            guard let found = CADFontManager.getTTFEquivalent(filename: query) else { continue }
            let base = URL(fileURLWithPath: found).lastPathComponent
            if isSameFace(requested: filename, resolvedFile: base)
                || base.lowercased() == filename.lowercased()
                || isSameFace(requested: query, resolvedFile: base) {
                path = found
                exact = true
                break
            }
            if path == nil {
                path = found // substitute candidate; keep looking for exact
            }
        }
        guard let path else { return nil }
        if !exact {
            // A substitute file (e.g. Arial for Arial Narrow): usable for
            // metrics and named references, never embedded as the face.
            guard let font = CADFontManager.getOrLoadTTFFont(path: path) else { return nil }
            return ResolvedFace(font: font, path: path, substituted: true, simulatedBold: bold)
        }
        let facePath = CADFontManager.resolveStyledTTFPath(
            basePath: path, bold: bold, italic: italic)
        let simulatedBold = bold && facePath == path
        guard let font = CADFontManager.getOrLoadTTFFont(path: facePath) else { return nil }
        return ResolvedFace(font: font, path: facePath, substituted: false, simulatedBold: simulatedBold)
    }

    // ---------------------------------------------------------------------
    // MARK: Layout
    // ---------------------------------------------------------------------

    struct Segment: Sendable {
        var face: ResolvedFace
        /// Unicode scalars in visual order.
        var scalars: [UInt32]
        /// Glyph IDs (CIDs) parallel to scalars.
        var cids: [Int]
        /// Advance width in em (sum of glyph advances, no width factor).
        var widthEm: Double
    }

    struct Line: Sendable {
        var segments: [Segment]
        /// Baseline start in world coordinates (alignment applied).
        var origin: Vector3
        /// Underline spans: world offset along the baseline + world width.
        var underlines: [(x: Double, width: Double)]
    }

    struct LaidText: Sendable {
        var lines: [Line]
        var blockHeight: Double
        /// World units per em (drives the PDF font size).
        var emWorld: Double
        /// Cap ascent/descent in world units (bounds + baseline math).
        var ascentWorld: Double
        var descentWorld: Double
        /// Scalars used per font file (drives ToUnicode maps).
        var usedScalars: [String: Set<UInt32>]
    }

    /// One live-text run for the PDF content stream: laid-out lines plus
    /// the placement inputs emission needs.
    struct EmbeddedItem: Sendable {
        var laid: LaidText
        /// Requested face name for the PDF BaseFont (run font or style).
        var displayName: String
        var rotation: Double
        var widthFactor: Double
        var obliqueDegrees: Double
        var color: ColorRGBA

        /// Conservative world-space bounds over all lines.
        func bounds() -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
            guard !laid.lines.isEmpty else { return nil }
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            func grow(_ x: Double, _ y: Double) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            for line in laid.lines {
                let widthWorld = line.segments.reduce(0.0) { $0 + $1.widthEm }
                    * laid.emWorld * max(widthFactor, 1e-9)
                let ex = line.origin.x + cosR * widthWorld
                let ey = line.origin.y + sinR * widthWorld
                // Below-baseline normal (Y-down): descenders hang +normal.
                let nx = -sinR, ny = cosR
                grow(line.origin.x - nx * laid.ascentWorld,
                     line.origin.y - ny * laid.ascentWorld)
                grow(ex + nx * laid.descentWorld, ey + ny * laid.descentWorld)
            }
            guard minX.isFinite else { return nil }
            return (minX, minY, maxX, maxY)
        }
    }

    /// Lay out formatted or plain text exactly like the screen: same
    /// `CADTextFormatter.layout` call, same reference width, same
    /// paragraph alignment and line-spacing inputs. Widths are measured
    /// with the base TTF face — the screen measures layout with the base
    /// SDL_ttf font too, then renders per-run styled faces.
    static func layout(
        formatted: FormattedText?,
        plainText: String,
        origin: Vector3,
        rotation: Double,
        heightWorld: Double,
        widthFactor: Double,
        maxWidthWorld: Double?,
        alignH: Int,
        alignV: Int,
        lineSpacingFactor: Double,
        lineSpacingStyle: Int,
        baseFace: ResolvedFace
    ) -> LaidText {
        let font = baseFace.font
        let upm = Double(font.unitsPerEm)
        let emWorld = heightWorld * upm / max(1.0, Double(font.capHeightUnits))
        let wf = max(widthFactor, 1e-9)
        func measureWorld(_ s: String) -> Double {
            font.widthEm(of: s) * emWorld * wf
        }

        let lines: [CADTextFormatter.Line]
        if let formatted {
            lines = CADTextFormatter.layout(
                formatted: formatted,
                maxWidth: maxWidthWorld,
                measure: measureWorld)
        } else {
            lines = CADTextFormatter.layout(
                plainText,
                maxWidth: maxWidthWorld,
                measure: measureWorld)
        }

        let naturalHeight = emWorld
            * Double(font.ascentUnits - font.descentUnits + font.lineGapUnits) / upm
        let requested = heightWorld * (5.0 / 3.0) * max(lineSpacingFactor, 0.01)
        let lineAdvance = lineSpacingStyle == 2 ? requested : max(requested, naturalHeight)
        let capTopWorld = emWorld
            * Double(max(0, font.ascentUnits - font.capHeightUnits)) / upm
        let ascentWorld = emWorld * Double(font.ascentUnits) / upm
        let blockHeight = Double(max(lines.count, 1) - 1) * lineAdvance + naturalHeight

        let baseY: Double
        if alignH == 4 {
            baseY = -blockHeight * 0.5
        } else {
            switch alignV {
            case 1: baseY = -blockHeight
            case 2, 4: baseY = -blockHeight * 0.5
            case 3: baseY = -capTopWorld
            default: baseY = -heightWorld
            }
        }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        func worldPoint(localX: Double, localY: Double) -> Vector3 {
            Vector3(
                x: origin.x + localX * cosR - localY * sinR,
                y: origin.y + localX * sinR + localY * cosR,
                z: origin.z)
        }

        func horizontalOffset(line: CADTextFormatter.Line, lineWidthWorld: Double) -> Double {
            let hasParagraphAlignment = line.alignment != 0
            let paragraphAlignment = hasParagraphAlignment ? line.alignment : alignH
            let effectiveAlignment: Int
            if hasParagraphAlignment {
                effectiveAlignment = paragraphAlignment == 5 ? 0 : paragraphAlignment
            } else if alignH == 3 || alignH == 5 {
                effectiveAlignment = 1
            } else {
                effectiveAlignment = alignH
            }
            if hasParagraphAlignment, let maxWidthWorld, maxWidthWorld > 0 {
                let referenceBoxLeft: Double
                switch alignH {
                case 1, 4: referenceBoxLeft = -maxWidthWorld * 0.5
                case 2: referenceBoxLeft = -maxWidthWorld
                default: referenceBoxLeft = 0
                }
                switch effectiveAlignment {
                case 1, 4:
                    return referenceBoxLeft + (maxWidthWorld - lineWidthWorld) * 0.5
                case 2:
                    return referenceBoxLeft + maxWidthWorld - lineWidthWorld
                default:
                    return referenceBoxLeft
                }
            }
            switch effectiveAlignment {
            case 1, 4: return -lineWidthWorld * 0.5
            case 2: return -lineWidthWorld
            default: return 0
            }
        }

        var out: [Line] = []
        var used: [String: Set<UInt32>] = [:]
        for (lineIndex, line) in lines.enumerated() {
            guard !line.glyphs.isEmpty else { continue }
            // Group contiguous glyphs by styled face (bold/italic runs).
            var segments: [Segment] = []
            for glyph in line.glyphs {
                for scalar in glyph.text.unicodeScalars {
                    let face: ResolvedFace
                    if glyph.bold || glyph.italic {
                        let styledPath = CADFontManager.resolveStyledTTFPath(
                            basePath: baseFace.path, bold: glyph.bold, italic: glyph.italic)
                        if styledPath != baseFace.path,
                           let styled = CADFontManager.getOrLoadTTFFont(path: styledPath) {
                            face = ResolvedFace(
                                font: styled, path: styledPath,
                                substituted: baseFace.substituted, simulatedBold: false)
                        } else {
                            // No styled face file: italic degrades silently,
                            // bold double-strikes at emission.
                            face = ResolvedFace(
                                font: baseFace.font, path: baseFace.path,
                                substituted: baseFace.substituted,
                                simulatedBold: glyph.bold)
                        }
                    } else {
                        face = baseFace
                    }
                    let value = scalar.value
                    let gid = face.font.glyphID(for: scalar)
                    let adv = Double(face.font.advanceWidth(glyphID: gid)) / upm
                    if let last = segments.last, last.face.path == face.path,
                       last.face.simulatedBold == face.simulatedBold {
                        segments[segments.count - 1].scalars.append(value)
                        segments[segments.count - 1].cids.append(gid)
                        segments[segments.count - 1].widthEm += adv
                    } else {
                        segments.append(Segment(
                            face: face, scalars: [value], cids: [gid],
                            widthEm: adv))
                    }
                    used[face.path, default: []].insert(value)
                }
            }
            let lineWidthWorld = segments.reduce(0.0) { $0 + $1.widthEm } * emWorld * wf
            let offsetX = horizontalOffset(line: line, lineWidthWorld: lineWidthWorld)
            let baselineLocal = baseY + Double(lineIndex) * lineAdvance + ascentWorld
            let ranges = CADTextFormatter.underlineRanges(for: line, measure: measureWorld)
            out.append(Line(
                segments: segments,
                origin: worldPoint(localX: offsetX, localY: baselineLocal),
                underlines: ranges))
        }
        let descentWorld = emWorld * Double(-min(0, font.descentUnits)) / upm
        return LaidText(
            lines: out, blockHeight: blockHeight, emWorld: emWorld,
            ascentWorld: ascentWorld, descentWorld: descentWorld, usedScalars: used)
    }

    // ---------------------------------------------------------------------
    // MARK: Emission (live vector text)
    // ---------------------------------------------------------------------

    /// Emit laid-out text as per-line PDF text objects against CID fonts.
    /// One `Tj` per styled segment; bold without a face file double-strikes.
    static func emit(
        _ laid: LaidText,
        displayName: String,
        rotation: Double,
        widthFactor: Double,
        obliqueDegrees: Double,
        color: ColorRGBA,
        options: PDFExporter.PDFExportOptions,
        catalog: PDFFontCatalog,
        to cb: PDFContentBuilder
    ) {
        guard !laid.lines.isEmpty else { return }
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let wf = max(widthFactor, 1e-9)
        let k = tan(obliqueDegrees * .pi / 180.0)
        let em = laid.emWorld
        cb.raw("q\n")
        PDFPrimitives.setColor(color, to: cb)
        for line in laid.lines {
            var cursor = 0.0 // world units along the baseline from line origin
            for seg in line.segments {
                let num = catalog.register(
                    face: seg.face, displayName: displayName,
                    captureOn: options.captureFonts,
                    scalars: Set(seg.scalars))
                let segWidthWorld = seg.widthEm * em * wf
                let x = line.origin.x + cosR * cursor
                let y = line.origin.y + sinR * cursor
                emitSegment(
                    num: num, cids: seg.cids, em: em, wf: wf, k: k,
                    cosR: cosR, sinR: sinR, x: x, y: y, to: cb)
                if seg.face.simulatedBold {
                    emitSegment(
                        num: num, cids: seg.cids, em: em, wf: wf, k: k,
                        cosR: cosR, sinR: sinR,
                        x: x + 0.02 * em * cosR, y: y + 0.02 * em * sinR, to: cb)
                }
                cursor += segWidthWorld
            }
            // Underline spans ride below the baseline, along its direction.
            if !line.underlines.isEmpty {
                let gap = max(0.025 * em, 0.02)
                let thick = max(0.012 * em, 0.01)
                let nx = -sinR, ny = cosR // below-baseline normal (Y-down)
                for span in line.underlines {
                    let x0 = line.origin.x + cosR * span.x + nx * gap
                    let y0 = line.origin.y + sinR * span.x + ny * gap
                    let x1 = x0 + cosR * span.width
                    let y1 = y0 + sinR * span.width
                    let x2 = x1 + nx * thick
                    let y2 = y1 + ny * thick
                    let x3 = x0 + nx * thick
                    let y3 = y0 + ny * thick
                    cb.num(x0); cb.num(y0); cb.raw("m ")
                    cb.num(x1); cb.num(y1); cb.raw("l ")
                    cb.num(x2); cb.num(y2); cb.raw("l ")
                    cb.num(x3); cb.num(y3); cb.raw("l h f\n")
                }
            }
        }
        cb.raw("Q\n")
    }

    // ---------------------------------------------------------------------
    // MARK: Convert to geometry (outlines)
    // ---------------------------------------------------------------------

    /// Explode laid-out text to filled world-space polygons (AutoCAD
    /// "Convert all text to geometry"). Quadratics are flattened to line
    /// segments; contours are grouped into outers + holes by nesting depth
    /// and filled even-odd, matching the renderer's tessellation.
    static func geometryOutlines(
        _ laid: LaidText, rotation: Double, widthFactor: Double, obliqueDegrees: Double
    ) -> [CADPrimitive] {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let wf = max(widthFactor, 1e-9)
        let k = tan(obliqueDegrees * .pi / 180.0)
        let em = laid.emWorld
        var out: [CADPrimitive] = []
        for line in laid.lines {
            var cursor = 0.0
            for seg in line.segments {
                let upm = Double(seg.face.font.unitsPerEm)
                let s = em / upm
                for (ci, cid) in seg.cids.enumerated() {
                    _ = ci
                    guard let outline = seg.face.font.outline(glyphID: cid),
                          !outline.contours.isEmpty else {
                        cursor += Double(seg.face.font.advanceWidth(glyphID: cid)) / upm * em * wf
                        continue
                    }
                    let adv = Double(outline.advance) / upm * em * wf
                    // Flatten each contour to world-space loops.
                    var loops: [[Vector3]] = []
                    for contour in outline.contours {
                        let flat = flattenContour(contour)
                        guard flat.count >= 3 else { continue }
                        loops.append(flat.map { pt in
                            // Glyph space is y-up; world text space is y-down.
                            let lx = (pt.x * wf + pt.y * k) * s + cursor
                            let ly = -pt.y * s
                            return Vector3(
                                x: line.origin.x + lx * cosR - ly * sinR,
                                y: line.origin.y + lx * sinR + ly * cosR,
                                z: line.origin.z)
                        })
                    }
                    out.append(contentsOf: groupContours(loops))
                    cursor += adv
                }
            }
        }
        return out
    }

    /// Flatten one TrueType contour (on/off-curve points, implicitly
    /// closed) to a point loop, converting quadratics to line segments.
    private static func flattenContour(_ contour: CADTrueTypeFont.Contour) -> [(x: Double, y: Double)] {
        let pts = contour.points
        guard !pts.isEmpty else { return [] }
        // Expand implied on-curve midpoints between consecutive off-curves.
        var expanded: [(p: (x: Double, y: Double), on: Bool)] = []
        let n = pts.count
        for i in 0..<n {
            expanded.append((pts[i], contour.onCurve[i]))
            let j = (i + 1) % n
            if !contour.onCurve[i] && !contour.onCurve[j] {
                expanded.append((
                    ((pts[i].x + pts[j].x) * 0.5, (pts[i].y + pts[j].y) * 0.5), true))
            }
        }
        guard let start = expanded.firstIndex(where: { $0.on }) else { return [] }
        var out: [(x: Double, y: Double)] = []
        var i = start
        var pen = expanded[start].p
        out.append(pen)
        var guard_ = 0
        while guard_ < expanded.count * 2 + 4 {
            guard_ += 1
            let next = expanded[(i + 1) % expanded.count]
            if next.on {
                pen = next.p
                out.append(pen)
                i = (i + 1) % expanded.count
                if i == start { break }
            } else {
                let after = expanded[(i + 2) % expanded.count]
                guard after.on else { break }
                let ctrl = next.p
                let end = after.p
                // 8 subdivisions per quadratic span.
                for step in 1...8 {
                    let t = Double(step) / 8.0
                    let mt = 1 - t
                    out.append((
                        x: mt * mt * pen.x + 2 * mt * t * ctrl.x + t * t * end.x,
                        y: mt * mt * pen.y + 2 * mt * t * ctrl.y + t * t * end.y))
                }
                pen = end
                i = (i + 2) % expanded.count
                if i == start { break }
            }
        }
        return out
    }

    /// Group flattened loops into outer + holes by nesting depth
    /// (even-odd), one `fillComplexPolygon` per outer loop.
    private static func groupContours(_ loops: [[Vector3]]) -> [CADPrimitive] {
        guard !loops.isEmpty else { return [] }
        func contains(_ outer: [Vector3], _ pt: Vector3) -> Bool {
            var inside = false
            var j = outer.count - 1
            for i in 0..<outer.count {
                let a = outer[i], b = outer[j]
                if (a.y > pt.y) != (b.y > pt.y),
                   pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
        // Depth = number of other loops containing this loop's first point.
        var depthOf = [Int](repeating: 0, count: loops.count)
        for i in loops.indices {
            guard let probe = loops[i].first else { continue }
            for j in loops.indices where j != i {
                if contains(loops[j], probe) { depthOf[i] += 1 }
            }
        }
        var out: [CADPrimitive] = []
        for i in loops.indices where depthOf[i] % 2 == 0 {
            var holes: [[Vector3]] = []
            for j in loops.indices where depthOf[j] == depthOf[i] + 1 {
                if let probe = loops[j].first, contains(loops[i], probe) {
                    holes.append(loops[j])
                }
            }
            out.append(.fillComplexPolygon(outer: loops[i], holes: holes, color: nil))
        }
        return out
    }

    // ---------------------------------------------------------------------
    // MARK: Hidden searchable text (EPDFSHX)
    // ---------------------------------------------------------------------

    /// Emit invisible (render mode 3) WinAnsi text over SHX stroke geometry
    /// so SHX labels stay searchable. One `Tj` per paragraph at the entity
    /// origin — positioning is approximate (the text is invisible), but the
    /// character content is exact for the Latin-1 subset; other scalars
    /// degrade to spaces.
    static func emitHiddenText(
        _ text: String, position: Vector3, rotation: Double, height: Double,
        to cb: PDFContentBuilder
    ) {
        let c = cos(rotation); let s = sin(rotation)
        let paragraphs = text.components(separatedBy: "\n")
        cb.raw("q\n")
        for (index, paragraph) in paragraphs.enumerated() {
            // Stack paragraphs downward one cap height apart (Y-down).
            let x = position.x + s * Double(index) * height * 1.0
            let y = position.y + c * Double(index) * height * 1.0
            cb.raw("BT /F1 1 Tf 3 Tr ")
            cb.num(height * c); cb.num(height * s)
            cb.num(height * s); cb.num(-height * c)
            cb.num(x); cb.num(y)
            cb.raw("Tm (")
            cb.rawBytes(winAnsiBytes(paragraph))
            cb.raw(") Tj ET\n")
        }
        // `Tr` persists across text objects — reset so later live text
        // is not swallowed into invisibility.
        cb.raw("0 Tr\n")
        cb.raw("Q\n")
    }

    /// Latin-1 subset of WinAnsi; everything else becomes a space.
    static func winAnsiBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let byte: UInt8
            switch v {
            case 32...126, 160...172, 174...255:
                byte = UInt8(v & 0xFF)
            case 173: // soft hyphen: drop
                continue
            default:
                byte = 32
            }
            if byte == 0x28 || byte == 0x29 || byte == 0x5C {
                out.append(0x5C)
            }
            out.append(byte)
        }
        return out
    }

    private static func emitSegment(
        num: Int, cids: [Int], em: Double, wf: Double, k: Double,
        cosR: Double, sinR: Double, x: Double, y: Double,
        to cb: PDFContentBuilder
    ) {
        // Tm carries rotation/position at unit scale; Tf carries the
        // size (single-scale recipe — viewers apply both, so the size
        // must live in exactly one of them). The width factor rides the
        // Tm x-axis, which scales advances identically to `Tz`.
        cb.raw("BT /F\(num) ")
        cb.num(em); cb.raw("Tf ")
        cb.num(wf * cosR); cb.num(wf * sinR)
        cb.num(sinR + cosR * k); cb.num(-(cosR - sinR * k))
        cb.num(x); cb.num(y)
        cb.raw("Tm <")
        for cid in cids {
            cb.raw(String(format: "%04X", min(max(cid, 0), 0xFFFF)))
        }
        cb.raw("> Tj ET\n")
    }

    // ---------------------------------------------------------------------
    // MARK: Font catalog (object numbers + font dictionaries)
    // ---------------------------------------------------------------------

    /// Per-export registry of TTF faces: assigns `/F` numbers during
    /// emission, then writes the Type0/CIDFontType2/FontDescriptor/
    /// FontFile2/ToUnicode objects. Object order in the file is arbitrary,
    /// so numbers are stable by the time the page Resources dict is built.
    final class PDFFontCatalog: @unchecked Sendable {
        enum Mode { case embedded, referenced }

        struct Entry {
            var type0: Int
            var cid: Int
            var descriptor: Int
            var toUnicode: Int
            var file: Int
            var font: CADTrueTypeFont
            var baseName: String
            var mode: Mode
            var used: Set<UInt32>
        }

        private(set) var entries: [String: Entry] = [:]
        var nextNumber: Int

        init(firstNumber: Int = 7) {
            nextNumber = firstNumber
        }

        /// Register a face use; returns the Type0 `/F` number.
        func register(
            face: ResolvedFace, displayName: String,
            captureOn: Bool, scalars: Set<UInt32>
        ) -> Int {
            if var existing = entries[face.path] {
                existing.used.formUnion(scalars)
                if captureOn, !face.substituted, face.font.embeddingAllowed {
                    existing.mode = .embedded
                }
                entries[face.path] = existing
                return existing.type0
            }
            // Same face from a different file copy: reuse the first
            // embedded object instead of writing the font twice.
            let print = face.font.fingerprint
            if let key = entries.first(where: { $0.value.font.fingerprint == print })?.key {
                var existing = entries[key]!
                existing.used.formUnion(scalars)
                entries[key] = existing
                entries[face.path] = existing
                return existing.type0
            }
            let t = nextNumber; nextNumber += 5
            let base = CADTrueTypeFont.sanitizePostScriptName(displayName)
            let mode: Mode = (captureOn && !face.substituted && face.font.embeddingAllowed)
                ? .embedded : .referenced
            entries[face.path] = Entry(
                type0: t, cid: t + 1, descriptor: t + 2, toUnicode: t + 3, file: t + 4,
                font: face.font, baseName: base.isEmpty ? "Unknown" : base,
                mode: mode, used: scalars)
            return t
        }

        /// `/F7 7 0 R /F12 12 0 R …` for the page Resources dict.
        func resourceString() -> String {
            entries.values.sorted { $0.type0 < $1.type0 }
                .map { "/F\($0.type0) \($0.type0) 0 R" }
                .joined(separator: " ")
        }

        func writeObjects(into w: PDFByteWriter) {
            for entry in entries.values.sorted(by: { $0.type0 < $1.type0 }) {
                writeFontObjects(entry: entry, into: w)
            }
        }

        private func writeFontObjects(entry: Entry, into w: PDFByteWriter) {
            let font = entry.font
            let upm = Double(font.unitsPerEm)
            func thou(_ units: Int) -> Int {
                Int((Double(units) * 1000.0 / upm).rounded())
            }

            // ---- CIDFontType2 (full-range /W keeps metrics exact) ----
            var widths = "/W ["
            let total = font.glyphCount
            var g = 0
            while g < total {
                let end = min(g + 128, total)
                widths += "\(g) ["
                for gid in g..<end {
                    widths += "\(thou(font.advanceWidth(glyphID: gid))) "
                }
                widths += "] "
                g = end
            }
            widths += "]"

            w.beginObject(entry.cid)
            w.write("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /\(entry.baseName)")
            w.write(" /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>")
            w.write(" /DW \(thou(font.advanceWidth(glyphID: 0))) \(widths)")
            w.write(" /FontDescriptor \(entry.descriptor) 0 R >>\n")
            w.endObject()

            // ---- FontDescriptor (+FontFile2 when embedding) ----
            let bb = font.boundingBox
            w.beginObject(entry.descriptor)
            w.write("<< /Type /FontDescriptor /FontName /\(entry.baseName) /Flags 32")
            w.write(" /FontBBox [\(thou(bb.0)) \(thou(bb.1)) \(thou(bb.2)) \(thou(bb.3))]")
            w.write(" /ItalicAngle 0 /Ascent \(thou(font.ascentUnits))")
            w.write(" /Descent \(thou(font.descentUnits))")
            w.write(" /CapHeight \(thou(font.capHeightUnits)) /StemV 80")
            if entry.mode == .embedded {
                w.write(" /FontFile2 \(entry.file) 0 R")
            }
            w.write(" >>\n")
            w.endObject()

            // ---- ToUnicode CMap (used scalars only, ≤100 per block) ----
            var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            cmap += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
            cmap += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            cmap += "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
            let pairs = entry.used.sorted().compactMap { scalar -> String? in
                guard let uni = Unicode.Scalar(scalar) else { return nil }
                let gid = font.glyphID(for: uni)
                guard gid > 0 else { return nil }
                let utf16: String
                if scalar < 0x10000 {
                    utf16 = String(format: "%04X", scalar)
                } else {
                    let v = scalar - 0x10000
                    utf16 = String(format: "%04X%04X", 0xD800 + v / 0x400, 0xDC00 + v % 0x400)
                }
                return "<\(String(format: "%04X", gid))> <\(utf16)>"
            }
            var i = 0
            while i < pairs.count {
                let block = pairs[i..<min(i + 100, pairs.count)]
                cmap += "\(block.count) beginbfchar\n"
                for p in block { cmap += p + "\n" }
                cmap += "endbfchar\n"
                i += 100
            }
            cmap += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
            w.beginObject(entry.toUnicode)
            w.writeCompressedStream(Data(cmap.utf8))
            w.endObject()

            // ---- FontFile2 (whole file in v1; subsetting is follow-up) ----
            if entry.mode == .embedded {
                w.beginObject(entry.file)
                w.writeCompressedStream(font.rawData)
                w.endObject()
            }

            // ---- Type0 ----
            w.beginObject(entry.type0)
            w.write("<< /Type /Font /Subtype /Type0 /BaseFont /\(entry.baseName)")
            w.write(" /Encoding /Identity-H /DescendantFonts [\(entry.cid) 0 R]")
            w.write(" /ToUnicode \(entry.toUnicode) 0 R >>\n")
            w.endObject()
        }
    }
}
