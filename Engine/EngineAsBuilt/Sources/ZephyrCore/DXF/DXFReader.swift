import Foundation

/// Pure Swift DXF file reader.
/// Parses ASCII DXF pair-based format and builds libdxfrw-compatible entity tree.
public class DXFReader {

    public enum ReaderError: Swift.Error {
        case fileNotFound(String)
        case invalidFormat(String)
        case parseError(String)
        case unsupportedFormat(String)
    }

    public var versionRaw: String = ""

    // MARK: - Output

    public var version: DXFVersion = .unknown
    public var header: DXFHeaderData = DXFHeaderData()
    public var layers: [DXFLayerEntry] = []
    public var ltypes: [DXFLTypeEntry] = []
    public var dimstyles: [DXFDimstyleEntry] = []
    public var textstyles: [DXFStyleEntry] = []
    public var vports: [DXFVportEntry] = []
    public var appids: [DXFAppIdEntry] = []
    public var blockRecords: [DXFBlockRecordEntry] = []
    public var imagedefs: [DXFImageDefEntry] = []
    public var blocks: [DXFBlockEntity] = []
    public var entities: [DXFEntity] = []

    // MARK: - Internal

    private var pairs: [(code: Int, value: String)] = []
    private var pos: Int = 0
    public var textCodec = DXFTextCodec()

    public init() {}

    /// Parse DXF file at path
    public func readFile(at path: String) throws -> DXFReader {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ReaderError.fileNotFound("File not found: \(path)")
        }
        // Check binary
        if data.count >= 22,
           let sig = String(data: data.prefix(22), encoding: .ascii),
           sig.hasPrefix("AutoCAD Binary DXF") {
            throw ReaderError.unsupportedFormat("Binary DXF not supported. Use ASCII.")
        }
        guard let content = String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ReaderError.invalidFormat("Cannot decode DXF file as ASCII.")
        }
        return try readString(content)
    }

    /// Parse DXF from string content
    public func readString(_ content: String) throws -> DXFReader {
        pairs = try parsePairs(content)
        pos = 0
        try parseSections()
        resolveImageReferences()
        return self
    }

    // MARK: - Pair parsing

    private func parsePairs(_ content: String) throws -> [(Int, String)] {
        var result: [(Int, String)] = []
        var lines: [String]

        // Handle line endings
        if content.contains("\r\n") {
            lines = content.components(separatedBy: "\r\n")
        } else {
            lines = content.components(separatedBy: .newlines)
        }

        var i = 0
        while i < lines.count {
            let codeStr = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            if codeStr.isEmpty { continue }
            guard let code = Int32(codeStr).flatMap({ Int($0) }) else { continue }
            guard i < lines.count else { break }
            let value = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            result.append((code, value))
        }

        return result
    }

    // MARK: - Section parsing

    private func parseSections() throws {
        while pos < pairs.count {
            let (code, value) = pairs[pos]
            if code == 0 {
                if value == "EOF" { return }
                if value == "SECTION" {
                    pos += 1
                    try parseSectionBody()
                } else {
                    pos += 1
                }
            } else {
                pos += 1
            }
        }
    }

    private func parseSectionBody() throws {
        guard pos < pairs.count else { return }
        let (code, name) = pairs[pos]
        guard code == 2 else { return }
        pos += 1

        switch name {
        case "HEADER":    try parseHeader()
        case "CLASSES":   try skipToEndsec()
        case "TABLES":    try parseTables()
        case "BLOCKS":    try parseBlocks()
        case "ENTITIES":  try parseEntities()
        case "OBJECTS":   try parseObjects()
        default:          try skipToEndsec()
        }
    }

    private func skipToEndsec() throws {
        while pos < pairs.count {
            let (c, v) = pairs[pos]; pos += 1
            if c == 0 && v == "ENDSEC" { return }
        }
    }

    // MARK: - HEADER

    private func parseHeader() throws {
        var currentVar: String?
        while pos < pairs.count {
            let (code, value) = pairs[pos]; pos += 1
            if code == 0 && value == "ENDSEC" { return }
            if code == 9 { currentVar = value; continue }
            guard let vn = currentVar else { continue }

            // Generic capture: store ALL header vars in dictionary
            let stored: Any
            switch code {
            case 1, 2, 3, 6, 7, 8: stored = decode(value)
            case 10, 20, 30:
                // Coordinate: group 10 starts, 20/30 fill components
                if code == 10 { header.headerVars["\(vn)_x"] = d(value) }
                else if code == 20 { header.headerVars["\(vn)_y"] = d(value) }
                else if code == 30 { header.headerVars["\(vn)_z"] = d(value) }
                stored = d(value)
            case 40, 41, 42, 43, 44, 45, 46, 47, 48, 49: stored = d(value)
            case 50, 51, 52, 53, 54, 55, 56, 57, 58: stored = d(value)
            case 60, 61, 62, 63, 64, 65, 66, 67, 68, 69: stored = i(value)
            case 70, 71, 72, 73, 74, 75, 76, 77, 78, 79: stored = i(value)
            case 90, 91, 92, 93, 94, 95, 96, 97, 98, 99: stored = i(value)
            case 140, 141, 142, 143, 144, 145, 146, 147, 148, 149: stored = d(value)
            case 170, 171, 172, 173, 174, 175, 176, 177, 178, 179: stored = i(value)
            case 210: stored = d(value); header.headerVars["\(vn)_x"] = stored
            case 220: stored = d(value); header.headerVars["\(vn)_y"] = stored
            case 230: stored = d(value); header.headerVars["\(vn)_z"] = stored
            case 280, 281, 282, 283, 284, 285, 286, 287, 288, 289: stored = i(value)
            case 290, 291, 292, 293, 294, 295, 296, 297, 298, 299: stored = i(value)
            case 370, 371, 372, 373, 374, 375, 376, 377, 378, 379: stored = i(value)
            case 380, 381, 382, 383, 384, 385, 386, 387, 388, 389: stored = i(value)
            default: stored = value
            }
            header.headerVars[vn] = stored

            // Special handling for known critical vars
            switch vn {
            case "$ACADVER":      versionRaw = value; version = DXFVersion(rawValue: value) ?? .unknown; header.acadVer = value; textCodec.setVersion(version)
            case "$DWGCODEPAGE":  header.codePage = value; textCodec.setCodePage(value)
            case "$INSBASE":
                if code == 10 { header.insBase.x = d(value) }
                else if code == 20 { header.insBase.y = d(value) }
                else if code == 30 { header.insBase.z = d(value) }
            case "$EXTMIN":
                if code == 10 { header.extMin.x = d(value) }
                else if code == 20 { header.extMin.y = d(value) }
                else if code == 30 { header.extMin.z = d(value) }
            case "$EXTMAX":
                if code == 10 { header.extMax.x = d(value) }
                else if code == 20 { header.extMax.y = d(value) }
                else if code == 30 { header.extMax.z = d(value) }
            case "$CLAYER":        if code == 8 { header.currentLayer = decode(value) }
            case "$TEXTSIZE":      if code == 40 { header.textSize = d(value) }
            case "$LTSCALE":       if code == 40 { header.ltScale = d(value) }
            case "$CELTSCALE":     if code == 40 { header.celScale = d(value) }
            case "$CECOLOR":       if code == 62 { header.currentColor = i32(value) }
            case "$CELTYPE":       if code == 6 { header.currentLinetype = decode(value) }
            case "$LUNITS":        if code == 70 { header.lUnits = i(value) }
            case "$LUPREC":        if code == 70 { header.luPrec = i(value) }
            case "$INSUNITS":      if code == 70 { header.insUnits = i(value) }
            case "$MEASUREMENT":   if code == 70 { header.measurement = i(value) }
            default: break
            }
        }
    }

    // MARK: - TABLES

    private func parseTables() throws {
        while pos < pairs.count {
            let (code, value) = pairs[pos]
            if code == 0 && value == "ENDSEC" { pos += 1; return }
            guard code == 0 && value == "TABLE" else { pos += 1; continue }

            pos += 1
            var tableType = ""
            while pos < pairs.count {
                let (c, v) = pairs[pos]
                if c == 2 {
                    tableType = v.uppercased()
                    pos += 1
                    break
                }
                if c == 0 { break }
                pos += 1
            }

            while pos < pairs.count {
                let (c, v) = pairs[pos]
                if c == 0 && v == "ENDSEC" { return }
                if c == 0 && v == "ENDTAB" { pos += 1; break }
                if c != 0 { pos += 1; continue }

                switch tableType {
                case "LAYER":        tryParse { try parseLayer(at: pos) }
                case "LTYPE":        tryParse { try parseLType(at: pos) }
                case "DIMSTYLE":     tryParse { try parseDimstyle(at: pos) }
                case "STYLE":        tryParse { try parseStyle(at: pos) }
                case "VPORT":        tryParse { try parseVport(at: pos) }
                case "APPID":        tryParse { try parseAppId(at: pos) }
                case "BLOCK_RECORD": tryParse { try parseBlockRecord(at: pos) }
                case "IMAGEDEF":     tryParse { try parseImageDef(at: pos) }
                default:              pos += 1
                }
            }
        }
    }

    private func tryParse(_ closure: () throws -> Void) {
        do { try closure() } catch {}
    }

    // MARK: - Entity parsing (single method: reads from position, returns entity)

    /// Parse entity starting at given position. pos is index of the 0/EntityType pair.
    /// Returns entity or nil. Advances pos past entity properties (to next 0 pair).
    private func parseEntity(at startPos: inout Int) throws -> DXFEntity? {
        guard startPos < pairs.count else { return nil }
        let entityStart = startPos
        let (code, typeName) = pairs[startPos]
        guard code == 0 else { return nil }

        // Read all pairs until next 0. MTEXT can contain a 101/Embedded Object
        // payload with opaque group codes that look like normal MTEXT placement
        // fields; ignore that payload so later 10/20/40 codes do not overwrite
        // the real insertion point or text height.
        var props: [(Int, String)] = []
        var idx = startPos + 1
        var skippingEmbeddedMTextObject = false
        while idx < pairs.count {
            let (c, v) = pairs[idx]
            if c == 0 { break }
            if typeName == "MTEXT", c == 101, v.uppercased() == "EMBEDDED OBJECT" {
                skippingEmbeddedMTextObject = true
                idx += 1
                continue
            }
            if !skippingEmbeddedMTextObject { props.append((c, v)) }
            idx += 1
        }
        startPos = idx  // advance to next 0

        // Also store all pairs including the type for convenience
        var allPairs = props
        allPairs.insert((0, typeName), at: 0)

        switch typeName {
        case "POINT":    return parsePoint(allPairs)
        case "LINE":     return parseLine(allPairs)
        case "CIRCLE":   return parseCircle(allPairs)
        case "ARC":      return parseArc(allPairs)
        case "ELLIPSE":  return parseEllipse(allPairs)
        case "LWPOLYLINE": return parseLWPolyline(allPairs)
        case "POLYLINE":
            var polylinePos = entityStart
            let polyline = try parsePolylineEntity(at: &polylinePos)
            startPos = polylinePos
            return polyline
        case "VERTEX":   return nil  // handled by POLYLINE context
        case "SEQEND":   return nil
        case "SPLINE":   return parseSpline(allPairs)
        case "TEXT":     return parseText(allPairs)
        case "MTEXT":    return parseMText(allPairs)
        case "ATTDEF":   return parseText(allPairs)
        case "ATTRIB":   return parseText(allPairs)
        case "INSERT":   return parseInsert(allPairs)
        case "SOLID":    return parseSolid(allPairs)
        case "TRACE":    return parseTrace(allPairs)
        case "3DFACE":   return parse3DFace(allPairs)
        case "HATCH":    return parseHatch(allPairs)
        case "XLINE":    return parseXLine(allPairs)
        case "RAY":      return parseRay(allPairs)
        case "DIMENSION": return parseDimension(allPairs)
        case "LEADER":   return parseLeader(allPairs)
        case "IMAGE":    return parseImage(allPairs)
        case "VIEWPORT": return parseViewport(allPairs)
        case "ACAD_TABLE", "TABLE": return parseTable(allPairs)
        default: return DXFEntity(eType: .uNKNOWN)
        }
    }

    /// Parse all entities (ENTITIES section or block content)
    private func parseEntities() throws {
        while pos < pairs.count {
            let (c, v) = pairs[pos]
            if c == 0 && v == "ENDSEC" { pos += 1; return }
            if c == 0 && v == "ENDBLK" { return }
            if c == 0 {
                if let entity = try parseEntity(at: &pos) {
                    entities.append(entity)
                }
            } else {
                pos += 1
            }
        }
    }

    /// Better approach: collect all entities via direct pair scanning
}

// MARK: - Static entity parsers (take all pairs including type)

// I need to provide the entity parsing logic. Let me use extension methods
// on the DXFReader class that take [(Int, String)] arrays.

// MARK: - Entity Parsers

extension DXFReader {

    func parsePoint(_ pairs: [(Int, String)]) -> DXFPointEntity {
        let e = DXFPointEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 39: e.thickness_p = d(v)
            default: break
            }
        }
        return e
    }

    func parseLine(_ pairs: [(Int, String)]) -> DXFLineEntity {
        let e = DXFLineEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 39: e.thickness_p = d(v)
            default: break
            }
        }
        return e
    }

    func parseCircle(_ pairs: [(Int, String)]) -> DXFCircleEntity {
        let e = DXFCircleEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 40: e.radius = d(v)
            case 39: e.thickness_p = d(v)
            default: break
            }
        }
        return e
    }

    func parseArc(_ pairs: [(Int, String)]) -> DXFArcEntity {
        let e = DXFArcEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 40: e.radius = d(v)
            case 50: e.startAngle = d(v) * .pi / 180.0  // DXF stores degrees
            case 51: e.endAngle = d(v) * .pi / 180.0      // convert to radians
            case 39: e.thickness_p = d(v)
            default: break
            }
        }
        return e
    }

    func parseEllipse(_ pairs: [(Int, String)]) -> DXFEllipseEntity {
        let e = DXFEllipseEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)  // major axis endpoint offset
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 40: e.ratio = d(v)
            case 41: e.startParam = d(v)  // already in radians
            case 42: e.endParam = d(v)    // already in radians
            case 73: e.isCCW = i(v)
            default: break
            }
        }
        return e
    }

    func parseLWPolyline(_ pairs: [(Int, String)]) -> DXFLWPolylineEntity {
        let e = DXFLWPolylineEntity()
        applyCommon(pairs, to: e)
        var vertex: DXFVertex2D?
        for (c, v) in pairs {
            switch c {
            case 38: e.elevation = d(v)
            case 39: e.thickness_p = d(v)
            case 43: e.width = d(v)
            case 70: e.flags = i(v)
            case 90: e.vertexCount = i(v)
            case 10:
                vertex = DXFVertex2D()
                vertex!.x = d(v)
                if let vt = vertex { e.vertices.append(vt) }
            case 20: e.vertices.last?.y = d(v)
            case 40: e.vertices.last?.startWidth = d(v)
            case 41: e.vertices.last?.endWidth = d(v)
            case 42: e.vertices.last?.bulge = d(v)
            case 210: e.extPoint.x = d(v)
            case 220: e.extPoint.y = d(v)
            case 230: e.extPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parsePolylineHeader(_ pairs: [(Int, String)]) -> DXFPolylineEntity {
        let e = DXFPolylineEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 40: e.defStartWidth = d(v)
            case 41: e.defEndWidth = d(v)
            case 70: e.flags = i(v)
            case 71: e.vertexCount = i(v)
            case 72: e.faceCount = i(v)
            case 73: e.smoothM = i(v)
            case 74: e.smoothN = i(v)
            case 75: e.curveType = i(v)
            default: break
            }
        }
        return e
    }


    func parsePolylineEntity(at startPos: inout Int) throws -> DXFPolylineEntity? {
        guard startPos < pairs.count, pairs[startPos].code == 0, pairs[startPos].value == "POLYLINE" else {
            return nil
        }

        var headerPairs: [(Int, String)] = [(0, "POLYLINE")]
        var idx = startPos + 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]
            if c == 0 { break }
            headerPairs.append((c, v))
            idx += 1
        }

        let polyline = parsePolylineHeader(headerPairs)

        while idx < pairs.count {
            let (c, v) = pairs[idx]
            guard c == 0 else { idx += 1; continue }

            if v == "VERTEX" {
                var vertexPairs: [(Int, String)] = [(0, "VERTEX")]
                idx += 1
                while idx < pairs.count {
                    let (vc, vv) = pairs[idx]
                    if vc == 0 { break }
                    vertexPairs.append((vc, vv))
                    idx += 1
                }
                polyline.vertices.append(parseVertex(vertexPairs))
                continue
            }

            if v == "SEQEND" {
                idx += 1
                while idx < pairs.count, pairs[idx].code != 0 { idx += 1 }
                break
            }

            break
        }

        polyline.vertexCount = polyline.vertices.count
        startPos = idx
        return polyline
    }

    func parseVertex(_ pairs: [(Int, String)]) -> DXFVertexEntity {
        let e = DXFVertexEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 40: e.startWidth = d(v)
            case 41: e.endWidth = d(v)
            case 42: e.bulge = d(v)
            case 50: e.tangentDir = d(v) * .pi / 180.0
            case 70: e.flags = i(v)
            case 71: e.vIndex1 = i(v)
            case 72: e.vIndex2 = i(v)
            case 73: e.vIndex3 = i(v)
            case 74: e.vIndex4 = i(v)
            case 91: e.identifier = i(v)
            default: break
            }
        }
        return e
    }

    func parseSpline(_ pairs: [(Int, String)]) -> DXFSplineEntity {
        let e = DXFSplineEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.controlPoints.append(Vector3(x: d(v), y: 0, z: 0))
            case 20: if !e.controlPoints.isEmpty { e.controlPoints[e.controlPoints.count-1].y = d(v) }
            case 30: if !e.controlPoints.isEmpty { e.controlPoints[e.controlPoints.count-1].z = d(v) }
            case 11: e.fitPoints.append(Vector3(x: d(v), y: 0, z: 0))
            case 21: if !e.fitPoints.isEmpty { e.fitPoints[e.fitPoints.count-1].y = d(v) }
            case 31: if !e.fitPoints.isEmpty { e.fitPoints[e.fitPoints.count-1].z = d(v) }
            case 12: e.tgStart.x = d(v)
            case 22: e.tgStart.y = d(v)
            case 32: e.tgStart.z = d(v)
            case 13: e.tgEnd.x = d(v)
            case 23: e.tgEnd.y = d(v)
            case 33: e.tgEnd.z = d(v)
            case 40: e.knots.append(d(v))
            case 41: e.weights.append(d(v))
            case 42: e.tolKnot = d(v)
            case 43: e.tolControl = d(v)
            case 44: e.tolFit = d(v)
            case 70: e.flags = i(v)
            case 71: e.degree = i(v)
            case 72: e.nKnots = i32(v)
            case 73: e.nControl = i32(v)
            case 74: e.nFit = i32(v)
            case 210: e.normalVec.x = d(v)
            case 220: e.normalVec.y = d(v)
            case 230: e.normalVec.z = d(v)
            default: break
            }
        }
        return e
    }

    func parseText(_ pairs: [(Int, String)]) -> DXFTextEntity {
        let e = DXFTextEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 1:   e.text = decode(v)
            case 7:   e.style = decode(v)
            case 10:  e.basePoint.x = d(v)
            case 20:  e.basePoint.y = d(v)
            case 30:  e.basePoint.z = d(v)
            case 11:  e.secPoint.x = d(v)
            case 21:  e.secPoint.y = d(v)
            case 31:  e.secPoint.z = d(v)
            case 40:  e.height = d(v)
            case 41:  e.widthScale = d(v)
            case 50:  e.angle_p = d(v)  // degrees
            case 51:  e.oblique = d(v)  // degrees
            case 71:  e.textGen = i(v)
            case 72:  e.alignH = i(v)
            case 73:  e.alignV = i(v)
            default: break
            }
        }
        return e
    }

    func parseMText(_ pairs: [(Int, String)]) -> DXFMTextEntity {
        let e = DXFMTextEntity()
        applyCommon(pairs, to: e)
        var explicitAngleOrder = -1
        var directionOrder = -1
        for (pairIndex, pair) in pairs.enumerated() {
            let (c, v) = pair
            switch c {
            case 1:   e.text = decode(v)
            case 3:   e.text += decode(v)  // MText continuation chunks
            case 7:   e.style = decode(v)
            case 10:  e.basePoint.x = d(v)
            case 20:  e.basePoint.y = d(v)
            case 30:  e.basePoint.z = d(v)
            case 11:
                e.secPoint.x = d(v)  // X axis direction
                directionOrder = pairIndex
            case 21:
                e.secPoint.y = d(v)
                directionOrder = pairIndex
            case 31:
                e.secPoint.z = d(v)
                directionOrder = pairIndex
            case 40:  e.height = d(v)
            case 41:  e.widthScale = d(v)  // reference rectangle width
            case 44:  e.interlin = d(v)    // line spacing
            case 45:  e.backgroundScale = d(v)
            case 50:
                e.angle_p = d(v)     // rotation in degrees
                explicitAngleOrder = pairIndex
            case 63:  e.backgroundColor = i(v)
            case 71:  e.textGen = i(v)     // attachment point
            case 72:  break                 // drawing direction, not alignment
            case 90:  e.backgroundFillFlags = i(v)
            case 421: e.backgroundColor24 = i(v)
            case 441: e.backgroundTransparency = i(v)
            default: break
            }
        }

        if directionOrder > explicitAngleOrder {
            let dx = e.secPoint.x
            let dy = e.secPoint.y
            if abs(dx) > 1e-12 || abs(dy) > 1e-12 {
                e.angle_p = atan2(dy, dx) * 180.0 / .pi
            }
        }

        switch e.textGen {
        case 1, 4, 7: e.alignH = 0
        case 2, 5, 8: e.alignH = 1
        case 3, 6, 9: e.alignH = 2
        default: e.alignH = 0
        }

        switch e.textGen {
        case 1...3: e.alignV = 3
        case 4...6: e.alignV = 2
        case 7...9: e.alignV = 1
        default: e.alignV = 3
        }

        return e
    }

    func parseInsert(_ pairs: [(Int, String)]) -> DXFInsertEntity {
        let e = DXFInsertEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 2:   e.name = v
            case 10:  e.basePoint.x = d(v)
            case 20:  e.basePoint.y = d(v)
            case 30:  e.basePoint.z = d(v)
            case 41:  e.xScale = d(v)
            case 42:  e.yScale = d(v)
            case 43:  e.zScale = d(v)
            case 50:  e.angle = d(v) * .pi / 180.0  // degrees to radians
            case 70:  e.colCount = i(v)
            case 71:  e.rowCount = i(v)
            case 44:  e.colSpace = d(v)
            case 45:  e.rowSpace = d(v)
            default: break
            }
        }
        return e
    }

    func parseSolid(_ pairs: [(Int, String)]) -> DXFSolidEntity {
        let e = DXFSolidEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 12: e.thirdPoint.x = d(v)
            case 22: e.thirdPoint.y = d(v)
            case 32: e.thirdPoint.z = d(v)
            case 13: e.fourPoint.x = d(v)
            case 23: e.fourPoint.y = d(v)
            case 33: e.fourPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parseTrace(_ pairs: [(Int, String)]) -> DXFTraceEntity {
        let e = DXFTraceEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 12: e.thirdPoint.x = d(v)
            case 22: e.thirdPoint.y = d(v)
            case 32: e.thirdPoint.z = d(v)
            case 13: e.fourPoint.x = d(v)
            case 23: e.fourPoint.y = d(v)
            case 33: e.fourPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parse3DFace(_ pairs: [(Int, String)]) -> DXF3DFaceEntity {
        let e = DXF3DFaceEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 12: e.thirdPoint.x = d(v)
            case 22: e.thirdPoint.y = d(v)
            case 32: e.thirdPoint.z = d(v)
            case 13: e.fourPoint.x = d(v)
            case 23: e.fourPoint.y = d(v)
            case 33: e.fourPoint.z = d(v)
            case 70: e.invisibleFlag = i(v)
            default: break
            }
        }
        return e
    }

    func parseXLine(_ pairs: [(Int, String)]) -> DXFXLineEntity {
        let e = DXFXLineEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parseRay(_ pairs: [(Int, String)]) -> DXFRayEntity {
        let e = DXFRayEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parseDimension(_ pairs: [(Int, String)]) -> DXFDimensionEntity {
        let e = DXFDimensionEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 1:   e.text = v
            case 2:   e.name = v
            case 3:   e.style = v
            case 10:  e.defPoint.x = d(v)
            case 20:  e.defPoint.y = d(v)
            case 30:  e.defPoint.z = d(v)
            case 11:  e.textPoint.x = d(v)
            case 21:  e.textPoint.y = d(v)
            case 31:  e.textPoint.z = d(v)
            case 12:  e.clonePoint.x = d(v)
            case 22:  e.clonePoint.y = d(v)
            case 32:  e.clonePoint.z = d(v)
            case 13:  e.def1.x = d(v)
            case 23:  e.def1.y = d(v)
            case 33:  e.def1.z = d(v)
            case 14:  e.def2.x = d(v)
            case 24:  e.def2.y = d(v)
            case 34:  e.def2.z = d(v)
            case 15:  e.circlePoint.x = d(v)
            case 25:  e.circlePoint.y = d(v)
            case 35:  e.circlePoint.z = d(v)
            case 16:  e.arcPoint.x = d(v)
            case 26:  e.arcPoint.y = d(v)
            case 36:  e.arcPoint.z = d(v)
            case 40:  e.length = d(v)
            case 41:  e.lineFactor = d(v)
            case 42:  e.measurement = d(v)
            case 50:  e.angle_p = d(v)
            case 52:  e.oblique = d(v)
            case 53:
                e.rot = d(v)
                e.hasTextRotation = true
            case 70:  e.type = i(v)
            case 71:  e.align = i(v)
            case 72:  e.lineStyle = i(v)
            case 210: e.extPoint.x = d(v)
            case 220: e.extPoint.y = d(v)
            case 230: e.extPoint.z = d(v)
            default: break
            }
        }
        return e
    }

    func parseHatch(_ pairs: [(Int, String)]) -> DXFHatchEntity {
        let e = DXFHatchEntity()
        applyCommon(pairs, to: e)
        if let owner = pairs.prefix(while: { $0.0 != 91 }).first(where: { $0.0 == 330 }) {
            e.parentHandle = parseHandle(owner.1)
        }
        var currentLoop: DXFHatchLoop?
        var isPolyline: Bool = false
        var splineDegree: Int = 0
        var splineNKnots: Int = 0
        var splineNControl: Int = 0
        var splineFitCountSeen = false
        var sourceHandlesRemaining = 0
        var currentPatternLine: DXFHatchPatternLineData?

        func flushPatternLine() {
            guard let line = currentPatternLine else { return }
            if abs(line.offset.x) > 1e-12 || abs(line.offset.y) > 1e-12 || !line.dashes.isEmpty {
                e.patternLines.append(line)
            }
            currentPatternLine = nil
        }

        for (c, v) in pairs {
            switch c {
            case 2:   e.name = decode(v)
            case 41:  e.scale = d(v)
            case 52:  e.angle_p = d(v)
            case 53:
                flushPatternLine()
                currentPatternLine = DXFHatchPatternLineData(angle: d(v))
            case 43:
                currentPatternLine?.base.x = d(v)
            case 44:
                currentPatternLine?.base.y = d(v)
            case 45:
                currentPatternLine?.offset.x = d(v)
            case 46:
                currentPatternLine?.offset.y = d(v)
            case 49:
                currentPatternLine?.dashes.append(d(v))
            case 79:
                break
            case 63:
                if e.isGradient != 0 {
                    let aci = Int(i(v))
                    var gc = (position: 0.0, aci: UInt16(aci & 0xFFFF), rgb: Int32(-1))
                    if !e.gradientColors.isEmpty {
                        let last = e.gradientColors.removeLast()
                        gc.position = last.position
                        gc.aci = UInt16(aci & 0xFFFF)
                        if last.rgb >= 0 { gc.rgb = last.rgb }
                    }
                    e.gradientColors.append(gc)
                } else {
                    e.bgColor = i32(v)
                }
            case 70:  e.solid = i(v)
            case 71:  e.associative = i(v)
            case 72:  // Edge type or polyline bulge flag
                if isPolyline { break }
                let edgeType = i(v)
                splineDegree = 0
                splineNKnots = 0
                splineNControl = 0
                splineFitCountSeen = false
                sourceHandlesRemaining = 0
                switch edgeType {
                case 1: e.addLine()
                case 2: e.addArc()
                case 3: e.addEllipse()
                case 4: e.addSpline()
                default: e.clearEntities()
                }
            case 75:  e.hStyle = i(v)
            case 76:  e.hPattern = i(v)
            case 77:  e.doubleFlag = i(v)
            case 78:  e.defLines = i(v)
            case 91:  e.loopsNum = i(v)
            case 92:
                let loopType = i(v)
                isPolyline = (loopType & 2) != 0
                currentLoop = DXFHatchLoop(type: loopType)
                if let lp = currentLoop { e.loops.append(lp) }
                e.clearEntities()
                splineDegree = 0
                splineNKnots = 0
                splineNControl = 0
                splineFitCountSeen = false
                sourceHandlesRemaining = 0
                if isPolyline, let lp = currentLoop {
                    let pl = DXFLWPolylineEntity()
                    e.pline = pl
                    lp.entities.append(pl)
                }
            case 93:
                let nc = i(v)
                if isPolyline {
                    e.pline?.vertexCount = nc
                } else if let lp = currentLoop {
                    lp.numEdges = nc
                }
            case 10:
                if e.spline != nil {
                    e.spline?.controlPoints.append(Vector3(x: d(v), y: 0, z: 0))
                } else if e.pt != nil {
                    e.pt?.basePoint.x = d(v)
                } else if let pline = e.pline {
                    let vertex = DXFVertex2D()
                    vertex.x = d(v)
                    e.plvert = vertex
                    pline.vertices.append(vertex)
                } else if currentLoop == nil {
                    e.basePoint.x = d(v)
                }
            case 20:
                if e.spline != nil, !(e.spline?.controlPoints ?? []).isEmpty {
                    e.spline?.controlPoints[e.spline!.controlPoints.count - 1].y = d(v)
                } else if e.pt != nil {
                    e.pt?.basePoint.y = d(v)
                } else if e.plvert != nil {
                    e.plvert?.y = d(v)
                } else if currentLoop == nil {
                    e.basePoint.y = d(v)
                }
            case 30:
                if e.spline != nil, !(e.spline?.controlPoints ?? []).isEmpty {
                    e.spline?.controlPoints[e.spline!.controlPoints.count - 1].z = d(v)
                } else if e.pt != nil {
                    e.pt?.basePoint.z = d(v)
                } else if currentLoop == nil {
                    e.basePoint.z = d(v)
                }
            case 11:
                if e.spline != nil {
                    e.spline?.fitPoints.append(Vector3(x: d(v), y: 0, z: 0))
                } else {
                    e.line?.secPoint.x = d(v)
                    e.ellipse?.secPoint.x = d(v)
                }
            case 21:
                if e.spline != nil, !(e.spline?.fitPoints ?? []).isEmpty {
                    e.spline?.fitPoints[e.spline!.fitPoints.count - 1].y = d(v)
                } else {
                    e.line?.secPoint.y = d(v)
                    e.ellipse?.secPoint.y = d(v)
                }
            case 31:
                if e.spline != nil, !(e.spline?.fitPoints ?? []).isEmpty {
                    e.spline?.fitPoints[e.spline!.fitPoints.count - 1].z = d(v)
                } else {
                    e.line?.secPoint.z = d(v)
                    e.ellipse?.secPoint.z = d(v)
                }
            case 12: e.spline?.tgStart.x = d(v)
            case 22: e.spline?.tgStart.y = d(v)
            case 32: e.spline?.tgStart.z = d(v)
            case 13: e.spline?.tgEnd.x = d(v)
            case 23: e.spline?.tgEnd.y = d(v)
            case 33: e.spline?.tgEnd.z = d(v)
            case 40:
                if e.spline != nil { e.spline?.knots.append(d(v)) }
                else if let arc = e.arc { arc.radius = d(v) }
                else if let ellipse = e.ellipse { ellipse.ratio = d(v) }
            case 42:
                if e.spline != nil { e.spline?.weights.append(d(v)) }
                else if e.plvert != nil { e.plvert?.bulge = d(v) }
            case 50:
                e.arc?.startAngle = d(v) * .pi / 180.0
                e.ellipse?.startParam = d(v) * .pi / 180.0
            case 51:
                e.arc?.endAngle = d(v) * .pi / 180.0
                e.ellipse?.endParam = d(v) * .pi / 180.0
            case 73:
                if e.spline != nil {
                    e.spline?.flags = (e.spline?.flags ?? 0) | (i(v) != 0 ? 4 : 0)  // rational flag
                } else if let arc = e.arc {
                    arc.isCCW = i(v)
                } else if let ellipse = e.ellipse {
                    ellipse.isCCW = i(v)
                } else if isPolyline {
                    e.pline?.flags = i(v)
                }
            case 74:
                if e.spline != nil {
                    e.spline?.flags = (e.spline?.flags ?? 0) | (i(v) != 0 ? 2 : 0)  // periodic flag
                }
            case 94:
                if e.spline != nil { splineDegree = i(v); e.spline?.degree = splineDegree }
            case 95:
                if e.spline != nil { splineNKnots = i(v); e.spline?.nKnots = Int32(splineNKnots) }
            case 96:
                if e.spline != nil { splineNControl = i(v); e.spline?.nControl = Int32(splineNControl) }
            case 97:
                if e.spline != nil && !splineFitCountSeen {
                    e.spline?.nFit = i32(v)
                    splineFitCountSeen = true
                } else if let loop = currentLoop {
                    sourceHandlesRemaining = min(100_000, max(0, i(v)))
                    loop.sourceBoundaryHandles.removeAll(keepingCapacity: true)
                    loop.sourceBoundaryHandles.reserveCapacity(sourceHandlesRemaining)
                }
            case 330:
                if sourceHandlesRemaining > 0, let loop = currentLoop {
                    loop.sourceBoundaryHandles.append(parseHandle(v))
                    sourceHandlesRemaining -= 1
                }
            case 450: e.isGradient = i(v); e.gradientColors = []
            case 452: e.singleColorGrad = i(v)
            case 453: e.gradientColors.reserveCapacity(min(10_000, i(v)))
            case 460: e.gradientAngle = d(v) * 180.0 / .pi  // radians → degrees
            case 461: e.gradientShift = d(v)
            case 462: e.gradientTint = d(v)
            case 463:
                let pos = d(v)
                e.gradientColors.append((position: pos, aci: 0, rgb: -1))
            case 421:
                let rgb = Int32(i(v))
                if !e.gradientColors.isEmpty {
                    var last = e.gradientColors.removeLast()
                    last.rgb = rgb
                    e.gradientColors.append(last)
                }
            case 470: e.gradientName = decode(v)
            case 98: e.clearEntities()
            default: break
            }
        }
        flushPatternLine()
        return e
    }

    func parseLeader(_ pairs: [(Int, String)]) -> DXFLeaderEntity {
        let e = DXFLeaderEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 3:   e.style = v
            case 10:  e.vertices.append(Vector3(x: d(v), y: 0, z: 0))
            case 20:  if !e.vertices.isEmpty { e.vertices[e.vertices.count-1].y = d(v) }
            case 30:  if !e.vertices.isEmpty { e.vertices[e.vertices.count-1].z = d(v) }
            case 40:  e.textHeight = d(v)
            case 41:  e.textWidth = d(v)
            case 71:  e.arrow = i(v)
            case 72:  e.leaderType = i(v)
            case 73:  e.flag = i(v)
            case 74:  e.hookLine = i(v)
            case 75:  e.hookFlag = i(v)
            case 76:  e.vertNum = i(v)
            case 77:  e.colorUse = i(v)
            case 210: e.extrusionPoint.x = d(v)
            case 220: e.extrusionPoint.y = d(v)
            case 230: e.extrusionPoint.z = d(v)
            case 211: e.horizDir.x = d(v)
            case 221: e.horizDir.y = d(v)
            case 231: e.horizDir.z = d(v)
            case 212: e.offsetBlock.x = d(v)
            case 222: e.offsetBlock.y = d(v)
            case 232: e.offsetBlock.z = d(v)
            case 213: e.offsetText.x = d(v)
            case 223: e.offsetText.y = d(v)
            case 233: e.offsetText.z = d(v)
            case 340: e.annotHandle = parseHandle(v)
            default: break
            }
        }
        return e
    }

    func parseImage(_ pairs: [(Int, String)]) -> DXFImageEntity {
        let e = DXFImageEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 11: e.secPoint.x = d(v)  // U-vector
            case 21: e.secPoint.y = d(v)
            case 31: e.secPoint.z = d(v)
            case 12: e.vVector.x = d(v)   // V-vector
            case 22: e.vVector.y = d(v)
            case 32: e.vVector.z = d(v)
            case 13: e.sizeU = d(v)
            case 23: e.sizeV = d(v)
            case 33: e.dz = d(v)
            case 280: e.clip = i(v)
            case 281: e.brightness = i(v)
            case 282: e.contrast = i(v)
            case 283: e.fade = i(v)
            case 340: e.ref = parseHandle(v)
            default: break
            }
        }
        return e
    }

    func parseViewport(_ pairs: [(Int, String)]) -> DXFViewportEntity {
        let e = DXFViewportEntity()
        applyCommon(pairs, to: e)
        for (c, v) in pairs {
            switch c {
            case 10: e.basePoint.x = d(v)
            case 20: e.basePoint.y = d(v)
            case 30: e.basePoint.z = d(v)
            case 40: e.psWidth = d(v)
            case 41: e.psHeight = d(v)
            case 12: e.centerPX = d(v)
            case 22: e.centerPY = d(v)
            case 17: e.viewTarget.x = d(v)
            case 27: e.viewTarget.y = d(v)
            case 37: e.viewTarget.z = d(v)
            case 45: e.viewHeight = d(v)
            case 51: e.twistAngle = d(v)
            case 68: e.vpStatus = i(v)
            case 69: e.vpID = i(v)
            default: break
            }
        }
        return e
    }

    func parseTable(_ pairs: [(Int, String)]) -> DXFEntity {
        let table = DXFTableEntity()
        applyCommon(pairs, to: table)

        var blockName = ""
        var insertion = Vector3.zero
        var horizontal = Vector3(x: 1, y: 0, z: 0)
        var inAcDbTable = false
        var sawHorizontal = false

        for (c, v) in pairs {
            if c == 100 {
                inAcDbTable = v.uppercased() == "ACDBTABLE"
                continue
            }

            if !inAcDbTable {
                switch c {
                case 2: if blockName.isEmpty { blockName = v }
                case 10: insertion.x = d(v)
                case 20: insertion.y = d(v)
                case 30: insertion.z = d(v)
                default: break
                }
            } else {
                switch c {
                case 11: horizontal.x = d(v); sawHorizontal = true
                case 21: horizontal.y = d(v)
                case 31: horizontal.z = d(v)
                default: break
                }
            }
        }

        guard !blockName.isEmpty else { return table }

        let insert = DXFInsertEntity()
        applyCommon(pairs, to: insert)
        insert.name = blockName
        insert.basePoint = insertion
        insert.xScale = 1.0
        insert.yScale = 1.0
        insert.zScale = 1.0
        insert.colCount = 1
        insert.rowCount = 1
        insert.angle = sawHorizontal ? atan2(horizontal.y, horizontal.x) : 0.0
        return insert
    }

    // MARK: - Table entry parsers

    func parseLayer(at startIdx: Int) throws {
        let entry = DXFLayerEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = decode(v)
            case 5:   entry.handle = parseHandle(v)
            case 6:   entry.lineType = decode(v)
            case 62:  entry.color = i32(v)
            case 70:  entry.flags = i(v)
            case 290: entry.plotFlag = i(v) != 0
            case 370: entry.lWeight = dxfLineWeightVal(v)
            case 390: entry.plotStyleHandle = parseHandle(v)
            case 420: entry.color24 = i32(v)
            case 440: entry.transparency = i32(v)
            default:  break
            }
        }
        layers.append(entry)
    }

    func parseLType(at startIdx: Int) throws {
        let entry = DXFLTypeEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 3:   entry.desc = v
            case 5:   entry.handle = parseHandle(v)
            case 40:  entry.length = d(v)
            case 49:  entry.path.append(d(v))
            case 70:  entry.flags = i(v)
            case 73:  entry.size = i(v)
            default:  break
            }
        }
        ltypes.append(entry)
    }

    func parseDimstyle(at startIdx: Int) throws {
        let entry = DXFDimstyleEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 3:   entry.dimpost = v
            case 4:   entry.dimapost = v
            case 5:   entry.dimblk = v
            case 6:   entry.dimblk1 = v
            case 7:   entry.dimblk2 = v
            case 40:  entry.dimscale = d(v)
            case 41:  entry.dimasz = d(v)
            case 42:  entry.dimexo = d(v)
            case 43:  entry.dimdli = d(v)
            case 44:  entry.dimexe = d(v)
            case 45:  entry.dimrnd = d(v)
            case 46:  entry.dimdle = d(v)
            case 47:  entry.dimtp = d(v)
            case 48:  entry.dimtm = d(v)
            case 49:  entry.dimfxl = d(v)
            case 70:  entry.flags = i(v)
            case 71:  entry.dimtol = i(v)
            case 72:  entry.dimlim = i(v)
            case 73:  entry.dimtih = i(v)
            case 74:  entry.dimtoh = i(v)
            case 75:  entry.dimse1 = i(v)
            case 76:  entry.dimse2 = i(v)
            case 77:  entry.dimtad = i(v)
            case 78:  entry.dimzin = i(v)
            case 79:  entry.dimazin = i(v)
            case 140: entry.dimtxt = d(v)
            case 141: entry.dimcen = d(v)
            case 142: entry.dimtsz = d(v)
            case 143: entry.dimaltf = d(v)
            case 144: entry.dimlfac = d(v)
            case 145: entry.dimtvp = d(v)
            case 146: entry.dimtfac = d(v)
            case 147: entry.dimgap = d(v)
            case 148: entry.dimaltrnd = d(v)
            case 170: entry.dimalt = i(v)
            case 171: entry.dimaltd = i(v)
            case 172: entry.dimtofl = i(v)
            case 173: entry.dimsah = i(v)
            case 174: entry.dimtix = i(v)
            case 175: entry.dimsoxd = i(v)
            case 176: entry.dimclrd = i(v)
            case 177: entry.dimclre = i(v)
            case 178: entry.dimclrt = i(v)
            case 179: entry.dimadec = i(v)
            case 271: entry.dimdec = i(v)
            case 272: entry.dimtdec = i(v)
            case 273: entry.dimaltu = i(v)
            case 274: entry.dimalttd = i(v)
            case 275: entry.dimaunit = i(v)
            case 276: entry.dimfrac = i(v)
            case 277: entry.dimlunit = i(v)
            case 278: entry.dimdsep = i(v)
            case 279: entry.dimtmove = i(v)
            case 280: entry.dimjust = i(v)
            case 281: entry.dimsd1 = i(v)
            case 282: entry.dimsd2 = i(v)
            case 283: entry.dimtolj = i(v)
            case 284: entry.dimtzin = i(v)
            case 285: entry.dimaltz = i(v)
            case 286: entry.dimaltttz = i(v)
            case 287: entry.dimfit = i(v)
            case 288: entry.dimupt = i(v)
            case 289: entry.dimatfit = i(v)
            case 290: entry.dimfxlon = i(v)
            case 340: entry.dimtxstyHandle = parseHandle(v)
            case 341: entry.dimldrblkHandle = parseHandle(v)
            case 342: entry.dimblkHandle = parseHandle(v)
            case 343: entry.dimblk1Handle = parseHandle(v)
            case 344: entry.dimblk2Handle = parseHandle(v)
            case 371: entry.dimlwd = i(v)
            case 372: entry.dimlwe = i(v)
            default:  break
            }
        }
        dimstyles.append(entry)
    }

    func parseStyle(at startIdx: Int) throws {
        let entry = DXFStyleEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 3:   entry.font = v
            case 4:   entry.bigFont = v
            case 5:   entry.handle = parseHandle(v)
            case 40:  entry.height = d(v)
            case 41:  entry.width = d(v)
            case 42:  entry.lastHeight = d(v)
            case 50:  entry.oblique = d(v)
            case 70:  entry.flags = i(v)
            case 71:  entry.genFlag = i(v)
            case 1071: entry.fontFamily = i(v)
            default:  break
            }
        }
        textstyles.append(entry)
    }

    func parseVport(at startIdx: Int) throws {
        let entry = DXFVportEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 5:   entry.handle = parseHandle(v)
            case 10:  entry.lowerLeft.x = d(v)
            case 20:  entry.lowerLeft.y = d(v)
            case 11:  entry.upperRight.x = d(v)
            case 21:  entry.upperRight.y = d(v)
            case 12:  entry.center.x = d(v)
            case 22:  entry.center.y = d(v)
            case 13:  entry.snapBase.x = d(v)
            case 23:  entry.snapBase.y = d(v)
            case 14:  entry.snapSpacing.x = d(v)
            case 24:  entry.snapSpacing.y = d(v)
            case 15:  entry.gridSpacing.x = d(v)
            case 25:  entry.gridSpacing.y = d(v)
            case 16:  entry.viewDir.x = d(v)
            case 26:  entry.viewDir.y = d(v)
            case 36:  entry.viewDir.z = d(v)
            case 17:  entry.viewTarget.x = d(v)
            case 27:  entry.viewTarget.y = d(v)
            case 37:  entry.viewTarget.z = d(v)
            case 40:  entry.height = d(v)
            case 41:  entry.ratio = d(v)
            case 42:  entry.lensHeight = d(v)
            case 43:  entry.frontClip = d(v)
            case 44:  entry.backClip = d(v)
            case 50:  entry.snapAngle = d(v)
            case 51:  entry.twistAngle = d(v)
            case 60:  entry.gridBehavior = i(v)
            case 70:  entry.flags = i(v)
            case 71:  entry.viewMode = i(v)
            case 72:  entry.circleZoom = i(v)
            case 73:  entry.fastZoom = i(v)
            case 74:  entry.ucsIcon = i(v)
            case 75:  entry.snap = i(v)
            case 76:  entry.grid = i(v)
            case 77:  entry.snapStyle = i(v)
            case 78:  entry.snapIsopair = i(v)
            default:  break
            }
        }
        vports.append(entry)
    }

    func parseAppId(at startIdx: Int) throws {
        let entry = DXFAppIdEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 5:   entry.handle = parseHandle(v)
            case 70:  entry.flags = i(v)
            default:  break
            }
        }
        appids.append(entry)
    }

    func parseBlockRecord(at startIdx: Int) throws {
        let entry = DXFBlockRecordEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 2:   entry.name = v
            case 5:   entry.handle = parseHandle(v)
            case 70:  entry.flags = i(v)
            case 10:  entry.basePoint.x = d(v)
            case 20:  entry.basePoint.y = d(v)
            case 30:  entry.basePoint.z = d(v)
            default:  break
            }
        }
        blockRecords.append(entry)
    }

    func parseImageDef(at startIdx: Int) throws {
        let entry = DXFImageDefEntry()
        var idx = startIdx
        idx += 1
        while idx < pairs.count {
            let (c, v) = pairs[idx]; idx += 1
            if c == 0 { pos = idx - 1; break }
            switch c {
            case 1:   entry.name_p = v
            case 5:   entry.handle = parseHandle(v)
            case 10:  entry.u = d(v)
            case 20:  entry.v = d(v)
            case 11:  entry.up = d(v)
            case 21:  entry.vp = d(v)
            case 70:  entry.flags = i(v)
            case 90:  entry.imgVersion = i(v)
            case 280: entry.loaded = i(v)
            case 281: entry.resolution = i(v)
            default:  break
            }
        }
        imagedefs.append(entry)
    }

    // MARK: - OBJECTS section

    private func parseObjects() throws {
        while pos < pairs.count {
            let (c, v) = pairs[pos]
            if c == 0 && v == "ENDSEC" { pos += 1; return }
            if c == 0 && v == "IMAGEDEF" {
                tryParse { try parseImageDef(at: pos) }
            } else {
                pos += 1
            }
        }
    }

    private func resolveImageReferences() {
        guard !imagedefs.isEmpty else { return }
        var pathByHandle: [UInt32: String] = [:]
        for def in imagedefs where def.handle != 0 && !def.name_p.isEmpty {
            pathByHandle[def.handle] = def.name_p
        }
        guard !pathByHandle.isEmpty else { return }

        func resolve(_ list: [DXFEntity]) {
            for entity in list {
                if let image = entity as? DXFImageEntity, let path = pathByHandle[image.ref] {
                    image.imageFilePath = path
                }
                if let block = entity as? DXFBlockEntity { resolve(block.entities) }
            }
        }

        resolve(entities)
        for block in blocks { resolve(block.entities) }
    }

    // MARK: - BLOCKS section

    private func parseBlocks() throws {
        while pos < pairs.count {
            let (c, v) = pairs[pos]
            if c == 0 && v == "ENDSEC" { pos += 1; return }

            if c == 0 && v == "BLOCK" {
                // Skip the 0/BLOCK pair - we'll handle it in parseBlock
                let blockStart = pos
                pos += 1
                if let block = try parseBlock(at: blockStart) {
                    blocks.append(block)
                }
            } else {
                pos += 1
            }
        }
    }

    private func parseBlock(at startPos: Int) throws -> DXFBlockEntity? {
        let block = DXFBlockEntity()

        // Read header properties until next 0-pair (entity type or ENDBLK)
        while pos < pairs.count {
            let (c, v) = pairs[pos]; pos += 1
            if c == 0 {
                // Back up so entity loop sees this 0-pair
                pos -= 1
                break
            }
            switch c {
            case 2:   block.name = v
            case 5:   block.handle = parseHandle(v)
            case 8:   block.layer = v
            case 10:  block.basePoint.x = d(v)
            case 20:  block.basePoint.y = d(v)
            case 30:  block.basePoint.z = d(v)
            case 70:  block.flags = i(v)
            default:  break
            }
        }

        // Parse entities inside block until ENDBLK
        while pos < pairs.count {
            let (c, v) = pairs[pos]
            if c == 0 && v == "ENDBLK" {
                pos += 1  // consume ENDBLK, done
                break
            }
            if c == 0 {
                if let entity = try parseEntity(at: &pos) {
                    block.entities.append(entity)
                }
            } else {
                pos += 1
            }
        }

        return block
    }

    // MARK: - Helpers

    func applyCommon(_ pairs: [(Int, String)], to entity: DXFEntity) {
        var inAppData = false
        var currentAppBlock: [(code: Int, value: Any)] = []
        
        func flushAppBlock() {
            if !currentAppBlock.isEmpty {
                entity.appData.append(currentAppBlock)
                currentAppBlock = []
            }
        }
        
        for (c, v) in pairs {
            if c == 102 {
                let t = v.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("{") {
                    flushAppBlock()
                    inAppData = true
                    currentAppBlock = [(102, String(t.dropFirst()))]
                } else if t == "}" {
                    if inAppData {
                        currentAppBlock.append((102, "}"))
                        flushAppBlock()
                        inAppData = false
                    }
                }
                continue
            }
            if inAppData {
                currentAppBlock.append((c, v))
            }
            switch c {
            case 5:   entity.handle = parseHandle(v)
            case 6:   entity.lineType = decode(v)
            case 8:   entity.layer = decode(v)
            case 39:  entity.thickness = d(v)
            case 48:  entity.ltypeScale = d(v)
            case 60:  entity.visible = i(v) == 0
            case 62:  entity.color = i32(v)
            case 67:  entity.space = i(v)
            case 210: entity.extrusion.x = d(v); entity.haveExtrusion = true
            case 220: entity.extrusion.y = d(v)
            case 230: entity.extrusion.z = d(v)
            case 330: entity.parentHandle = parseHandle(v)
            case 370: entity.lWeight = dxfLineWeightVal(v)
            case 390: entity.plotStyleHandle = parseHandle(v)
            case 420: entity.color24 = i32(v)
            case 430: entity.colorName = decode(v)
            case 440: entity.transparency = i32(v)
            case 1000, 1001, 1002, 1003, 1004, 1005:
                entity.extendedData.append((c, decode(v)))
            case 1010, 1011, 1012, 1013:
                entity.extendedData.append((c, d(v)))
            case 1020, 1021, 1022, 1023: break
            case 1040, 1041, 1042:
                if !inAppData { entity.extendedData.append((c, d(v))) }
            case 1070:
                if !inAppData { entity.extendedData.append((c, i(v))) }
            case 1071:
                if !inAppData { entity.extendedData.append((c, i32(v))) }
            default:  break
            }
        }
        if inAppData { flushAppBlock() }
    }

    /// Decode string through text codec
    func decode(_ s: String) -> String {
        return textCodec.toUtf8(s)
    }

    func d(_ s: String) -> Double { return Double(s) ?? 0.0 }
    func i(_ s: String) -> Int { return Int(s) ?? 0 }
    func i32(_ s: String) -> Int32 { return Int32(s) ?? 0 }
    func parseHandle(_ s: String) -> UInt32 { return UInt32(s.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) ?? 0 }
    func dxfLineWeightVal(_ s: String) -> DXFLineWidth { return DXFLineWidth.fromDXF(Int(s) ?? -3) }
}

// MARK: - DXF Header data container

public struct DXFHeaderData {
    public var acadVer: String = ""
    public var codePage: String = ""
    public var insBase: Vector3 = .zero
    public var extMin: Vector3 = .zero
    public var extMax: Vector3 = .zero
    public var currentLayer: String = "0"
    public var textSize: Double = 2.5
    public var ltScale: Double = 1.0
    public var celScale: Double = 1.0
    public var currentColor: Int32 = 256
    public var currentLinetype: String = "BYLAYER"
    public var currentLineWeight: Int = -1
    public var lUnits: Int = 2
    public var luPrec: Int = 4
    public var insUnits: Int = 0
    public var measurement: Int = 1
    /// Generic capture of ALL header variables (including unknowns)
    public var headerVars: [String: Any] = [:]
}