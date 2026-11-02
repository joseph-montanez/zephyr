import Foundation

// =========================================================================
// MARK: - CADTrueTypeFont
//
// Minimal TrueType (sfnt) reader for the PDF export text pipeline.
//
// The screen renders TTF text through SDL_ttf raster sprites; PDF needs the
// same metrics without an SDL dependency so layout matches:
// advances for line breaking (shared with `CADTextFormatter`), glyph IDs and
// Unicode maps for font embedding, and glyph outlines for the
// convert-to-geometry export mode.
//
// Supported: TrueType-flavored OpenType (glyf outlines), cmap formats 4 and
// 12, loca short/long. CFF-flavored `.otf` (`CFF `/`CFF2` table) reports
// `hasGlyphOutlines == false` — such fonts can still be embedded but not
// converted to geometry.

public final class CADTrueTypeFont: @unchecked Sendable {

    public enum ParseError: Error, Sendable {
        case tooShort
        case badSignature
        case missingTable(String)
        case unsupportedCmap
        case badTableOffset
    }

    /// One glyph contour as a point loop. `onCurve[i]` parallels `points[i]`.
    public struct Contour: Sendable {
        public let points: [(x: Double, y: Double)]
        public let onCurve: [Bool]
    }

    public struct GlyphOutline: Sendable {
        public let contours: [Contour]
        /// Advance width in font units.
        public let advance: Int
        /// Left side bearing in font units.
        public let lsb: Int
    }

    private let data: Data
    private let tableStart: [String: Int]
    private let numGlyphs: Int
    /// Number of glyphs in the font (maxp.numGlyphs).
    public var glyphCount: Int { numGlyphs }
    private let locaIsLong: Bool
    private let locaOffset: Int
    private let glyfOffset: Int
    private let hmtxOffset: Int
    private let numHMetrics: Int
    private let maxAdvance: Int

    /// Font units per em (head.unitsPerEm).
    public let unitsPerEm: Int
    /// Family name from the name table (ID 1), if present.
    public let familyName: String?
    /// PostScript name from the name table (ID 6), sanitized for PDF
    /// BaseFont use (no spaces), falling back to the family name.
    public let postScriptName: String
    /// Cap height in font units (OS/2 sCapHeight when present).
    public let capHeightUnits: Int
    /// hhea ascender, descender (negative), and line gap, in font units.
    public let ascentUnits: Int
    public let descentUnits: Int
    public let lineGapUnits: Int
    /// head font bounding box in font units (xMin, yMin, xMax, yMax).
    public let boundingBox: (Int, Int, Int, Int)
    /// Whether the OS/2 fsType bits permit embedding.
    public let embeddingAllowed: Bool
    /// False for CFF-flavored fonts, which carry no glyf outlines.
    public let hasGlyphOutlines: Bool
    /// Raw font file bytes (embedded whole into the PDF FontFile2 stream).
    public var rawData: Data { data }

    /// Content fingerprint for export dedupe: two copies of the same face
    /// (repo Fonts/ vs system fonts) share one embedded object.
    public var fingerprint: String {
        var hasher = Hasher()
        hasher.combine(data.count)
        let headCount = min(512, data.count)
        if headCount > 0 {
            hasher.combine(data.prefix(headCount))
        }
        if data.count > 512 {
            hasher.combine(data.suffix(512))
        }
        return "\(data.count)-\(hasher.finalize())"
    }

    // MARK: - Load

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 12 else { throw ParseError.tooShort }
        let signature = CADTrueTypeFont.u32(data, 0)
        // 0x00010000 (TrueType), 'true', 'typ1', 'OTTO' (CFF-flavored).
        guard signature == 0x00010000 || signature == 0x74727565
            || signature == 0x74797031 || signature == 0x4F54544F
        else { throw ParseError.badSignature }
        self.data = data

        let numTables = Int(CADTrueTypeFont.u16(data, 4))
        var tables: [String: Int] = [:]
        for i in 0..<numTables {
            let base = 12 + i * 16
            guard base + 16 <= data.count else { throw ParseError.tooShort }
            let tag = String(bytes: data[base..<(base + 4)], encoding: .ascii) ?? ""
            let offset = Int(CADTrueTypeFont.u32(data, base + 8))
            let length = Int(CADTrueTypeFont.u32(data, base + 12))
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw ParseError.badTableOffset
            }
            tables[tag] = offset
        }
        self.tableStart = tables

        guard let head = tables["head"] else { throw ParseError.missingTable("head") }
        guard let maxp = tables["maxp"] else { throw ParseError.missingTable("maxp") }
        guard let hhea = tables["hhea"] else { throw ParseError.missingTable("hhea") }
        guard let hmtx = tables["hmtx"] else { throw ParseError.missingTable("hmtx") }
        guard tables["cmap"] != nil else { throw ParseError.missingTable("cmap") }
        guard let loca = tables["loca"] else { throw ParseError.missingTable("loca") }
        let locaLong = CADTrueTypeFont.i16(data, head + 50) != 0
        self.locaIsLong = locaLong
        self.locaOffset = loca
        self.unitsPerEm = max(16, Int(CADTrueTypeFont.u16(data, head + 18)))
        self.numGlyphs = Int(CADTrueTypeFont.u16(data, maxp + 4))
        self.numHMetrics = Int(CADTrueTypeFont.u16(data, hhea + 34))
        self.hmtxOffset = hmtx
        self.glyfOffset = tables["glyf"] ?? -1
        self.hasGlyphOutlines = tables["glyf"] != nil
            && tables["CFF "] == nil && tables["CFF2"] == nil

        if let os2 = tables["OS/2"], os2 + 78 <= data.count {
            let fsType = Int(CADTrueTypeFont.u16(data, os2 + 8))
            // Bit 1 (0x0002): restricted — must not embed. Any other
            // setting (installable, preview/print, editable) permits
            // embedding for a document like our PDF export.
            self.embeddingAllowed = (fsType & 0x0002) == 0
        } else {
            self.embeddingAllowed = true
        }

        let names: (family: String?, postScript: String?)
        if let nameTable = tables["name"] {
            names = CADTrueTypeFont.readNames(data: data, table: nameTable)
        } else {
            names = (nil, nil)
        }
        self.familyName = names.family
        if let ps = names.postScript, !ps.isEmpty {
            self.postScriptName = CADTrueTypeFont.sanitizePostScriptName(ps)
        } else if let family = names.family, !family.isEmpty {
            self.postScriptName = CADTrueTypeFont.sanitizePostScriptName(family)
        } else {
            self.postScriptName = "Unknown"
        }

        let upm = self.unitsPerEm
        if let os2 = tables["OS/2"], os2 + 96 <= data.count {
            let version = Int(CADTrueTypeFont.u16(data, os2))
            var cap = 0
            if version >= 2 {
                cap = Int(CADTrueTypeFont.i16(data, os2 + 88))
            }
            self.capHeightUnits = cap > 0 ? cap : (upm * 716) / 1000
        } else {
            self.capHeightUnits = (upm * 716) / 1000
        }

        self.ascentUnits = Int(CADTrueTypeFont.i16(data, hhea + 4))
        self.descentUnits = Int(CADTrueTypeFont.i16(data, hhea + 6))
        self.lineGapUnits = Int(CADTrueTypeFont.i16(data, hhea + 8))
        self.boundingBox = (
            Int(CADTrueTypeFont.i16(data, head + 36)),
            Int(CADTrueTypeFont.i16(data, head + 38)),
            Int(CADTrueTypeFont.i16(data, head + 40)),
            Int(CADTrueTypeFont.i16(data, head + 42)))

        var maxAdv = 0
        let hCount = min(numHMetrics, numGlyphs)
        for i in 0..<hCount {
            maxAdv = max(maxAdv, Int(CADTrueTypeFont.u16(data, hmtx + i * 4)))
        }
        self.maxAdvance = maxAdv
    }

    // MARK: - Raw accessors (big-endian)

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func i16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    // MARK: - Character map

    /// Glyph ID for a Unicode scalar (0 = .notdef when unmapped).
    public func glyphID(for scalar: Unicode.Scalar) -> Int {
        guard let cmap = tableStart["cmap"] else { return 0 }
        let value = scalar.value
        let numSubtables = Int(CADTrueTypeFont.u16(data, cmap + 2))
        var format4: Int? = nil
        var format12: Int? = nil
        var unicodeBMP: Int? = nil
        for i in 0..<numSubtables {
            let base = cmap + 4 + i * 8
            guard base + 8 <= data.count else { break }
            let platform = Int(CADTrueTypeFont.u16(data, base))
            let encoding = Int(CADTrueTypeFont.u16(data, base + 2))
            let offset = Int(CADTrueTypeFont.u32(data, base + 4))
            guard cmap + offset + 2 <= data.count else { continue }
            let format = Int(CADTrueTypeFont.u16(data, cmap + offset))
            if (platform == 3 && encoding == 10) || (platform == 0 && encoding >= 3) {
                // Unicode full repertoire.
                if format == 12 { format12 = cmap + offset }
            }
            if (platform == 3 && encoding == 1) || (platform == 0 && encoding == 3) {
                if format == 4 { unicodeBMP = cmap + offset }
            }
            if format == 4, format4 == nil { format4 = cmap + offset }
        }
        // Prefer format 12 (covers non-BMP); fall back to BMP tables.
        if let table = format12 ?? unicodeBMP ?? format4 {
            let format = Int(CADTrueTypeFont.u16(data, table))
            if format == 12 {
                return CADTrueTypeFont.lookupCmap12(data: data, table: table, scalar: value)
            } else if format == 4 {
                return CADTrueTypeFont.lookupCmap4(
                    data: data, table: table, scalar: value > 0xFFFF ? 0 : Int(value))
            }
        }
        return 0
    }

    private static func lookupCmap4(data: Data, table: Int, scalar: Int) -> Int {
        guard scalar >= 0, scalar <= 0xFFFF else { return 0 }
        let segCount = Int(u16(data, table + 6)) / 2
        guard segCount > 0 else { return 0 }
        let endBase = table + 14
        let startBase = endBase + segCount * 2 + 2
        let deltaBase = startBase + segCount * 2
        let rangeBase = deltaBase + segCount * 2
        for i in 0..<segCount {
            let end = Int(u16(data, endBase + i * 2))
            let start = Int(u16(data, startBase + i * 2))
            if scalar < start || scalar > end { continue }
            let delta = Int(i16(data, deltaBase + i * 2))
            let rangeOffset = Int(u16(data, rangeBase + i * 2))
            if rangeOffset == 0 {
                return (scalar + delta) & 0xFFFF
            }
            let glyphAddr = rangeBase + i * 2 + rangeOffset + (scalar - start) * 2
            guard glyphAddr + 2 <= data.count else { return 0 }
            let glyph = Int(u16(data, glyphAddr))
            if glyph == 0 { return 0 }
            return (glyph + delta) & 0xFFFF
        }
        return 0
    }

    private static func lookupCmap12(data: Data, table: Int, scalar: UInt32) -> Int {
        let numGroups = Int(u32(data, table + 12))
        var lo = 0
        var hi = numGroups - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let base = table + 16 + mid * 12
            guard base + 12 <= data.count else { return 0 }
            let start = u32(data, base)
            let end = u32(data, base + 4)
            if scalar < start {
                hi = mid - 1
            } else if scalar > end {
                lo = mid + 1
            } else {
                return Int(u32(data, base + 8)) + Int(scalar - start)
            }
        }
        return 0
    }

    // MARK: - Advances

    /// Advance width of a glyph in font units.
    public func advanceWidth(glyphID: Int) -> Int {
        guard glyphID >= 0, glyphID < numGlyphs else { return 0 }
        if glyphID < numHMetrics {
            return Int(CADTrueTypeFont.u16(data, hmtxOffset + glyphID * 4))
        }
        // Remaining glyphs share the last advance.
        if numHMetrics > 0 {
            return Int(CADTrueTypeFont.u16(data, hmtxOffset + (numHMetrics - 1) * 4))
        }
        return 0
    }

    /// Advance width of a string in em units (sum of glyph advances;
    /// kerning is intentionally ignored in v1 — see plan).
    public func widthEm(of text: String) -> Double {
        var total = 0
        for scalar in text.unicodeScalars {
            total += advanceWidth(glyphID: glyphID(for: scalar))
        }
        return Double(total) / Double(unitsPerEm)
    }

    /// Width of a string in thousandths of an em (PDF /W units).
    public func widthThousandths(of text: String) -> Int {
        Int((widthEm(of: text) * 1000).rounded())
    }

    // MARK: - Name table

    /// PDF BaseFont names must be PostScript names (no spaces or parens).
    static func sanitizePostScriptName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if v < 33 || v > 126 || scalar == "(" || scalar == ")"
                || scalar == "<" || scalar == ">" || scalar == "["
                || scalar == "]" || scalar == "{" || scalar == "}"
                || scalar == "/" || scalar == "%" || scalar == "#" {
                return "-"
            }
            return Character(scalar)
        }
        let result = String(cleaned)
        return result.isEmpty ? "Unknown" : result
    }

    private static func readNames(data: Data, table: Int) -> (family: String?, postScript: String?) {
        guard table + 6 <= data.count else { return (nil, nil) }
        let count = Int(u16(data, table + 2))
        let storage = table + Int(u16(data, table + 4))
        var family: String? = nil
        var postScript: String? = nil
        for i in 0..<count {
            let base = table + 6 + i * 12
            guard base + 12 <= data.count else { break }
            let platform = Int(u16(data, base))
            let encoding = Int(u16(data, base + 2))
            let nameID = Int(u16(data, base + 6))
            guard nameID == 1 || nameID == 4 || nameID == 6 else { continue }
            let length = Int(u16(data, base + 8))
            let offset = Int(u16(data, base + 10))
            guard storage + offset + length <= data.count, length > 0 else { continue }
            let bytes = data[(storage + offset)..<(storage + offset + length)]
            let value: String?
            if platform == 3 || (platform == 0) {
                value = String(data: Data(bytes), encoding: .utf16BigEndian)
            } else if platform == 1 && encoding == 0 {
                value = String(data: Data(bytes), encoding: .macOSRoman)
            } else {
                value = String(data: Data(bytes), encoding: .utf8)
            }
            guard let value, !value.isEmpty else { continue }
            if nameID == 6 {
                if postScript == nil || platform == 3 { postScript = value }
            } else {
                if family == nil || (platform == 3 && nameID == 1) { family = value }
            }
        }
        return (family, postScript)
    }

    // MARK: - Glyph outlines (glyf)

    private func glyphByteRange(glyphID: Int) -> Range<Int>? {
        guard glyphID >= 0, glyphID < numGlyphs, glyfOffset >= 0 else { return nil }
        func offset(_ index: Int) -> Int {
            if locaIsLong {
                return glyfOffset + Int(CADTrueTypeFont.u32(data, locaOffset + index * 4))
            }
            return glyfOffset + Int(CADTrueTypeFont.u16(data, locaOffset + index * 2)) * 2
        }
        let start = offset(glyphID)
        let end = offset(glyphID + 1)
        guard start <= end, start >= glyfOffset, end <= data.count else { return nil }
        return start..<end
    }

    /// Outline of a glyph in font units (y-up). Empty glyphs (space) yield
    /// no contours. Returns nil for CFF fonts or unreadable data.
    public func outline(glyphID: Int, depth: Int = 0) -> GlyphOutline? {
        guard hasGlyphOutlines, depth < 8 else { return nil }
        let advance = advanceWidth(glyphID: glyphID)
        guard let range = glyphByteRange(glyphID: glyphID) else {
            return GlyphOutline(contours: [], advance: advance, lsb: 0)
        }
        guard range.count >= 10 else {
            return GlyphOutline(contours: [], advance: advance, lsb: 0)
        }
        let base = range.lowerBound
        let numContours = Int(CADTrueTypeFont.i16(data, base))
        let lsb = Int(CADTrueTypeFont.i16(data, base + 4))
        if numContours == 0 {
            return GlyphOutline(contours: [], advance: advance, lsb: lsb)
        }
        if numContours > 0 {
            return GlyphOutline(
                contours: parseSimpleGlyph(base: base, numContours: numContours),
                advance: advance, lsb: lsb)
        }
        // Composite glyph: recurse into components with their transforms.
        var contours: [Contour] = []
        var pos = base + 10
        var guard_ = 0
        while guard_ < 64 {
            guard_ += 1
            guard pos + 4 <= range.upperBound else { break }
            let flags = Int(CADTrueTypeFont.u16(data, pos))
            let component = Int(CADTrueTypeFont.u16(data, pos + 2))
            pos += 4
            var arg1 = 0, arg2 = 0
            if flags & 0x0001 != 0 {
                guard pos + 4 <= range.upperBound else { break }
                arg1 = Int(CADTrueTypeFont.i16(data, pos))
                arg2 = Int(CADTrueTypeFont.i16(data, pos + 2))
                pos += 4
            } else {
                guard pos + 2 <= range.upperBound else { break }
                arg1 = Int(data[pos]); arg2 = Int(data[pos + 1])
                pos += 2
            }
            var a = 1.0, b = 0.0, c = 0.0, d = 1.0
            if flags & 0x0008 != 0 {
                guard pos + 2 <= range.upperBound else { break }
                a = Double(CADTrueTypeFont.i16(data, pos)) / 16384.0
                d = a
                pos += 2
            } else if flags & 0x0040 != 0 {
                guard pos + 4 <= range.upperBound else { break }
                a = Double(CADTrueTypeFont.i16(data, pos)) / 16384.0
                d = Double(CADTrueTypeFont.i16(data, pos + 2)) / 16384.0
                pos += 4
            } else if flags & 0x0080 != 0 {
                guard pos + 8 <= range.upperBound else { break }
                a = Double(CADTrueTypeFont.i16(data, pos)) / 16384.0
                b = Double(CADTrueTypeFont.i16(data, pos + 2)) / 16384.0
                c = Double(CADTrueTypeFont.i16(data, pos + 4)) / 16384.0
                d = Double(CADTrueTypeFont.i16(data, pos + 6)) / 16384.0
                pos += 8
            }
            // WE_HAVE_INSTRUCTIONS: skip them.
            // Compound point matching (ARGS_ARE_XY_VALUES clear) is rare in
            // body-text fonts; treat args as offsets regardless.
            let (dx, dy): (Double, Double)
            if flags & 0x0001 != 0 {
                let scale = (flags & 0x0002) != 0 ? 1.0 : Double(unitsPerEm) / 2048.0
                dx = Double(arg1) * scale; dy = Double(arg2) * scale
            } else {
                dx = Double(arg1); dy = Double(arg2)
            }
            if let sub = outline(glyphID: component, depth: depth + 1) {
                for contour in sub.contours {
                    let pts = contour.points.map { pt -> (x: Double, y: Double) in
                        (x: a * pt.x + c * pt.y + dx, y: b * pt.x + d * pt.y + dy)
                    }
                    contours.append(Contour(points: pts, onCurve: contour.onCurve))
                }
            }
            if flags & 0x0020 == 0 { break }
        }
        return GlyphOutline(contours: contours, advance: advance, lsb: lsb)
    }

    private func parseSimpleGlyph(base: Int, numContours: Int) -> [Contour] {
        // endPtsOfContours[numContours], instructionLength, instructions.
        var pos = base + 10 + numContours * 2
        guard pos + 2 <= data.count else { return [] }
        let instrLen = Int(CADTrueTypeFont.u16(data, pos))
        pos += 2 + instrLen
        guard pos <= data.count else { return [] }
        var endPts: [Int] = []
        for i in 0..<numContours {
            endPts.append(Int(CADTrueTypeFont.u16(data, base + 10 + i * 2)))
        }
        let numPoints = (endPts.last ?? -1) + 1
        guard numPoints > 0 else { return [] }
        // Flags (with repeats).
        var flags: [UInt8] = []
        while flags.count < numPoints {
            guard pos < data.count else { return [] }
            let flag = data[pos]; pos += 1
            flags.append(flag)
            if flag & 0x08 != 0 {
                guard pos < data.count else { return [] }
                let count = Int(data[pos]); pos += 1
                for _ in 0..<count { flags.append(flag) }
            }
        }
        // X coordinates (delta-encoded).
        var xs: [Double] = .init(repeating: 0, count: numPoints)
        var x = 0
        for i in 0..<numPoints {
            let flag = flags[i]
            if flag & 0x02 != 0 {
                guard pos < data.count else { return [] }
                let v = Int(data[pos]); pos += 1
                x += (flag & 0x10 != 0) ? v : -v
            } else if flag & 0x10 == 0 {
                guard pos + 2 <= data.count else { return [] }
                x += Int(CADTrueTypeFont.i16(data, pos)); pos += 2
            }
            xs[i] = Double(x)
        }
        var ys: [Double] = .init(repeating: 0, count: numPoints)
        var y = 0
        for i in 0..<numPoints {
            let flag = flags[i]
            if flag & 0x04 != 0 {
                guard pos < data.count else { return [] }
                let v = Int(data[pos]); pos += 1
                y += (flag & 0x20 != 0) ? v : -v
            } else if flag & 0x20 == 0 {
                guard pos + 2 <= data.count else { break }
                y += Int(CADTrueTypeFont.i16(data, pos)); pos += 2
            }
            ys[i] = Double(y)
        }
        var contours: [Contour] = []
        var start = 0
        for end in endPts {
            guard end < numPoints else { break }
            var pts: [(x: Double, y: Double)] = []
            var onCurve: [Bool] = []
            for i in start...end {
                pts.append((x: xs[i], y: ys[i]))
                onCurve.append(flags[i] & 0x01 != 0)
            }
            contours.append(Contour(points: pts, onCurve: onCurve))
            start = end + 1
        }
        return contours
    }
}

