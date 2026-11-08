import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - LispDimensionBuilder
//
// Native dimensions from Lisp: entmake DIMENSION, entmake DIMSTYLE, and the
// shared metadata/commit path behind scripted dimension commands.
//
// Group contracts mirror the DXF IMPORTER's reading (not AutoCAD's
// reference table), so assoc lists copied from imported entities keep
// their meaning. Two deliberate entmake conventions differ from file
// convention and are documented at each use site:
//   - Coordinates are used as-is. File import negates Y and degrees on
//     the way in; entmake (like every other entity case) does not.
//   - Group 50/52/53 are degrees used as-is (radians = deg * pi / 180).
//     File convention negates them for the Y flip; entmake does not.
//
// DIMSTYLE creation via entmake is a deliberate AutoCAD deviation
// (AutoCAD forbids table entmake): it is the only Lisp path that creates
// a style, and unknown groups fail closed naming the group.
// =========================================================================

enum LispDimensionBuilder {
    // MARK: - Shared inputs

    /// Raw per-type points. Group roles mirror the importer:
    /// linear 10/13/14, aligned 10/13/14, angular 10/14/16/15,
    /// angular3Point 10/13/14/15, diameter 10/15, radius 10/15 (arc/center),
    /// ordinate 10/13, arcLength 10/13/14/15, jogged 10/15 (arc/center, +12 jog).
    /// Group 11 (text middle) is optional everywhere and defaults per type.
    /// Group 10 is optional for linear/aligned/angular/angular3Point/
    /// arcLength (computed from the style) and required for the rest.
    /// Definition points are WCS (engine coordinates, as-is), matching the
    /// importer's flip-only treatment of file defpoints. An explicit group
    /// 11 is dimension-plane (OCS) sketch coordinates and is mapped through
    /// group 210 like the importer's text point; computed text defaults are
    /// already engine coordinates and stay put. Absent or default 210 is
    /// the identity: zero behavior change versus no extrusion.
    struct DimPoints {
        var type: CADDimensionType
        var flags: Int = 0
        var extrusion: Vector3? = nil
        var styleName: String = "Standard"
        var text: String? = nil
        var measurement: Double? = nil
        var p10: Vector3? = nil
        var p11: Vector3? = nil
        var p13: Vector3? = nil
        var p14: Vector3? = nil
        var p15: Vector3? = nil
        var p16: Vector3? = nil
        var p12: Vector3? = nil
        var rotationDeg: Double? = nil
        var obliqueDeg: Double? = nil
        var textRotDeg: Double? = nil
    }

    // MARK: - Dimension type

    /// DXF group-70 low nibble, mirroring the importer's reading exactly —
    /// including its extension that file value 8 means arcLength. Jogged
    /// dimensions have no group-70 code of their own: entmake selects
    /// jogged with radius groups plus a group-12 jog point (12 is
    /// otherwise unused for radius, so the marker is unambiguous).
    /// Scripted DJO bypasses groups and passes the type directly.
    static func typeFromDimtype(_ raw: Int, name: String) throws -> CADDimensionType {
        let nibble = raw & 0x0F
        if nibble == 8 { return .arcLength }
        guard let type = CADDimensionType(rawValue: nibble) else {
            throw LispError.hostError(
                "\(name): DIMENSION group 70 type \(nibble) is not supported")
        }
        return type
    }

    // MARK: - Metadata from assoc (entmake path)

    static func metadataFromAssoc(
        _ assoc: LispEntityAdapter.DxfAssoc, document: CADDocument, name: String
    ) throws -> (metadata: CADDimensionMetadata, layerID: UUID) {
        let raw70 = assoc.int(70) ?? 0
        var points = DimPoints(type: try typeFromDimtype(raw70, name: name))
        points.flags = (raw70 & ~0x0F) & ~32
        let rawStyle = assoc.string(3) ?? "Standard"
        points.styleName = rawStyle.isEmpty ? "Standard" : rawStyle
        let rawText = assoc.string(1) ?? ""
        // "<>" is the measured-value placeholder, never literal text:
        // the importer maps it to nil, so entmake does the same.
        points.text = (rawText.isEmpty || rawText == "<>") ? nil : rawText
        let rawMeasure = assoc.double(42)
        points.measurement = (rawMeasure != nil && rawMeasure!.isFinite) ? rawMeasure : nil
        points.p10 = assoc.point(10)
        points.p11 = assoc.point(11)
        points.p13 = assoc.point(13)
        points.p14 = assoc.point(14)
        points.p15 = assoc.point(15)
        points.p16 = assoc.point(16)
        points.p12 = assoc.point(12)
        points.extrusion = assoc.point(210)
        points.rotationDeg = assoc.double(50)
        points.obliqueDeg = assoc.double(52)
        points.textRotDeg = assoc.double(53)
        let layerID = try resolveLayer(assoc: assoc, document: document, name: name)
        return (try metadataFromPoints(points, document: document, name: name), layerID)
    }

    // MARK: - Metadata core (entmake + scripted share this)

    static func metadataFromPoints(
        _ points: DimPoints, document: CADDocument, name: String
    ) throws -> CADDimensionMetadata {
        let style = document.dimensionStyle(named: points.styleName)
        func need(_ v: Vector3?, _ group: Int, _ what: String) throws -> Vector3 {
            guard let v, v.x.isFinite, v.y.isFinite else {
                throw LispError.hostError(
                    "\(name): DIMENSION needs (\(group) . \(what)) groups")
            }
            return v
        }

        var defPoint: Vector3?
        var defPoint2: Vector3?
        var defPoint3: Vector3?
        var defPoint4: Vector3?
        var defPoint5: Vector3?
        var textMid = points.p11
        var rotation = (points.rotationDeg ?? 0) * Double.pi / 180.0
        var measurement: Double? = points.measurement
        if let m = measurement, !m.isFinite { measurement = nil }
        // Radius groups plus a group-12 jog point select jogged (see
        // typeFromDimtype: group 70 has no jogged code of its own).
        var dimType = points.type
        if dimType == .radius, points.p12 != nil {
            dimType = .jogged
        }

        switch dimType {
        case .linearOrRotated:
            let d2 = try need(points.p13, 13, "second extension origin")
            let d3 = try need(points.p14, 14, "third extension origin")
            let pos = points.p10 ?? offsetMid(
                p1: d2, p2: d3, angle: rotation, distance: style.dimLineOffset)
            defPoint = pos
            defPoint2 = d2
            defPoint3 = d3
            if textMid == nil {
                textMid = projectedMid(p1: d2, p2: d3, through: pos, angle: rotation)
            }
            if measurement == nil {
                let dx = d3.x - d2.x, dy = d3.y - d2.y
                let c = cos(rotation), s = sin(rotation)
                measurement = abs(dx * c + dy * s)
            }
        case .aligned:
            let d2 = try need(points.p13, 13, "first extension origin")
            let d3 = try need(points.p14, 14, "second extension origin")
            rotation = atan2(d3.y - d2.y, d3.x - d2.x)
            let pos = points.p10 ?? offsetMid(
                p1: d2, p2: d3, angle: rotation, distance: style.dimLineOffset)
            defPoint = pos
            defPoint2 = d2
            defPoint3 = d3
            if textMid == nil {
                textMid = projectedMid(p1: d2, p2: d3, through: pos, angle: rotation)
            }
            if measurement == nil {
                let dx = d3.x - d2.x, dy = d3.y - d2.y
                measurement = hypot(dx, dy)
            }
        case .angular:
            let q1 = try need(points.p14, 14, "first line point")
            let q2 = try need(points.p16, 16, "second line point")
            let center = try need(points.p15, 15, "angle vertex")
            let a1 = atan2(q1.y - center.y, q1.x - center.x)
            let a2 = atan2(q2.y - center.y, q2.x - center.x)
            let r = max(hypot(q1.x - center.x, q1.y - center.y), 1e-9)
            let pos = points.p10 ?? arcMid(center: center, a: q1, b: q2, radius: r)
            defPoint = pos
            defPoint2 = q1
            defPoint3 = q2
            defPoint4 = center
            if textMid == nil {
                let rr = hypot(pos.x - center.x, pos.y - center.y)
                textMid = arcMid(center: center, a: q1, b: q2, radius: rr)
            }
            if measurement == nil { measurement = abs(a2 - a1) }
        case .angular3Point:
            let q1 = try need(points.p13, 13, "first arc point")
            let q2 = try need(points.p14, 14, "second arc point")
            let center = try need(points.p15, 15, "angle vertex")
            let r = max(hypot(q1.x - center.x, q1.y - center.y), 1e-9)
            let pos = points.p10 ?? arcMid(center: center, a: q1, b: q2, radius: r)
            defPoint = pos
            defPoint2 = q1
            defPoint3 = q2
            defPoint4 = center
            let a1 = atan2(q1.y - center.y, q1.x - center.x)
            let a2 = atan2(q2.y - center.y, q2.x - center.x)
            if textMid == nil {
                let rr = hypot(pos.x - center.x, pos.y - center.y)
                textMid = arcMid(center: center, a: q1, b: q2, radius: rr)
            }
            if measurement == nil { measurement = abs(a2 - a1) }
        case .diameter:
            let e1 = try need(points.p10, 10, "first diameter endpoint")
            let e2 = try need(points.p15, 15, "second diameter endpoint")
            defPoint = e1
            defPoint2 = e2
            if textMid == nil {
                textMid = Vector3(
                    x: (e1.x + e2.x) / 2, y: (e1.y + e2.y) / 2, z: 0)
            }
            if measurement == nil {
                measurement = hypot(e2.x - e1.x, e2.y - e1.y)
            }
        case .radius:
            let arc = try need(points.p10, 10, "arc point")
            let center = try need(points.p15, 15, "center point")
            defPoint = center
            defPoint2 = arc
            if textMid == nil {
                textMid = Vector3(
                    x: (center.x + arc.x) / 2, y: (center.y + arc.y) / 2, z: 0)
            }
            if measurement == nil {
                measurement = hypot(arc.x - center.x, arc.y - center.y)
            }
        case .ordinate:
            let feature = try need(points.p10, 10, "feature point")
            let leader = try need(points.p13, 13, "leader endpoint")
            defPoint = feature
            defPoint2 = leader
            defPoint3 = points.p14
            if textMid == nil { textMid = leader }
            if measurement == nil {
                measurement = (points.flags & 64) != 0 ? feature.x : feature.y
            }
        case .arcLength:
            let start = try need(points.p13, 13, "arc start point")
            let end = try need(points.p14, 14, "arc end point")
            let center = try need(points.p15, 15, "arc center point")
            let r = hypot(start.x - center.x, start.y - center.y)
            let pos = points.p10 ?? arcMid(center: center, a: start, b: end, radius: r)
            defPoint = pos
            defPoint2 = start
            defPoint3 = end
            defPoint4 = center
            defPoint5 = points.p16
            if textMid == nil {
                let rr = hypot(pos.x - center.x, pos.y - center.y)
                textMid = arcMid(center: center, a: start, b: end, radius: rr)
            }
            if measurement == nil {
                let a1 = atan2(start.y - center.y, start.x - center.x)
                let a2 = atan2(end.y - center.y, end.x - center.x)
                measurement = r * abs(a2 - a1)
            }
        case .jogged:
            // Radius group convention (10 = arc, 15 = center); the jog
            // marker is the group-12 point, not a group-70 code.
            let arc = try need(points.p10, 10, "arc point")
            let center = try need(points.p15, 15, "center point")
            let ux: Double
            let uy: Double
            do {
                let dx = arc.x - center.x, dy = arc.y - center.y
                let len = hypot(dx, dy)
                ux = len > 1e-9 ? dx / len : 1
                uy = len > 1e-9 ? dy / len : 0
            }
            defPoint = center
            defPoint2 = arc
            var jog = points.p12
            var text = textMid
            if text == nil {
                let r = hypot(arc.x - center.x, arc.y - center.y)
                let off = r + style.textHeight * 2
                text = Vector3(x: center.x + ux * off, y: center.y + uy * off, z: 0)
            }
            if jog == nil, let text {
                jog = Vector3(
                    x: (center.x + text.x) / 2, y: (center.y + text.y) / 2, z: 0)
            }
            defPoint3 = jog
            textMid = text
            if measurement == nil {
                measurement = hypot(arc.x - center.x, arc.y - center.y)
            }
        }

        // Group 210 orients explicit group-11 text through the shared OCS
        // math (file convention; the Y-flip is file-only and not applied).
        // Measurement above stays planar-XY by design: defpoints are WCS,
        // so with default extrusion it equals LT exactly, matching the
        // importer's own XY fallback.
        if let given = points.p11,
           let extrusion = points.extrusion,
           !DXFEntityConverter.isDefaultExtrusion(extrusion)
        {
            textMid = DXFEntityConverter.ocsToWcs(given, extrusion: extrusion)
        }

        return CADDimensionMetadata(
            styleName: points.styleName,
            type: dimType,
            measurement: measurement ?? 0,
            defPoint: defPoint ?? .zero,
            defPoint2: defPoint2 ?? .zero,
            defPoint3: defPoint3,
            defPoint4: defPoint4,
            defPoint5: defPoint5,
            textMidpoint: textMid ?? .zero,
            textOverride: points.text,
            rotationAngle: rotation,
            textRotationAngle: points.textRotDeg.map { $0 * Double.pi / 180.0 },
            obliqueAngle: obliqueRadians(points.obliqueDeg),
            flags: points.flags)
    }

    // MARK: - Defaults and measurement helpers

    /// Midpoint of the extension feet projected onto the dim line.
    static func projectedMid(
        p1: Vector3, p2: Vector3, through pos: Vector3, angle: Double
    ) -> Vector3 {
        let c = cos(angle), s = sin(angle)
        func foot(_ p: Vector3) -> Vector3 {
            let t = (p.x - pos.x) * c + (p.y - pos.y) * s
            return Vector3(x: pos.x + t * c, y: pos.y + t * s, z: 0)
        }
        let f1 = foot(p1), f2 = foot(p2)
        return Vector3(x: (f1.x + f2.x) / 2, y: (f1.y + f2.y) / 2, z: 0)
    }

    /// Mid of p1/p2 pushed off the line by distance along its perpendicular.
    static func offsetMid(
        p1: Vector3, p2: Vector3, angle: Double, distance: Double
    ) -> Vector3 {
        let c = cos(angle), s = sin(angle)
        return Vector3(
            x: (p1.x + p2.x) / 2 - s * distance,
            y: (p1.y + p2.y) / 2 + c * distance, z: 0)
    }

    static func arcMid(
        center: Vector3, a: Vector3, b: Vector3, radius: Double?
    ) -> Vector3 {
        let r = radius ?? hypot(a.x - center.x, a.y - center.y)
        let a1 = atan2(a.y - center.y, a.x - center.x)
        let a2 = atan2(b.y - center.y, b.x - center.x)
        let mid = (a1 + a2) / 2.0
        return Vector3(x: center.x + r * cos(mid), y: center.y + r * sin(mid), z: 0)
    }

    /// Group 52 in degrees, entmake convention (as-is, no file Y-flip).
    static func obliqueRadians(_ degrees: Double?) -> Double? {
        guard let degrees, degrees != 0, abs(degrees - 90) > 1e-9,
              degrees.isFinite
        else { return nil }
        return degrees * Double.pi / 180.0
    }

    static func resolveLayer(
        assoc: LispEntityAdapter.DxfAssoc, document: CADDocument, name: String
    ) throws -> UUID {
        if let layerName = assoc.string(8),
           let layer = document.findLayer(named: layerName)
        {
            return layer.handle
        }
        if let active = document.activeLayerID { return active }
        if let first = document.allLayers.first { return first.handle }
        throw LispError.hostError("\(name): no layers in drawing")
    }

    // MARK: - Commit (mirrors commitDimension, grouped + returning)

    /// Generates, commits, and returns the block-reference entity.
    /// Mirrors DimensionPrimitives.commitDimension exactly, except the two
    /// document writes (block + entity) run inside one undo group so the
    /// whole dimension is a single undo entry.
    static func commit(
        metadata: CADDimensionMetadata, layerID: UUID, color: ColorRGBA?,
        document: CADDocument
    ) -> CADEntity {
        document.undoManager.beginUndoGroup()
        defer { document.undoManager.endUndoGroup() }
        // Explicit color wins (scripted current color); otherwise resolve
        // through the layer exactly like regen does, so committed and
        // regenerated geometry agree.
        let resolved: ColorRGBA
        if let color {
            resolved = color
        } else {
            let shell = CADEntity(layerID: layerID)
            resolved = DimensionPrimitives.resolvedColor(for: shell, in: document)
        }
        let style = document.resolvedDimensionStyle(for: metadata)
        let primitives = DimensionPrimitives.generatePrimitives(
            for: metadata, style: style, color: resolved)
        let blockName = "*D" + UUID().uuidString.prefix(8)
        let block = CADBlock(
            name: String(blockName),
            geometry: primitives,
            primitiveStyles: DimensionPrimitives.primitiveStyles(
                for: primitives,
                dimensionStyle: style))
        document.addBlock(block)
        var entity = CADEntity(layerID: layerID)
        entity.blockID = block.handle
        entity.dimensionMetadata = CADDimensionMetadataBox(metadata)
        document.addEntities([entity])
        return entity
    }

    // MARK: - DIMSTYLE creation and lookup

    /// Builds a style from entmake groups. Accepted groups mirror what the
    /// DXF exporter writes for DIMSTYLE records (subset documented below);
    /// anything else fails closed naming the group.
    ///   2 name (default Standard) | 3 prefix | 4 suffix | 5/6 arrow blocks
    ///   7 text style name | 40 overall scale | 41 arrow size
    ///   42 extension offset | 43 dimline offset | 44 extension extend
    ///   140 text height | 142 tick size | 144 linear scale
    ///   147 text offset (gap) | 179 angle precision | 271 precision
    ///   75/76 suppress first/second extension (nonzero = true)
    static func styleFromAssoc(
        _ assoc: LispEntityAdapter.DxfAssoc, name: String
    ) throws -> CADDimensionStyle {
        var style = CADDimensionStyle()
        style.name = assoc.string(2) ?? "Standard"
        if let v = assoc.string(3) { style.dimensionPrefix = v }
        if let v = assoc.string(4) { style.dimensionSuffix = v }
        if let v = assoc.string(5) { style.firstArrowBlockName = v }
        if let v = assoc.string(6) { style.secondArrowBlockName = v }
        if let v = assoc.string(7) { style.textStyle = v }
        if let v = assoc.double(40) { style.overallScale = v }
        if let v = assoc.double(41) { style.arrowSize = v }
        if let v = assoc.double(42) { style.extensionLineOffset = v }
        if let v = assoc.double(43) { style.dimLineOffset = v }
        if let v = assoc.double(44) { style.extensionLineExtend = v }
        if let v = assoc.double(140) { style.textHeight = v }
        if let v = assoc.double(142) { style.tickSize = v }
        if let v = assoc.double(144) { style.linearScaleFactor = v }
        if let v = assoc.double(147) { style.textOffset = v }
        if let v = assoc.int(179) { style.anglePrecision = v }
        if let v = assoc.int(271) { style.unitsPrecision = v }
        if let v = assoc.int(75) { style.suppressFirstExtension = v != 0 }
        if let v = assoc.int(76) { style.suppressSecondExtension = v != 0 }
        // Fail closed on anything outside the subset: silent acceptance
        // would pretend to honor vars the renderer ignores.
        let allowed: Set<Int> = [0, 2, 3, 4, 5, 6, 7, 40, 41, 42, 43, 44,
                                 140, 142, 144, 147, 179, 271, 75, 76]
        let extra = Set(assoc.pairs.map(\.code)).subtracting(allowed)
        guard extra.isEmpty else {
            throw LispError.hostError(
                "\(name): DIMSTYLE groups \(extra.sorted()) are not supported")
        }
        return style
    }

    /// tblsearch assoc for one style, using the same groups entmake accepts.
    static func dimstyleEntry(name: String, style: CADDimensionStyle) -> LispValue {
        var pairs: [LispValue] = [
            dotted(0, "DIMSTYLE"),
            dotted(2, name),
            dotted(40, style.overallScale),
            dotted(41, style.arrowSize),
            dotted(42, style.extensionLineOffset),
            dotted(43, style.dimLineOffset),
            dotted(44, style.extensionLineExtend),
            dotted(140, style.textHeight),
            dotted(142, style.tickSize),
            dotted(147, style.textOffset),
            dotted(271, style.unitsPrecision),
            dotted(179, style.anglePrecision),
        ]
        if let v = style.linearScaleFactor {
            pairs.append(dotted(144, v))
        }
        if let v = style.dimensionPrefix {
            pairs.append(dotted(3, v))
        }
        if let v = style.dimensionSuffix {
            pairs.append(dotted(4, v))
        }
        if let v = style.firstArrowBlockName {
            pairs.append(dotted(5, v))
        }
        if let v = style.secondArrowBlockName {
            pairs.append(dotted(6, v))
        }
        if let v = style.textStyle {
            pairs.append(dotted(7, v))
        }
        if style.suppressFirstExtension {
            pairs.append(dotted(75, 1))
        }
        if style.suppressSecondExtension {
            pairs.append(dotted(76, 1))
        }
        return LispEntityAdapter.lispList(pairs)
    }

    private static func dotted(_ group: Int, _ text: String) -> LispValue {
        LispEntityAdapter.dotted(.int(group), .string(text))
    }

    private static func dotted(_ group: Int, _ number: Double) -> LispValue {
        LispEntityAdapter.dotted(.int(group), .real(number))
    }

    private static func dotted(_ group: Int, _ number: Int) -> LispValue {
        LispEntityAdapter.dotted(.int(group), .int(number))
    }
}
