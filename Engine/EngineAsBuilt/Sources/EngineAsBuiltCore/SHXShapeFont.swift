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
        
        // Skip trailing terminators like \n or \x1a or \0
        while reader.pos < data.count {
            let nextByte = data[reader.pos]
            if nextByte == 0x0A || nextByte == 0x1A || nextByte == 0x00 {
                reader.pos += 1
            } else {
                break
            }
        }
        
        let parts = header.components(separatedBy: " ")
        guard parts.count >= 2 else {
            throw SHXError.invalidHeader
        }
        
        let fontType = parts[1].lowercased()
        
        if fontType == "unifont" {
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
            
            for ref in glyphRef {
                guard reader.pos + ref.length <= data.count else { break }
                let rawGlyphData = reader.readBytes(ref.length)
                
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
                } else {
                    if let glyph = decodeShape(data: rawGlyphData, offset: 0, length: rawGlyphData.count) {
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
        } else if fontType == "bigfont" {
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
    private func decodeShape(data: Data, offset: Int, length: Int) -> GlyphShape? {
        guard length > 0 else { return nil }

        var pos = offset
        let end = offset + length
        
        // Skip the null-terminated name at the beginning of the shape description
        while pos < end {
            let b = data[pos]
            pos += 1
            if b == 0 {
                break
            }
        }

        var x: Double = 0, y: Double = 0
        var lastX: Double = 0, lastY: Double = 0
        var penDown = true
        var segments: [(x1: Double, y1: Double, x2: Double, y2: Double)] = []
        var scale: Double = 1.0
        var stack: [(Double, Double)] = []
        var skip = false

        // SHX integer-based direction table (16 directions at 22.5° increments)
        // These use integer dx/dy multipliers per the AutoCAD SHX specification.
        // NOT trigonometric values — the SHX format defines these as grid steps.
        let dirs: [(dx: Double, dy: Double)] = [
            ( 1.0,  0.0),   //  0: E
            ( 1.0,  0.5),   //  1: ENE
            ( 1.0,  1.0),   //  2: NE
            ( 0.5,  1.0),   //  3: NNE
            ( 0.0,  1.0),   //  4: N
            (-0.5,  1.0),   //  5: NNW
            (-1.0,  1.0),   //  6: NW
            (-1.0,  0.5),   //  7: WNW
            (-1.0,  0.0),   //  8: W
            (-1.0, -0.5),   //  9: WSW
            (-1.0, -1.0),   // 10: SW
            (-0.5, -1.0),   // 11: SSW
            ( 0.0, -1.0),   // 12: S
            ( 0.5, -1.0),   // 13: SSE
            ( 1.0, -1.0),   // 14: SE
            ( 1.0, -0.5),   // 15: ESE
        ]

        while pos < end {
            let b = data[pos]
            pos += 1

            let direction = Int(b & 0x0F)
            let vecLength = Int(b >> 4)

            if vecLength == 0 {
                // Special control code (high nibble = 0)
                switch direction {
                case 0: // END_OF_SHAPE
                    break

                case 1: // PEN_DOWN
                    if !skip {
                        penDown = true
                    }
                    skip = false

                case 2: // PEN_UP
                    if !skip {
                        penDown = false
                    }
                    skip = false

                case 3: // DIVIDE_VECTOR (cumulative)
                    guard pos < end else { break }
                    let factor = Double(data[pos])
                    pos += 1
                    if !skip && factor != 0 {
                        scale /= factor
                    }
                    skip = false

                case 4: // MULTIPLY_VECTOR (cumulative)
                    guard pos < end else { break }
                    let factor = Double(data[pos])
                    pos += 1
                    if !skip && factor != 0 {
                        scale *= factor
                    }
                    skip = false

                case 5: // PUSH_STACK
                    if !skip {
                        stack.append((x, y))
                    }
                    skip = false

                case 6: // POP_STACK
                    if !skip, let saved = stack.popLast() {
                        x = saved.0
                        y = saved.1
                        lastX = x
                        lastY = y
                    }
                    skip = false

                case 7: // DRAW_SUBSHAPE
                    // For unifont, subshape number is 2 bytes (u16 LE)
                    guard pos + 1 < end else {
                        // For shapes font, subshape is 1 byte
                        if pos < end { pos += 1 }
                        skip = false
                        break
                    }
                    _ = data[pos]       // low byte
                    _ = data[pos + 1]   // high byte
                    pos += 2
                    // TODO: inline subshape glyph data here
                    skip = false

                case 8: // XY_DISPLACEMENT
                    guard pos + 1 < end else { break }
                    let dx = Double(Int8(bitPattern: data[pos])) * scale
                    let dy = Double(Int8(bitPattern: data[pos + 1])) * scale
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

                case 9: // POLY_XY_DISPLACEMENT (terminated by 0,0)
                    while pos + 1 < end {
                        let dx = Double(Int8(bitPattern: data[pos])) * scale
                        let dy = Double(Int8(bitPattern: data[pos + 1])) * scale
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
                    if skip { skip = false }

                case 10: // OCTANT_ARC
                    guard pos + 1 < end else { break }
                    let radius = Double(data[pos]) * scale
                    let sc = Int8(bitPattern: data[pos + 1])
                    pos += 2
                    if !skip {
                        // Decode octant arc parameters
                        let s = Int((sc >> 4) & 0x7)
                        var c = Int(sc & 0x7)
                        let ccw = (sc >> 7) & 1
                        if c == 0 { c = 8 }
                        let octant = Double.pi / 4.0
                        let sDir = ccw != 0 ? -s : s
                        let startAngle = Double(sDir) * octant
                        let endAngle = Double(c + sDir) * octant
                        // Move to end position of the arc
                        let cx = x - radius * cos(startAngle)
                        let cy = y - radius * sin(startAngle)
                        x = cx + radius * cos(endAngle)
                        y = cy + radius * sin(endAngle)
                        // Approximate arc as line segment from start to end
                        if penDown {
                            segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                        }
                        lastX = x
                        lastY = y
                    }
                    skip = false

                case 11: // FRACTIONAL_ARC
                    guard pos + 4 < end else { break }
                    let startOff = Double(data[pos])
                    let endOff = Double(data[pos + 1])
                    let radiusHigh = Int(data[pos + 2])
                    let radiusLow = Int(data[pos + 3])
                    let sc = Int8(bitPattern: data[pos + 4])
                    pos += 5
                    if !skip {
                        let radius = Double(256 * radiusHigh + radiusLow) * scale
                        let octant = Double.pi / 4.0
                        let s = Int((sc >> 4) & 0x7)
                        var c = Int(sc & 0x7)
                        let ccw = (sc >> 7) & 1
                        if c == 0 { c = 8 }
                        let sDir = ccw != 0 ? -s : s
                        let startAngle = (startOff / 256.0) * octant + Double(sDir) * octant
                        let endAngle = Double(c + sDir) * octant + (endOff / 256.0) * octant
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

                case 12: // BULGE_ARC
                    guard pos + 2 < end else { break }
                    let dx = Double(Int8(bitPattern: data[pos])) * scale
                    let dy = Double(Int8(bitPattern: data[pos + 1])) * scale
                    _ = Int8(bitPattern: data[pos + 2]) // bulge height
                    pos += 3
                    if !skip {
                        x += dx
                        y += dy
                        // Approximate as straight line (proper arc would use bulge factor)
                        if penDown {
                            segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                        }
                        lastX = x
                        lastY = y
                    }
                    skip = false

                case 13: // POLY_BULGE_ARC (terminated by dx=0, dy=0)
                    while pos + 1 < end {
                        let dx = Double(Int8(bitPattern: data[pos])) * scale
                        let dy = Double(Int8(bitPattern: data[pos + 1])) * scale
                        pos += 2
                        if dx == 0 && dy == 0 { break }
                        guard pos < end else { break }
                        _ = Int8(bitPattern: data[pos]) // bulge height
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
                    if skip { skip = false }

                case 14: // COND_MODE_2 (vertical text only)
                    // In horizontal mode: skip the next command.
                    // The skipped command is typically a vertical-text repositioning move.
                    skip = true

                default:
                    break
                }
            } else {
                // Direction-length move: high nibble = length, low nibble = direction
                if !skip {
                    let len = Double(vecLength) * scale
                    let (dx, dy) = dirs[direction]
                    x += dx * len
                    y += dy * len
                    if penDown {
                        segments.append((x1: lastX, y1: lastY, x2: x, y2: y))
                    }
                    lastX = x
                    lastY = y
                }
                skip = false
            }
        }

        return GlyphShape(segments: segments, advanceX: x)
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
        maxWidth: Double? = nil
    ) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        let scale = height / fontHeight  // scale from font space to world space
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let spaceAdvance = glyphs[0x20]?.advanceX ?? (fontHeight * 0.6)

        // Split text into explicit paragraphs first
        let paragraphs = text.components(separatedBy: "\n")
        var finalLines: [String] = []

        if let maxW = maxWidth, maxW > 0 {
            let maxWLocal = maxW / scale
            for paragraph in paragraphs {
                let words = paragraph.components(separatedBy: " ")
                var currentLine = ""
                var currentLineWidth: Double = 0

                for word in words {
                    let wordWidth = getLocalStringWidth(word, spaceAdvance: spaceAdvance)
                    let spaceWidth = currentLine.isEmpty ? 0 : spaceAdvance
                    
                    if currentLineWidth + spaceWidth + wordWidth > maxWLocal && !currentLine.isEmpty {
                        finalLines.append(currentLine)
                        currentLine = word
                        currentLineWidth = wordWidth
                    } else {
                        if currentLine.isEmpty {
                            currentLine = word
                            currentLineWidth = wordWidth
                        } else {
                            currentLine += " " + word
                            currentLineWidth += spaceWidth + wordWidth
                        }
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
        let underlineY = -0.15 * fontHeight // Underline slightly below baseline

        for (lineIndex, lineText) in finalLines.enumerated() {
            let lineScalars = Array(lineText.unicodeScalars)
            let lineLocalWidth = getLocalStringWidth(lineText, spaceAdvance: spaceAdvance)

            var offsetX: Double = 0
            switch alignH {
            case 1: // Center
                offsetX = -0.5 * lineLocalWidth
            case 2: // Right
                offsetX = -lineLocalWidth
            case 4: // Middle
                offsetX = -0.5 * lineLocalWidth
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
                        let lx1 = (offsetX + cursorX + seg.x1) * scale
                        let ly1 = -(currentLineOffsetY + seg.y1) * scale
                        let lx2 = (offsetX + cursorX + seg.x2) * scale
                        let ly2 = -(currentLineOffsetY + seg.y2) * scale

                        let wx1 = origin.x + lx1 * cosR - ly1 * sinR
                        let wy1 = origin.y + lx1 * sinR + ly1 * cosR
                        let wx2 = origin.x + lx2 * cosR - ly2 * sinR
                        let wy2 = origin.y + lx2 * sinR + ly2 * cosR

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
                    let lx1 = (offsetX + cursorX) * scale
                    let ly1 = -(currentLineOffsetY + underlineY) * scale
                    let lx2 = (offsetX + cursorX + charAdvance) * scale
                    let ly2 = -(currentLineOffsetY + underlineY) * scale

                    let wx1 = origin.x + lx1 * cosR - ly1 * sinR
                    let wy1 = origin.y + lx1 * sinR + ly1 * cosR
                    let wx2 = origin.x + lx2 * cosR - ly2 * sinR
                    let wy2 = origin.y + lx2 * sinR + ly2 * cosR

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

    /// Helper to get local width of a string in font-local units.
    private func getLocalStringWidth(_ str: String, spaceAdvance: Double) -> Double {
        var width: Double = 0
        let scalars = Array(str.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let char = scalars[i]
            
            if char.value == 0x25 && i + 2 < scalars.count && scalars[i + 1].value == 0x25 {
                let codeChar = scalars[i + 2]
                let codeLower = codeChar.value | 0x20
                if codeLower == 0x75 { // 'u'
                    i += 3
                    continue
                } else if codeLower == 0x64 { // 'd'
                    let codePoint = glyphs[0x00B0] != nil ? 0x00B0 : (glyphs[127] != nil ? 127 : 0x00B0)
                    width += glyphs[codePoint]?.advanceX ?? spaceAdvance
                    i += 3
                    continue
                } else if codeLower == 0x70 { // 'p'
                    let codePoint = glyphs[0x00B1] != nil ? 0x00B1 : 0x00B1
                    width += glyphs[codePoint]?.advanceX ?? spaceAdvance
                    i += 3
                    continue
                } else if codeLower == 0x63 { // 'c'
                    let codePoint = glyphs[0x2205] != nil ? 0x2205 : (glyphs[0x00D8] != nil ? 0x00D8 : 0x2205)
                    width += glyphs[codePoint]?.advanceX ?? spaceAdvance
                    i += 3
                    continue
                } else if codeChar.value == 0x25 { // '%'
                    width += glyphs[0x25]?.advanceX ?? spaceAdvance
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
