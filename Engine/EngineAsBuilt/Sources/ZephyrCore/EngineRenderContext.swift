import Foundation
import SwiftSDL
import ImGui

// =========================================================================
// MARK: - WindowRenderContext
// =========================================================================

/// Per-visible-tab render state: the document's tessellated geometry, GPU
/// buffers, background regen/vertex-build generations, and (for secondary
/// views) a scratch camera.
///
/// The primary context renders the active tab through the engine's shared
/// live stores (`geometryManager`, `spriteManager`, `cadBridge`), which the
/// editing code also uses. Each secondary context (a tab shown in an
/// unfocused window) owns private instances of all three, so background
/// rebuilds for one tab can never disturb another.
@MainActor
public final class WindowRenderContext {
    // MARK: Document stores

    /// Tessellated primitives. Primary: `engine.geometryManager`.
    public let geometry: GeometryManager
    /// Text/image sprites. Primary: `engine.spriteManager`.
    public let sprites: SpriteManager
    /// Regen bridge with its own pending slot. Primary: `engine.cadBridge`.
    public let bridge: CADRendererBridge

    // MARK: Regen generations (primary: migrated from `engine._regeneration*`)

    public var regenGeneration: Int = 0
    public var appliedGeneration: Int = -1
    public var regenInFlight: Int? = nil
    public var regenTask: Task<Void, Never>? = nil
    /// `editRevision` of the document built into `geometry` (nil = empty).
    public var builtRevision: UInt64? = nil
    /// `editRevision` the in-flight (or last launched) regen targets.
    /// Prevents relaunching every frame while a secondary build is pending.
    public var pendingRevision: UInt64? = nil
    /// The tab + drawing view this context's geometry was built for (split
    /// panes only). Revision numbers can coincide across view documents, so
    /// a view change must invalidate explicitly rather than rely on them.
    public var builtTabID: UUID? = nil
    public var builtViewIndex: Int = -1
    /// Identity of the document object built into this context. Tab/view
    /// identity is not enough: block editing swaps a temporary document in
    /// and the parent document back out under the same tab and view.
    public var builtDocumentID: ObjectIdentifier? = nil

    // MARK: CAD GPU buffer (primary: migrated from the renderer)

    public var vertexBuffer: OpaquePointer? = nil
    public var vertexCount: Int = 0
    public var batches: [CADDrawBatch] = []

    // MARK: Async vertex-build state (primary: migrated from the renderer)

    public let vbBuilder = CADVertexBufferBuilder()
    public var vbToken: Int = 0
    public var vbInFlightToken: Int? = nil
    public var vbTask: Task<Void, Never>? = nil
    public var vbInFlightRegion: (minX: Double, minY: Double, maxX: Double, maxY: Double)? = nil
    public var vbInFlightZoom: Double = -1.0
    public var vbInFlightMutationGen: Int = -1
    public var vbInFlightPaletteGen: Int = -1

    // MARK: Render-cache metadata (primary: migrated from renderer/engine)

    public var cachedViewportMinX: Double = 0
    public var cachedViewportMinY: Double = 0
    public var cachedViewportMaxX: Double = 0
    public var cachedViewportMaxY: Double = 0
    public var bufferedZoom: Double = -1.0
    public var cachedMutationGen: Int = -1
    public var cachedPaletteGen: Int = -1
    public var cachedUsingGrid: Bool = false
    public var lastCameraZoom: Double = -1.0

    // MARK: Secondary camera scratch

    /// Scratch camera synced from the tab's saved `CameraState` every
    /// secondary frame. Primary views use `engine.camera` instead.
    public let camera = EngineCameraManager()

    /// - Parameters:
    ///   - geometry/sprites/bridge: Live stores. Primary contexts pass the
    ///     engine's shared instances; secondary contexts pass fresh ones.
    public init(
        geometry: GeometryManager,
        sprites: SpriteManager,
        bridge: CADRendererBridge
    ) {
        self.geometry = geometry
        self.sprites = sprites
        self.bridge = bridge
    }

    /// Supersede built geometry when this context is retargeted to a
    /// different document object. Returns true when the caller should also
    /// invalidate GPU vertex state.
    @discardableResult
    public func supersedeIfDocumentChanged(to document: CADDocument) -> Bool {
        let documentID = ObjectIdentifier(document)
        guard builtDocumentID != documentID else { return false }
        builtDocumentID = documentID
        regenTask?.cancel()
        regenTask = nil
        regenInFlight = nil
        bridge.cancelPending()
        bridge.invalidateCurveLOD()
        // Do not let the outgoing document's primitives/sprites draw while
        // the incoming document regenerates.
        geometry.clearAll()
        for spriteIDs in bridge.entitySpriteMap.values {
            for id in spriteIDs {
                sprites.removeSprite(id: id)
            }
        }
        bridge.entityPrimitiveMap.removeAll()
        bridge.entitySpriteMap.removeAll()
        regenGeneration &+= 1
        appliedGeneration = -1
        builtRevision = nil
        pendingRevision = nil
        return true
    }

    /// Cancel all background work and release the GPU vertex buffer.
    /// Secondary contexts call this when dropped; the primary calls it
    /// from the renderer's teardown path.
    public func destroy(device: OpaquePointer) {
        regenTask?.cancel()
        regenTask = nil
        regenInFlight = nil
        bridge.cancelPending()
        bridge.invalidateCurveLOD()
        vbTask?.cancel()
        vbTask = nil
        vbInFlightToken = nil
        vbInFlightRegion = nil
        vbBuilder.cancelPending()
        if let buf = vertexBuffer {
            SDL_ReleaseGPUBuffer(device, buf)
            vertexBuffer = nil
        }
        vertexCount = 0
        batches.removeAll()
    }

    /// Drop built state so the next frame rebuilds from scratch.
    /// Used when display settings (e.g. anti-aliasing) invalidate every view.
    public func invalidateBuiltState(device: OpaquePointer) {
        vbTask?.cancel()
        vbTask = nil
        vbInFlightToken = nil
        vbInFlightRegion = nil
        vbBuilder.cancelPending()
        if let buf = vertexBuffer {
            SDL_ReleaseGPUBuffer(device, buf)
            vertexBuffer = nil
        }
        vertexCount = 0
        batches.removeAll()
        lastCameraZoom = -1.0
        cachedMutationGen = -1
        cachedPaletteGen = -1
    }
}
