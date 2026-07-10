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
    public var fontName: String
    public var height: Double
    public var rotation: Double
    public var alignH: Int       // 0=left, 1=center, 2=right
    public var alignV: Int       // 0=baseline, 1=bottom, 2=middle, 3=top
    public var mtextWidth: Double // 0 = no wrap (TEXT), >0 = wrap width (MTEXT)
    public var targetHandle: UUID? // nil = creating new, non-nil = editing existing

    public init(
        text: String = "",
        fontName: String = "simplex.shx",
        height: Double = 2.5,
        rotation: Double = 0,
        alignH: Int = 0,
        alignV: Int = 0,
        mtextWidth: Double = 0,
        targetHandle: UUID? = nil
    ) {
        self.text = text
        self.fontName = fontName
        self.height = height
        self.rotation = rotation
        self.alignH = alignH
        self.alignV = alignV
        self.mtextWidth = mtextWidth
        self.targetHandle = targetHandle
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

        if let oldTexture = sprite.texture {
            SDL_ReleaseGPUTexture(gpuDevice, oldTexture)
        }

        sprite.texture = newTexture
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

    internal func addCADTextSprites(
        text: String,
        fontPath: String,
        fontSize: Float,
        position: Vector3,
        rotation: Double,
        height: Double,
        maxWidth: Double?,
        alignH: Int,
        alignV: Int,
        color: (UInt8, UInt8, UInt8, UInt8),
        backgroundScale: Double? = nil,
        backgroundColor: (UInt8, UInt8, UInt8, UInt8)? = nil,
        z: Double,
        geometryManager: GeometryManager,
        spriteManager: SpriteManager,
        renderer: EngineRenderer,
        gpuDevice: OpaquePointer
    ) -> (spriteIDs: [SpriteID], primitiveIDs: [SpriteID]) {
        guard let font = getOrCreateFont(path: fontPath, size: fontSize) else {
            return ([], [])
        }

        let sample = measureTextPixels(font: font, text: "Hg")
        let pixelHeight = max(sample.h, 1.0)
        let worldScale = height / pixelHeight
        let maxWidthPixels = maxWidth.map { $0 / worldScale }

        let lines = CADTextFormatter.layout(text, maxWidth: maxWidthPixels) { s in
            measureTextPixels(font: font, text: s).w
        }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let lineHeightWorld = height * 1.666
        let blockHeight = Double(max(lines.count, 1) - 1) * lineHeightWorld + height

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
                baseY = 0
            default:
                baseY = -height
            }
        }

        func worldPoint(localX: Double, localY: Double) -> Vector3 {
            Vector3(
                x: position.x + localX * cosR - localY * sinR,
                y: position.y + localX * sinR + localY * cosR,
                z: z
            )
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
                let metrics = measureTextPixels(font: font, text: line.text)
                let lineWidthWorld = metrics.w * worldScale
                let lineHeightWorldActual = max(metrics.h, 1.0) * worldScale
                let offsetX: Double
                switch alignH {
                case 1, 4:
                    offsetX = -lineWidthWorld * 0.5
                case 2:
                    offsetX = -lineWidthWorld
                default:
                    offsetX = 0
                }
                let offsetY = baseY + Double(lineIndex) * lineHeightWorld
                minX = min(minX, offsetX)
                maxX = max(maxX, offsetX + lineWidthWorld)
                minY = min(minY, offsetY)
                maxY = max(maxY, offsetY + lineHeightWorldActual)
            }

            if minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite {
                let margin = max(0.0, (backgroundScale - 1.0) * height * 0.5)
                let localCorners = [
                    (minX - margin, minY - margin),
                    (maxX + margin, minY - margin),
                    (maxX + margin, maxY + margin),
                    (minX - margin, maxY + margin),
                ]
                let corners = localCorners.map { corner in
                    let point = worldPoint(localX: corner.0, localY: corner.1)
                    return SDL_FPoint(x: Float(point.x), y: Float(point.y))
                }
                let maskID = geometryManager.addFillCorners(
                    corners,
                    z: z - 0.02,
                    color: backgroundColor)
                primitiveIDs.append(maskID)
            }
        }

        for (lineIndex, line) in lines.enumerated() {
            let lineText = line.text
            guard !lineText.isEmpty else { continue }

            // Bake texture in white so the display-adaptive tint color
            // (computed from sprite.color in renderSprite) produces the
            // exact adjusted color via ImDrawListAddImageQuad modulation.
            let sdlColor = SDL_Color(r: 255, g: 255, b: 255, a: color.3)
            let rendered = renderTextToTexture(
                font: font, text: lineText, color: sdlColor, renderer: renderer, gpuDevice: gpuDevice)
            guard let texture = rendered.texture else { continue }

            let lineWidthWorld = rendered.w * worldScale

            let offsetX: Double
            switch alignH {
            case 1, 4:
                offsetX = -lineWidthWorld * 0.5
            case 2:
                offsetX = -lineWidthWorld
            default:
                offsetX = 0
            }

            let offsetY = baseY + Double(lineIndex) * lineHeightWorld
            let quadWidth = rendered.w * worldScale
            let quadHeight = rendered.h * worldScale
            let halfWidth = quadWidth * 0.5
            let halfHeight = quadHeight * 0.5

            // Sprite.position is the unrotated top-left of a quad that the
            // renderer rotates around position + half-size. Convert the
            // text's local, rotated top-left into that representation by
            // calculating the desired rotated center first. Passing the
            // rotated top-left directly shifts 90-degree MTEXT perpendicular
            // to its insertion point (notably vertical dimension labels).
            let desiredCenter = worldPoint(
                localX: offsetX + halfWidth,
                localY: offsetY + halfHeight)
            let p = Vector3(
                x: desiredCenter.x - halfWidth,
                y: desiredCenter.y - halfHeight,
                z: z)

            let id = SpriteID(id1: Int64.random(in: 1...Int64.max), id2: Int64.random(in: 1...Int64.max))
            let sprite = Sprite(
                id: id,
                position: (p.x, p.y, p.z),
                scale: (worldScale, worldScale, 1.0),
                size: (rendered.w, rendered.h),
                rotate: (0.0, 0.0, rotation * 180.0 / .pi),
                color: color,
                speed: (0.0, 0.0),
                texture: texture,
                text: lineText,
                font: font,
                useBoundsWhilePanning: true
            )

            spriteManager.addRawSprite(sprite)
            spriteIDs.append(id)

            // Build the pan placeholder in the CAD geometry path. Unlike the
            // ImGui texture quad, these lines use the exact CAD GPU camera
            // matrix and remain locked to the drawing during pan.
            let centerX = p.x + halfWidth
            let centerY = p.y + halfHeight

            func rotatedCorner(_ x: Double, _ y: Double) -> Vector3 {
                Vector3(
                    x: centerX + x * cosR - y * sinR,
                    y: centerY + x * sinR + y * cosR,
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
                    x1: Float(a.x), y1: Float(a.y),
                    x2: Float(b.x), y2: Float(b.y),
                    z: z,
                    color: color)
                if let proxy = geometryManager.getPrimitive(id: proxyID) {
                    proxy.isPanProxy = true
                }
                primitiveIDs.append(proxyID)
            }

            let ranges = CADTextFormatter.underlineRanges(for: line) { s in
                measureTextPixels(font: font, text: s).w
            }

            let underlineY = offsetY + height * 0.92

            for range in ranges {
                let x1 = offsetX + range.x * worldScale
                let x2 = offsetX + (range.x + range.width) * worldScale
                let p1 = worldPoint(localX: x1, localY: underlineY)
                let p2 = worldPoint(localX: x2, localY: underlineY)

                let underlineID = geometryManager.addLine(
                    x1: Float(p1.x),
                    y1: Float(p1.y),
                    x2: Float(p2.x),
                    y2: Float(p2.y),
                    z: z + 0.01,
                    color: color
                )
                primitiveIDs.append(underlineID)
            }
        }

        return (spriteIDs, primitiveIDs)
    }
}
