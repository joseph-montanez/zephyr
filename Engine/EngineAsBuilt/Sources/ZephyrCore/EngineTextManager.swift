import Foundation
import SwiftSDL
import SwiftSDL_ttf

// =========================================================================
// MARK: - TextEditorState
//
// All editable fields for the text editor dialog.
// Persisted in the engine so the dialog state survives frame-to-frame.
// Used by both the core engine (storage) and the app layer (TextEditorUI).
// =========================================================================
public struct TextEditorState: Sendable {
    public var text: String
    public var styleName: String
    public var fontName: String
    public var height: Double
    public var rotation: Double
    public var alignH: Int       // 0=left, 1=center, 2=right (3=aligned, 4=middle, 5=fit pass through untouched)
    public var alignV: Int       // 0=baseline, 1=bottom, 2=middle, 3=top
    public var mtextWidth: Double // 0 = no wrap (TEXT), >0 = wrap width (MTEXT)
    public var targetHandle: UUID? // nil = creating new, non-nil = editing existing
    /// Decoded `dxf.formattedText` at edit time, so OK preserves paragraph
    /// alignment/indents/run formatting instead of rebuilding plain text.
    public var originalFormatted: FormattedText?
    /// Entity's stored `dxf.mtextWidth` at edit time, restored if the user
    /// toggles the MTEXT checkbox off and back on within one edit.
    public var originalMTextWidth: Double

    public init(
        text: String = "",
        styleName: String = "Standard",
        fontName: String = "simplex.shx",
        height: Double = 2.5,
        rotation: Double = 0,
        alignH: Int = 0,
        alignV: Int = 0,
        mtextWidth: Double = 0,
        targetHandle: UUID? = nil,
        originalFormatted: FormattedText? = nil,
        originalMTextWidth: Double = 0
    ) {
        self.text = text
        self.styleName = styleName
        self.fontName = fontName
        self.height = height
        self.rotation = rotation
        self.alignH = alignH
        self.alignV = alignV
        self.mtextWidth = mtextWidth
        self.targetHandle = targetHandle
        self.originalFormatted = originalFormatted
        self.originalMTextWidth = originalMTextWidth
    }
}

/// Result of the text editor dialog.
public enum TextEditorResult: Sendable {
    case active              // Dialog still open
    case confirmed(TextEditorState)  // User clicked OK
    case cancelled           // User cancelled or closed
}

// =========================================================================
// MARK: - EngineTextManager
//
// Manages TTF font caching, text rendering to GPU textures, and the 
// state for the in-app text editor (DDEDIT).
// =========================================================================
@MainActor
public final class EngineTextManager {
    
    // MARK: - Editor State
    
    /// Whether the text editor modal dialog is active.
    public var isEditorActive: Bool = false
    
    /// Current state for the text editor (persisted across frames).
    public var editorState: TextEditorState = TextEditorState()
    
    /// Last result from the text editor (set when the dialog closes).
    public var editorResult: TextEditorResult = .active
    
    // MARK: - Font Cache
    
    internal var fontCache: [String: OpaquePointer?] = [:]

    private struct CADFontMetrics {
        let capHeightPixels: Double
        let capTopPaddingPixels: Double
        let lineHeightPixels: Double
        let ascentPixels: Double
        let descentPixels: Double
    }

    private var cadFontMetricsCache: [UInt: CADFontMetrics] = [:]
    
    public init() {}
    
    // MARK: - TTF/Font Management

    /// Gets a font from the cache or loads it if not found.
    internal func getOrCreateFont(path: String, size: Float) -> OpaquePointer? {
        let cacheKey = "\(path):\(size)"

        if let cachedFont = fontCache[cacheKey] {
            return cachedFont
        }

        let newFont = TTF_OpenFont(path, size)
        if newFont == nil {
            print("TTF_OpenFont Error for '\(path)': \(String(cString: SDL_GetError()))")
            return nil
        }

        print("Loaded font '\(path)' at size \(size) into cache.")
        fontCache[cacheKey] = newFont
        return newFont
    }

    private func styledFontPath(
        basePath: String,
        bold: Bool,
        italic: Bool
    ) -> String {
        guard bold || italic else { return basePath }

        let baseURL = URL(fileURLWithPath: basePath)
        let directory = baseURL.deletingLastPathComponent()
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let lowerStem = stem.lowercased()
        var candidates: [String] = []

        func add(_ name: String) {
            guard !name.isEmpty, !candidates.contains(name) else { return }
            candidates.append(name)
        }

        if lowerStem == "arialn" || lowerStem.contains("arial narrow") {
            if bold && italic {
                add("ARIALNBI.TTF")
                add("arialnbi.ttf")
                add("Arial Narrow Bold Italic.ttf")
                add("Arial Narrow BoldItalic.ttf")
            } else if bold {
                add("ARIALNB.TTF")
                add("arialnb.ttf")
                add("Arial Narrow Bold.ttf")
            } else {
                add("ARIALNI.TTF")
                add("arialni.ttf")
                add("Arial Narrow Italic.ttf")
            }
        }

        let suffixes: [String]
        if bold && italic {
            suffixes = [" Bold Italic", " BoldItalic", "-BoldItalic", "BI"]
        } else if bold {
            suffixes = [" Bold", "-Bold", "Bold", "B"]
        } else {
            suffixes = [" Italic", "-Italic", "Italic", "I"]
        }

        let extensionSuffix = ext.isEmpty ? "" : ".\(ext)"
        for suffix in suffixes {
            add(stem + suffix + extensionSuffix)
        }

        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }

        return basePath
    }

    private func cadFontMetrics(for font: OpaquePointer) -> CADFontMetrics {
        let key = UInt(bitPattern: font)
        if let cached = cadFontMetricsCache[key] {
            return cached
        }

        var minX: Int32 = 0
        var maxX: Int32 = 0
        var minY: Int32 = 0
        var maxY: Int32 = 0
        var advance: Int32 = 0

        let lineHeight = max(Double(TTF_GetFontHeight(font)), 1.0)
        let hasCapMetrics = TTF_GetGlyphMetrics(
            font, UInt32(72),
            &minX, &maxX, &minY, &maxY, &advance)
        let capHeight = hasCapMetrics
            ? max(Double(maxY - minY), 1.0)
            : lineHeight
        let ascent = max(Double(TTF_GetFontAscent(font)), capHeight)
        let descent = min(Double(TTF_GetFontDescent(font)), 0.0)
        let capTopPadding = hasCapMetrics
            ? max(0.0, ascent - Double(maxY))
            : max(0.0, lineHeight - capHeight) * 0.5
        let metrics = CADFontMetrics(
            capHeightPixels: capHeight,
            capTopPaddingPixels: capTopPadding,
            lineHeightPixels: max(lineHeight, capHeight),
            ascentPixels: ascent,
            descentPixels: descent)
        cadFontMetricsCache[key] = metrics
        return metrics
    }

    /// Renders a string of text to a new SDL_Texture.
    /// Returns (texture, width, height).
    internal func renderTextToTexture(
        font: OpaquePointer?,
        text: String,
        color: SDL_Color,
        renderer: EngineRenderer,
        gpuDevice: OpaquePointer
    ) -> (texture: OpaquePointer?, w: Double, h: Double) {
        guard !text.isEmpty else { return (nil, 0.0, 0.0) }

        let surface = text.withCString { cstr in
            TTF_RenderText_Blended(font, cstr, 0, color)
        }

        guard let surface = surface else {
            print("TTF_RenderText_Blended Error: \(String(cString: SDL_GetError()))")
            return (nil, 0, 0)
        }

        // Make sure the surface is in RGBA32 format for upload
        var finalSurface = surface
        let targetFormat = SDL_PIXELFORMAT_RGBA32
        var convertedSurface: UnsafeMutablePointer<SDL_Surface>? = nil
        if surface.pointee.format != targetFormat {
            convertedSurface = SDL_ConvertSurface(surface, targetFormat)
            if let converted = convertedSurface {
                finalSurface = converted
            } else {
                print("Failed to convert text surface to RGBA32 format")
            }
        }
        defer {
            if let converted = convertedSurface {
                SDL_DestroySurface(converted)
            }
        }

        let texture = renderer.uploadToGPUTexture(
            width: finalSurface.pointee.w,
            height: finalSurface.pointee.h,
            pixelData: finalSurface.pointee.pixels
        )
        if texture == nil {
            print("Failed to upload text texture to GPU")
        }

        let w = Double(surface.pointee.w)
        let h = Double(surface.pointee.h)
        SDL_DestroySurface(surface)

        return (texture, w, h)
    }

    // MARK: - Public Text API

    /// Creates a text sprite. Returns the SpriteID.
    @discardableResult
    public func addText(
        id1: Int64, id2: Int64,
        text: String,
        fontPath: String,
        fontSize: Float,
        position: (Double, Double, Double),
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        spriteManager: SpriteManager,
        renderer: EngineRenderer,
        gpuDevice: OpaquePointer
    ) -> SpriteID {
        guard let font = getOrCreateFont(path: fontPath, size: fontSize) else {
            print("Failed to load font '\(fontPath)'.")
            return SpriteID(id1: id1, id2: id2)
        }

        // Bake texture in white so the display-adaptive tint color (applied via
        // ImDrawListAddImageQuad in renderSprite) produces the exact adjusted color.
        // sprite.color preserves the original for the tint calculation.
        let sdlColor = SDL_Color(r: 255, g: 255, b: 255, a: color.3)
        let (texture, w, h) = renderTextToTexture(
            font: font, text: text, color: sdlColor, renderer: renderer, gpuDevice: gpuDevice)

        let spriteID = SpriteID(id1: id1, id2: id2)
        let textSprite = Sprite(
            id: spriteID,
            position: position,
            scale: (1.0, 1.0, 1.0),
            size: (w, h),
            rotate: (0.0, 0.0, 0.0),
            color: color,
            speed: (0.0, 0.0),
            texture: texture,
            ownsTexture: texture != nil,
            text: text,
            font: font
        )
        spriteManager.addRawSprite(textSprite)
        return spriteID
    }

    /// Updates the text string of an existing text sprite.
    public func setText(
        id1: Int64, _ id2: Int64, 
        newText: String, 
        spriteManager: SpriteManager,
        renderer: EngineRenderer,
        gpuDevice: OpaquePointer
    ) {
        let spriteID = SpriteID(id1: id1, id2: id2)
        guard let sprite = spriteManager.getSprite(for: spriteID) else {
            print("setText: unknown sprite ID.")
            return
        }
        guard let font = sprite.font else {
            print("setText: called on a non-text sprite.")
            return
        }

        // Re-bake in white so the display-adaptive tint works correctly.
        let a = sprite.color.3
        let bakeColor = SDL_Color(r: 255, g: 255, b: 255, a: a)
        let (newTexture, newWidth, newHeight) = renderTextToTexture(
            font: font, text: newText, color: bakeColor, renderer: renderer, gpuDevice: gpuDevice)

        if let oldTexture = sprite.texture, oldTexture != newTexture, sprite.ownsTexture {
            SDL_ReleaseGPUTexture(gpuDevice, oldTexture)
        }

        sprite.texture = newTexture
        sprite.ownsTexture = newTexture != nil
        sprite.size = (newWidth, newHeight)
        sprite.text = newText
    }

    internal func measureTextPixels(font: OpaquePointer?, text: String) -> (w: Double, h: Double) {
        guard !text.isEmpty else { return (0, 0) }

        let color = SDL_Color(r: 255, g: 255, b: 255, a: 255)
        let surface = text.withCString { cstr in
            TTF_RenderText_Blended(font, cstr, 0, color)
        }

        guard let surface else {
            return (0, 0)
        }

        let w = Double(surface.pointee.w)
        let h = Double(surface.pointee.h)
        SDL_DestroySurface(surface)
        return (w, h)
    }

    private func measureTextLayoutPixels(
        font: OpaquePointer?,
        text: String
    ) -> Double {
        guard let font, !text.isEmpty else { return 0 }

        let surfaceWidth = measureTextPixels(font: font, text: text).w
        var advanceWidth = 0.0
        var measuredAllGlyphs = true

        for scalar in text.unicodeScalars {
            var minX: Int32 = 0
            var maxX: Int32 = 0
            var minY: Int32 = 0
            var maxY: Int32 = 0
            var advance: Int32 = 0

            if TTF_GetGlyphMetrics(
                font, scalar.value,
                &minX, &maxX, &minY, &maxY, &advance
            ) {
                advanceWidth += Double(advance)
            } else {
                measuredAllGlyphs = false
                break
            }
        }

        let measuredWidth = measuredAllGlyphs && advanceWidth > 0
            ? min(surfaceWidth, advanceWidth)
            : surfaceWidth
        let wrapTolerance = max(1.0, measuredWidth * 0.02)
        return max(0.0, measuredWidth - wrapTolerance)
    }

    internal func addCADTextSprites(
        text: String,
        fontPath: String,
        fontSize: Float,
        position: Vector3,
        rotation: Double,
        height: Double,
        widthFactor: Double = 1.0,
        obliqueAngle: Double = 0.0,
        maxWidth: Double?,
        fitWidth: Double? = nil,
        alignH: Int,
        alignV: Int,
        lineSpacingFactor: Double = 1.0,
        lineSpacingStyle: Int = 1,
        formattedText: FormattedText? = nil,
        color: (UInt8, UInt8, UInt8, UInt8),
        backgroundScale: Double? = nil,
        backgroundColor: (UInt8, UInt8, UInt8, UInt8)? = nil,
        backgroundUsesViewportColor: Bool = false,
        z: Double,
        geometryManager: GeometryManager,
        spriteManager: SpriteManager,
        renderer: EngineRenderer,
        gpuDevice: OpaquePointer
    ) -> (spriteIDs: [SpriteID], primitiveIDs: [SpriteID]) {
        guard let font = getOrCreateFont(path: fontPath, size: fontSize) else {
            return ([], [])
        }

        let renderOrigin = geometryManager.renderOrigin
        func localPoint(_ point: Vector3) -> SDL_FPoint {
            SDL_FPoint(
                x: renderOrigin.localX(point.x),
                y: renderOrigin.localY(point.y))
        }

        let metrics = cadFontMetrics(for: font)
        var worldScale = height / metrics.capHeightPixels
        var horizontalWorldScale = worldScale * max(widthFactor, 1e-9)
        let maxWidthPixels = maxWidth.map { $0 / horizontalWorldScale }

        let lines: [CADTextFormatter.Line]
        if let formattedText {
            lines = CADTextFormatter.layout(
                formatted: formattedText,
                maxWidth: maxWidthPixels
            ) { value in
                measureTextLayoutPixels(font: font, text: value)
            }
        } else {
            lines = CADTextFormatter.layout(text, maxWidth: maxWidthPixels) { value in
                measureTextLayoutPixels(font: font, text: value)
            }
        }

        let linePixelMetrics = lines.map { line -> (w: Double, h: Double) in
            if line.text.isEmpty {
                return (0.0, metrics.lineHeightPixels)
            }
            let lineScales = Set(line.glyphs.map(\.heightScale))
            guard lineScales.count > 1 else {
                return measureTextPixels(font: font, text: line.text)
            }
            // Mixed `\H` runs: measure each scale group at its own size so
            // the line box matches the scale-aware wrap width; the tallest
            // group sets the line height. (World mapping is size-invariant,
            // so group pixels convert with the same world scale.)
            var mixedW = 0.0
            var mixedH = 0.0
            var glyphIndex = line.glyphs.startIndex
            while glyphIndex < line.glyphs.endIndex {
                let groupScale = line.glyphs[glyphIndex].heightScale
                var groupEnd = line.glyphs.index(after: glyphIndex)
                while groupEnd < line.glyphs.endIndex, line.glyphs[groupEnd].heightScale == groupScale {
                    groupEnd = line.glyphs.index(after: groupEnd)
                }
                let groupText = line.glyphs[glyphIndex..<groupEnd].map(\.text).joined()
                if !groupText.isEmpty {
                    let openScale = min(max(groupScale, 0.001), 1000.0)
                    let groupFont = getOrCreateFont(path: fontPath, size: fontSize * Float(openScale)) ?? font
                    let groupMetrics = measureTextPixels(font: groupFont, text: groupText)
                    mixedW += groupMetrics.w
                    mixedH = max(mixedH, groupMetrics.h)
                }
                glyphIndex = groupEnd
            }
            return (mixedW, mixedH)
        }

        // Fit (alignH 5) / Aligned (alignH 3): rescale so the single
        // line spans fitWidth exactly. World/height scales are var so
        // Aligned can grow both axes; Fit stretches only horizontal.
        var effectiveHeight = height
        if let fitWidth, fitWidth > 0, (alignH == 3 || alignH == 5),
           lines.count == 1, let firstLine = linePixelMetrics.first, firstLine.w > 0 {
            let naturalWorld = firstLine.w * horizontalWorldScale
            if naturalWorld > 1e-12 {
                let k = fitWidth / naturalWorld
                horizontalWorldScale *= k
                if alignH == 3 {
                    worldScale *= k
                    effectiveHeight *= k
                }
            }
        }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let spacingFactor = max(lineSpacingFactor, 0.01)
        let requestedLineHeight = effectiveHeight * (5.0 / 3.0) * spacingFactor
        let renderedLineHeight = metrics.lineHeightPixels * worldScale
        let lineHeightWorld = lineSpacingStyle == 2
            ? requestedLineHeight
            : max(requestedLineHeight, renderedLineHeight)
        let lastLineHeight = max(
            linePixelMetrics.last?.h ?? metrics.lineHeightPixels,
            1.0) * worldScale
        let blockHeight =
            Double(max(lines.count, 1) - 1) * lineHeightWorld
            + lastLineHeight

        let baseY: Double
        if alignH == 4 {
            baseY = -blockHeight * 0.5
        } else {
            switch alignV {
            case 1:
                baseY = -blockHeight
            case 2, 4:
                baseY = -blockHeight * 0.5
            case 3:
                baseY = -metrics.capTopPaddingPixels * worldScale
            default:
                baseY = -effectiveHeight
            }
        }

        func worldPoint(localX: Double, localY: Double) -> Vector3 {
            Vector3(
                x: position.x + localX * cosR - localY * sinR,
                y: position.y + localX * sinR + localY * cosR,
                z: z
            )
        }

        func styledSegments(
            for line: CADTextFormatter.Line
        ) -> [(text: String, bold: Bool, italic: Bool, scale: Double)] {
            var result: [(text: String, bold: Bool, italic: Bool, scale: Double)] = []
            for glyph in line.glyphs {
                if let last = result.last,
                   last.bold == glyph.bold,
                   last.italic == glyph.italic,
                   last.scale == glyph.heightScale {
                    result[result.count - 1].text += glyph.text
                } else {
                    result.append((
                        text: glyph.text,
                        bold: glyph.bold,
                        italic: glyph.italic,
                        scale: glyph.heightScale))
                }
            }
            return result
        }

        func horizontalOffset(
            for line: CADTextFormatter.Line,
            lineWidthWorld: Double
        ) -> Double {
            let hasParagraphAlignment = line.alignment != 0
            let paragraphAlignment = hasParagraphAlignment ? line.alignment : alignH
            let effectiveAlignment: Int
            if hasParagraphAlignment {
                effectiveAlignment = paragraphAlignment == 5 ? 0 : paragraphAlignment
            } else if alignH == 3 || alignH == 5 {
                effectiveAlignment = (fitWidth ?? 0) > 0 ? 0 : 1
            } else {
                effectiveAlignment = alignH
            }

            if hasParagraphAlignment, let maxWidth, maxWidth > 0 {
                let referenceBoxLeft: Double
                switch alignH {
                case 1, 4:
                    referenceBoxLeft = -maxWidth * 0.5
                case 2:
                    referenceBoxLeft = -maxWidth
                default:
                    referenceBoxLeft = 0
                }

                switch effectiveAlignment {
                case 1, 4:
                    return referenceBoxLeft + (maxWidth - lineWidthWorld) * 0.5
                case 2:
                    return referenceBoxLeft + maxWidth - lineWidthWorld
                default:
                    return referenceBoxLeft
                }
            }

            switch effectiveAlignment {
            case 1, 4:
                return -lineWidthWorld * 0.5
            case 2:
                return -lineWidthWorld
            default:
                return 0
            }
        }

        var spriteIDs: [SpriteID] = []
        var primitiveIDs: [SpriteID] = []

        if let backgroundScale,
           let backgroundColor,
           backgroundScale >= 1.0 {
            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude

            for (lineIndex, line) in lines.enumerated() where !line.text.isEmpty {
                let lineMetrics = linePixelMetrics[lineIndex]
                let lineWidthWorld = lineMetrics.w * horizontalWorldScale
                let lineHeightWorldActual = max(lineMetrics.h, 1.0) * worldScale
                let offsetX = horizontalOffset(
                    for: line,
                    lineWidthWorld: lineWidthWorld)
                let offsetY = baseY + Double(lineIndex) * lineHeightWorld
                minX = min(minX, offsetX)
                maxX = max(maxX, offsetX + lineWidthWorld)
                minY = min(minY, offsetY)
                maxY = max(maxY, offsetY + lineHeightWorldActual)
            }

            if minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite {
                let margin = max(0.0, (backgroundScale - 1.0) * effectiveHeight * 0.5)
                let localCorners = [
                    (minX - margin, minY - margin),
                    (maxX + margin, minY - margin),
                    (maxX + margin, maxY + margin),
                    (minX - margin, maxY + margin),
                ]
                let corners = localCorners.map { corner in
                    let point = worldPoint(localX: corner.0, localY: corner.1)
                    return localPoint(point)
                }
                let maskID = geometryManager.addFillCorners(
                    corners,
                    z: z - 0.02,
                    color: backgroundColor)
                if let mask = geometryManager.getPrimitive(id: maskID) {
                    mask.usesViewportBackgroundColor = backgroundUsesViewportColor
                }
                primitiveIDs.append(maskID)
            }
        }

        for (lineIndex, line) in lines.enumerated() {
            let lineText = line.text
            guard !lineText.isEmpty else { continue }

            let lineMetrics = linePixelMetrics[lineIndex]
            let lineWidthWorld = lineMetrics.w * horizontalWorldScale
            let lineHeightWorldActual = max(lineMetrics.h, 1.0) * worldScale

            let offsetX = horizontalOffset(
                for: line,
                lineWidthWorld: lineWidthWorld)

            let offsetY = baseY + Double(lineIndex) * lineHeightWorld
            let halfWidth = lineWidthWorld * 0.5
            let halfHeight = lineHeightWorldActual * 0.5
            let lineCenter = worldPoint(
                localX: offsetX + halfWidth,
                localY: offsetY + halfHeight)

            func rotatedCorner(_ x: Double, _ y: Double) -> Vector3 {
                Vector3(
                    x: lineCenter.x + x * cosR - y * sinR,
                    y: lineCenter.y + x * sinR + y * cosR,
                    z: z)
            }

            let corners = [
                rotatedCorner(-halfWidth, -halfHeight),
                rotatedCorner(halfWidth, -halfHeight),
                rotatedCorner(halfWidth, halfHeight),
                rotatedCorner(-halfWidth, halfHeight),
            ]
            for cornerIndex in 0..<4 {
                let a = corners[cornerIndex]
                let b = corners[(cornerIndex + 1) % 4]
                let proxyID = geometryManager.addLine(
                    x1: renderOrigin.localX(a.x), y1: renderOrigin.localY(a.y),
                    x2: renderOrigin.localX(b.x), y2: renderOrigin.localY(b.y),
                    z: z,
                    color: color)
                if let proxy = geometryManager.getPrimitive(id: proxyID) {
                    proxy.isPanProxy = true
                }
                primitiveIDs.append(proxyID)
            }

            let sdlColor = SDL_Color(r: 255, g: 255, b: 255, a: color.3)
            var segmentCursorPixels = 0.0

            for segment in styledSegments(for: line) where !segment.text.isEmpty {
                let segmentPath = styledFontPath(
                    basePath: fontPath,
                    bold: segment.bold,
                    italic: segment.italic)
                let segmentFont =
                    // Open the segment's own size so mixed `\H` runs render at
                    // their laid-out height. World mapping is size-invariant
                    // (height/capHeight), so cursor pixels convert uniformly.
                    // Absurd scales clamp for the font open (wrapping stays
                    // exact); a failed open falls back to the base font.
                    getOrCreateFont(path: segmentPath, size: fontSize * Float(min(max(segment.scale, 0.001), 1000.0))) ?? font
                let rendered = renderTextToTexture(
                    font: segmentFont,
                    text: segment.text,
                    color: sdlColor,
                    renderer: renderer,
                    gpuDevice: gpuDevice)
                guard let texture = rendered.texture else {
                    continue
                }

                let quadWidth = rendered.w * horizontalWorldScale
                let quadHeight = rendered.h * worldScale
                let segmentX =
                    offsetX + segmentCursorPixels * horizontalWorldScale

                func addSegmentSprite(localXOffset: Double, spriteZ: Double, ownsTexture: Bool) {
                    let segmentHalfWidth = quadWidth * 0.5
                    let segmentHalfHeight = quadHeight * 0.5
                    let desiredCenter = worldPoint(
                        localX: segmentX + localXOffset + segmentHalfWidth,
                        localY: offsetY + segmentHalfHeight)
                    let spritePosition = Vector3(
                        x: desiredCenter.x - segmentHalfWidth,
                        y: desiredCenter.y - segmentHalfHeight,
                        z: spriteZ)
                    let id = SpriteID(
                        id1: Int64.random(in: 1...Int64.max),
                        id2: Int64.random(in: 1...Int64.max))
                    let sprite = Sprite(
                        id: id,
                        position: (
                            spritePosition.x,
                            spritePosition.y,
                            spritePosition.z),
                        scale: (horizontalWorldScale, worldScale, 1.0),
                        size: (rendered.w, rendered.h),
                        rotate: (0.0, 0.0, rotation * 180.0 / .pi),
                        shearX: tan(obliqueAngle * .pi / 180.0),
                        color: color,
                        speed: (0.0, 0.0),
                        texture: texture,
                        ownsTexture: ownsTexture,
                        text: segment.text,
                        font: segmentFont,
                        useBoundsWhilePanning: true)
                    spriteManager.addRawSprite(sprite)
                    spriteIDs.append(id)
                }

                addSegmentSprite(localXOffset: 0, spriteZ: z, ownsTexture: true)
                if segment.bold && segmentPath == fontPath {
                    addSegmentSprite(
                        localXOffset: horizontalWorldScale,
                        spriteZ: z + 0.001, ownsTexture: false)
                }

                segmentCursorPixels += rendered.w
            }

            let ranges = CADTextFormatter.underlineRanges(for: line) { value in
                measureTextPixels(font: font, text: value).w
            }

            let underlineOffsetPixels = max(
                1.0,
                min(metrics.capHeightPixels, -metrics.descentPixels))
            let underlineY = offsetY
                + (metrics.ascentPixels + underlineOffsetPixels) * worldScale

            for range in ranges {
                let x1 = offsetX + range.x * horizontalWorldScale
                let x2 = offsetX + (range.x + range.width) * horizontalWorldScale
                let p1 = worldPoint(localX: x1, localY: underlineY)
                let p2 = worldPoint(localX: x2, localY: underlineY)

                let underlineID = geometryManager.addLine(
                    x1: renderOrigin.localX(p1.x),
                    y1: renderOrigin.localY(p1.y),
                    x2: renderOrigin.localX(p2.x),
                    y2: renderOrigin.localY(p2.y),
                    z: z + 0.01,
                    color: color)
                primitiveIDs.append(underlineID)
            }
        }

        return (spriteIDs, primitiveIDs)
    }
}
