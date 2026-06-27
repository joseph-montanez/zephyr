import Foundation
import SwiftSDL
import SwiftSDL_ttf

// =========================================================================
// MARK: - Sprite System
// =========================================================================

/// A hashable ID for sprites to use as a dictionary key
public struct SpriteID: Hashable, Sendable {
    public let id1: Int64
    public let id2: Int64
}

/// Represents a sprite's renderable state
public final class Sprite: @unchecked Sendable {
    public var id: SpriteID
    public var position: (Double, Double, Double)
    public var size: (Double, Double)
    public var color: (UInt8, UInt8, UInt8, UInt8) {
        didSet {
            let rgba = ColorRGBA(r: color.0, g: color.1, b: color.2, a: color.3)
            let light = rgba.displayAdjusted(forLightBackground: true)
            let dark = rgba.displayAdjusted(forLightBackground: false)
            self.adjustedColorLight = (light.r, light.g, light.b, light.a)
            self.adjustedColorDark = (dark.r, dark.g, dark.b, dark.a)
        }
    }
    public var adjustedColorLight: (UInt8, UInt8, UInt8, UInt8)
    public var adjustedColorDark: (UInt8, UInt8, UInt8, UInt8)
    public var texture: OpaquePointer? = nil
    public var rotate: (Double, Double, Double)
    public var speed: (Double, Double)
    public var scale: (Double, Double, Double)
    public var text: String?
    public var font: OpaquePointer?
    public var sourceRect: SDL_FRect? = nil
    /// CAD TTF text may use a lightweight outline while the camera is panning.
    /// This avoids a visible phase difference between ImGui texture quads and
    /// CAD geometry rendered through the GPU camera matrix.
    public var useBoundsWhilePanning: Bool

    init(
        id: SpriteID,
        position: (Double, Double, Double),
        scale: (Double, Double, Double),
        size: (Double, Double),
        rotate: (Double, Double, Double),
        color: (UInt8, UInt8, UInt8, UInt8),
        speed: (Double, Double),
        texture: OpaquePointer? = nil,
        text: String? = nil,
        font: OpaquePointer? = nil,
        sourceRect: SDL_FRect? = nil,
        useBoundsWhilePanning: Bool = false
    ) {
        self.id = id
        self.position = position
        self.color = color
        let rgba = ColorRGBA(r: color.0, g: color.1, b: color.2, a: color.3)
        let light = rgba.displayAdjusted(forLightBackground: true)
        let dark = rgba.displayAdjusted(forLightBackground: false)
        self.adjustedColorLight = (light.r, light.g, light.b, light.a)
        self.adjustedColorDark = (dark.r, dark.g, dark.b, dark.a)
        self.size = size
        self.texture = texture
        self.rotate = rotate
        self.speed = speed
        self.scale = scale
        self.text = text
        self.font = font
        self.sourceRect = sourceRect
        self.useBoundsWhilePanning = useBoundsWhilePanning
    }
}

/// Manages all sprites for rendering
public final class SpriteManager: @unchecked Sendable {
    private var sprites: [SpriteID: Sprite] = [:]
    private var isSortNeeded = false
    private var renderList: [Sprite] = []

    public init() {}

    public func addSprite(
        id1: Int64, id2: Int64,
        position: (Double, Double, Double),
        scale: (Double, Double, Double) = (1, 1, 1),
        size: (Double, Double),
        rotation: (Double, Double, Double) = (0, 0, 0),
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        speed: (Double, Double) = (0, 0),
        texture: OpaquePointer? = nil
    ) {
        let spriteID = SpriteID(id1: id1, id2: id2)
        if sprites[spriteID] != nil {
            // Sprite already exists; update it instead
            updateSprite(
                id: spriteID, position: position, scale: scale, size: size,
                rotation: rotation, color: color, speed: speed, texture: texture)
            return
        }
        let newSprite = Sprite(
            id: spriteID,
            position: position,
            scale: scale,
            size: size,
            rotate: rotation,
            color: color,
            speed: speed,
            texture: texture
        )
        sprites[spriteID] = newSprite
        renderList.append(newSprite)
        isSortNeeded = true
    }

    public func addRawSprite(_ sprite: Sprite) {
        sprites[sprite.id] = sprite
        renderList.append(sprite)
        isSortNeeded = true
    }

    public func removeSprite(id: SpriteID) {
        if sprites.removeValue(forKey: id) != nil {
            renderList.removeAll(where: { $0.id == id })
            isSortNeeded = true
        }
    }

    public func removeSprite(_ id1: Int64, _ id2: Int64) {
        removeSprite(id: SpriteID(id1: id1, id2: id2))
    }

    public func getSprite(for id: SpriteID) -> Sprite? {
        return sprites[id]
    }

    public func getSprite(_ id1: Int64, _ id2: Int64) -> Sprite? {
        return sprites[SpriteID(id1: id1, id2: id2)]
    }

    public func updateSprite(
        id: SpriteID,
        position: (Double, Double, Double)? = nil,
        scale: (Double, Double, Double)? = nil,
        size: (Double, Double)? = nil,
        rotation: (Double, Double, Double)? = nil,
        color: (UInt8, UInt8, UInt8, UInt8)? = nil,
        speed: (Double, Double)? = nil,
        texture: OpaquePointer? = nil
    ) {
        guard let sprite = sprites[id] else { return }
        if let pos = position {
            if sprite.position.2 != pos.2 { isSortNeeded = true }
            sprite.position = pos
        }
        if let s = scale { sprite.scale = s }
        if let s = size { sprite.size = s }
        if let r = rotation { sprite.rotate = r }
        if let c = color { sprite.color = c }
        if let s = speed { sprite.speed = s }
        if let t = texture { sprite.texture = t }
    }

    public func setTexture(for id: SpriteID, texture: OpaquePointer?) {
        sprites[id]?.texture = texture
    }

    public func setSourceRect(_ id: SpriteID, _ rect: (Float, Float, Float, Float)) {
        guard let sprite = sprites[id] else { return }
        if rect.2 <= 0 || rect.3 <= 0 {
            sprite.sourceRect = nil
        } else {
            sprite.sourceRect = SDL_FRect(x: rect.0, y: rect.1, w: rect.2, h: rect.3)
        }
    }

    /// Returns a sorted snapshot of sprites for rendering (z-order).
    public func getSpritesForRendering() -> [Sprite] {
        if isSortNeeded {
            renderList.sort(by: { $0.position.2 < $1.position.2 })
            isSortNeeded = false
        }
        return renderList
    }

    public var spriteCount: Int { sprites.count }
}

// =========================================================================
// MARK: - SDL C-Struct Sendable Conformances
// =========================================================================
// SDL_FPoint and SDL_FRect are imported C structs. Swift 6 does not
// implicitly mark them Sendable, so we provide retroactive conformances.
extension SDL_FPoint: @retroactive @unchecked Sendable {}
extension SDL_FRect: @retroactive @unchecked Sendable {}

// =========================================================================
// MARK: - Geometry System
// =========================================================================

public enum PrimitiveType: UInt32, Sendable {
    case point = 0
    case line = 1
    case rect = 2
    case fillRect = 3
    case points = 4
    case lines = 5
    case rects = 6
    case fillRects = 7
}

/// Represents a renderable primitive object
public final class RenderPrimitive: @unchecked Sendable {
    public struct GradientData: Sendable {
        public let color1: (UInt8, UInt8, UInt8, UInt8)
        public let color2: (UInt8, UInt8, UInt8, UInt8)
        public let angleCos: Double
        public let angleSin: Double
        public let minX: Double
        public let minY: Double
        public let diag: Double
        public init(color1: (UInt8, UInt8, UInt8, UInt8), color2: (UInt8, UInt8, UInt8, UInt8), angleCos: Double, angleSin: Double, minX: Double, minY: Double, diag: Double) {
            self.color1 = color1
            self.color2 = color2
            self.angleCos = angleCos
            self.angleSin = angleSin
            self.minX = minX
            self.minY = minY
            self.diag = diag
        }
    }

    public var id: SpriteID
    public var type: PrimitiveType
    public var z: Double
    public var color: (UInt8, UInt8, UInt8, UInt8) {
        didSet {
            self.sdlColor = SDL_FColor(
                r: Float(color.0) / 255.0,
                g: Float(color.1) / 255.0,
                b: Float(color.2) / 255.0,
                a: Float(color.3) / 255.0
            )
            let rgba = ColorRGBA(r: color.0, g: color.1, b: color.2, a: color.3)
            let light = rgba.displayAdjusted(forLightBackground: true)
            let dark = rgba.displayAdjusted(forLightBackground: false)
            self.adjustedColorLight = (light.r, light.g, light.b, light.a)
            self.adjustedColorDark = (dark.r, dark.g, dark.b, dark.a)
        }
    }
    /// Precomputed float color for SDL_Vertex / SDL_SetRenderDrawColor (avoids per-frame conversion).
    public var sdlColor: SDL_FColor
    public var adjustedColorLight: (UInt8, UInt8, UInt8, UInt8)
    public var adjustedColorDark: (UInt8, UInt8, UInt8, UInt8)
    public var isScreenSpace: Bool
    public var lineWeight: Double = 0.0
    public var geomWidth: Double = 0.0
    public var isHatchLine: Bool = false
    public var hatchSpacing: Double = 0.0
    public var gradientData: GradientData?
    /// Render only while the camera is actively panning.
    public var isPanProxy: Bool = false
    /// Entity index (0-based, dense). 0 = no entity (default). Set during applySpecs
    /// so the vertex buffer builder can propagate it to each CADVertex.
    public var entityIndex: UInt32 = 0
    public var points: [SDL_FPoint] = []
    public var rects: [SDL_FRect] = []
    /// Rotated corners stored when a rect is converted to polygon after rotation.
    /// Used for bounding-box computation, hit-testing, and filled-polygon rendering.
    public var corners: [SDL_FPoint] = []
    /// Cached screen-space points (valid when cameraGenerationPoints == engine's _renderGeneration).
    public var cachedScreenPoints: [SDL_FPoint] = []
    /// Cached screen-space rects (valid when cameraGenerationRects == engine's _renderGeneration).
    public var cachedScreenRects: [SDL_FRect] = []
    /// Cached screen-space rotated corners (valid when cameraGenerationCorners == engine's _renderGeneration).
    public var cachedScreenCorners: [SDL_FPoint] = []
    /// Camera generation that produced each cache. Split per-cache so transforming
    /// one (e.g. points) never marks the others (rects/corners) as up to date.
    public var cameraGenerationPoints: Int = -1
    public var cameraGenerationRects: Int = -1
    public var cameraGenerationCorners: Int = -1
    /// World-space bounding box (nil until computed, nil for screen-space primitives).
    public var worldMinX: Double?
    public var worldMinY: Double?
    public var worldMaxX: Double?
    public var worldMaxY: Double?

    /// Compute world-space AABB from points/rects/corners (all in world-space).
    func computeWorldBounds() {
        guard !isScreenSpace else { return }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var hasData = false

        for p in points {
            minX = Swift.min(minX, Double(p.x))
            maxX = Swift.max(maxX, Double(p.x))
            minY = Swift.min(minY, Double(p.y))
            maxY = Swift.max(maxY, Double(p.y))
            hasData = true
        }
        for r in rects {
            minX = Swift.min(minX, Double(r.x))
            maxX = Swift.max(maxX, Double(r.x + r.w))
            minY = Swift.min(minY, Double(r.y))
            maxY = Swift.max(maxY, Double(r.y + r.h))
            hasData = true
        }
        for c in corners {
            minX = Swift.min(minX, Double(c.x))
            maxX = Swift.max(maxX, Double(c.x))
            minY = Swift.min(minY, Double(c.y))
            maxY = Swift.max(maxY, Double(c.y))
            hasData = true
        }

        if hasData {
            worldMinX = minX
            worldMinY = minY
            worldMaxX = maxX
            worldMaxY = maxY
        }
    }

    init(
        id: SpriteID, type: PrimitiveType, z: Double,
        color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        isScreenSpace: Bool,
        gradientData: GradientData? = nil
    ) {
        self.id = id
        self.type = type
        self.z = z
        self.color = color
        self.sdlColor = SDL_FColor(
            r: Float(color.r) / 255.0,
            g: Float(color.g) / 255.0,
            b: Float(color.b) / 255.0,
            a: Float(color.a) / 255.0
        )
        let rgba = ColorRGBA(r: color.r, g: color.g, b: color.b, a: color.a)
        let light = rgba.displayAdjusted(forLightBackground: true)
        let dark = rgba.displayAdjusted(forLightBackground: false)
        self.adjustedColorLight = (light.r, light.g, light.b, light.a)
        self.adjustedColorDark = (dark.r, dark.g, dark.b, dark.a)
        self.isScreenSpace = isScreenSpace
        self.gradientData = gradientData
    }
}

/// Manages all non-sprite renderable geometry
public final class GeometryManager: @unchecked Sendable {
    private var primitives: [SpriteID: RenderPrimitive] = [:]
    private var isSortNeeded = false
    private var renderList: [RenderPrimitive] = []
    private var nextGeomID1: Int64 = 1
    /// Incremented on any mutation (add/remove/clear). Used for render cache invalidation.
    public internal(set) var mutationGeneration: Int = 0
    /// Maps entity index (UInt32) → entity handle (UUID). Built during applySpecs.
    /// entityIndex 0 = background/no-entity. Valid indices are >= 1.
    public var entityIndexToHandle: [UInt32: UUID] = [:]
    /// Maps entity handle (UUID) → entity index (UInt32).
    public var handleToEntityIndex: [UUID: UInt32] = [:]

    // MARK: Spatial Grid (lazy-built when primitive count exceeds threshold)
    private static let spatialGridThreshold: Int = 4_000
    /// Flattened grid: cellIndex = cy * gridCols + cx → list of indices into renderList
    private var spatialGrid: [[Int]] = []
    private var gridCols: Int = 0
    private var gridRows: Int = 0
    private var gridOriginX: Double = 0
    private var gridOriginY: Double = 0
    private var gridCellSize: Double = 1000.0
    private var gridBuilt: Bool = false
    /// Reusable boolean array for dedup in visiblePrimitiveIndices. Allocated once,
    /// resized when renderList grows. Reset after each query via the result list.
    private var gridSeen: [Bool] = []
    /// Reusable integer array for epoch-based dedup in visiblePrimitiveIndices.
    private var gridSeenEpochs: [Int] = []
    private var currentQueryEpoch: Int = 0

    /// Build spatial grid for fast viewport culling. O(n) — call after regeneration.
    /// Only built when primitiveCount >= threshold.
    /// Must be called after renderList is sorted (call getPrimitivesForRendering first).
    public func buildSpatialGridIfNeeded() {
        guard primitives.count >= Self.spatialGridThreshold else {
            gridBuilt = false
            return
        }

        // Rebuild renderList from dictionary if dirty (sync with getPrimitivesForRendering)
        if isSortNeeded {
            renderList = Array(primitives.values)
            renderList.sort(by: { $0.z < $1.z })
            isSortNeeded = false
        }

        // Find world bounds
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var hasBounds = false
        for p in renderList {
            guard let mx = p.worldMinX, let my = p.worldMinY,
                let Mx = p.worldMaxX, let My = p.worldMaxY
            else { continue }
            minX = Swift.min(minX, mx)
            maxX = Swift.max(maxX, Mx)
            minY = Swift.min(minY, my)
            maxY = Swift.max(maxY, My)
            hasBounds = true
        }
        guard hasBounds else {
            gridBuilt = false
            return
        }

        // Auto-size grid: aim for ~500 primitives per cell.
        // Floor the cell size relative to the drawing extent so cells never get
        // pathologically small at large world coordinates (where Float vertex
        // quantization could otherwise rival a single cell and mis-file geometry).
        let area = (maxX - minX) * (maxY - minY)
        let cellsTarget = Double(primitives.count) / 500.0
        let span = Swift.max(maxX - minX, maxY - minY)
        let minCell = Swift.max(1.0, span * 1e-5)
        if area > 0 && cellsTarget > 1 {
            gridCellSize = Swift.max(minCell, sqrt(area / cellsTarget))
        } else {
            gridCellSize = Swift.max(minCell, 1000.0)
        }

        // Cap grid resolution to prevent memory explosion if primitives have a huge/pathological coordinate span.
        let maxGridSize = 2048
        let spanX = maxX - minX
        let spanY = maxY - minY
        if spanX / gridCellSize > Double(maxGridSize) {
            gridCellSize = spanX / Double(maxGridSize)
        }
        if spanY / gridCellSize > Double(maxGridSize) {
            gridCellSize = spanY / Double(maxGridSize)
        }

        gridCols = max(1, Int(spanX / gridCellSize) + 1)
        gridRows = max(1, Int(spanY / gridCellSize) + 1)
        gridOriginX = minX
        gridOriginY = minY

        let cellCount = gridCols * gridRows
        spatialGrid = Array(repeating: [], count: cellCount)

        // Pad each primitive's AABB by one cell so a vertex sitting exactly on a
        // cell boundary is filed in both neighbouring cells. Combined with Double
        // bounds, this makes boundary rounding irrelevant at any coordinate scale.
        for (i, p) in renderList.enumerated() {
            guard let mx = p.worldMinX, let my = p.worldMinY,
                let Mx = p.worldMaxX, let My = p.worldMaxY
            else { continue }
            // No padding! Just the exact cells it touches.
            let cx1 = max(0, Int((mx - gridOriginX) / gridCellSize))
            let cy1 = max(0, Int((my - gridOriginY) / gridCellSize))
            let cx2 = min(gridCols - 1, Int((Mx - gridOriginX) / gridCellSize))
            let cy2 = min(gridRows - 1, Int((My - gridOriginY) / gridCellSize))
            for cy in cy1...cy2 {
                for cx in cx1...cx2 {
                    spatialGrid[cy * gridCols + cx].append(i)
                }
            }
        }
        gridBuilt = true
    }

    /// Invalidate spatial grid. Call after direct primitive moves.
    /// Next frame falls back to full iteration until grid is rebuilt by regeneration.
    public func invalidateGrid() {
        gridBuilt = false
        gridSeen.removeAll()
    }

    /// Returns indices into renderList for primitives potentially visible in the given world-space AABB.
    /// Uses spatial grid if built, otherwise returns nil (caller falls back to full iteration).
    /// Includes a 1-cell safety margin (sufficient since grid building no longer over-pads).
    public func visiblePrimitiveIndices(
        inWorldRect minX: Double, minY: Double,
        maxX: Double, maxY: Double
    ) -> [Int]? {
        guard gridBuilt else { return nil }
        
        // 1 cell margin is sufficient since primitives are filed exactly into the cells they touch.
        let cx1 = max(0, Int((minX - gridOriginX) / gridCellSize) - 1)
        let cy1 = max(0, Int((minY - gridOriginY) / gridCellSize) - 1)
        let cx2 = min(gridCols - 1, Int((maxX - gridOriginX) / gridCellSize) + 1)
        let cy2 = min(gridRows - 1, Int((maxY - gridOriginY) / gridCellSize) + 1)
        
        guard cx1 <= cx2, cy1 <= cy2 else { return [] }

        // Epoch-based deduplication: O(1) clear.
        currentQueryEpoch &+= 1
        if currentQueryEpoch == Int.max {
            // Extremely rare wrap-around: reset the array
            gridSeenEpochs = [Int](repeating: 0, count: renderList.count)
            currentQueryEpoch = 1
        } else if gridSeenEpochs.count < renderList.count {
            // Resize if renderList grew (pad with 0s)
            let diff = renderList.count - gridSeenEpochs.count
            for _ in 0..<diff {
                gridSeenEpochs.append(0)
            }
        }

        var result: [Int] = []
        // Pre-allocate a reasonable capacity to avoid geometric resizing in the tight loop.
        // Estimate based on the area being queried vs total area.
        result.reserveCapacity(Swift.min(renderList.count, 4000))
        
        // Hoist the epoch variable for faster local register access
        let epoch = currentQueryEpoch
        
        // Unsafe pointers for absolute maximum speed in the innermost loop
        gridSeenEpochs.withUnsafeMutableBufferPointer { seenPtr in
            for cy in cy1...cy2 {
                let rowOffset = cy * gridCols
                for cx in cx1...cx2 {
                    let cellList = spatialGrid[rowOffset + cx]
                    cellList.withUnsafeBufferPointer { cellPtr in
                        for idx in cellPtr {
                            // If the primitive hasn't been seen in THIS query epoch...
                            if seenPtr[idx] != epoch {
                                seenPtr[idx] = epoch // Mark as seen
                                result.append(idx)
                            }
                        }
                    }
                }
            }
        }
        
        if result.count > 1 {
            result.sort()
        }

        // No cleanup loop needed! The epoch counter handles it.
        return result
    }

    public init() {}

    private func nextID() -> SpriteID {
        let id = SpriteID(id1: nextGeomID1, id2: 0)
        nextGeomID1 &+= 1
        return id
    }

    private func addPrimitive(_ primitive: RenderPrimitive) {
        primitive.computeWorldBounds()
        primitives[primitive.id] = primitive
        isSortNeeded = true
        mutationGeneration &+= 1
    }

    public func removePrimitive(id: SpriteID) {
        primitives.removeValue(forKey: id)
        isSortNeeded = true
        mutationGeneration &+= 1
    }

    /// Clear all primitives atomically. O(1). Use instead of individual removePrimitive calls.
    public func clearAll() {
        primitives.removeAll()
        renderList.removeAll()
        isSortNeeded = false
        gridBuilt = false
        gridSeen.removeAll()
        entityIndexToHandle.removeAll()
        handleToEntityIndex.removeAll()
        mutationGeneration &+= 1
    }

    public func setPrimitiveColor(id: SpriteID, color: (UInt8, UInt8, UInt8, UInt8)) {
        primitives[id]?.color = color
    }

    // --- Convenience methods for direct Swift API ---

    @discardableResult
    public func addPoint(
        x: Float, y: Float, z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .point, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.points = [SDL_FPoint(x: x, y: y)]
        addPrimitive(primitive)
        return id
    }

    @discardableResult
    public func addLine(
        x1: Float, y1: Float, x2: Float, y2: Float, z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .line, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.points = [
            SDL_FPoint(x: x1, y: y1),
            SDL_FPoint(x: x2, y: y2),
        ]
        addPrimitive(primitive)
        return id
    }

    @discardableResult
    public func addRect(
        x: Float, y: Float, w: Float, h: Float, z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .rect, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.rects = [SDL_FRect(x: x, y: y, w: w, h: h)]
        addPrimitive(primitive)
        return id
    }

    @discardableResult
    public func addFillRect(
        x: Float, y: Float, w: Float, h: Float, z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .fillRect, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.rects = [SDL_FRect(x: x, y: y, w: w, h: h)]
        addPrimitive(primitive)
        return id
    }

    /// Create a filled polygon from 4 world-space corners (for rotated rects).
    @discardableResult
    public func addFillCorners(
        _ corners: [SDL_FPoint], z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false,
        gradientData: RenderPrimitive.GradientData? = nil
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .fillRect, z: z, color: color, isScreenSpace: isScreenSpace, gradientData: gradientData)
        primitive.corners = corners
        // Also set points so the renderer can pick up the polygon
        addPrimitive(primitive)
        return id
    }

    @discardableResult
    public func addPoints(
        _ pts: [SDL_FPoint], z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .points, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.points = pts
        addPrimitive(primitive)
        return id
    }

    @discardableResult
    public func addLines(
        _ pts: [SDL_FPoint], z: Double = 0,
        color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255),
        isScreenSpace: Bool = false
    ) -> SpriteID {
        let id = nextID()
        let primitive = RenderPrimitive(
            id: id, type: .lines, z: z, color: color, isScreenSpace: isScreenSpace)
        primitive.points = pts
        addPrimitive(primitive)
        return id
    }

    public func getPrimitivesForRendering() -> [RenderPrimitive] {
        if isSortNeeded {
            renderList = Array(primitives.values)
            renderList.sort(by: { $0.z < $1.z })
            isSortNeeded = false
        }
        return renderList
    }

    /// Lookup a primitive by its renderList index (returned by visiblePrimitiveIndices).
    public func getPrimitive(at index: Int) -> RenderPrimitive? {
        guard index >= 0 && index < renderList.count else { return nil }
        return renderList[index]
    }

    /// Estimate the total vertex count across renderList for capacity pre-allocation.
    /// Rough heuristic: ~6 vertices per point for thick/AA lines, 2 for thin lines.
    public func estimatedVertexCount(usingAA antiAlias: Bool) -> Int {
        var count = 0
        for p in renderList {
            let ptCount = p.points.count
            switch p.type {
            case .point, .points:
                count += ptCount * 6
            case .line, .lines:
                if p.lineWeight > 0.25 || p.geomWidth > 0.0 || antiAlias {
                    count += max(0, ptCount - 1) * 6
                } else {
                    count += max(0, ptCount - 1) * 2
                }
            case .rect, .rects, .fillRect, .fillRects:
                count += max(p.corners.count, p.rects.count * 6)
            }
        }
        return count
    }

    /// Lookup a primitive by its ID (for direct manipulation during drag).
    public func getPrimitive(id: SpriteID) -> RenderPrimitive? {
        return primitives[id]
    }

    public var primitiveCount: Int { primitives.count }
}
