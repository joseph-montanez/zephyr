import Foundation

// =========================================================================
// MARK: - SHXShapeFont
//
// Parses AutoCAD .SHX shape font files and renders text as vector line-segment
// geometry. SHX fonts encode each glyph as a series of (length, direction)
// bytes with special control codes — pure vector data with no textures or
// rasterization, making them perfect at any zoom level.
//
// Format reference: "AutoCAD Shape Font File Format"
// - Header: null-terminated ASCII text (e.g. "AutoCAD-86 unifont 1.0")
// - Glyph table: (shapeNumber, dataLength) pairs
// - Glyph data: vector bytes terminated by byte 0

// =========================================================================
// MARK: - SHXShapeFont
// =========================================================================

/// Parses an AutoCAD .SHX shape font file and renders text as line-segment geometry.
///
/// SHX fonts encode each glyph as a series of (length, direction) bytes along with
/// special control codes. This is pure vector data — no textures, no rasterization,
/// perfect at any zoom level.
///
/// Format reference: "AutoCAD Shape Font File Format"
/// - Header: null-terminated ASCII text (e.g. "AutoCAD-86 unifont 1.0")
/// - Glyph table: for each glyph: shapeNumber(u16), dataLength(u16)
/// - Glyph data: vector/special bytes, terminated by byte 0
public final class SHXShapeFont: @unchecked Sendable {

    /// Decoded glyph: a list of line segments in glyph-local coordinates.
    public struct GlyphShape: Sendable {
        public let segments: [(x1: Double, y1: Double, x2: Double, y2: Double)]
        /// Advance width to next character position.
        public let advanceX: Double
    }

    /// The total height of the font (from top descender to bottom ascender).
    /// All glyph coordinates are relative to origin at baseline-left.
    public private(set) var fontHeight: Double = 21.0

    private var glyphs: [Int: GlyphShape] = [:]

    /// Whether parsing produced drawable character shapes. Some legacy SHX
    /// files use a format variant this parser does not yet understand; treating
    /// those as loaded fonts silently drops every text glyph.
    public var isUsable: Bool {
        !glyphs.isEmpty && glyphs.values.contains(where: { !$0.segments.isEmpty })
    }

    // Glyph width cache (used for text layout)
    private var widths: [Int: Double] = [:]

    // Code 7 can invoke another shape from the same SHX file. Keep the raw
    // definitions so referenced shapes can be interpreted in the caller's
    // current position, scale, draw mode, and position stack.
    private var shapeDefinitions: [Int: Data] = [:]
    private var subshapeNumberByteCount: Int = 2

    // MARK: - Initialization

    /// Load an SHX font from a file URL.
    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try parse(data: data)
    }

    /// Load an SHX font from in-memory data.
    public init(data: Data) throws {
        try parse(data: data)
    }

    // MARK: - Parsing

    private struct BinaryReader {
        let data: Data
        var pos: Int = 0

        mutating func readUInt8() -> UInt8 {
            let val = data[pos]
            pos += 1
            return val
        }

        mutating func readUInt16() -> UInt16 {
            let val = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt16.self) }
            pos += 2
            return UInt16(littleEndian: val)
        }

        mutating func readUInt32() -> UInt32 {
            let val = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }
            pos += 4
            return UInt32(littleEndian: val)
        }

        mutating func readString() -> String {
            var bytes = [UInt8]()
            while pos < data.count {
                let b = data[pos]
                pos += 1
                if b == 0x0D || b == 0x0A || b == 0x00 {
                    break
                }
                bytes.append(b)
            }
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }

        mutating func readBytes(_ count: Int) -> Data {
            let start = pos
            let end = pos + count
            pos += count
            return data.subdata(in: start..<end)
        }
    }

    private func parse(data: Data) throws {
        var reader = BinaryReader(data: data)
        let header = reader.readString()
        
        // The compiled header ends with CR/LF/SUB. `readString()` already
        // consumed CR (or the single terminator used by older variants), so
        // consume only the remaining LF/SUB bytes. Do not skip NUL bytes here:
        // shape fonts commonly begin their content with start-code 0x0000.
        if reader.pos < data.count && data[reader.pos] == 0x0A {
            reader.pos += 1
        }
        if reader.pos < data.count && data[reader.pos] == 0x1A {
            reader.pos += 1
        }
        
        let parts = header.components(separatedBy: " ")
        guard parts.count >= 2 else {
            throw SHXError.invalidHeader
        }
        
        let fontType = parts[1].lowercased()
        
        if fontType == "unifont" {
            subshapeNumberByteCount = 2
            let count = Int(reader.readUInt32())
            _ = reader.readUInt16() // length
            
            // Read font name
            _ = reader.readString() // fontName
            let above = Double(reader.readUInt8())
            _ = reader.readUInt8() // below
            _ = reader.readUInt8() // mode
            _ = reader.readUInt8() // encoding
            _ = reader.readUInt8() // embedded
            _ = reader.readUInt8() // ignore byte
            
            if above > 0 {
                self.fontHeight = above
            }
            
            print("[SHX] Parsing unifont: count=\(count), fontHeight=\(fontHeight)")
            
            for _ in 0..<(count - 1) {
                guard reader.pos + 4 <= data.count else { break }
                let index = Int(reader.readUInt16())
                let len = Int(reader.readUInt16())
                guard reader.pos + len <= data.count else { break }
                let rawGlyphData = reader.readBytes(len)
                
                if let glyph = decodeShape(data: rawGlyphData, offset: 0, length: rawGlyphData.count) {
                    glyphs[index] = glyph
                    if !glyph.segments.isEmpty {
                        let allX = glyph.segments.flatMap { [$0.x1, $0.x2] }
                        widths[index] = (allX.max() ?? 0) - (allX.min() ?? 0)
                    } else {
                        widths[index] = 0
                    }
                }
            }
        } else if fontType == "shapes" {
            subshapeNumberByteCount = 1
            let start = Int(reader.readUInt16())
            let end = Int(reader.readUInt16())
            let count = Int(reader.readUInt16())
            
            print("[SHX] Parsing shapes: start=\(start), end=\(end), count=\(count)")
            
            var glyphRef: [(index: Int, length: Int)] = []
            for _ in 0..<count {
                guard reader.pos + 4 <= data.count else { break }
                let index = Int(reader.readUInt16())
                let len = Int(reader.readUInt16())
                glyphRef.append((index, len))
            }
            
            var definitions: [Int: Data] = [:]
            for ref in glyphRef {
                guard reader.pos + ref.length <= data.count else { break }
                definitions[ref.index] = reader.readBytes(ref.length)
            }

            // All definitions must be available before decoding because a glyph
            // can reference a shape that appears later in the compiled table.
            shapeDefinitions = definitions

            for ref in glyphRef {
                guard let rawGlyphData = definitions[ref.index] else { continue }

                if ref.index == 0 {
                    // Font metadata shape
                    var subReader = BinaryReader(data: rawGlyphData)
                    _ = subReader.readString()
                    if subReader.pos < rawGlyphData.count {
                        let above = Double(subReader.readUInt8())
                        if above > 0 {
                            self.fontHeight = above
                            print("[SHX] Parsed fontHeight from shape 0: \(fontHeight)")
                        }
                    }
                } else if let glyph = decodeShape(
                    data: rawGlyphData,
                    offset: 0,
                    length: rawGlyphData.count,
                    rootShapeNumber: ref.index
                ) {
                    glyphs[ref.index] = glyph
                    if !glyph.segments.isEmpty {
                        let allX = glyph.segments.flatMap { [$0.x1, $0.x2] }
                        widths[ref.index] = (allX.max() ?? 0) - (allX.min() ?? 0)
                    } else {
                        widths[ref.index] = 0
                    }
                }
            }
        } else if fontType == "bigfont" {
            subshapeNumberByteCount = 2
            let count = Int(reader.readUInt16())
            let length = Int(reader.readUInt16())
            let changeCount = Int(reader.readUInt16())
            
            print("[SHX] Parsing bigfont: count=\(count), length=\(length), changeCount=\(changeCount)")
            
            // Skip changes
            reader.pos += changeCount * 4
            
            var glyphRef: [(index: Int, length: Int, offset: Int)] = []
            for _ in 0..<count {
                guard reader.pos + 8 <= data.count else { break }
                let index = Int(reader.readUInt16())
                let len = Int(reader.readUInt16())
                let offset = Int(reader.readUInt32())
                glyphRef.append((index, len, offset))
            }
            
            for ref in glyphRef {
                guard ref.offset + ref.length <= data.count else { continue }
                let glyphData = data.subdata(in: ref.offset..<(ref.offset + ref.length))
                
                if ref.index == 0 {
                    var subReader = BinaryReader(data: glyphData)
                    _ = subReader.readString() // skip name if any
                    if subReader.pos < glyphData.count {
                        let above = Double(subReader.readUInt8())
                        if above > 0 {
                            self.fontHeight = above
                            print("[SHX] Parsed fontHeight from shape 0: \(fontHeight)")
                        }
                    }
                } else {
                    if let glyph = decodeShape(data: glyphData, offset: 0, length: ref.length) {
                        glyphs[ref.index] = glyph
                        if !glyph.segments.isEmpty {
                            let allX = glyph.segments.flatMap { [$0.x1, $0.x2] }
                            widths[ref.index] = (allX.max() ?? 0) - (allX.min() ?? 0)
                        } else {
                            widths[ref.index] = 0
                        }
                    }
                }
            }
        } else {
            throw SHXError.parseFailed("Unsupported font type: \(fontType)")
        }
        
        print("[SHX] Parsed font. Glyphs count: \(glyphs.count)")
    }

    /// Decode a single shape from binary data.
    /// 
    /// SHX shapes use a stack-based byte interpreter where each byte is either a 
    /// special control code (when high nibble = 0) or a direction-length move.
    /// 
    /// Key differences from naive implementations:
    /// - Direction vectors use integer-based multipliers (not trigonometric)
    /// - COND_MODE_2 (0x0E) skips the next command in horizontal text mode
    /// - DIVIDE/MULTIPLY scale is cumulative, not reset
    /// - Segment start points track the last drawn/moved position separately
    private func decodeShape(
        data: Data,
        offset: Int,
        length: Int,
        rootShapeNumber: Int? = nil
    ) -> GlyphShape? {
        guard length > 0 else { return nil }

        var x: Double = 0
        var y: Double = 0
        var lastX: Double = 0
        var lastY: Double = 0
        var penDown = true
        var segments: [(x1: Double, y1: Double, x2: Double, y2: Double)] = []
        var scale: Double = 1.0
        var stack: [(Double, Double)] = []
        var skip = false
        var activeShapes = Set<Int>()
        if let rootShapeNumber {
            activeShapes.insert(rootShapeNumber)
        }

        let dirs: [(dx: Double, dy: Double)] = [
            ( 1.0,  0.0),
            ( 1.0,  0.5),
            ( 1.0,  1.0),
            ( 0.5,  1.0),
            ( 0.0,  1.0),
            (-0.5,  1.0),
            (-1.0,  1.0),
            (-1.0,  0.5),
            (-1.0,  0.0),
            (-1.0, -0.5),
            (-1.0, -1.0),
            (-0.5, -1.0),
            ( 0.0, -1.0),
            ( 0.5, -1.0),
            ( 1.0, -1.0),
            ( 1.0, -0.5),
        ]

        func interpret(
            _ shapeData: Data,
            offset: Int,
            length: Int,
            depth: Int
        ) {
            guard depth <= 32, length > 0 else { return }

            var pos = offset
            let end = min(shapeData.count, offset + length)

            // Each compiled definition starts with a null-terminated shape name.
            while pos < end {
                let byte = shapeData[pos]
                pos += 1
                if byte == 0 { break }
            }

            while pos < end {
                let b = shapeData[pos]
                pos += 1

                let direction = Int(b & 0x0F)
                let vecLength = Int(b >> 4)

                if vecLength == 0 {
                    switch direction {
                    case 0:
                        return

                    case 1:
                        if !skip { penDown = true }
                        skip = false

                    case 2:
                        if !skip { penDown = false }
                        skip = false

                    case 3:
                        guard pos < end else { return }
                        let factor = Double(shapeData[pos])
                        pos += 1
                        if !skip && factor != 0 { scale /= factor }
                        skip = false

                    case 4:
                        guard pos < end else { return }
                        let factor = Double(shapeData[pos])
                        pos += 1
                        if !skip && factor != 0 { scale *= factor }
                        skip = false

                    case 5:
                        if !skip { stack.append((x, y)) }
                        skip = false

                    case 6:
                        if !skip, let saved = stack.popLast() {
                            x = saved.0
                            y = saved.1
                            lastX = x
                            lastY = y
                        }
                        skip = false

                    case 7:
                        let subshapeNumber: Int
                        if subshapeNumberByteCount == 2 {
                            guard pos + 1 < end else { return }
                            subshapeNumber = Int(shapeData[pos])
                                | (Int(shapeData[pos + 1]) << 8)
                            pos += 2
                        } else {
                            guard pos < end else { return }
                            subshapeNumber = Int(shapeData[pos])
                            pos += 1
                        }

                        if !skip,
                           let subshape = shapeDefinitions[subshapeNumber],
                           !activeShapes.contains(subshapeNumber) {
                            activeShapes.insert(subshapeNumber)
                            interpret(
                                subshape,
                                offset: 0,
                                length: subshape.count,
                                depth: depth + 1)
                            activeShapes.remove(subshapeNumber)
                        }
                        skip = false

                    case 8:
                        guard pos + 1 < end else { return }
                        let dx = Double(Int8(bitPattern: shapeData[pos])) * scale
                        let dy = Double(Int8(bitPattern: shapeData[pos + 1])) * scale
                        pos += 2
                        if !skip {
                            x += dx
                            y += dy
                            if penDown {
                                segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                            }
                            lastX = x
                            lastY = y
                        }
                        skip = false

                    case 9:
                        while pos + 1 < end {
                            let dx = Double(Int8(bitPattern: shapeData[pos])) * scale
                            let dy = Double(Int8(bitPattern: shapeData[pos + 1])) * scale
                            pos += 2
                            if dx == 0 && dy == 0 { break }
                            if !skip {
                                x += dx
                                y += dy
                                if penDown {
                                    segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                                }
                                lastX = x
                                lastY = y
                            }
                        }
                        skip = false

                    case 10:
                        guard pos + 1 < end else { return }
                        let radius = Double(shapeData[pos]) * scale
                        let sc = Int8(bitPattern: shapeData[pos + 1])
                        pos += 2
                        if !skip {
                            let s = Int((sc >> 4) & 0x7)
                            var c = Int(sc & 0x7)
                            let ccw = (sc >> 7) & 1
                            if c == 0 { c = 8 }
                            let octant = Double.pi / 4.0
                            let sDir = ccw != 0 ? -s : s
                            let startAngle = Double(sDir) * octant
                            let endAngle = Double(c + sDir) * octant
                            let cx = x - radius * cos(startAngle)
                            let cy = y - radius * sin(startAngle)
                            x = cx + radius * cos(endAngle)
                            y = cy + radius * sin(endAngle)
                            if penDown {
                                segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                            }
                            lastX = x
                            lastY = y
                        }
                        skip = false

                    case 11:
                        guard pos + 4 < end else { return }
                        let startOff = Double(shapeData[pos])
                        let endOff = Double(shapeData[pos + 1])
                        let radiusHigh = Int(shapeData[pos + 2])
                        let radiusLow = Int(shapeData[pos + 3])
                        let sc = Int8(bitPattern: shapeData[pos + 4])
                        pos += 5
                        if !skip {
                            let radius = Double(256 * radiusHigh + radiusLow) * scale
                            let octant = Double.pi / 4.0
                            let s = Int((sc >> 4) & 0x7)
                            var c = Int(sc & 0x7)
                            let ccw = (sc >> 7) & 1
                            if c == 0 { c = 8 }
                            let sDir = ccw != 0 ? -s : s
                            let startAngle = (startOff / 256.0) * octant
                                + Double(sDir) * octant
                            let endAngle = Double(c + sDir) * octant
                                + (endOff / 256.0) * octant
                            let cx = x - radius * cos(startAngle)
                            let cy = y - radius * sin(startAngle)
                            x = cx + radius * cos(endAngle)
                            y = cy + radius * sin(endAngle)
                            if penDown {
                                segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                            }
                            lastX = x
                            lastY = y
                        }
                        skip = false

                    case 12:
                        guard pos + 2 < end else { return }
                        let dx = Double(Int8(bitPattern: shapeData[pos])) * scale
                        let dy = Double(Int8(bitPattern: shapeData[pos + 1])) * scale
                        pos += 3
                        if !skip {
                            x += dx
                            y += dy
                            if penDown {
                                segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                            }
                            lastX = x
                            lastY = y
                        }
                        skip = false

                    case 13:
                        while pos + 1 < end {
                            let dx = Double(Int8(bitPattern: shapeData[pos])) * scale
                            let dy = Double(Int8(bitPattern: shapeData[pos + 1])) * scale
                            pos += 2
                            if dx == 0 && dy == 0 { break }
                            guard pos < end else { return }
                            pos += 1
                            if !skip {
                                x += dx
                                y += dy
                                if penDown {
                                    segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                                }
                                lastX = x
                                lastY = y
                            }
                        }
                        skip = false

                    case 14:
                        skip = true

                    default:
                        skip = false
                    }
                } else {
                    if !skip {
                        let len = Double(vecLength) * scale
                        let vector = dirs[direction]
                        x += vector.dx * len
                        y += vector.dy * len
                        if penDown {
                            segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                        }
                        lastX = x
                        lastY = y
                    }
                    skip = false
                }
            }
        }

        interpret(data, offset: offset, length: length, depth: 0)
        return GlyphShape(segments: segments, advanceX: x)
    }


    private static func resolvedSpaceAdvance(
        stored: Double,
        fontHeight: Double
    ) -> Double {
        let fallback = max(fontHeight * 0.4, 1e-9)
        guard stored.isFinite, stored > 0, stored <= fontHeight * 2.0 else {
            return fallback
        }
        return stored
    }

    // MARK: - Text-to-Geometry

    /// Convert a string into line primitives at the given position and height.
    /// - Parameters:
    ///   - text: The text to render.
    ///   - origin: Bottom-left origin in world coordinates.
    ///   - height: Cap height in world units (text height from DXF).
    ///   - rotation: Text rotation angle in radians.
    /// - Returns: Array of line primitives in world coordinates.
    /// Convert a string into line primitives at the given position and height,
    /// wrapping text if a bounding box maxWidth is provided.
    public func renderText(
        _ text: String,
        origin: Vector3,
        height: Double,
        rotation: Double = 0,
        alignH: Int = 0,
        alignV: Int = 0,
        widthFactor: Double = 1.0,
        obliqueAngle: Double = 0.0,
        maxWidth: Double? = nil
    ) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        let scaleY = height / fontHeight
        let scaleX = scaleY * max(widthFactor, 1e-9)
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let shear = tan(obliqueAngle * .pi / 180.0)
        let storedSpaceAdvance = glyphs[0x20]?.advanceX ?? 0.0
        let spaceAdvance = Self.resolvedSpaceAdvance(
            stored: storedSpaceAdvance,
            fontHeight: fontHeight)

        // Split text into explicit paragraphs first
        let paragraphs = text.components(separatedBy: "\n")
        var finalLines: [String] = []

        if let maxW = maxWidth, maxW > 0 {
            let maxWLocal = maxW / scaleX
            for paragraph in paragraphs {
                let words = paragraph.components(separatedBy: " ")
                var currentLine = ""

                for word in words {
                    let candidate = currentLine.isEmpty
                        ? word
                        : currentLine + " " + word
                    let candidateBounds = getLocalDrawableBounds(
                        candidate,
                        spaceAdvance: spaceAdvance)
                    let candidateWidth = candidateBounds.map {
                        max(0.0, $0.maxX)
                    } ?? getLocalStringWidth(
                        candidate,
                        spaceAdvance: spaceAdvance)

                    let wrappingWidth = max(
                        0.0,
                        candidateWidth - (currentLine.isEmpty ? 0.0 : spaceAdvance))

                    if !currentLine.isEmpty && wrappingWidth > maxWLocal {
                        finalLines.append(currentLine)
                        currentLine = word
                    } else {
                        currentLine = candidate
                    }
                }
                if !currentLine.isEmpty {
                    finalLines.append(currentLine)
                }
            }
        } else {
            finalLines = paragraphs
        }

        let localLineSpacing = 1.666 * fontHeight

        var blockOffsetY: Double = 0
        switch alignV {
        case 1: // Bottom
            blockOffsetY = Double(finalLines.count - 1) * localLineSpacing + 0.2 * fontHeight
        case 2: // Middle
            blockOffsetY = 0.5 * Double(finalLines.count - 1) * localLineSpacing - 0.5 * fontHeight
        case 3: // Top
            blockOffsetY = -fontHeight
        default: // Baseline (0)
            blockOffsetY = Double(finalLines.count - 1) * localLineSpacing
        }

        if alignH == 4 {
            blockOffsetY = 0.5 * Double(finalLines.count - 1) * localLineSpacing - 0.5 * fontHeight
        }

        var isUnderlined = false
        let underlineY = -0.23 * fontHeight // Underline below baseline

        for (lineIndex, lineText) in finalLines.enumerated() {
            let lineScalars = Array(lineText.unicodeScalars)
            let lineLocalWidth = getLocalStringWidth(lineText, spaceAdvance: spaceAdvance)
            let drawableBounds = getLocalDrawableBounds(lineText, spaceAdvance: spaceAdvance)
                ?? (minX: 0.0, maxX: lineLocalWidth)

            var offsetX: Double = 0
            switch alignH {
            case 1, 4:
                offsetX = -0.5 * (drawableBounds.minX + drawableBounds.maxX)
            case 2:
                offsetX = -drawableBounds.maxX
            default:
                offsetX = 0
            }

            // The vertical offset for this specific line (line 0 is at the top)
            let currentLineOffsetY = blockOffsetY - Double(lineIndex) * localLineSpacing

            var cursorX: Double = 0

            func renderCharacter(_ codePoint: Int) {
                if codePoint == 0x0A || codePoint == 0x0D { return }

                let charAdvance: Double
                if codePoint == 0x20 {
                    charAdvance = spaceAdvance
                } else if let glyph = glyphs[codePoint] {
                    charAdvance = glyph.advanceX
                    
                    for seg in glyph.segments {
                        let lx1 = (offsetX + cursorX + seg.x1) * scaleX
                        let ly1 = -(currentLineOffsetY + seg.y1) * scaleY
                        let lx2 = (offsetX + cursorX + seg.x2) * scaleX
                        let ly2 = -(currentLineOffsetY + seg.y2) * scaleY

                        let sx1 = lx1 - ly1 * shear
                        let wx1 = origin.x + sx1 * cosR - ly1 * sinR
                        let wy1 = origin.y + sx1 * sinR + ly1 * cosR
                        let sx2 = lx2 - ly2 * shear
                        let wx2 = origin.x + sx2 * cosR - ly2 * sinR
                        let wy2 = origin.y + sx2 * sinR + ly2 * cosR

                        primitives.append(.line(
                            start: Vector3(x: wx1, y: wy1, z: origin.z),
                            end: Vector3(x: wx2, y: wy2, z: origin.z)
                        ))
                    }
                } else {
                    charAdvance = spaceAdvance
                }

                // Draw underline if active
                if isUnderlined {
                    let lx1 = (offsetX + cursorX) * scaleX
                    let ly1 = -(currentLineOffsetY + underlineY) * scaleY
                    let lx2 = (offsetX + cursorX + charAdvance) * scaleX
                    let ly2 = -(currentLineOffsetY + underlineY) * scaleY

                    let sx1 = lx1 - ly1 * shear
                    let wx1 = origin.x + sx1 * cosR - ly1 * sinR
                    let wy1 = origin.y + sx1 * sinR + ly1 * cosR
                    let sx2 = lx2 - ly2 * shear
                    let wx2 = origin.x + sx2 * cosR - ly2 * sinR
                    let wy2 = origin.y + sx2 * sinR + ly2 * cosR

                    primitives.append(.line(
                        start: Vector3(x: wx1, y: wy1, z: origin.z),
                        end: Vector3(x: wx2, y: wy2, z: origin.z)
                    ))
                }

                cursorX += charAdvance
            }

            var i = 0
            while i < lineScalars.count {
                let char = lineScalars[i]
                
                if char.value == 0x25 && i + 2 < lineScalars.count && lineScalars[i + 1].value == 0x25 {
                    let codeChar = lineScalars[i + 2]
                    let codeLower = codeChar.value | 0x20
                    if codeLower == 0x75 { // 'u'
                        isUnderlined.toggle()
                        i += 3
                        continue
                    } else if codeLower == 0x64 { // 'd'
                        let codePoint = glyphs[0x00B0] != nil ? 0x00B0 : (glyphs[127] != nil ? 127 : 0x00B0)
                        renderCharacter(codePoint)
                        i += 3
                        continue
                    } else if codeLower == 0x70 { // 'p'
                        let codePoint = glyphs[0x00B1] != nil ? 0x00B1 : 0x00B1
                        renderCharacter(codePoint)
                        i += 3
                        continue
                    } else if codeLower == 0x63 { // 'c'
                        let codePoint = glyphs[0x2205] != nil ? 0x2205 : (glyphs[0x00D8] != nil ? 0x00D8 : 0x2205)
                        renderCharacter(codePoint)
                        i += 3
                        continue
                    } else if codeChar.value == 0x25 { // '%'
                        renderCharacter(0x25)
                        i += 3
                        continue
                    }
                }
                
                let codePoint = Int(char.value)
                renderCharacter(codePoint)
                i += 1
            }
        }

        return primitives
    }


    private struct FormattedGlyphLayout {
        let scalar: Unicode.Scalar
        let font: SHXShapeFont
        let height: Double
        let underline: Bool
        let overline: Bool
        let widthFactor: Double
        let tracking: Double
        let oblique: Double
    }

    private struct FormattedLineLayout {
        var glyphs: [FormattedGlyphLayout]
        let alignment: Int
        let isLastInParagraph: Bool
        let leftIndent: Double
        let rightIndent: Double
        let tabStops: [Double]
    }

    public func renderFormattedText(
        _ formatted: FormattedText,
        origin: Vector3,
        rotation: Double = 0,
        alignH: Int = 0,
        alignV: Int = 0,
        widthFactor: Double = 1.0,
        maxWidth: Double? = nil,
        lineSpacingFactor: Double = 1.0,
        lineSpacingStyle: Int = 1,
        textStyleFonts: [String: String] = [:]
    ) -> [CADPrimitive] {
        let defaultHeight = max(formatted.defaultHeight, 1e-9)
        let entityWidthFactor = max(widthFactor, 1e-9)

        func resolvedFont(for run: FormattedTextRun) -> SHXShapeFont {
            let filename = CADFontManager.resolveFontReference(
                run.fontName ?? formatted.defaultFont,
                textStyleFonts: textStyleFonts,
                fallback: "")
            if !filename.isEmpty,
               let font = CADFontManager.getOrLoadSHXFont(
                filename: filename,
                allowFallback: false) {
                return font
            }
            return self
        }

        func spaceAdvance(for font: SHXShapeFont) -> Double {
            Self.resolvedSpaceAdvance(
                stored: font.glyphs[0x20]?.advanceX ?? 0.0,
                fontHeight: font.fontHeight)
        }

        func makeGlyphs(_ run: FormattedTextRun) -> [FormattedGlyphLayout] {
            let text: String
            if let stack = run.stack {
                text = stack.numerator + "/" + stack.denominator
            } else {
                text = run.text
            }
            let font = resolvedFont(for: run)
            let height = max(run.height ?? defaultHeight, 1e-9)
            let widthFactor = max(run.widthFactor ?? 1.0, 1e-9) * entityWidthFactor
            let tracking = max(run.tracking ?? 1.0, 0.0)
            let oblique = (run.oblique ?? 0.0) * .pi / 180.0
            return text.unicodeScalars.map {
                FormattedGlyphLayout(
                    scalar: $0,
                    font: font,
                    height: height,
                    underline: run.underline,
                    overline: run.overline,
                    widthFactor: widthFactor,
                    tracking: tracking,
                    oblique: oblique)
            }
        }

        func baseAdvance(_ glyph: FormattedGlyphLayout) -> Double {
            let codePoint = Int(glyph.scalar.value)
            let glyphSpaceAdvance = spaceAdvance(for: glyph.font)
            let localAdvance: Double
            if codePoint == 0x20 || codePoint == 0x09 {
                localAdvance = glyphSpaceAdvance
            } else {
                localAdvance = glyph.font.glyphs[codePoint]?.advanceX ?? glyphSpaceAdvance
            }
            return localAdvance
                * (glyph.height / glyph.font.fontHeight)
                * glyph.widthFactor
                * glyph.tracking
        }

        func advance(
            _ glyph: FormattedGlyphLayout,
            cursor: Double,
            lineLeft: Double,
            tabStops: [Double]
        ) -> Double {
            guard glyph.scalar.value == 0x09 else {
                return baseAdvance(glyph)
            }

            if let stop = tabStops.first(where: { $0 > cursor + 1e-9 }) {
                return stop - cursor
            }

            let step = max(baseAdvance(glyph) * 4.0, 1e-9)
            let fallbackOrigin = max(lineLeft, tabStops.last ?? lineLeft)
            let distance = max(0.0, cursor - fallbackOrigin)
            let next = fallbackOrigin + (floor(distance / step) + 1.0) * step
            return max(next - cursor, step)
        }

        func lineAdvance(
            _ glyphs: [FormattedGlyphLayout],
            lineLeft: Double,
            tabStops: [Double]
        ) -> Double {
            var cursor = lineLeft
            for glyph in glyphs {
                cursor += advance(
                    glyph,
                    cursor: cursor,
                    lineLeft: lineLeft,
                    tabStops: tabStops)
            }
            return cursor - lineLeft
        }

        func drawableBounds(
            _ glyphs: [FormattedGlyphLayout],
            lineLeft: Double,
            tabStops: [Double]
        ) -> (minX: Double, maxX: Double)? {
            var cursor = lineLeft
            var minX = Double.infinity
            var maxX = -Double.infinity

            for glyph in glyphs {
                let codePoint = Int(glyph.scalar.value)
                let scaleY = glyph.height / glyph.font.fontHeight
                let scaleX = scaleY * glyph.widthFactor
                let shear = tan(glyph.oblique)
                if let shape = glyph.font.glyphs[codePoint] {
                    for segment in shape.segments {
                        let x1 = cursor + (segment.x1 + shear * segment.y1) * scaleX
                        let x2 = cursor + (segment.x2 + shear * segment.y2) * scaleX
                        minX = min(minX, x1, x2)
                        maxX = max(maxX, x1, x2)
                    }
                }
                cursor += advance(
                    glyph,
                    cursor: cursor,
                    lineLeft: lineLeft,
                    tabStops: tabStops)
            }

            guard minX.isFinite, maxX.isFinite else { return nil }
            return (minX, maxX)
        }

        func wrappingWidth(
            _ glyphs: [FormattedGlyphLayout],
            lineLeft: Double,
            tabStops: [Double]
        ) -> Double {
            let advanceWidth = lineAdvance(
                glyphs,
                lineLeft: lineLeft,
                tabStops: tabStops)
            guard let bounds = drawableBounds(
                glyphs,
                lineLeft: lineLeft,
                tabStops: tabStops) else {
                return advanceWidth
            }
            return max(advanceWidth, bounds.maxX - lineLeft)
        }

        func splitRuns(
            _ glyphs: [FormattedGlyphLayout]
        ) -> [(glyphs: [FormattedGlyphLayout], isWhitespace: Bool)] {
            var result: [(glyphs: [FormattedGlyphLayout], isWhitespace: Bool)] = []
            var current: [FormattedGlyphLayout] = []
            var currentWhitespace: Bool? = nil

            func flush() {
                guard let whitespace = currentWhitespace, !current.isEmpty else { return }
                result.append((current, whitespace))
                current.removeAll(keepingCapacity: true)
            }

            for glyph in glyphs {
                let whitespace = glyph.scalar.value == 0x20 || glyph.scalar.value == 0x09
                if let currentWhitespace, currentWhitespace != whitespace {
                    flush()
                }
                currentWhitespace = whitespace
                current.append(glyph)
            }
            flush()
            return result
        }

        var lines: [FormattedLineLayout] = []
        for paragraph in formatted.paragraphs {
            let paragraphGlyphs = paragraph.runs.flatMap(makeGlyphs)
            let paragraphUnit = defaultHeight
            let leftIndent = (paragraph.leftIndent ?? 0.0) * paragraphUnit
            let firstLineIndent = (paragraph.firstLineIndent ?? 0.0) * paragraphUnit
            let rightIndent = max(0.0, (paragraph.rightIndent ?? 0.0) * paragraphUnit)
            let firstLineLeft = leftIndent + firstLineIndent
            let continuationLeft = leftIndent
            let tabStops = (paragraph.tabStops ?? [])
                .map { $0 * paragraphUnit }
                .sorted()

            guard let maxWidth, maxWidth > 0 else {
                lines.append(FormattedLineLayout(
                    glyphs: paragraphGlyphs,
                    alignment: paragraph.alignment,
                    isLastInParagraph: true,
                    leftIndent: firstLineLeft,
                    rightIndent: rightIndent,
                    tabStops: tabStops))
                continue
            }

            let runs = splitRuns(paragraphGlyphs)
            if runs.isEmpty {
                lines.append(FormattedLineLayout(
                    glyphs: [],
                    alignment: paragraph.alignment,
                    isLastInParagraph: true,
                    leftIndent: firstLineLeft,
                    rightIndent: rightIndent,
                    tabStops: tabStops))
                continue
            }

            var current: [FormattedGlyphLayout] = []
            var pendingWhitespace: [FormattedGlyphLayout] = []
            var currentLeft = firstLineLeft

            for run in runs {
                if run.isWhitespace {
                    if current.isEmpty {
                        current.append(contentsOf: run.glyphs)
                    } else {
                        pendingWhitespace.append(contentsOf: run.glyphs)
                    }
                    continue
                }

                let candidate = current + pendingWhitespace + run.glyphs
                let currentHasText = current.contains {
                    $0.scalar.value != 0x20 && $0.scalar.value != 0x09
                }
                let availableWidth = max(0.0, maxWidth - currentLeft - rightIndent)
                let candidateWidth = wrappingWidth(
                    candidate,
                    lineLeft: currentLeft,
                    tabStops: tabStops)

                if currentHasText && candidateWidth > availableWidth {
                    lines.append(FormattedLineLayout(
                        glyphs: current,
                        alignment: paragraph.alignment,
                        isLastInParagraph: false,
                        leftIndent: currentLeft,
                        rightIndent: rightIndent,
                        tabStops: tabStops))
                    current = run.glyphs
                    currentLeft = continuationLeft
                } else {
                    current = candidate
                }
                pendingWhitespace.removeAll(keepingCapacity: true)
            }

            if !pendingWhitespace.isEmpty {
                current.append(contentsOf: pendingWhitespace)
            }
            lines.append(FormattedLineLayout(
                glyphs: current,
                alignment: paragraph.alignment,
                isLastInParagraph: true,
                leftIndent: currentLeft,
                rightIndent: rightIndent,
                tabStops: tabStops))
        }

        if lines.isEmpty {
            lines = [FormattedLineLayout(
                glyphs: [],
                alignment: 0,
                isLastInParagraph: true,
                leftIndent: 0,
                rightIndent: 0,
                tabStops: [])]
        }

        let lineHeights = lines.map { line in
            line.glyphs.map(\.height).max() ?? defaultHeight
        }
        let spacingFactor = max(lineSpacingFactor, 0.01)
        let defaultLineAdvance = defaultHeight * (5.0 / 3.0) * spacingFactor
        var lineTops = [Double](repeating: 0, count: lines.count)
        if lines.count > 1 {
            for index in 1..<lines.count {
                let previousHeight = lineHeights[index - 1]
                let requestedAdvance: Double
                if lineSpacingStyle == 2 {
                    requestedAdvance = defaultLineAdvance
                } else {
                    requestedAdvance = previousHeight * (5.0 / 3.0) * spacingFactor
                }
                let lineAdvance = lineSpacingStyle == 2
                    ? requestedAdvance
                    : max(previousHeight, requestedAdvance)
                lineTops[index] = lineTops[index - 1] + lineAdvance
            }
        }
        let contentHeight = (lineTops.last ?? 0) + (lineHeights.last ?? defaultHeight)

        let verticalOffset: Double
        switch alignV {
        case 1:
            verticalOffset = -contentHeight
        case 2, 4:
            verticalOffset = -contentHeight * 0.5
        case 3:
            verticalOffset = 0
        default:
            verticalOffset = -contentHeight
        }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        var primitives: [CADPrimitive] = []

        func worldPoint(_ x: Double, _ y: Double) -> Vector3 {
            Vector3(
                x: origin.x + x * cosR - y * sinR,
                y: origin.y + x * sinR + y * cosR,
                z: origin.z)
        }

        for lineIndex in lines.indices {
            let line = lines[lineIndex]
            let measuredBounds = drawableBounds(
                line.glyphs,
                lineLeft: line.leftIndent,
                tabStops: line.tabStops)
            let minX = measuredBounds?.minX ?? line.leftIndent
            let maxX = measuredBounds?.maxX
                ?? (line.leftIndent + lineAdvance(
                    line.glyphs,
                    lineLeft: line.leftIndent,
                    tabStops: line.tabStops))

            let hasParagraphAlignment = line.alignment != 0
            let paragraphAlignment = hasParagraphAlignment ? line.alignment : alignH
            let effectiveAlignment = paragraphAlignment == 5 ? 0 : paragraphAlignment
            let referenceBoxLeft: Double
            if let maxWidth, maxWidth > 0 {
                switch alignH {
                case 1, 4:
                    referenceBoxLeft = -maxWidth * 0.5
                case 2:
                    referenceBoxLeft = -maxWidth
                default:
                    referenceBoxLeft = 0
                }
            } else {
                referenceBoxLeft = 0
            }

            let offsetX: Double
            if let maxWidth, maxWidth > 0 {
                let contentLeft = referenceBoxLeft + line.leftIndent
                let contentRight = referenceBoxLeft + maxWidth - line.rightIndent
                switch effectiveAlignment {
                case 1, 4:
                    offsetX = (contentLeft + contentRight) * 0.5
                        - 0.5 * (minX + maxX)
                case 2:
                    offsetX = contentRight - maxX
                default:
                    offsetX = contentLeft - minX
                }
            } else {
                switch effectiveAlignment {
                case 1, 4:
                    offsetX = -0.5 * (minX + maxX)
                case 2:
                    offsetX = -maxX
                default:
                    offsetX = 0
                }
            }

            let shouldJustify = effectiveAlignment == 4
                || (effectiveAlignment == 3 && !line.isLastInParagraph)
            let spaceCount = line.glyphs.reduce(into: 0) { count, glyph in
                if glyph.scalar.value == 0x20 {
                    count += 1
                }
            }
            let extraSpace: Double
            if shouldJustify, spaceCount > 0, let maxWidth {
                let availableWidth = max(
                    0.0,
                    maxWidth - line.leftIndent - line.rightIndent)
                let usedWidth = lineAdvance(
                    line.glyphs,
                    lineLeft: line.leftIndent,
                    tabStops: line.tabStops)
                extraSpace = max(0.0, availableWidth - usedWidth)
                    / Double(spaceCount)
            } else {
                extraSpace = 0
            }

            var cursor = line.leftIndent
            let lineTop = verticalOffset + lineTops[lineIndex]
            for glyph in line.glyphs {
                let codePoint = Int(glyph.scalar.value)
                let glyphAdvance = advance(
                    glyph,
                    cursor: cursor,
                    lineLeft: line.leftIndent,
                    tabStops: line.tabStops)
                let scaleY = glyph.height / glyph.font.fontHeight
                let scaleX = scaleY * glyph.widthFactor
                let shear = tan(glyph.oblique)

                if let shape = glyph.font.glyphs[codePoint] {
                    for segment in shape.segments {
                        let localX1 = offsetX + cursor + (segment.x1 + shear * segment.y1) * scaleX
                        let localY1 = lineTop + glyph.height - segment.y1 * scaleY
                        let localX2 = offsetX + cursor + (segment.x2 + shear * segment.y2) * scaleX
                        let localY2 = lineTop + glyph.height - segment.y2 * scaleY
                        primitives.append(.line(
                            start: worldPoint(localX1, localY1),
                            end: worldPoint(localX2, localY2)))
                    }
                }

                if glyph.underline || glyph.overline {
                    let localX1 = offsetX + cursor
                    let localX2 = offsetX + cursor + glyphAdvance
                    if glyph.underline {
                        let y = lineTop + glyph.height * 1.23
                        primitives.append(.line(
                            start: worldPoint(localX1, y),
                            end: worldPoint(localX2, y)))
                    }
                    if glyph.overline {
                        let y = lineTop + glyph.height * 0.05
                        primitives.append(.line(
                            start: worldPoint(localX1, y),
                            end: worldPoint(localX2, y)))
                    }
                }

                cursor += glyphAdvance
                if glyph.scalar.value == 0x20 {
                    cursor += extraSpace
                }
            }
        }

        return primitives
    }

    /// Helper to get local width of a string in font-local units.
    private func getLocalStringWidth(_ str: String, spaceAdvance: Double) -> Double {
        var width: Double = 0
        let scalars = Array(str.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let char = scalars[i]
            
            if char.value == 0x25 && i + 2 < scalars.count && scalars[i + 1].value == 0x25 {
                let codeChar = scalars[i + 2]
                if let codePoint = resolvedSpecialCodePoint(for: codeChar) {
                    width += glyphs[codePoint]?.advanceX ?? spaceAdvance
                    i += 3
                    continue
                }
                let codeLower = codeChar.value | 0x20
                if codeLower == 0x75 {
                    i += 3
                    continue
                }
            }
            
            let codePoint = Int(char.value)
            if codePoint == 0x20 {
                width += spaceAdvance
            } else if codePoint == 0x0A || codePoint == 0x0D {
                // skip
            } else {
                width += glyphs[codePoint]?.advanceX ?? spaceAdvance
            }
            i += 1
        }
        return width
    }

    private func getLocalDrawableBounds(_ str: String, spaceAdvance: Double) -> (minX: Double, maxX: Double)? {
        var cursorX: Double = 0
        var minX = Double.infinity
        var maxX = -Double.infinity
        let scalars = Array(str.unicodeScalars)
        var i = 0

        func includeGlyph(_ codePoint: Int) {
            guard let glyph = glyphs[codePoint] else {
                cursorX += spaceAdvance
                return
            }
            for seg in glyph.segments {
                minX = min(minX, cursorX + seg.x1, cursorX + seg.x2)
                maxX = max(maxX, cursorX + seg.x1, cursorX + seg.x2)
            }
            cursorX += glyph.advanceX
        }

        while i < scalars.count {
            let char = scalars[i]

            if char.value == 0x25 && i + 2 < scalars.count && scalars[i + 1].value == 0x25 {
                let codeChar = scalars[i + 2]
                if let codePoint = resolvedSpecialCodePoint(for: codeChar) {
                    includeGlyph(codePoint)
                    i += 3
                    continue
                }
                let codeLower = codeChar.value | 0x20
                if codeLower == 0x75 {
                    i += 3
                    continue
                }
            }

            let codePoint = Int(char.value)
            if codePoint == 0x20 {
                cursorX += spaceAdvance
            } else if codePoint != 0x0A && codePoint != 0x0D {
                includeGlyph(codePoint)
            }
            i += 1
        }

        guard minX.isFinite, maxX.isFinite else { return nil }
        return (minX, maxX)
    }

    private func resolvedSpecialCodePoint(for codeChar: Unicode.Scalar) -> Int? {
        let codeLower = codeChar.value | 0x20
        if codeLower == 0x64 {
            return glyphs[0x00B0] != nil ? 0x00B0 : (glyphs[127] != nil ? 127 : 0x00B0)
        }
        if codeLower == 0x70 {
            return 0x00B1
        }
        if codeLower == 0x63 {
            return glyphs[0x2205] != nil ? 0x2205 : (glyphs[0x00D8] != nil ? 0x00D8 : 0x2205)
        }
        if codeChar.value == 0x25 {
            return 0x25
        }
        return nil
    }

    // MARK: - Helpers

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    private static func stripGlyphHeader(_ glyphData: Data) -> Data {
        if glyphData.count >= 2 && glyphData[0] == 0 && glyphData[1] == 0 {
            return glyphData.subdata(in: 2..<glyphData.count)
        } else if glyphData.count >= 1 && glyphData[0] == 0 {
            var nameEnd = -1
            for idx in 1..<glyphData.count {
                if glyphData[idx] == 0 {
                    nameEnd = idx
                    break
                }
            }
            if nameEnd != -1 {
                var isValidName = true
                for idx in 1..<nameEnd {
                    let c = glyphData[idx]
                    let isUpper = (c >= 65 && c <= 90) // A-Z
                    let isDigit = (c >= 48 && c <= 57) // 0-9
                    let isSpace = (c == 32)
                    let isAmp = (c == 38)
                    if !isUpper && !isDigit && !isSpace && !isAmp {
                        isValidName = false
                        break
                    }
                }
                if isValidName {
                    return glyphData.subdata(in: (nameEnd + 1)..<glyphData.count)
                } else {
                    return glyphData.subdata(in: 1..<glyphData.count)
                }
            } else {
                return glyphData.subdata(in: 1..<glyphData.count)
            }
        }
        return glyphData
    }
}

// MARK: - Errors

public enum SHXError: Error {
    case invalidHeader
    case parseFailed(String)
}
