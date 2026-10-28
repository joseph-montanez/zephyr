import Foundation
import SwiftSDL
import SwiftSDL_image
import SwiftSDL_ttf
import ImGui

// Large-file design note:
// This type remains the frame coordinator. New rendering responsibilities
// should be introduced as composed collaborators, not as additional
// `EngineRenderer` extensions. See Documentation/LargeFileRefactoring.md for
// the staged overlay and popup extraction plan.

struct CameraUniformData {
    var m00: Float = 0, m01: Float = 0, m02: Float = 0, m03: Float = 0
    var m10: Float = 0, m11: Float = 0, m12: Float = 0, m13: Float = 0
    var m20: Float = 0, m21: Float = 0, m22: Float = 0, m23: Float = 0
    var m30: Float = 0, m31: Float = 0, m32: Float = 0, m33: Float = 0
    
    var hiddenHandleCount: UInt32 = 0
    var hiddenPadding0: UInt32 = 0
    var hiddenPadding1: UInt32 = 0
    var hiddenPadding2: UInt32 = 0
    
    var h00: UInt32 = 0, h01: UInt32 = 0, h02: UInt32 = 0, h03: UInt32 = 0
    var h10: UInt32 = 0, h11: UInt32 = 0, h12: UInt32 = 0, h13: UInt32 = 0
    var h20: UInt32 = 0, h21: UInt32 = 0, h22: UInt32 = 0, h23: UInt32 = 0
    var h30: UInt32 = 0, h31: UInt32 = 0, h32: UInt32 = 0, h33: UInt32 = 0
}

@MainActor
public final class EngineRenderer {
    public unowned let engine: PhrostEngine

    /// The original render context, bound to the engine's initial stores.
    /// Adopted into `secondaryCtxs` by the first tab that renders through
    /// `tabCtx(for:)`; afterwards it is simply that tab's pooled context.
    public let primaryCtx: WindowRenderContext
    /// Tab that adopted `primaryCtx` into the per-tab pool, if any.
    internal var primaryCtxAdoptedTabID: UUID? = nil
    /// Per-tab render contexts, keyed by tab ID. Contexts are bound to
    /// TABS, never to activity: switching the active tab never wipes or
    /// rebuilds another tab's geometry — the incoming tab's warm context
    /// is simply the one that gets primary (overlay/pick) treatment.
    /// Entries exist only while their tab is shown in some window.
    public var secondaryCtxs: [UUID: WindowRenderContext] = [:]

    /// The pooled render context for a tab, creating it on first use.
    public func tabCtx(for tabID: UUID) -> WindowRenderContext {
        if let existing = secondaryCtxs[tabID] { return existing }
        if primaryCtxAdoptedTabID == nil {
            primaryCtxAdoptedTabID = tabID
            primaryCtx.builtTabID = tabID
            secondaryCtxs[tabID] = primaryCtx
            return primaryCtx
        }
        let ctx = WindowRenderContext(
            geometry: GeometryManager(),
            sprites: SpriteManager(),
            bridge: CADRendererBridge())
        ctx.builtTabID = tabID
        secondaryCtxs[tabID] = ctx
        return ctx
    }

    /// A drawing-view switch must supersede a tab context's built state
    /// explicitly (edit revisions can coincide across view documents).
    internal func supersedeCtxIfViewChanged(_ ctx: WindowRenderContext, tab: DocumentTab) {
        if ctx.builtTabID != tab.id || ctx.builtViewIndex != tab.activeViewIndex {
            ctx.builtTabID = tab.id
            ctx.builtViewIndex = tab.activeViewIndex
            ctx.regenTask?.cancel()
            ctx.regenTask = nil
            ctx.regenInFlight = nil
            ctx.bridge.cancelPending()
            ctx.regenGeneration &+= 1
            ctx.appliedGeneration = -1
            ctx.builtRevision = nil
            ctx.pendingRevision = nil
            ctx.invalidateBuiltState(device: engine.gpuDevice)
        }
    }

    /// Bump every pooled context's generation (global render-parameter
    /// changes such as tessellation/simplify toggles).
    public func bumpAllContextGenerations() {
        primaryCtx.regenGeneration &+= 1
        for ctx in secondaryCtxs.values where ctx !== primaryCtx {
            ctx.regenGeneration &+= 1
        }
        for ctx in paneCtxs.values {
            ctx.regenGeneration &+= 1
        }
    }
    /// Render state for non-focused split panes, keyed by leaf ID. Each
    /// pane keeps its own tab, drawing view, and camera, so sharing the
    /// primary context's view-culled buffers is impossible.
    /// Entries exist only while their leaf is a non-focused pane with a tab.
    public var paneCtxs: [UUID: WindowRenderContext] = [:]
    /// GPU vertex buffer holding one background quad per split pane (world
    /// space, drawn through the triangle pipeline). Recreated when the pane
    /// count changes; re-uploaded every split frame (camera-dependent).
    internal var paneBgVertexBuffer: OpaquePointer? = nil
    internal var paneBgVertexCapacity: Int = 0



    // MARK: GPU Shaders & Pipelines
    internal var cadVertShader: OpaquePointer?
    internal var cadFragShader: OpaquePointer?
    internal var cadAAFragShader: OpaquePointer?
    internal var imguiVertShader: OpaquePointer?
    internal var imguiFragShader: OpaquePointer?

    internal var cadLinePipeline: OpaquePointer?
    internal var cadPointPipeline: OpaquePointer?
    internal var cadTrianglePipeline: OpaquePointer?
    internal var cadLineAAPipeline: OpaquePointer?
    internal var cadTriangleAAPipeline: OpaquePointer?
    internal var imguiPipeline: OpaquePointer?

    internal var fontSampler: OpaquePointer?

    // MARK: ID-Buffer (GPU Entity Picking)
    internal var cadIDVertShader: OpaquePointer?
    internal var cadIDFragShader: OpaquePointer?
    internal var cadIDPipeline: OpaquePointer?
    internal var cadIDLinePipeline: OpaquePointer?
    internal var cadIDPointPipeline: OpaquePointer?
    /// 9×9 pick texture (R32_UINT format). Only the region around the cursor is rendered.
    internal var pickTexture: OpaquePointer?
    /// Ring buffer of 3 transfer buffers for async readback (avoids CPU stalls).
    internal var pickRingBuffers: [OpaquePointer?] = [nil, nil, nil]
    internal var pickRingIndex: Int = 0
    /// Pending pick request: screen-space cursor position for next ID pass.
    internal var _pendingPickScreenX: Float?
    internal var _pendingPickScreenY: Float?

    // MARK: ImGui GPU Buffers
    internal var imguiVertexBuffer: OpaquePointer?
    internal var imguiVertexCapacity: Int = 0
    internal var imguiIndexBuffer: OpaquePointer?
    internal var imguiIndexCapacity: Int = 0
    internal var imguiVtxTransferBuffer: OpaquePointer?
    internal var imguiVtxTransferCapacityBytes: Int = 0
    internal var imguiIdxTransferBuffer: OpaquePointer?
    internal var imguiIdxTransferCapacityBytes: Int = 0


    internal var usesTriangleHairlines: Bool { false }

    internal var lineWidthPixelScale: Float {
        max(1.0, max(engine.scaleX, engine.scaleY))
    }

    internal var currentLineWidthZoom: Double {
        engine.camera.zoom * Double(lineWidthPixelScale)
    }

    internal func isLineWidthZoomStable(_ zoom: Double, _ referenceZoom: Double) -> Bool {
        guard referenceZoom > 0 else { return false }
        let ratio = zoom / referenceZoom
        return ratio > 0.995 && ratio < 1.005
    }

    /// Anti-aliased line rendering toggle.
    public var antiAliasLines: Bool = false {
        didSet {
            primaryCtx.invalidateBuiltState(device: engine.gpuDevice)
            for ctx in secondaryCtxs.values {
                ctx.invalidateBuiltState(device: engine.gpuDevice)
            }
        }
    }

    /// Last color set via SDL_SetRenderDrawColor. Tracked to skip redundant calls.
    internal var _lastDrawColor: UInt32 = 0xFFFF_FFFF  // sentinel: never matches

    /// Overscan added on each side when building the CAD vertex buffer, as a fraction of the
    /// viewport. Pans that keep the viewport inside this margin reuse the buffer (no CPU
    /// re-tessellation). 0.5 ⇒ buffered region ≈ 2× the viewport per axis. Tune upward for
    /// fewer rebuilds at the cost of a larger buffer.
    internal var cadCullMargin: Double = 0.5

    /// Prefetch seam: fraction of the buffered half-extent at which a *proactive* rebuild
    /// fires. 1.0 = reactive (rebuild only when viewport actually exits the buffer) = today's
    /// behavior. Lower later (e.g. 0.7) to enable predictive prefetch with no structural change.
    internal var cadPrefetchThreshold: Double = 1.0

    /// Approximate vertex counter for foreground ImDrawList overflow guard.
    /// ImGui 16-bit index limit is 65535. We stop adding vertices at ~60000
    /// to leave room for essential overlays (crosshair, rect select, etc.).
    internal var _foregroundVertexEstimate: Int = 0
    internal let _foregroundVertexLimit: Int = 60000
    /// True when the camera center changed during the current rendered frame.
    /// This catches every pan source, including radial navigation callbacks.
    internal var _panProxyActiveThisFrame: Bool = false
    internal var _lastRenderedCameraOffset: (x: Double, y: Double)? = nil
    /// Divider currently being dragged: its split ID, the grab offset from
    /// the cut along the drag axis (so the cut doesn't jump to the cursor),
    /// and whether a double-click reset suppressed the drag until release.
    private var _paneDividerGrab: (id: UUID, offset: Float, suppressed: Bool)? = nil

    public init(engine: PhrostEngine) {
        self.engine = engine
        self.primaryCtx = WindowRenderContext(
            geometry: engine.geometryManager,
            sprites: engine.spriteManager,
            bridge: engine.cadBridge)
    }



    // MARK: - Rendering

    internal func rebuildCadVertexBuffer(
        ctx: WindowRenderContext,
        camera: EngineCameraManager,
        viewportWidth: Int32,
        viewportHeight: Int32,
        pixelScale: Float,
        geometry: GeometryManager,
        paletteGen: Int,
        useLightDisplayPalette: Bool,
        viewportBackground: (UInt8, UInt8, UInt8, UInt8)
    ) {
        // Cancel any in-flight async build — this sync rebuild supersedes it.
        ctx.vbTask?.cancel()
        ctx.vbTask = nil
        ctx.vbInFlightToken = nil
        ctx.vbInFlightRegion = nil
        ctx.vbBuilder.cancelPending()

        let vp = camera.worldViewportRect(windowWidth: viewportWidth, windowHeight: viewportHeight)
        let marginX = (vp.maxX - vp.minX) * cadCullMargin
        let marginY = (vp.maxY - vp.minY) * cadCullMargin
        let cullMinX = vp.minX - marginX, cullMaxX = vp.maxX + marginX
        let cullMinY = vp.minY - marginY, cullMaxY = vp.maxY + marginY

        let region = (minX: cullMinX, minY: cullMinY, maxX: cullMaxX, maxY: cullMaxY)
        let inputs = gatherTessInputs(
            region: region, from: geometry, into: ctx,
            useLightDisplayPalette: useLightDisplayPalette,
            viewportBackground: viewportBackground)

        // Let tessellate handle empty inputs cleanly — returns empty VertexBuildResult
        // so applyVertexBuild writes metadata atomically and cache hits next frame.
        guard let result = CADVertexBufferBuilder.tessellate(
            inputs,
            cameraZoom: camera.zoom,
            pixelScale: pixelScale,
            antiAliasLines: antiAliasLines,
            hairlineQuads: usesTriangleHairlines,
            region: region,
            mutationGen: geometry.mutationGeneration
        ) else {
            return  // cancelled
        }

        applyVertexBuild(result, paletteGen: paletteGen, ctx: ctx)
    }

    private func makeImCol32(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt32 {
        return (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r)
    }

    // MARK: - Context Regen + Vertex Prep (shared primary/secondary)

    /// World-origin quantum for a document's render space.
    internal func renderOrigin(for doc: CADDocument) -> CADRenderOrigin {
        guard let bounds = doc.renderableWorldBoundingBox(visibleLayersOnly: false) else {
            return .zero
        }
        let centerX = (bounds.min.x + bounds.max.x) * 0.5
        let centerY = (bounds.min.y + bounds.max.y) * 0.5
        guard centerX.isFinite, centerY.isFinite else { return .zero }
        let quantum = 1024.0
        return CADRenderOrigin(
            x: (centerX / quantum).rounded() * quantum,
            y: (centerY / quantum).rounded() * quantum)
    }

    /// 8-bit viewport-background tuple for "background-colored" primitives.
    internal func bgTuple(_ color: SDL_FColor) -> (UInt8, UInt8, UInt8, UInt8) {
        func channel(_ value: Float) -> UInt8 {
            UInt8(max(0.0, min(255.0, value * 255.0)).rounded())
        }
        return (channel(color.r), channel(color.g), channel(color.b), channel(color.a))
    }

    /// Run one context's background regen. The context is re-resolved by ID at
    /// task start so a tab closed mid-flight safely no-ops instead of writing
    /// into a destroyed context. `ctxID` nil addresses the primary context;
    /// non-nil IDs resolve through the tab-keyed secondary contexts first,
    /// then the leaf-keyed dual-view pane contexts.
    private func runContextRegen(
        ctxID: UUID?,
        snapshot: CADDocumentSnapshot,
        generation: Int,
        simplify: Bool,
        renderOrigin: CADRenderOrigin,
        tessDiv: Double
    ) async {
        let ctx: WindowRenderContext
        if let ctxID {
            guard let secondary = secondaryCtxs[ctxID] ?? paneCtxs[ctxID] else { return }
            ctx = secondary
        } else {
            ctx = primaryCtx
        }
        await ctx.bridge.regenerate(
            fromSnapshot: snapshot,
            generation: generation,
            simplifyComplexBlocks: simplify,
            into: ctx.geometry,
            renderOrigin: renderOrigin,
            splineTessellationDivisor: tessDiv
        )
    }

    /// Ensure a context's geometry reflects `doc`: fold edits, launch a
    /// background regen when stale, and apply ready results.
    /// - Returns: Whether fresh specs were applied this frame.
    @discardableResult
    internal func ensureContextRegenerated(
        ctxID: UUID?,
        ctx: WindowRenderContext,
        doc: CADDocument,
        simplifyComplexBlocks: Bool,
        splineTessellationDivisor: Double,
        background: SDL_FColor,
        isPrimary: Bool
    ) -> Bool {
        // A document-object swap under the same tab/view (entering or
        // exiting the block editor) must supersede this context even when
        // the incoming document's revision coincides with the outgoing one
        // or another context already consumed its regeneration flag.
        if ctx.supersedeIfDocumentChanged(to: doc) {
            ctx.invalidateBuiltState(device: engine.gpuDevice)
        }
        // Fold in-tab edits into the generation so they supersede any in-flight
        // task exactly the way a tab switch does.
        if doc.needsRegeneration {
            doc.needsRegeneration = false
            ctx.regenGeneration &+= 1
        }
        // A secondary context goes stale when its tab was edited while active
        // (activation always re-arms the primary path, so clearing the flag
        // above is safe). The pending guard makes this bump-once per revision
        // instead of once per frame while the build is in flight.
        if !isPrimary, ctx.builtRevision != doc.renderRevision,
           ctx.pendingRevision != doc.renderRevision {
            ctx.regenGeneration &+= 1
        }
        let wantGen = ctx.regenGeneration

        // Launch (or relaunch) a background regeneration for the current generation
        // when the displayed geometry is stale and no task is already computing it.
        // The snapshot is a value-typed copy, so the task never touches the live doc.
        if wantGen != ctx.appliedGeneration && ctx.regenInFlight != wantGen {
            if engine.commandProcessor.isLispActivelyEvaluating {
                return false
            }
            print("[Loop] regen needed for generation \(wantGen), launching task")
            ctx.regenTask?.cancel()
            let (docSnapshot, origin) = doc.documentLock.withLock {
                (doc.renderSnapshot(), renderOrigin(for: doc))
            }
            ctx.regenInFlight = wantGen
            ctx.pendingRevision = doc.renderRevision
            let simplify = simplifyComplexBlocks
            let tessDiv = splineTessellationDivisor
            ctx.regenTask = Task.detached { [weak self] in
                guard let self else { return }
                await self.runContextRegen(
                    ctxID: ctxID, snapshot: docSnapshot, generation: wantGen,
                    simplify: simplify, renderOrigin: origin, tessDiv: tessDiv)
            }
        }

        // Apply results only if they match the generation we currently want to
        // show. Results from a superseded tab/edit are dropped, never displayed.
        let pendingApplied = ctx.bridge.applyPendingIfNeeded(
            forGeneration: wantGen, into: ctx.geometry,
            spriteManager: ctx.sprites, imageStore: doc.effectiveImageStore,
            viewportBackground: bgTuple(background), engine: engine)

        if pendingApplied {
            ctx.appliedGeneration = wantGen
            ctx.regenInFlight = nil
            ctx.regenTask = nil
            ctx.pendingRevision = nil
            ctx.builtRevision = doc.renderRevision
            if isPrimary {
                engine.interaction.pendingPreviewHandles.removeAll()
                // Rebuild entity spatial grid after geometry has been regenerated.
                doc.documentLock.withLock {
                    if !doc.entityGridBuilt {
                        doc.rebuildEntityGrid()
                    }
                }
            }
        }
        return pendingApplied
    }

    /// Route one context's vertex-buffer work for this frame: sync rebuild on
    /// cold start, async launch when the cache misses, always apply if ready.
    internal func routeContextVertexBuild(
        ctx: WindowRenderContext,
        camera: EngineCameraManager,
        viewportWidth: Int32,
        viewportHeight: Int32,
        pixelScale: Float,
        background: SDL_FColor,
        useLightDisplayPalette: Bool,
        pendingApplied: Bool,
        interactive: Bool
    ) {
        let mutationGen = ctx.geometry.mutationGeneration
        let vp = camera.worldViewportRect(windowWidth: viewportWidth, windowHeight: viewportHeight)

        let insideBuffer =
            vp.minX >= ctx.cachedViewportMinX && vp.maxX <= ctx.cachedViewportMaxX &&
            vp.minY >= ctx.cachedViewportMinY && vp.maxY <= ctx.cachedViewportMaxY
        let lineZoom = camera.zoom * Double(pixelScale)
        let zoomStable = isLineWidthZoomStable(lineZoom, ctx.bufferedZoom)

        let renderCacheHit = !pendingApplied && interactive && insideBuffer
            && zoomStable
            && ctx.cachedMutationGen == mutationGen
            && ctx.cachedPaletteGen == engine.ui.displayPaletteGeneration

        // Sync for cold-start, async for pan/zoom. applyPendingVertexBuildIfReady
        // acquires+submits its own command buffer, so it MUST run before the
        // render pass acquires its command buffer below.
        if ctx.cachedMutationGen == -1 {
            rebuildCadVertexBuffer(
                ctx: ctx, camera: camera,
                viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                pixelScale: pixelScale, geometry: ctx.geometry,
                paletteGen: engine.ui.displayPaletteGeneration,
                useLightDisplayPalette: useLightDisplayPalette,
                viewportBackground: bgTuple(background))
        } else if !renderCacheHit && interactive {
            launchAsyncVertexBuildIfNeeded(
                ctx: ctx, camera: camera,
                viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                pixelScale: pixelScale, geometry: ctx.geometry,
                paletteGen: engine.ui.displayPaletteGeneration,
                useLightDisplayPalette: useLightDisplayPalette,
                viewportBackground: bgTuple(background))
        }
        applyPendingVertexBuildIfReady(ctx: ctx, currentLineZoom: lineZoom)
    }

    internal func render(deltaSec: Double) {
        // Each OS window frames on its own ImGui context; start from main's
        // so prologue io reads are deterministic. (The minimized early-out
        // below skips aux frames too — pre-existing behavior, unchanged.)
        if let main = engine.windowManager.mainWindow {
            engine.activateImGuiContext(for: main)
        }
        let windowFlags = SDL_GetWindowFlags(engine.window)
        let isMinimized = (windowFlags & 0x0000_0000_0000_0040) != 0
        if isMinimized {
            // A minimized window receives no meaningful input; drop anything
            // queued so it can't replay stale after restore.
            engine.windowManager.mainWindow?.inputQueue.removeAll()
            return
        }

        var windowWidth: Int32 = 0
        var windowHeight: Int32 = 0
        var pixelWidth: Int32 = 0
        var pixelHeight: Int32 = 0
        guard SDL_GetWindowSize(engine.window, &windowWidth, &windowHeight),
              SDL_GetWindowSizeInPixels(engine.window, &pixelWidth, &pixelHeight),
              windowWidth > 0,
              windowHeight > 0,
              pixelWidth > 0,
              pixelHeight > 0
        else {
            return
        }

        engine.windowWidth = windowWidth
        engine.windowHeight = windowHeight
        engine.pixelWidth = pixelWidth
        engine.pixelHeight = pixelHeight

        let newScaleX = Float(pixelWidth) / Float(windowWidth)
        let newScaleY = Float(pixelHeight) / Float(windowHeight)

        // print("newScaleX: \(newScaleX), newScaleY: \(newScaleY), engine.scaleX: \(engine.scaleX), engine.scaleY: \(engine.scaleY) engine.windowWidth: \(engine.windowWidth), engine.windowHeight: \(engine.windowHeight), engine.pixelWidth: \(engine.pixelWidth), engine.pixelHeight: \(engine.pixelHeight)")

        if newScaleX != engine.scaleX || newScaleY != engine.scaleY {
            engine.camera.renderGeneration &+= 1
        }
        engine.scaleX = newScaleX
        engine.scaleY = newScaleY

        let newDpiScale = SDL_GetWindowDisplayScale(engine.window)
        engine.updateScale(dpiScale: newDpiScale, fbScale: newScaleX)
        refreshMainWindowTitle()

        // Phase 2: Ring-buffer readback from a previous frame's pick pass.
        // Read from pickRingBuffer[(pickRingIndex - 2) % 3] — 2 frames old.
        // If mapping succeeds, scan the 81 uint values for the closest valid
        // entity index to the center pixel, and resolve it to a handle.
        if pickRingIndex >= 2 {
            let readIdx = (pickRingIndex - 2) % 3
            if let ringBuf = pickRingBuffers[readIdx] {
                if let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, ringBuf, false) {
                    let uints = mapped.bindMemory(to: UInt32.self, capacity: 81)
                    // Scan 9×9 block: find closest valid entity index to center (4,4)
                    var bestDist = Int.max
                    var bestIdx: UInt32 = 0
                    for dy in 0..<9 {
                        for dx in 0..<9 {
                            let pixelIdx = dy * 9 + dx
                            let eIdx = uints[pixelIdx]
                            if eIdx != 0 {
                                let dist = (dx - 4) * (dx - 4) + (dy - 4) * (dy - 4)
                                if dist < bestDist {
                                    bestDist = dist
                                    bestIdx = eIdx
                                }
                            }
                        }
                    }
                    // Only apply GPU hover result when not hovering a grip
                    if bestIdx != 0, let handle = engine.geometryManager.entityIndexToHandle[bestIdx],
                       engine.interaction.hoveredGrip == nil
                    {
                        engine.interaction.hoveredEntityHandle = handle
                    }
                    SDL_UnmapGPUTransferBuffer(engine.gpuDevice, ringBuf)
                }
            }
        }

        guard let mainWindow = engine.windowManager.mainWindow else { return }
        let mainUI = { [self] in
            if let callback = self.engine.imguiFrameCallback { callback() } else { ImGuiShowDemoWindow(nil) }
        }
        if engine.mainPanes.isSplit {
            renderSplitMainWindow(target: mainWindow, deltaSec: deltaSec, uiBuilder: mainUI)
        } else {
            let t0 = SDL_GetTicks()
            let activeDoc = engine.tabManager.activeDocument
            let inBlockEditor = engine.tabManager.activeTab?.editingBlockID != nil

            let activeTab = engine.tabManager.activeTab
            let actx = activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx
            if let activeTab { supersedeCtxIfViewChanged(actx, tab: activeTab) }
            let pendingApplied = ensureContextRegenerated(
                ctxID: activeTab?.id, ctx: actx, doc: activeDoc,
                simplifyComplexBlocks: inBlockEditor ? false : engine.simplifyComplexBlocks,
                splineTessellationDivisor: engine.splineTessellationDivisor,
                background: engine.ui.backgroundColor,
                isPrimary: true)

            // Render cache: vertices are world-space and the camera matrix is re-uploaded every
            // frame (see PushGPUVertexUniformData in the draw pass below), so PAN/ROTATE never
            // require a rebuild. Rebuild only when the viewport leaves the over-scanned buffered
            // region, when zoom changes enough to break screen-constant primitive sizing, or when
            // geometry actually mutates.
            routeContextVertexBuild(
                ctx: actx, camera: engine.camera,
                viewportWidth: engine.windowWidth, viewportHeight: engine.windowHeight,
                pixelScale: lineWidthPixelScale,
                background: engine.ui.backgroundColor,
                useLightDisplayPalette: engine.ui.isViewportBackgroundLight,
                pendingApplied: pendingApplied,
                interactive: !(engine.interaction.dragActive || engine.interaction.gripActive
                    || engine.interaction.rectSelectActive))
            // NOTE: ctx.cachedMutationGen is written at swap time inside applyVertexBuild.
            if engine.mainWindowShowsActiveTab() {
                renderPrimaryWindow(
                    target: mainWindow,
                    deltaSec: deltaSec,
                    t0: t0,
                    uiBuilder: mainUI)
            } else {
                renderSecondaryWindow(
                    target: mainWindow,
                    tab: engine.mainShownTab(),
                    deltaSec: deltaSec,
                    uiBuilder: mainUI)
            }
        }


        // Sequential frames for auxiliary OS windows on the shared context.
        // NOTE: this array is a snapshot — commands during the main frame may
        // have docked/closed windows, so every entry is revalidated.
        for aux in engine.windowManager.auxWindows {
            guard engine.windowManager.window(for: aux.id) === aux else { continue }
            if aux.closeRequestedByUI {
                if let tabID = aux.hostedTabID {
                    engine.dockTab(id: tabID)
                } else {
                    engine.closeAuxWindow(id: aux.id)
                }
                continue
            }
            guard let hostedID = aux.hostedTabID else {
                renderAuxWindow(aux, deltaSec: deltaSec)
                continue
            }
            guard let tab = engine.tabManager.tab(for: hostedID) else {
                engine.closeAuxWindow(id: aux.id)
                continue
            }
            guard refreshAuxMetrics(aux) else { continue }
            syncAuxWindowTitle(aux)
            // Float windows render the FULL AppUI (role-gated: no file tab
            // bar / top chrome / app-global dialogs), same as main.
            if hostedID == engine.tabManager.activeTab?.id {
                renderPrimaryWindow(
                    target: aux, deltaSec: deltaSec, t0: SDL_GetTicks(),
                    uiBuilder: mainUI)
            } else {
                renderSecondaryWindow(
                    target: aux, tab: tab, deltaSec: deltaSec,
                    uiBuilder: mainUI)
            }
        }

        // Prune secondary contexts for tabs no window shows anymore, releasing
        // their GPU buffers. Contexts of visible tabs are kept even while
        // active so focus toggles rebind instantly (staleness is caught by
        // the built-revision check instead of rebuilding blindly).
        var visibleTabs = Set<UUID>()
        if let active = engine.tabManager.activeTab {
            visibleTabs.insert(active.id)
        }
        if let shown = engine.mainShownTab() {
            visibleTabs.insert(shown.id)
        }
        // Every split leaf is visible, including inactive tabs in
        // non-focused panes; otherwise their contexts are destroyed and
        // recreated on every frame and can never finish rebuilding.
        for node in engine.mainPanes.leaves() {
            if case .leaf(_, let tabID) = node, let tabID {
                visibleTabs.insert(tabID)
            }
        }
        for aux in engine.windowManager.auxWindows {
            if let hosted = aux.hostedTabID {
                visibleTabs.insert(hosted)
            }
        }
        for id in secondaryCtxs.keys where !visibleTabs.contains(id) {
            engine.dropSecondaryCtx(for: id)
        }

        // Split-pane contexts stay warm for every leaf showing a tab —
        // including the focused one. Pruning the focused leaf's context
        // forced a cold rebuild (blank, then pop-in) on every focus change,
        // which read as the panes "swapping" with a blink. A warm context
        // costs one buffer set per pane and catches up on defocus via the
        // usual revision checks. Contexts are pruned only when their leaf
        // disappears or the view unsplits.
        var livePaneLeaves = Set<UUID>()
        if engine.mainPanes.isSplit {
            for node in engine.mainPanes.leaves() {
                if case .leaf(let id, let shown) = node, shown != nil {
                    livePaneLeaves.insert(id)
                }
            }
        }
        for id in paneCtxs.keys where !livePaneLeaves.contains(id) {
            if let ctx = paneCtxs.removeValue(forKey: id) {
                ctx.destroy(device: engine.gpuDevice)
            }
        }
    }
    /// Recompute cached grips when camera/selection/regeneration changed.
    private func refreshGripCache(transform: CameraTransform) {
        // Only recompute grips when camera, selection, grip drag, or document
        // regeneration (e.g. layer visibility) changes.
        if engine.interaction.cachedGripGeneration != engine.camera.renderGeneration
            || engine._cachedSelectionGen != engine.cadSelection._selectionGeneration
            || engine._cachedApplyGen != (engine.tabManager.activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx).appliedGeneration
            || engine.interaction.gripActive
            || engine.interaction.dragActive
        {
            // GRIPOBJLIMIT: when too many entities are selected, suppress grips.
            // Entities retain their geometry highlight; no per-entity boxes.
            var gripHandles = engine.cadSelection.selectedHandles
            if CADSelectionDisplayPolicy.gripsSuppressed(selectedCount: gripHandles.count, gripObjectLimit: engine.gripObjectMax) {
                gripHandles = []
                
            } else {
                gripHandles = engine.cadSelection.selectedHandles
            }
            engine._cachedCadGrips = CADGripSystem.getAllGrips(
                document: engine.document, cam: transform,
                simplifyComplexBlocks: true,
                selectedHandles: gripHandles,
                selectedLeaderContentHandle: engine.cadSelection.selectedLeaderContentHandle,
                gripObjectLimit: engine.gripObjectMax)
            engine.interaction.cachedGripGeneration = engine.camera.renderGeneration
            engine._cachedSelectionGen = engine.cadSelection._selectionGeneration
            engine._cachedApplyGen = (engine.tabManager.activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx).appliedGeneration
        }
    }

    /// Vector overlays for the primary (active-tab) view. Split panes call
    /// this for the focused leaf with a leaf-adjusted transform and clip rect.
    private func renderPrimaryVectorOverlays(
        transform: CameraTransform,
        origin: (x: Float, y: Float) = (0, 0),
        includeCrosshair: Bool = true
    ) {
        if includeCrosshair {
            renderCrosshairCursor(cam: transform, origin: origin)
        }
        renderGrid(cam: transform)
        renderSnapIndicator(cam: transform)

        // --> Call the new subtle, background-adaptive tracking lines <--
        let drawList = igGetBackgroundDrawList(nil)
        renderTrackingOverlays(drawList: drawList, cam: transform)

        renderCadSelectionHighlight(cam: transform)
        renderCadHoverHighlight(cam: transform)
        renderRectSelectPreview(cam: transform)
        renderCadGrips(cam: transform)
        renderRectSelectBox(origin: origin)
        renderMoveGhostPreview(cam: transform)
        renderInteractivePreview(cam: transform)
    }

    /// Feature-command overlay plus text-editor dismissal checks (once per frame).
    private func renderFeatureOverlay(transform: CameraTransform) {
        // Feature command overlay (e.g. selection rectangle preview)
        if let featureCmd = engine.commandProcessor.activeFeatureCommand {
            featureCmd.renderOverlay(cam: transform, engine: engine)

            // TextCommand / DDEditCommand: check if the editor modal was dismissed.
            if let textCmd = featureCmd as? TextCommand {
                if textCmd.checkEditorResult(engine: engine, processor: engine.commandProcessor) {
                    engine.commandProcessor.finishFeatureCommand(engine: engine)
                }
            } else if let ddEditCmd = featureCmd as? DDEditCommand {
                if ddEditCmd.checkEditorResult(engine: engine, processor: engine.commandProcessor) {
                    engine.commandProcessor.finishFeatureCommand(engine: engine)
                }
            }
        }
    }

    /// Sprites for the primary view, drawn late so TTF quads never use a
    /// pre-pan camera.
    private func renderPrimarySprites(
        transform: CameraTransform, deltaSec: Double,
        viewportWidth: Float? = nil, viewportHeight: Float? = nil,
        cullOrigin: (x: Float, y: Float) = (0, 0)
    ) {
        var backgroundVertexEstimate = 0
        let backgroundVertexLimit = 60000

        // Suppress image sprites during active manipulation (drag/grip) —
        // the selection highlight bounding box is shown instead.
        // On plain selection, the sprite stays visible with grips on top.
        let isAdjusting = engine.interaction.dragActive || engine.interaction.gripActive
        let hiddenImageSpriteIDs: Set<SpriteID> = {
            guard isAdjusting else { return [] }
            var ids = Set<SpriteID>()
            for handle in engine.cadSelection.selectedHandles {
                guard let entity = engine.document.entity(for: handle),
                      let geometry = entity.localGeometry ?? engine.document.resolvedGeometry(for: entity),
                      geometry.contains(where: { if case .image = $0 { return true }; return false })
                else { continue }
                for sid in engine.cadBridge.entitySpriteMap[handle] ?? [] {
                    ids.insert(sid)
                }
            }
            return ids
        }()

        for sprite in engine.spriteManager.getSpritesForRendering() {
            guard backgroundVertexEstimate < backgroundVertexLimit else { break }
            if hiddenImageSpriteIDs.contains(sprite.id) { continue }
            renderSprite(
                sprite, deltaSec: deltaSec, cam: transform,
                viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                cullOrigin: cullOrigin)
            backgroundVertexEstimate += 4
        }
    }

    /// Render the main window with split panes: per-leaf CAD passes through
    /// leaf viewports, primary overlays clipped to the focused pane,
    /// secondary grid+sprites in the others, plus divider widgets.
    private func renderSplitMainWindow(
        target: EngineManagedWindow,
        deltaSec: Double,
        uiBuilder: () -> Void
    ) {
        engine.activateImGuiContext(for: target)
        engine.ui.frameRole = .mainWindow
        // Layout from last frame's canvas (1-frame lag on resize — invisible).
        let canvasF = engine.ui.drawingViewportRect
            ?? SDL_FRect(x: 0, y: 0, w: Float(engine.windowWidth), h: Float(engine.windowHeight))
        let canvas = PaneRect(
            x: canvasF.x, y: canvasF.y,
            w: max(1, canvasF.w), h: max(1, canvasF.h))
        let leaves = engine.mainPanes.leafRects(canvas: canvas)
        guard !leaves.isEmpty else { return }
        let focusedID = engine.mainPanes.focusedLeafID
        let focusedLeaf = leaves.first(where: { $0.id == focusedID }) ?? leaves[0]
        let activeID = engine.tabManager.activeTab?.id
        let focusedShowsActive = focusedLeaf.tabID != nil && focusedLeaf.tabID == activeID

        // --- Prep: primary for the active tab (focused-leaf dims when the
        // focused pane shows it, else full-window dims for its float window).
        let t0 = SDL_GetTicks()
        let activeDoc = engine.tabManager.activeDocument
        let inBlockEditor = engine.tabManager.activeTab?.editingBlockID != nil
        let primaryW: Int32 = focusedShowsActive ? Int32(focusedLeaf.rect.w) : engine.windowWidth
        let primaryH: Int32 = focusedShowsActive ? Int32(focusedLeaf.rect.h) : engine.windowHeight
        let activeTab = engine.tabManager.activeTab
        let actx = activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx
        if let activeTab { supersedeCtxIfViewChanged(actx, tab: activeTab) }
        let pendingApplied = ensureContextRegenerated(
            ctxID: activeTab?.id, ctx: actx, doc: activeDoc,
            simplifyComplexBlocks: inBlockEditor ? false : engine.simplifyComplexBlocks,
            splineTessellationDivisor: engine.splineTessellationDivisor,
            background: engine.ui.backgroundColor,
            isPrimary: true)
        routeContextVertexBuild(
            ctx: actx, camera: engine.camera,
            viewportWidth: primaryW, viewportHeight: primaryH,
            pixelScale: lineWidthPixelScale,
            background: engine.ui.backgroundColor,
            useLightDisplayPalette: engine.ui.isViewportBackgroundLight,
            pendingApplied: pendingApplied,
            interactive: !(engine.interaction.dragActive || engine.interaction.gripActive
                    || engine.interaction.rectSelectActive))

        // Non-focused pane prep: every such pane gets its own leaf-keyed
        // context driven by its remembered entry — which tab, which of the
        // tab's drawing views (Model, paper layouts, ...), and which camera
        // (AutoCAD-style independent viewports). A pane without an entry
        // (never focused since assignment) follows its tab's active drawing
        // view and camera until it earns an entry of its own.
        var leafBgs: [UUID: SDL_FColor] = [:]
        let nonFocusedLeaves = leaves.filter { $0.id != focusedID && $0.tabID != nil }
        for leaf in nonFocusedLeaves {
            guard let tabID = leaf.tabID,
                  let tab = engine.tabManager.tab(for: tabID),
                  !tab.drawingViews.isEmpty else { continue }
            let entry = engine.paneViews.entry(leafID: leaf.id, tabID: tabID)
            let viewIndex = min(
                max(entry?.viewIndex ?? tab.activeViewIndex, 0),
                tab.drawingViews.count - 1)
            let view = tab.drawingViews[viewIndex]
            let bg = engine.ui.backgroundColor(forViewBackground: view.backgroundColor)
            leafBgs[leaf.id] = bg
            let ctx: WindowRenderContext
            if let existing = paneCtxs[leaf.id] {
                ctx = existing
            } else {
                ctx = WindowRenderContext(
                    geometry: GeometryManager(),
                    sprites: SpriteManager(),
                    bridge: CADRendererBridge())
                paneCtxs[leaf.id] = ctx
            }
            ctx.camera.applyState(entry?.state ?? view.cameraState)
            // A context retargeted to another tab or drawing view must not
            // keep the previous document's geometry: edit revisions can
            // coincide across view documents, so supersede explicitly
            // (mirrors the primary path's tab-switch handling).
            if ctx.builtTabID != tabID || ctx.builtViewIndex != viewIndex {
                ctx.builtTabID = tabID
                ctx.builtViewIndex = viewIndex
                ctx.regenTask?.cancel()
                ctx.regenTask = nil
                ctx.regenInFlight = nil
                ctx.bridge.cancelPending()
                ctx.regenGeneration &+= 1
                ctx.appliedGeneration = -1
                ctx.builtRevision = nil
                ctx.pendingRevision = nil
                ctx.invalidateBuiltState(device: engine.gpuDevice)
            }
            let applied = ensureContextRegenerated(
                ctxID: leaf.id, ctx: ctx, doc: view.document,
                simplifyComplexBlocks: tab.editingBlockID != nil ? false : engine.simplifyComplexBlocks,
                splineTessellationDivisor: engine.splineTessellationDivisor,
                background: bg, isPrimary: false)
            routeContextVertexBuild(
                ctx: ctx, camera: ctx.camera,
                viewportWidth: Int32(leaf.rect.w), viewportHeight: Int32(leaf.rect.h),
                pixelScale: lineWidthPixelScale,
                background: bg, useLightDisplayPalette: EngineUIManager.isLightBackground(bg),
                pendingApplied: applied, interactive: true)
        }

        // --- Frame.
        let t1 = SDL_GetTicks()
        engine.io.pointee.DisplaySize = ImVec2(x: Float(engine.windowWidth), y: Float(engine.windowHeight))
        engine.io.pointee.DisplayFramebufferScale = ImVec2(x: engine.scaleX, y: engine.scaleY)
        engine.io.pointee.DeltaTime = Float(deltaSec)
        engine.applyPendingUiScaleRebuild()
        engine.ui.replayQueuedInput(for: target, appFocused: engine.windowManager.focusedWindow != nil)
        ImGuiNewFrame()
        updateOSCursorVisibility()

        // Pre-UI: focused-leaf vector overlays (mirrors the primary order).
        _foregroundVertexEstimate = 0
        if focusedShowsActive {
            let saved = engine.snapshotMetrics()
            engine.borrowPaneDims(width: Int32(focusedLeaf.rect.w), height: Int32(focusedLeaf.rect.h))
            let ft = engine.camera.transformForSubRect(
                originX: Double(focusedLeaf.rect.x), originY: Double(focusedLeaf.rect.y),
                width: Int32(focusedLeaf.rect.w), height: Int32(focusedLeaf.rect.h))
            pushLeafClip(focusedLeaf.rect)
            // Overlays (selection/hover highlight, grips, ghosts, crosshair)
            // draw into the background/foreground lists, whose clip stacks
            // are independent of the window list clipped above — without
            // these, highlight geometry spills across the divider.
            pushBackgroundClip(focusedLeaf.rect)
            pushForegroundClip(focusedLeaf.rect)
            refreshGripCache(transform: ft)
            renderPrimaryVectorOverlays(
                transform: ft, origin: (focusedLeaf.rect.x, focusedLeaf.rect.y),
                includeCrosshair: false)
            renderFeatureOverlay(transform: ft)
            popForegroundClip()
            popBackgroundClip()
            ImGuiPopClipRect()
            engine.restoreMetrics(saved)
        }
        // The cursor is global: it follows the mouse in whichever pane is
        // hovered (the OS cursor is hidden over the whole canvas) and
        // mirrors into other panes sharing the same tab + drawing view.
        renderSplitCrosshairs(leaves: leaves, focusedID: focusedID, activeID: activeID)

        // 2. ImGui user panels/callbacks + divider widgets.
        uiBuilder()
        renderPaneDividers(canvas: canvas, focusedID: focusedLeaf.id)

        let currentOffset = engine.camera.offset
        let cameraMoved: Bool
        if let previousOffset = _lastRenderedCameraOffset {
            cameraMoved =
                abs(currentOffset.x - previousOffset.x) > 1e-12
                || abs(currentOffset.y - previousOffset.y) > 1e-12
        } else {
            cameraMoved = false
        }
        _panProxyActiveThisFrame =
            cameraMoved
            || engine.interaction.panActive
            || engine.interaction.touchPanActive
            || engine.interaction.radialPanActive
        _lastRenderedCameraOffset = currentOffset

        // Post-UI sprites: focused leaf first, then secondary leaves.
        if focusedShowsActive {
            if let interim = interimPaneCtx(
                leaf: focusedLeaf, focusedID: focusedID, activeID: activeID) {
                // Primary stores were just cleared by the switch; the
                // pane's own sprites are the current ones.
                renderLeafGridAndSprites(
                    leaf: focusedLeaf, ctx: interim,
                    bg: engine.ui.backgroundColor, deltaSec: deltaSec,
                    includeGrid: false, cameraOverride: engine.camera)
            } else {
                let saved = engine.snapshotMetrics()
                engine.borrowPaneDims(width: Int32(focusedLeaf.rect.w), height: Int32(focusedLeaf.rect.h))
                let ft = engine.camera.transformForSubRect(
                    originX: Double(focusedLeaf.rect.x), originY: Double(focusedLeaf.rect.y),
                    width: Int32(focusedLeaf.rect.w), height: Int32(focusedLeaf.rect.h))
                pushLeafClip(focusedLeaf.rect)
                pushBackgroundClip(focusedLeaf.rect)
                renderPrimarySprites(
                    transform: ft, deltaSec: deltaSec,
                    viewportWidth: focusedLeaf.rect.w, viewportHeight: focusedLeaf.rect.h,
                    cullOrigin: (focusedLeaf.rect.x, focusedLeaf.rect.y))
                popBackgroundClip()
                ImGuiPopClipRect()
                engine.restoreMetrics(saved)
            }
        }
        for leaf in nonFocusedLeaves {
            guard let ctx = paneCtxs[leaf.id] else { continue }
            let bg = leafBgs[leaf.id] ?? engine.ui.backgroundColor
            renderLeafGridAndSprites(leaf: leaf, ctx: ctx, bg: bg, deltaSec: deltaSec)
        }

        // 3. Feature commands UI
        engine.commandProcessor.activeFeatureCommand?.renderImGui(engine: engine)

        renderObjectPickerPopup()
        let t2 = SDL_GetTicks()
        ImGuiRender()
        target.wantCaptureMouse = engine.io.pointee.WantCaptureMouse
        target.wantCaptureKeyboard = engine.io.pointee.WantCaptureKeyboard

        let imguiDrawDataReady = uploadImGuiDrawData()

        // Pick pass for the focused pane (pending coords are pane-local).
        if focusedShowsActive,
           let pickX = _pendingPickScreenX, let pickY = _pendingPickScreenY,
           let pickTex = pickTexture, cadIDPipeline != nil, actx.vertexBuffer != nil,
           actx.vertexCount > 0
        {
            _pendingPickScreenX = nil
            _pendingPickScreenY = nil

            if let pickCmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) {
                var pickColorTarget = SDL_GPUColorTargetInfo()
                pickColorTarget.texture = pickTex
                pickColorTarget.mip_level = 0
                pickColorTarget.layer_or_depth_plane = 0
                pickColorTarget.clear_color = SDL_FColor(r: 0, g: 0, b: 0, a: 0)
                pickColorTarget.load_op = SDL_GPU_LOADOP_CLEAR
                pickColorTarget.store_op = SDL_GPU_STOREOP_STORE
                pickColorTarget.cycle = false

                if let pickPass = SDL_BeginGPURenderPass(pickCmd, &pickColorTarget, 1, nil) {
                    SDL_BindGPUGraphicsPipeline(pickPass, cadIDPipeline)

                    var vertexBinding = SDL_GPUBufferBinding(buffer: actx.vertexBuffer!, offset: 0)
                    SDL_BindGPUVertexBuffers(pickPass, 0, &vertexBinding, 1)

                    var pickMatrix = engine.camera.computePickMatrix(
                        cursorScreenX: pickX,
                        cursorScreenY: pickY,
                        windowWidth: Int32(focusedLeaf.rect.w),
                        windowHeight: Int32(focusedLeaf.rect.h),
                        renderOrigin: actx.geometry.renderOrigin)
                    SDL_PushGPUVertexUniformData(pickCmd, 0, &pickMatrix, UInt32(pickMatrix.count * 4))

                    var lastBoundType: CADPipelineType? = nil
                    for batch in actx.batches {
                        if batch.isPanProxy { continue }
                        let pipe: OpaquePointer?
                        switch batch.pipelineType {
                        case .line:       pipe = cadIDLinePipeline
                        case .point:      pipe = cadIDPointPipeline
                        case .triangle,
                             .aaLine:     pipe = cadIDPipeline
                        }
                        if lastBoundType != batch.pipelineType {
                            SDL_BindGPUGraphicsPipeline(pickPass, pipe)
                            lastBoundType = batch.pipelineType
                        }
                        if pipe != nil {
                            SDL_DrawGPUPrimitives(pickPass, batch.vertexCount, 1, batch.firstVertex, 0)
                        }
                    }

                    SDL_EndGPURenderPass(pickPass)
                }

                let ringIdx = pickRingIndex % 3
                if let ringBuf = pickRingBuffers[ringIdx] {
                    let copyPass = SDL_BeginGPUCopyPass(pickCmd)
                    if copyPass != nil {
                        var srcRegion = SDL_GPUTextureRegion()
                        srcRegion.texture = pickTex
                        srcRegion.mip_level = 0
                        srcRegion.layer = 0
                        srcRegion.x = 0
                        srcRegion.y = 0
                        srcRegion.z = 0
                        srcRegion.w = 9
                        srcRegion.h = 9
                        srcRegion.d = 1

                        var dstLocation = SDL_GPUTextureTransferInfo()
                        dstLocation.transfer_buffer = ringBuf
                        dstLocation.offset = 0
                        dstLocation.pixels_per_row = 9
                        dstLocation.rows_per_layer = 9

                        SDL_DownloadFromGPUTexture(copyPass, &srcRegion, &dstLocation)
                        SDL_EndGPUCopyPass(copyPass)
                    }
                }
                pickRingIndex += 1

                SDL_SubmitGPUCommandBuffer(pickCmd)
            }
        }

        // Resolve and upload pane backgrounds before acquiring the swapchain
        // command buffer. The upload submits its own command buffer; doing
        // that while a swapchain texture is checked out on another command
        // buffer is not a safe ordering for the GPU backends used here.
        let plans = leaves.map {
            planLeafCADPass(
                leaf: $0, focusedID: focusedID, activeID: activeID,
                leafBgs: leafBgs)
        }
        uploadPaneBgQuads(leaves: leaves, plans: plans)

        // Swapchain: one CAD pass per leaf, then the ImGui pass.
        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            print("Failed to acquire GPU command buffer")
            return
        }

        var swapchainTexture: OpaquePointer? = nil
        if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, target.handle, &swapchainTexture, nil, nil) {
            print("Failed to acquire swapchain texture. Window may be minimized or occluded.")
            SDL_CancelGPUCommandBuffer(cmd)
            return
        }

        if let swapchainTexture = swapchainTexture {
            for (index, leaf) in leaves.enumerated() {
                renderLeafCADPass(
                    cmd: cmd, swapchainTexture: swapchainTexture, leaf: leaf,
                    leafIndex: index, isFirst: index == 0, plan: plans[index])
            }

            var imguiTarget = SDL_GPUColorTargetInfo()
            imguiTarget.texture = swapchainTexture
            imguiTarget.mip_level = 0
            imguiTarget.layer_or_depth_plane = 0
            imguiTarget.clear_color = engine.ui.backgroundColor
            imguiTarget.load_op = SDL_GPU_LOADOP_LOAD
            imguiTarget.store_op = SDL_GPU_STOREOP_STORE
            imguiTarget.cycle = false

            if let imguiPass = SDL_BeginGPURenderPass(cmd, &imguiTarget, 1, nil) {
                var fullViewport = SDL_GPUViewport()
                fullViewport.x = 0
                fullViewport.y = 0
                fullViewport.w = Float(engine.pixelWidth)
                fullViewport.h = Float(engine.pixelHeight)
                fullViewport.min_depth = 0
                fullViewport.max_depth = 1
                SDL_SetGPUViewport(imguiPass, &fullViewport)
                var fullScissor = SDL_Rect(
                    x: 0, y: 0, w: engine.pixelWidth, h: engine.pixelHeight)
                SDL_SetGPUScissor(imguiPass, &fullScissor)
                if imguiDrawDataReady {
                    engine.ui.renderImGuiDrawData(cmd: cmd, renderPass: imguiPass, renderer: self, fontTexture: engine.fontTexture)
                }
                SDL_EndGPURenderPass(imguiPass)
            }
        }

        SDL_SubmitGPUCommandBuffer(cmd)

        let t3 = SDL_GetTicks()
        let cadMs = Double(t1 - t0)
        let primMs = Double(t2 - t1)
        let imguiMs = Double(t3 - t2)
        engine._frameTimingCadMs += cadMs
        engine._frameTimingPrimMs += primMs
        engine._frameTimingImGuiMs += imguiMs
        engine._frameTimingCount += 1
        if engine._frameTimingCount >= 60 {
            let n = Double(engine._frameTimingCount)
            print(
                String(
                    format:
                        "[FrameTiming] CAD:%.1fms  Prims:%.1fms  ImGui:%.1fms  Total:%.1fms  FPS:%.0f",
                    engine._frameTimingCadMs / n, engine._frameTimingPrimMs / n,
                    engine._frameTimingImGuiMs / n,
                    (engine._frameTimingCadMs + engine._frameTimingPrimMs + engine._frameTimingImGuiMs) / n,
                    1000.0 / ((engine._frameTimingCadMs + engine._frameTimingPrimMs + engine._frameTimingImGuiMs) / n)))
            engine._frameTimingCadMs = 0
            engine._frameTimingPrimMs = 0
            engine._frameTimingImGuiMs = 0
            engine._frameTimingCount = 0
        }
    }

    /// Grid plus image/text sprites for one non-focused pane, clipped to it.
    /// `includeGrid` is false for the focused pane's interim rendering,
    /// whose overlay pass already drew the same grid (drawing it twice
    /// brightens it until the handover, which reads as a blink).
    private func renderLeafGridAndSprites(
        leaf: (id: UUID, tabID: UUID?, rect: PaneRect),
        ctx: WindowRenderContext,
        bg: SDL_FColor,
        deltaSec: Double,
        includeGrid: Bool = true,
        cameraOverride: EngineCameraManager? = nil
    ) {
        let isLight = EngineUIManager.isLightBackground(bg)
        // Interim donor rendering positions the donor's sprites with the
        // focused (live) camera, matching the geometry pass.
        let st = (cameraOverride ?? ctx.camera).transformForSubRect(
            originX: Double(leaf.rect.x), originY: Double(leaf.rect.y),
            width: Int32(leaf.rect.w), height: Int32(leaf.rect.h))
        pushLeafClip(leaf.rect)
        pushBackgroundClip(leaf.rect)
        if includeGrid {
            let vp = ctx.camera.worldViewportRect(
                windowWidth: Int32(leaf.rect.w), windowHeight: Int32(leaf.rect.h))
            renderGrid(
                cam: st,
                viewportWidth: leaf.rect.w, viewportHeight: leaf.rect.h,
                cameraZoom: ctx.camera.zoom, viewport: vp, useLightPalette: isLight)
        }
        var spriteEstimate = 0
        for sprite in ctx.sprites.getSpritesForRendering() {
            guard spriteEstimate < 60000 else { break }
            renderSprite(
                sprite, deltaSec: deltaSec, cam: st,
                viewportWidth: leaf.rect.w, viewportHeight: leaf.rect.h,
                useLightPalette: isLight, cullOrigin: (leaf.rect.x, leaf.rect.y))
            spriteEstimate += 4
        }
        popBackgroundClip()
        ImGuiPopClipRect()
    }

    /// Push an ImGui clip rect for a leaf (intersected with the current one).
    private func pushLeafClip(_ rect: PaneRect) {
        ImGuiPushClipRect(
            ImVec2(x: rect.x, y: rect.y),
            ImVec2(x: rect.x + rect.w, y: rect.y + rect.h),
            true)
    }

    /// Push the leaf clip onto the BACKGROUND draw list. Sprites (TTF text,
    /// images) draw there, and draw lists keep independent clip stacks:
    /// `ImGuiPushClipRect` only affects the current window's list, so
    /// without this, text quads spill across pane dividers (GPU geometry
    /// doesn't — it's scissored in its own pass). Pair with
    /// `popBackgroundClip()`.
    private func pushBackgroundClip(_ rect: PaneRect) {
        if let bgDL = igGetBackgroundDrawList(nil) {
            ImDrawListPushClipRect(
                bgDL,
                ImVec2(x: rect.x, y: rect.y),
                ImVec2(x: rect.x + rect.w, y: rect.y + rect.h),
                true)
        }
    }

    private func popBackgroundClip() {
        if let bgDL = igGetBackgroundDrawList(nil) {
            ImDrawListPopClipRect(bgDL)
        }
    }

    /// Foreground-list counterpart of `pushBackgroundClip` (crosshair and
    /// other foreground overlays). Pair with `popForegroundClip()`.
    private func pushForegroundClip(_ rect: PaneRect) {
        if let fgDL = igGetForegroundDrawList_ViewportPtr(nil) {
            ImDrawListPushClipRect(
                fgDL,
                ImVec2(x: rect.x, y: rect.y),
                ImVec2(x: rect.x + rect.w, y: rect.y + rect.h),
                true)
        }
    }

    private func popForegroundClip() {
        if let fgDL = igGetForegroundDrawList_ViewportPtr(nil) {
            ImDrawListPopClipRect(fgDL)
        }
    }

    /// One leaf's CAD pass: clear to the leaf background, then draw its
    /// batches through a leaf viewport+scissor (points scaled to pixels).
    /// One leaf's CAD pass inputs, resolved once per frame and shared by the
    /// background-quad upload and the pass itself so both agree on the camera.
    private struct LeafPassPlan {
        var bg: SDL_FColor
        var ctx: WindowRenderContext?
        var camera: EngineCameraManager
        var renderOrigin: CADRenderOrigin
        var isPrimaryLeaf: Bool
    }

    /// A context already built for the focused pane's tab+view, shown while
    /// the primary pipeline rebuilds after a tab/view switch cleared its
    /// stores. Prefers the pane's own context (its buffers are culled
    /// around this pane's camera); falls back to any other pane or
    /// secondary context built for the same tab+view — e.g. swapping the
    /// focused pane to the paper layout the other pane already shows.
    /// Without this, the focused pane sits empty (paper-white) for the
    /// whole regen: a full-pane flash on every swap. Nil once the primary
    /// buffers exist again.
    private func interimPaneCtx(
        leaf: (id: UUID, tabID: UUID?, rect: PaneRect),
        focusedID: UUID,
        activeID: UUID?
    ) -> WindowRenderContext? {
        guard leaf.id == focusedID,
              let tabID = leaf.tabID, tabID == activeID,
              tabCtx(for: tabID).vertexCount == 0
        else { return nil }
        let wantView = engine.tabManager.activeTab?.activeViewIndex ?? -1
        let wantDocumentID = engine.tabManager.activeTab.map { ObjectIdentifier($0.document) }
        func ready(_ ctx: WindowRenderContext) -> Bool {
            ctx.vertexBuffer != nil && ctx.vertexCount > 0
                && ctx.builtTabID == tabID && ctx.builtViewIndex == wantView
                && ctx.builtDocumentID == wantDocumentID
        }
        if let own = paneCtxs[leaf.id], ready(own) { return own }
        for ctx in paneCtxs.values where ready(ctx) { return ctx }
        if let secondary = secondaryCtxs[tabID], ready(secondary) { return secondary }
        return nil
    }

    private func planLeafCADPass(
        leaf: (id: UUID, tabID: UUID?, rect: PaneRect),
        focusedID: UUID,
        activeID: UUID?,
        leafBgs: [UUID: SDL_FColor]
    ) -> LeafPassPlan {
        // Only the focused pane showing the active tab is the primary view.
        // Every other pane uses its leaf-keyed context (own tab, drawing
        // view, and camera); anything not ready yet paints its background.
        if leaf.id == focusedID, leaf.tabID != nil, leaf.tabID == activeID {
            if let interim = interimPaneCtx(
                leaf: leaf, focusedID: focusedID, activeID: activeID) {
                return LeafPassPlan(
                    bg: engine.ui.backgroundColor, ctx: interim,
                    camera: engine.camera,
                    renderOrigin: interim.geometry.renderOrigin,
                    isPrimaryLeaf: true)
            }
            let actx = tabCtx(for: activeID!)
            return LeafPassPlan(
                bg: engine.ui.backgroundColor, ctx: actx,
                camera: engine.camera, renderOrigin: actx.geometry.renderOrigin,
                isPrimaryLeaf: true)
        }
        let bg = leafBgs[leaf.id] ?? engine.ui.backgroundColor
        if let pane = paneCtxs[leaf.id],
           pane.vertexBuffer != nil, pane.vertexCount > 0 {
            return LeafPassPlan(
                bg: bg, ctx: pane,
                camera: pane.camera, renderOrigin: pane.geometry.renderOrigin,
                isPrimaryLeaf: false)
        }
        if leaf.tabID != nil, leaf.tabID == activeID {
            // Same-tab pane still building its own context: draw the primary
            // buffers through this pane's camera meanwhile so the pane shows
            // geometry immediately. The buffers are culled around the focused
            // view, which is exact at split time (both panes start on the
            // same view) and a useful preview while the build catches up.
            // Only valid when the pane wants the tab's active drawing view —
            // the primary buffers hold that view's geometry.
            let entry = leaf.tabID.flatMap {
                engine.paneViews.entry(leafID: leaf.id, tabID: $0)
            }
            let activeView = leaf.tabID.flatMap {
                engine.tabManager.tab(for: $0)?.activeViewIndex
            } ?? 0
            if (entry?.viewIndex ?? activeView) == activeView {
                let actx = tabCtx(for: activeID!)
                return LeafPassPlan(
                    bg: bg, ctx: actx,
                    camera: paneCtxs[leaf.id]?.camera ?? engine.camera,
                    renderOrigin: actx.geometry.renderOrigin,
                    isPrimaryLeaf: false)
            }
        }
        // Empty pane or context not ready: background only. The camera is
        // arbitrary (the quad is derived from it), so use the live one.
        return LeafPassPlan(
            bg: bg, ctx: nil,
            camera: engine.camera, renderOrigin: .zero,
            isPrimaryLeaf: false)
    }

    /// Six world-space background vertices covering a leaf's visible rect
    /// (1% overscan against edge cracks), colored opaque `bg`.
    private func paneBgQuad(plan: LeafPassPlan, leafRect: PaneRect) -> [CADVertex] {
        let w = max(1, Int32(leafRect.w))
        let h = max(1, Int32(leafRect.h))
        let vp = plan.camera.worldViewportRect(windowWidth: w, windowHeight: h)
        let ox = plan.renderOrigin.x
        let oy = plan.renderOrigin.y
        let ex = (vp.maxX - vp.minX) * 0.005 + 1e-9
        let ey = (vp.maxY - vp.minY) * 0.005 + 1e-9
        let x0 = Float(vp.minX - ex - ox)
        let x1 = Float(vp.maxX + ex - ox)
        let y0 = Float(vp.minY - ey - oy)
        let y1 = Float(vp.maxY + ey - oy)
        func v(_ x: Float, _ y: Float) -> CADVertex {
            CADVertex(x: x, y: y, r: plan.bg.r, g: plan.bg.g, b: plan.bg.b, a: 1.0)
        }
        return [v(x0, y0), v(x1, y0), v(x0, y1), v(x1, y0), v(x1, y1), v(x0, y1)]
    }

    /// Upload one background quad per leaf (see `paneBgVertexBuffer`).
    /// The buffer is recreated when the pane count changes.
    private func uploadPaneBgQuads(
        leaves: [(id: UUID, tabID: UUID?, rect: PaneRect)],
        plans: [LeafPassPlan]
    ) {
        var vertices: [CADVertex] = []
        vertices.reserveCapacity(leaves.count * 6)
        for (leaf, plan) in zip(leaves, plans) {
            vertices.append(contentsOf: paneBgQuad(plan: plan, leafRect: leaf.rect))
        }
        guard !vertices.isEmpty else { return }
        if paneBgVertexBuffer == nil || paneBgVertexCapacity != vertices.count {
            if let old = paneBgVertexBuffer {
                SDL_ReleaseGPUBuffer(engine.gpuDevice, old)
                paneBgVertexBuffer = nil
            }
            let sizeInBytes = UInt32(vertices.count * MemoryLayout<CADVertex>.stride)
            var bufferCreateInfo = SDL_GPUBufferCreateInfo(
                usage: SDL_GPU_BUFFERUSAGE_VERTEX, size: sizeInBytes, props: 0)
            guard let vb = SDL_CreateGPUBuffer(engine.gpuDevice, &bufferCreateInfo) else {
                print("Failed to create pane background vertex buffer: \(String(cString: SDL_GetError()))")
                return
            }
            paneBgVertexBuffer = vb
            paneBgVertexCapacity = vertices.count
        }
        guard let bgBuffer = paneBgVertexBuffer else { return }
        let sizeInBytes = UInt32(vertices.count * MemoryLayout<CADVertex>.stride)
        var transferInfo = SDL_GPUTransferBufferCreateInfo()
        transferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
        transferInfo.size = sizeInBytes
        guard let transferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &transferInfo),
              let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, transferBuf, false)
        else {
            print("Failed to map pane background transfer buffer: \(String(cString: SDL_GetError()))")
            return
        }
        _ = vertices.withUnsafeBytes { ptr in
            memcpy(mapped, ptr.baseAddress!, Int(sizeInBytes))
        }
        SDL_UnmapGPUTransferBuffer(engine.gpuDevice, transferBuf)
        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice),
              let cp = SDL_BeginGPUCopyPass(cmd)
        else {
            print("Failed to acquire command buffer for pane background upload")
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
            return
        }
        var sourceLocation = SDL_GPUTransferBufferLocation(transfer_buffer: transferBuf, offset: 0)
        var destLocation = SDL_GPUBufferRegion(
            buffer: bgBuffer, offset: 0, size: sizeInBytes)
        SDL_UploadToGPUBuffer(cp, &sourceLocation, &destLocation, false)
        SDL_EndGPUCopyPass(cp)
        if !SDL_SubmitGPUCommandBuffer(cmd) {
            print("Failed to submit command buffer for pane background upload")
        }
        SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
    }

    private func renderLeafCADPass(
        cmd: OpaquePointer,
        swapchainTexture: OpaquePointer,
        leaf: (id: UUID, tabID: UUID?, rect: PaneRect),
        leafIndex: Int,
        isFirst: Bool,
        plan: LeafPassPlan
    ) {
        // Only the first leaf clears (clears cover the whole target, so a
        // per-leaf clear would wipe previously rendered panes); later panes
        // load, and every pane repaints its own rect with a background quad
        // since panes can have different view backgrounds.
        var colorTarget = SDL_GPUColorTargetInfo()
        colorTarget.texture = swapchainTexture
        colorTarget.mip_level = 0
        colorTarget.layer_or_depth_plane = 0
        // Clear to THIS pane's background, never the global one: the clear
        // covers the whole target, so a white paper-space global would
        // flash every pane white if a background quad ever failed to cover.
        colorTarget.clear_color = plan.bg
        colorTarget.load_op = isFirst ? SDL_GPU_LOADOP_CLEAR : SDL_GPU_LOADOP_LOAD
        colorTarget.store_op = SDL_GPU_STOREOP_STORE
        colorTarget.cycle = false

        guard let renderPass = SDL_BeginGPURenderPass(cmd, &colorTarget, 1, nil) else { return }

        var viewport = SDL_GPUViewport()
        viewport.x = leaf.rect.x * engine.scaleX
        viewport.y = leaf.rect.y * engine.scaleY
        viewport.w = leaf.rect.w * engine.scaleX
        viewport.h = leaf.rect.h * engine.scaleY
        viewport.min_depth = 0
        viewport.max_depth = 1
        SDL_SetGPUViewport(renderPass, &viewport)
        var scissor = SDL_Rect(
            x: Int32((leaf.rect.x * engine.scaleX).rounded()),
            y: Int32((leaf.rect.y * engine.scaleY).rounded()),
            w: max(1, Int32((leaf.rect.w * engine.scaleX).rounded())),
            h: max(1, Int32((leaf.rect.h * engine.scaleY).rounded())))
        SDL_SetGPUScissor(renderPass, &scissor)

        let matrix = plan.camera.computeMatrix(
            windowW: Double(leaf.rect.w),
            windowH: Double(leaf.rect.h),
            renderOrigin: plan.renderOrigin)
        pushCADUniforms(cmd: cmd, matrix: matrix, includeHiddenHandles: plan.isPrimaryLeaf)

        var lastBoundPipeline: CADPipelineType? = nil
        if let bgBuf = paneBgVertexBuffer, cadTrianglePipeline != nil {
            var bgBinding = SDL_GPUBufferBinding(buffer: bgBuf, offset: 0)
            SDL_BindGPUVertexBuffers(renderPass, 0, &bgBinding, 1)
            SDL_BindGPUGraphicsPipeline(renderPass, cadTrianglePipeline)
            lastBoundPipeline = .triangle
            SDL_DrawGPUPrimitives(renderPass, 6, 1, UInt32(leafIndex * 6), 0)
        }

        if let ctx = plan.ctx, let vertexBuf = ctx.vertexBuffer, ctx.vertexCount > 0 {
            var vertexBinding = SDL_GPUBufferBinding(buffer: vertexBuf, offset: 0)
            SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

            for batch in ctx.batches {
                if batch.isPanProxy && !(plan.isPrimaryLeaf && _panProxyActiveThisFrame) { continue }
                let pipeline: OpaquePointer?
                switch batch.pipelineType {
                case .point:
                    pipeline = cadPointPipeline
                case .triangle:
                    pipeline = cadTrianglePipeline
                case .line:
                    pipeline = cadLinePipeline
                case .aaLine:
                    pipeline = cadLineAAPipeline
                }

                if lastBoundPipeline != batch.pipelineType {
                    SDL_BindGPUGraphicsPipeline(renderPass, pipeline)
                    lastBoundPipeline = batch.pipelineType
                }

                SDL_DrawGPUPrimitives(renderPass, batch.vertexCount, 1, batch.firstVertex, 0)
            }
        }

        SDL_EndGPURenderPass(renderPass)
    }

    /// Pane gutters, divider drag handles, the focused-pane outline, and
    /// per-pane identity badges.
    ///
    /// Each divider's invisible button lives in its own strip-sized window:
    /// widget calls need a current window (the split frame has none open at
    /// this point — the buttons used to be orphaned and could never hover
    /// or activate), and a canvas-sized host window would make
    /// `WantCaptureMouse` true over the whole canvas, swallowing CAD input.
    /// A window exactly covering the hit strip captures only there.
    ///
    /// Gutters are always painted (not just on hover) so pane boundaries
    /// stay visible; hovering shows a resize cursor, dragging tints the
    /// gutter gold, and double-clicking resets that split to 50/50.
    private func renderPaneDividers(canvas: PaneRect, focusedID: UUID) {
        let theme = engine.ui.theme
        // Background list, not foreground: chrome must stay under popup
        // windows (e.g. command autocomplete).
        let dl = igGetBackgroundDrawList(nil)
        let mouse = ImGuiGetIO()?.pointee.MousePos ?? ImVec2(x: -1, y: -1)
        let gutterHalf = PaneLayout.gutterWidth * 0.5

        for divider in engine.mainPanes.dividers(canvas: canvas) {
            ImGuiSetNextWindowPos(
                ImVec2(x: divider.rect.x, y: divider.rect.y),
                Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSize(
                ImVec2(x: divider.rect.w, y: divider.rect.h),
                Int32(ImGuiCond_Always.rawValue))
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 0, y: 0))
            var open = true
            let stripFlags: Int32 =
                Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
                | Int32(ImGuiWindowFlags_NoResize.rawValue)
                | Int32(ImGuiWindowFlags_NoMove.rawValue)
                | Int32(ImGuiWindowFlags_NoScrollbar.rawValue)
                | Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
                | Int32(ImGuiWindowFlags_NoBackground.rawValue)
                | Int32(ImGuiWindowFlags_NoFocusOnAppearing.rawValue)
                | Int32(ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue)
                | Int32(ImGuiWindowFlags_NoNavFocus.rawValue)
            var hovered = false
            var active = false
            var activated = false
            var deactivated = false
            var doubleClicked = false
            if igBegin("##panedividerwin_\(divider.id.uuidString)", &open, stripFlags) {
                _ = ImGuiInvisibleButton("##panedivider", ImVec2(x: divider.rect.w, y: divider.rect.h), 0)
                hovered = ImGuiIsItemHovered(0)
                active = ImGuiIsItemActive()
                activated = ImGuiIsItemActivated()
                deactivated = ImGuiIsItemDeactivated()
                doubleClicked = hovered && ImGuiIsMouseDoubleClicked(0)
            }
            igEnd()
            ImGuiPopStyleVar(1)

            // Cut position along the drag axis (centre of the hit strip).
            let isSideBySide = divider.axis == .sideBySide
            let cut = isSideBySide
                ? divider.rect.x + divider.rect.w * 0.5
                : divider.rect.y + divider.rect.h * 0.5
            let mouseAlong = isSideBySide ? mouse.x : mouse.y

            if hovered || active {
                ImGuiSetMouseCursor(Int32(
                    isSideBySide
                        ? ImGuiMouseCursor_ResizeEW.rawValue
                        : ImGuiMouseCursor_ResizeNS.rawValue))
            }
            if activated {
                _paneDividerGrab = (divider.id, mouseAlong - cut, false)
            }
            if doubleClicked {
                engine.mainPanes.setRatio(splitID: divider.id, ratio: 0.5, canvas: canvas)
                if _paneDividerGrab?.id == divider.id {
                    _paneDividerGrab?.suppressed = true
                }
            } else if active, let grab = _paneDividerGrab, grab.id == divider.id, !grab.suppressed {
                let target = mouseAlong - grab.offset
                engine.mainPanes.setRatioFromPoint(
                    splitID: divider.id,
                    point: isSideBySide ? (target, mouse.y) : (mouse.x, target),
                    canvas: canvas)
            }
            if deactivated, _paneDividerGrab?.id == divider.id {
                _paneDividerGrab = nil
            }

            // Gutter: always painted so pane boundaries are visible.
            let gMin = isSideBySide
                ? ImVec2(x: cut - gutterHalf, y: divider.rect.y)
                : ImVec2(x: divider.rect.x, y: cut - gutterHalf)
            let gMax = isSideBySide
                ? ImVec2(x: cut + gutterHalf, y: divider.rect.y + divider.rect.h)
                : ImVec2(x: divider.rect.x + divider.rect.w, y: cut + gutterHalf)
            let fill: ImVec4
            if active {
                fill = theme.brandGold
            } else if hovered {
                fill = ImVec4(x: theme.brandGold.x, y: theme.brandGold.y, z: theme.brandGold.z, w: 0.55)
            } else {
                fill = theme.panelBg
            }
            ImDrawListAddRectFilled(dl, gMin, gMax, igGetColorU32_Vec4(fill), 0.0, 0)
            if !active && !hovered {
                // Hairline edges keep the gutter readable on any background.
                let edge = igGetColorU32_Vec4(theme.border)
                if isSideBySide {
                    ImDrawListAddLine(dl, ImVec2(x: gMin.x, y: gMin.y), ImVec2(x: gMin.x, y: gMax.y), edge, 1.0)
                    ImDrawListAddLine(dl, ImVec2(x: gMax.x, y: gMin.y), ImVec2(x: gMax.x, y: gMax.y), edge, 1.0)
                } else {
                    ImDrawListAddLine(dl, ImVec2(x: gMin.x, y: gMin.y), ImVec2(x: gMax.x, y: gMin.y), edge, 1.0)
                    ImDrawListAddLine(dl, ImVec2(x: gMin.x, y: gMax.y), ImVec2(x: gMax.x, y: gMax.y), edge, 1.0)
                }
            }

            // Grip: three dots at the middle of the gutter.
            let gripColor = igGetColorU32_Vec4(
                active ? theme.panelBg : (hovered ? theme.textPrimary : theme.textDim))
            let mid = isSideBySide
                ? ImVec2(x: cut, y: divider.rect.y + divider.rect.h * 0.5)
                : ImVec2(x: divider.rect.x + divider.rect.w * 0.5, y: cut)
            for i in -1...1 {
                let offset = Float(i) * 6
                let p = isSideBySide
                    ? ImVec2(x: mid.x, y: mid.y + offset)
                    : ImVec2(x: mid.x + offset, y: mid.y)
                ImDrawListAddCircleFilled(dl, p, 1.5, gripColor, 8)
            }
        }

        // Gold outline around the focused pane (background list, like the
        // gutters, so it never paints over popup windows). Drawn inside the
        // leaf rect so it doesn't sit on the gutter.
        let leaves = engine.mainPanes.leafRects(canvas: canvas)
        if let focused = leaves.first(where: { $0.id == focusedID }) {
            ImDrawListAddRect(
                dl,
                ImVec2(x: focused.rect.x + 1, y: focused.rect.y + 1),
                ImVec2(x: focused.rect.x + focused.rect.w - 1, y: focused.rect.y + focused.rect.h - 1),
                igGetColorU32_Vec4(theme.brandGold), 0.0, 2.0, 0)
        }

        renderPaneBadges(leaves: leaves, focusedID: focusedID, mouse: mouse)
    }

    /// Top-left identity badge per pane: `<tab> · <view>`. The focused pane's
    /// badge is gold; others are muted. A badge fades while the cursor is
    /// over it so it never hides geometry being picked.
    private func renderPaneBadges(
        leaves: [(id: UUID, tabID: UUID?, rect: PaneRect)],
        focusedID: UUID,
        mouse: ImVec2
    ) {
        let theme = engine.ui.theme
        let dl = igGetBackgroundDrawList(nil)
        let padX: Float = 6
        let padY: Float = 2
        let inset: Float = 6
        for leaf in leaves {
            let label = paneBadgeLabel(leafID: leaf.id, tabID: leaf.tabID, focusedID: focusedID)
            let textSize = ImGuiCalcTextSize(label, nil, false, -1)
            let pillW = textSize.x + padX * 2
            let pillH = textSize.y + padY * 2
            // Skip panes too small to fit the badge without crowding.
            guard leaf.rect.w > pillW + inset * 4, leaf.rect.h > pillH + inset * 4 else { continue }
            let pMin = ImVec2(x: leaf.rect.x + inset, y: leaf.rect.y + inset)
            let pMax = ImVec2(x: pMin.x + pillW, y: pMin.y + pillH)
            let underMouse = mouse.x >= pMin.x && mouse.x < pMax.x
                && mouse.y >= pMin.y && mouse.y < pMax.y
            let fade: Float = underMouse ? 0.2 : 1.0
            let isFocused = leaf.id == focusedID
            let bg = isFocused
                ? ImVec4(x: theme.brandGold.x, y: theme.brandGold.y, z: theme.brandGold.z, w: 0.9 * fade)
                : ImVec4(x: theme.panelBg.x, y: theme.panelBg.y, z: theme.panelBg.z, w: 0.75 * fade)
            let fg = isFocused
                ? ImVec4(x: 0.08, y: 0.08, z: 0.08, w: fade)
                : ImVec4(x: theme.textDim.x, y: theme.textDim.y, z: theme.textDim.z, w: fade)
            pushBackgroundClip(leaf.rect)
            ImDrawListAddRectFilled(dl, pMin, pMax, igGetColorU32_Vec4(bg), 4.0, 0)
            ImDrawListAddText(
                dl, ImVec2(x: pMin.x + padX, y: pMin.y + padY),
                igGetColorU32_Vec4(fg), label, nil)
            popBackgroundClip()
        }
    }

    /// Badge text for a pane: tab name plus the drawing view it shows.
    private func paneBadgeLabel(leafID: UUID, tabID: UUID?, focusedID: UUID) -> String {
        guard let tabID, let tab = engine.tabManager.tab(for: tabID) else { return "(empty)" }
        guard !tab.drawingViews.isEmpty else { return tab.displayName }
        var viewIndex = tab.activeViewIndex
        if !(leafID == focusedID && tabID == engine.tabManager.activeTab?.id) {
            viewIndex = engine.paneViews.entry(leafID: leafID, tabID: tabID)?.viewIndex
                ?? tab.activeViewIndex
        }
        viewIndex = min(max(viewIndex, 0), tab.drawingViews.count - 1)
        let viewName = tab.drawingViews[viewIndex].name
        return viewName.isEmpty ? tab.displayName : "\(tab.displayName) · \(viewName)"
    }

    /// Push a CAD camera matrix (plus drag/grip hidden handles for primary
    /// views) as vertex uniforms.
    private func pushCADUniforms(cmd: OpaquePointer, matrix: [Float], includeHiddenHandles: Bool) {
        var uniformData = CameraUniformData()
        uniformData.m00 = matrix[0]; uniformData.m01 = matrix[1]; uniformData.m02 = matrix[2]; uniformData.m03 = matrix[3]
        uniformData.m10 = matrix[4]; uniformData.m11 = matrix[5]; uniformData.m12 = matrix[6]; uniformData.m13 = matrix[7]
        uniformData.m20 = matrix[8]; uniformData.m21 = matrix[9]; uniformData.m22 = matrix[10]; uniformData.m23 = matrix[11]
        uniformData.m30 = matrix[12]; uniformData.m31 = matrix[13]; uniformData.m32 = matrix[14]; uniformData.m33 = matrix[15]

        if includeHiddenHandles {
            let dragOrGrip = engine.interaction.dragActive || engine.interaction.gripActive
            if dragOrGrip || !engine.interaction.pendingPreviewHandles.isEmpty {
                var hiddenEntities: [UInt32] = []
                let handlesToHide = dragOrGrip ? engine.cadSelection.selectedHandles : engine.interaction.pendingPreviewHandles
                for handle in handlesToHide {
                    if let idx = engine.geometryManager.handleToEntityIndex[handle] {
                        hiddenEntities.append(idx)
                        if hiddenEntities.count >= 16 { break }
                    }
                }
                uniformData.hiddenHandleCount = UInt32(hiddenEntities.count)
                if hiddenEntities.count > 0 { uniformData.h00 = hiddenEntities[0] }
                if hiddenEntities.count > 1 { uniformData.h01 = hiddenEntities[1] }
                if hiddenEntities.count > 2 { uniformData.h02 = hiddenEntities[2] }
                if hiddenEntities.count > 3 { uniformData.h03 = hiddenEntities[3] }
                if hiddenEntities.count > 4 { uniformData.h10 = hiddenEntities[4] }
                if hiddenEntities.count > 5 { uniformData.h11 = hiddenEntities[5] }
                if hiddenEntities.count > 6 { uniformData.h12 = hiddenEntities[6] }
                if hiddenEntities.count > 7 { uniformData.h13 = hiddenEntities[7] }
                if hiddenEntities.count > 8 { uniformData.h20 = hiddenEntities[8] }
                if hiddenEntities.count > 9 { uniformData.h21 = hiddenEntities[9] }
                if hiddenEntities.count > 10 { uniformData.h22 = hiddenEntities[10] }
                if hiddenEntities.count > 11 { uniformData.h23 = hiddenEntities[11] }
                if hiddenEntities.count > 12 { uniformData.h30 = hiddenEntities[12] }
                if hiddenEntities.count > 13 { uniformData.h31 = hiddenEntities[13] }
                if hiddenEntities.count > 14 { uniformData.h32 = hiddenEntities[14] }
                if hiddenEntities.count > 15 { uniformData.h33 = hiddenEntities[15] }
            }
        }

        SDL_PushGPUVertexUniformData(cmd, 0, &uniformData, UInt32(MemoryLayout<CameraUniformData>.size))
    }

    /// Show or hide the OS cursor based on ImGui capture state.
    private func updateOSCursorVisibility() {
        if let wantCapture = ImGuiGetIO()?.pointee.WantCaptureMouse {
            let isHiddenByImGui = ImGuiGetMouseCursor() == Int32(ImGuiMouseCursor_None.rawValue)

            if engine.interaction.forceHideOSCursor {
                ImGuiGetIO()?.pointee.ConfigFlags |= Int32(ImGuiConfigFlags_NoMouseCursorChange.rawValue)
                if SDL_CursorVisible() { _ = SDL_HideCursor() }
            } else if wantCapture && !isHiddenByImGui && !SDL_CursorVisible() {
                ImGuiGetIO()?.pointee.ConfigFlags &= ~Int32(ImGuiConfigFlags_NoMouseCursorChange.rawValue)
                _ = SDL_ShowCursor()
            } else if (!wantCapture || isHiddenByImGui) && SDL_CursorVisible() {
                ImGuiGetIO()?.pointee.ConfigFlags &= ~Int32(ImGuiConfigFlags_NoMouseCursorChange.rawValue)
                _ = SDL_HideCursor()
            }
        }
    }

    /// Render the active tab into a window: overlays, UI, CAD, and pick passes.
    /// `target` is usually the main window; a float window showing the active tab
    /// renders through the same path with borrowed engine metrics.
    private func renderPrimaryWindow(
        target: EngineManagedWindow,
        deltaSec: Double,
        t0: UInt64,
        uiBuilder: () -> Void
    ) {
        engine.activateImGuiContext(for: target)
        engine.ui.frameRole = target.isMain ? .mainWindow : .floatWindow(hostedTabID: target.hostedTabID)
        let actx = engine.tabManager.activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx
        // Float windows borrow the engine-global metrics slots so the whole
        // primary pipeline (transforms, overlays, passes) just works.
        let savedMetrics = target.isMain ? nil : engine.snapshotMetrics()
        let savedViewport = target.isMain ? nil : engine.ui.snapshotDrawingViewport()
        if !target.isMain {
            engine.windowWidth = target.width
            engine.windowHeight = target.height
            engine.pixelWidth = target.pixelWidth
            engine.pixelHeight = target.pixelHeight
            engine.scaleX = target.scaleX
            engine.scaleY = target.scaleY
        }
        defer {
            if let savedMetrics, let savedViewport {
                engine.restoreMetrics(savedMetrics)
                engine.ui.restoreDrawingViewport(base: savedViewport.base, current: savedViewport.current)
            }
        }

        let t1 = SDL_GetTicks()

        var transform = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)

        engine.io.pointee.DisplaySize = ImVec2(x: Float(engine.windowWidth), y: Float(engine.windowHeight))
        engine.io.pointee.DisplayFramebufferScale = ImVec2(x: engine.scaleX, y: engine.scaleY)
        engine.io.pointee.DeltaTime = Float(deltaSec)

        // Apply any deferred UI scale rebuild before NewFrame locks the font atlas.
        engine.applyPendingUiScaleRebuild()

        // Replay this window's captured input before its frame starts.
        engine.ui.replayQueuedInput(for: target, appFocused: engine.windowManager.focusedWindow != nil)

        ImGuiNewFrame()

        updateOSCursorVisibility()

        // 1. Draw active command / interaction overlays on ImGui foreground draw list
        _foregroundVertexEstimate = 0
        refreshGripCache(transform: transform)
        renderPrimaryVectorOverlays(transform: transform)
        renderFeatureOverlay(transform: transform)

        // 2. ImGui user panels/callbacks. Some controls (notably radial Pan)
        // mutate the camera here, so sprite transforms must be calculated after it.
        uiBuilder()

        let currentOffset = engine.camera.offset
        let cameraMoved: Bool
        if let previousOffset = _lastRenderedCameraOffset {
            cameraMoved =
                abs(currentOffset.x - previousOffset.x) > 1e-12
                || abs(currentOffset.y - previousOffset.y) > 1e-12
        } else {
            cameraMoved = false
        }
        _panProxyActiveThisFrame =
            cameraMoved
            || engine.interaction.panActive
            || engine.interaction.touchPanActive
            || engine.interaction.radialPanActive
        _lastRenderedCameraOffset = currentOffset

        // Refresh after UI controls have had a chance to pan the camera.
        transform = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)

        // Draw sprites late in the frame so TTF quads never use a pre-pan camera.
        renderPrimarySprites(transform: transform, deltaSec: deltaSec)
        
        // 3. Feature commands UI
        engine.commandProcessor.activeFeatureCommand?.renderImGui(engine: engine)
        
        renderObjectPickerPopup()
        ImGuiRender()
        target.wantCaptureMouse = engine.io.pointee.WantCaptureMouse
        target.wantCaptureKeyboard = engine.io.pointee.WantCaptureKeyboard

        let imguiDrawDataReady = uploadImGuiDrawData()

        // --- Phase 2: GPU ID-buffer pick pass ---
        if let pickX = _pendingPickScreenX, let pickY = _pendingPickScreenY,
           let pickTex = pickTexture, cadIDPipeline != nil, actx.vertexBuffer != nil,
           actx.vertexCount > 0
        {
            _pendingPickScreenX = nil
            _pendingPickScreenY = nil

            if let pickCmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) {
                // Render the pick pass into the 9×9 texture
                var pickColorTarget = SDL_GPUColorTargetInfo()
                pickColorTarget.texture = pickTex
                pickColorTarget.mip_level = 0
                pickColorTarget.layer_or_depth_plane = 0
                pickColorTarget.clear_color = SDL_FColor(r: 0, g: 0, b: 0, a: 0)
                pickColorTarget.load_op = SDL_GPU_LOADOP_CLEAR
                pickColorTarget.store_op = SDL_GPU_STOREOP_STORE
                pickColorTarget.cycle = false

                if let pickPass = SDL_BeginGPURenderPass(pickCmd, &pickColorTarget, 1, nil) {
                    SDL_BindGPUGraphicsPipeline(pickPass, cadIDPipeline)

                    var vertexBinding = SDL_GPUBufferBinding(buffer: actx.vertexBuffer!, offset: 0)
                    SDL_BindGPUVertexBuffers(pickPass, 0, &vertexBinding, 1)

                    // Upload pick matrix (9×9 viewport centered on cursor)
                    var pickMatrix = engine.camera.computePickMatrix(
                        cursorScreenX: pickX,
                        cursorScreenY: pickY,
                        windowWidth: engine.windowWidth,
                        windowHeight: engine.windowHeight,
                        renderOrigin: engine.geometryManager.renderOrigin)
                    SDL_PushGPUVertexUniformData(pickCmd, 0, &pickMatrix, UInt32(pickMatrix.count * 4))

                    // Draw all batches with appropriate ID pipeline per primitive type
                    var lastBoundType: CADPipelineType? = nil
                    for batch in actx.batches {
                        if batch.isPanProxy { continue }
                        let pipe: OpaquePointer?
                        switch batch.pipelineType {
                        case .line:       pipe = cadIDLinePipeline
                        case .point:      pipe = cadIDPointPipeline
                        case .triangle,
                             .aaLine:     pipe = cadIDPipeline
                        }
                        if lastBoundType != batch.pipelineType {
                            SDL_BindGPUGraphicsPipeline(pickPass, pipe)
                            lastBoundType = batch.pipelineType
                        }
                        if pipe != nil {
                            SDL_DrawGPUPrimitives(pickPass, batch.vertexCount, 1, batch.firstVertex, 0)
                        }
                    }

                    SDL_EndGPURenderPass(pickPass)
                }

                // Copy pick texture to ring buffer for async readback
                let ringIdx = pickRingIndex % 3
                if let ringBuf = pickRingBuffers[ringIdx] {
                    let copyPass = SDL_BeginGPUCopyPass(pickCmd)
                    if copyPass != nil {
                        var srcRegion = SDL_GPUTextureRegion()
                        srcRegion.texture = pickTex
                        srcRegion.mip_level = 0
                        srcRegion.layer = 0
                        srcRegion.x = 0
                        srcRegion.y = 0
                        srcRegion.z = 0
                        srcRegion.w = 9
                        srcRegion.h = 9
                        srcRegion.d = 1

                        var dstLocation = SDL_GPUTextureTransferInfo()
                        dstLocation.transfer_buffer = ringBuf
                        dstLocation.offset = 0
                        dstLocation.pixels_per_row = 9
                        dstLocation.rows_per_layer = 9

                        SDL_DownloadFromGPUTexture(copyPass, &srcRegion, &dstLocation)
                        SDL_EndGPUCopyPass(copyPass)
                    }
                }
                pickRingIndex += 1

                if !SDL_SubmitGPUCommandBuffer(pickCmd) {
                    print("Warning: Failed to submit pick command buffer")
                }
            }
        }

        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            print("Failed to acquire GPU command buffer")
            return
        }

        var swapchainTexture: OpaquePointer? = nil
        if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, target.handle, &swapchainTexture, nil, nil) {
            print("Failed to acquire swapchain texture")
            SDL_CancelGPUCommandBuffer(cmd)
            return
        }

        let t2 = SDL_GetTicks()

        if let swapchainTexture = swapchainTexture {
            var colorTarget = SDL_GPUColorTargetInfo()
            colorTarget.texture = swapchainTexture
            colorTarget.mip_level = 0
            colorTarget.layer_or_depth_plane = 0
            colorTarget.clear_color = engine.ui.backgroundColor
            colorTarget.load_op = SDL_GPU_LOADOP_CLEAR
            colorTarget.store_op = SDL_GPU_STOREOP_STORE
            colorTarget.cycle = true

            let renderPass = SDL_BeginGPURenderPass(cmd, &colorTarget, 1, nil)
            if renderPass != nil {
                if let vertexBuf = actx.vertexBuffer, actx.vertexCount > 0 {
                    var lastBoundPipeline: CADPipelineType? = nil
                    var vertexBinding = SDL_GPUBufferBinding(buffer: vertexBuf, offset: 0)
                    SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

                    let cameraMatrix = engine.camera.computeMatrix(
                        windowW: Double(engine.windowWidth),
                        windowH: Double(engine.windowHeight),
                        renderOrigin: engine.geometryManager.renderOrigin)
                    
                    pushCADUniforms(cmd: cmd, matrix: cameraMatrix, includeHiddenHandles: true)

                    let isPanning = _panProxyActiveThisFrame
                    for batch in actx.batches {
                        if batch.isPanProxy && !isPanning { continue }
                        let pipeline: OpaquePointer?
                        switch batch.pipelineType {
                        case .point:
                            pipeline = cadPointPipeline
                        case .triangle:
                            pipeline = cadTrianglePipeline
                        case .line:
                            pipeline = cadLinePipeline
                        case .aaLine:
                            pipeline = cadLineAAPipeline
                        }

                        if lastBoundPipeline != batch.pipelineType {
                            SDL_BindGPUGraphicsPipeline(renderPass, pipeline)
                            lastBoundPipeline = batch.pipelineType
                        }

                        SDL_DrawGPUPrimitives(renderPass, batch.vertexCount, 1, batch.firstVertex, 0)
                    }
                }

                if imguiDrawDataReady {
                    engine.ui.renderImGuiDrawData(cmd: cmd, renderPass: renderPass!, renderer: self, fontTexture: engine.fontTexture)
                }

                SDL_EndGPURenderPass(renderPass)
            }
        }

        let t3 = SDL_GetTicks()

        SDL_SubmitGPUCommandBuffer(cmd)

        let cadMs = Double(t1 - t0)
        let primMs = Double(t2 - t1)
        let imguiMs = Double(t3 - t2)
        engine._frameTimingCadMs += cadMs
        engine._frameTimingPrimMs += primMs
        engine._frameTimingImGuiMs += imguiMs
        engine._frameTimingCount += 1
        if engine._frameTimingCount >= 60 {
            let n = Double(engine._frameTimingCount)
            print(
                String(
                    format:
                        "[FrameTiming] CAD:%.1fms  Prims:%.1fms  ImGui:%.1fms  Total:%.1fms  FPS:%.0f",
                    engine._frameTimingCadMs / n, engine._frameTimingPrimMs / n,
                    engine._frameTimingImGuiMs / n,
                    (engine._frameTimingCadMs + engine._frameTimingPrimMs + engine._frameTimingImGuiMs) / n,
                    1000.0 / ((engine._frameTimingCadMs + engine._frameTimingPrimMs + engine._frameTimingImGuiMs) / n)))
            engine._frameTimingCadMs = 0
            engine._frameTimingPrimMs = 0
            engine._frameTimingImGuiMs = 0
            engine._frameTimingCount = 0
        }
    }

    /// Render a visible-but-inactive tab from its own context: grid, sprites,
    /// and CAD geometry with the tab's saved camera. Interaction overlays
    /// (selection, grips, crosshair, snap) stay exclusive to the primary
    /// window. A nil tab renders UI only (main window with every tab floated).
    private func renderSecondaryWindow(
        target: EngineManagedWindow,
        tab: DocumentTab?,
        deltaSec: Double,
        uiBuilder: () -> Void
    ) {
        engine.activateImGuiContext(for: target)
        engine.ui.frameRole = target.isMain ? .mainWindow : .floatWindow(hostedTabID: target.hostedTabID)
        let dims: (w: Int32, h: Int32, sx: Float, sy: Float) = target.isMain
            ? (engine.windowWidth, engine.windowHeight, engine.scaleX, engine.scaleY)
            : (target.width, target.height, target.scaleX, target.scaleY)
        guard dims.w > 0, dims.h > 0 else { return }

        // Float frames must not clobber the main window's viewport rect.
        let savedViewport = target.isMain ? nil : engine.ui.snapshotDrawingViewport()
        defer {
            if let savedViewport {
                engine.ui.restoreDrawingViewport(base: savedViewport.base, current: savedViewport.current)
            }
        }

        var ctx: WindowRenderContext? = nil
        var bg = engine.ui.backgroundColor
        if let tab {
            let view = tab.drawingViews[tab.activeViewIndex]
            bg = engine.ui.backgroundColor(forViewBackground: view.backgroundColor)
            let isLight = EngineUIManager.isLightBackground(bg)
            let c = tabCtx(for: tab.id)
            ctx = c
            c.camera.applyState(tab.cameraState)
            // Same stale-geometry guard as split panes: a drawing-view
            // switch must supersede explicitly (revisions can coincide).
            if c.builtTabID != tab.id || c.builtViewIndex != tab.activeViewIndex {
                c.builtTabID = tab.id
                c.builtViewIndex = tab.activeViewIndex
                c.regenTask?.cancel()
                c.regenTask = nil
                c.regenInFlight = nil
                c.bridge.cancelPending()
                c.regenGeneration &+= 1
                c.appliedGeneration = -1
                c.builtRevision = nil
                c.pendingRevision = nil
                c.invalidateBuiltState(device: engine.gpuDevice)
            }
            let doc = tab.document
            let pendingApplied = ensureContextRegenerated(
                ctxID: tab.id, ctx: c, doc: doc,
                simplifyComplexBlocks: tab.editingBlockID != nil ? false : engine.simplifyComplexBlocks,
                splineTessellationDivisor: engine.splineTessellationDivisor,
                background: bg, isPrimary: false)
            routeContextVertexBuild(
                ctx: c, camera: c.camera,
                viewportWidth: dims.w, viewportHeight: dims.h,
                pixelScale: max(1.0, max(dims.sx, dims.sy)),
                background: bg, useLightDisplayPalette: isLight,
                pendingApplied: pendingApplied, interactive: true)
        }

        engine.io.pointee.DisplaySize = ImVec2(x: Float(dims.w), y: Float(dims.h))
        engine.io.pointee.DisplayFramebufferScale = ImVec2(x: dims.sx, y: dims.sy)
        engine.io.pointee.DeltaTime = Float(deltaSec)

        engine.ui.replayQueuedInput(for: target, appFocused: engine.windowManager.focusedWindow != nil)

        ImGuiNewFrame()

        uiBuilder()

        if let ctx {
            let transform = ctx.camera.currentTransform(windowWidth: dims.w, windowHeight: dims.h)
            let vp = ctx.camera.worldViewportRect(windowWidth: dims.w, windowHeight: dims.h)
            let isLight = EngineUIManager.isLightBackground(bg)
            renderGrid(
                cam: transform,
                viewportWidth: Float(dims.w), viewportHeight: Float(dims.h),
                cameraZoom: ctx.camera.zoom, viewport: vp, useLightPalette: isLight)
            var spriteEstimate = 0
            for sprite in ctx.sprites.getSpritesForRendering() {
                guard spriteEstimate < 60000 else { break }
                renderSprite(
                    sprite, deltaSec: deltaSec, cam: transform,
                    viewportWidth: Float(dims.w), viewportHeight: Float(dims.h),
                    useLightPalette: isLight)
                spriteEstimate += 4
            }
            if let tab {
                renderSecondaryOverlays(target: target, tab: tab, ctx: ctx, transform: transform)
            }
        }

        ImGuiRender()
        target.wantCaptureMouse = engine.io.pointee.WantCaptureMouse
        target.wantCaptureKeyboard = engine.io.pointee.WantCaptureKeyboard

        let imguiDrawDataReady = uploadImGuiDrawData()

        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            print("Failed to acquire GPU command buffer (secondary window)")
            return
        }

        var swapchainTexture: OpaquePointer? = nil
        if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, target.handle, &swapchainTexture, nil, nil) {
            print("Failed to acquire swapchain texture (secondary window)")
            SDL_CancelGPUCommandBuffer(cmd)
            return
        }

        if let swapchainTexture = swapchainTexture {
            var colorTarget = SDL_GPUColorTargetInfo()
            colorTarget.texture = swapchainTexture
            colorTarget.mip_level = 0
            colorTarget.layer_or_depth_plane = 0
            colorTarget.clear_color = bg
            colorTarget.load_op = SDL_GPU_LOADOP_CLEAR
            colorTarget.store_op = SDL_GPU_STOREOP_STORE
            colorTarget.cycle = true

            if let renderPass = SDL_BeginGPURenderPass(cmd, &colorTarget, 1, nil) {
                if let ctx, let vertexBuf = ctx.vertexBuffer, ctx.vertexCount > 0 {
                    var lastBoundPipeline: CADPipelineType? = nil
                    var vertexBinding = SDL_GPUBufferBinding(buffer: vertexBuf, offset: 0)
                    SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

                    let cameraMatrix = ctx.camera.computeMatrix(
                        windowW: Double(dims.w),
                        windowH: Double(dims.h),
                        renderOrigin: ctx.geometry.renderOrigin)

                    var uniformData = CameraUniformData()
                    uniformData.m00 = cameraMatrix[0]; uniformData.m01 = cameraMatrix[1]; uniformData.m02 = cameraMatrix[2]; uniformData.m03 = cameraMatrix[3]
                    uniformData.m10 = cameraMatrix[4]; uniformData.m11 = cameraMatrix[5]; uniformData.m12 = cameraMatrix[6]; uniformData.m13 = cameraMatrix[7]
                    uniformData.m20 = cameraMatrix[8]; uniformData.m21 = cameraMatrix[9]; uniformData.m22 = cameraMatrix[10]; uniformData.m23 = cameraMatrix[11]
                    uniformData.m30 = cameraMatrix[12]; uniformData.m31 = cameraMatrix[13]; uniformData.m32 = cameraMatrix[14]; uniformData.m33 = cameraMatrix[15]

                    SDL_PushGPUVertexUniformData(cmd, 0, &uniformData, UInt32(MemoryLayout<CameraUniformData>.size))

                    for batch in ctx.batches {
                        if batch.isPanProxy { continue }
                        let pipeline: OpaquePointer?
                        switch batch.pipelineType {
                        case .point:
                            pipeline = cadPointPipeline
                        case .triangle:
                            pipeline = cadTrianglePipeline
                        case .line:
                            pipeline = cadLinePipeline
                        case .aaLine:
                            pipeline = cadLineAAPipeline
                        }

                        if lastBoundPipeline != batch.pipelineType {
                            SDL_BindGPUGraphicsPipeline(renderPass, pipeline)
                            lastBoundPipeline = batch.pipelineType
                        }

                        SDL_DrawGPUPrimitives(renderPass, batch.vertexCount, 1, batch.firstVertex, 0)
                    }
                }

                if imguiDrawDataReady {
                    engine.ui.renderImGuiDrawData(cmd: cmd, renderPass: renderPass, renderer: self, fontTexture: engine.fontTexture)
                }

                SDL_EndGPURenderPass(renderPass)
            }
        }

        SDL_SubmitGPUCommandBuffer(cmd)
    }

    /// Refresh the main window's OS title from the tab its canvas shows
    /// (focused pane's tab when split), with a dirty dot for unsaved
    /// changes. Cached so SDL is only touched on change. (macOS hides the
    /// main titlebar; the title still feeds Expose and screen readers.)
    private func refreshMainWindowTitle() {
        guard let main = engine.windowManager.mainWindow else { return }
        let title: String
        if let shown = engine.mainShownTab() {
            title = "Zephyr CAD — \(shown.displayName)" + (shown.hasUnsavedChanges ? " ●" : "")
        } else {
            title = "Zephyr CAD"
        }
        if main.lastTitle != title {
            if ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil {
                print("[Diag] main title: \(main.lastTitle ?? "nil") -> \(title)")
            }
            main.lastTitle = title
            SDL_SetWindowTitle(main.handle, title)
        }
    }

    /// Keep a float window's OS title in sync with its hosted tab
    /// (name + dirty dot). The window's chrome is the full AppUI rendered
    /// in float role; docking is via TABDOCK or the OS close box.
    private func syncAuxWindowTitle(_ aux: EngineManagedWindow) {
        guard let tabID = aux.hostedTabID,
              let tab = engine.tabManager.tab(for: tabID) else { return }
        let title = tab.displayName + (tab.hasUnsavedChanges ? " ●" : "")
        if aux.lastTitle != title {
            aux.lastTitle = title
            SDL_SetWindowTitle(aux.handle, title)
        }
    }

    /// Passive feedback for a secondary (non-active-tab) view: crosshair at
    /// this window's own mouse position, hover highlight via a
    /// document-scoped CPU hit test, and this document's persisted
    /// selection (geometry/frame highlights plus grip squares). Mirrors the primary
    /// overlay colors, minus drag/edit state, which belongs to the
    /// window showing the active tab.
    private func renderSecondaryOverlays(
        target: EngineManagedWindow, tab: DocumentTab,
        ctx: WindowRenderContext, transform: CameraTransform
    ) {
        guard let vpF = engine.ui.drawingViewportRect else { return }
        let vp = PaneRect(x: vpF.x, y: vpF.y, w: vpF.w, h: vpF.h)
        let doc = tab.document
        let handles = tab.selectionState.selectedHandles
        let mouseInCanvas = target.hasMousePos
            && target.mouseX >= vp.x && target.mouseX <= vp.x + vp.w
            && target.mouseY >= vp.y && target.mouseY <= vp.y + vp.h

        if !handles.isEmpty || mouseInCanvas {
            pushBackgroundClip(vp)
            let drawList = igGetBackgroundDrawList(nil)
            let selColor = igGetColorU32_Vec4(engine.ui.theme.brandGold)
            var secondaryHighlightSegments = 0
            CADSelectionHighlightRenderer.drawGeometryHighlights(handles: handles, document: doc, cam: transform, vertexEditor: engine.cadBridge.vertexEditor, geometry: ctx.geometry, drawList: drawList, color: selColor, lineWidth: 2.0, maxSegments: 4096, segmentsDrawn: &secondaryHighlightSegments)
            for handle in handles where CADSelectionHighlightRenderer.frameRequired(handle: handle, document: doc) {
                guard let entity = doc.entity(for: handle),
                      let layer = doc.layer(for: entity.layerID), layer.isVisible,
                      let wbb = entity.worldBoundingBox else { continue }
                let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: transform)
                let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: transform)
                let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: transform)
                let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: transform)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, 2.0)
                ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), selColor, 2.0)
                ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), selColor, 2.0)
                ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), selColor, 2.0)
            }
            if !CADSelectionDisplayPolicy.gripsSuppressed(selectedCount: handles.count, gripObjectLimit: engine.gripObjectMax) {
                let grips = CADGripSystem.getAllGrips(
                    document: doc, cam: transform, simplifyComplexBlocks: true,
                    selectedHandles: handles,
                    selectedLeaderContentHandle: tab.selectionState.selectedLeaderContentHandle,
                    gripObjectLimit: engine.gripObjectMax)
                var drawn = 0
                for grip in grips {
                    if drawn >= engine.gripMax { break }
                    let half: Float = 4.0
                    let pMin = ImVec2(x: grip.screenPos.x - half, y: grip.screenPos.y - half)
                    let pMax = ImVec2(x: grip.screenPos.x + half, y: grip.screenPos.y + half)
                    ImDrawListAddRectFilled(
                        drawList, pMin, pMax,
                        makeImCol32(r: 0, g: 100, b: 255, a: 255), 0.0, 0)
                    ImDrawListAddRect(
                        drawList, pMin, pMax,
                        makeImCol32(r: 255, g: 255, b: 255, a: 255), 0.0, 1.0, 0)
                    drawn += 1
                }
            }

            // Hover highlight for this window's own document (CPU hit
            // test; the GPU pick pass belongs to the primary view).
            if mouseInCanvas, !engine.io.pointee.WantCaptureMouse {
                let (wx, wy) = EngineCameraManager.screenToWorld(
                    screenX: target.mouseX, screenY: target.mouseY, cam: transform)
                let threshold = 6.0 / ctx.camera.zoom
                if let hover = CADHitTesting.hitTest(
                        worldX: wx, worldY: wy, document: doc,
                        threshold: threshold,
                        simplifyComplexBlocks: engine.simplifyComplexBlocks),
                   !handles.contains(hover),
                   let entity = doc.entity(for: hover),
                   let layer = doc.layer(for: entity.layerID), layer.isVisible {
                    let hc = makeImCol32(r: 64, g: 224, b: 208, a: 180)
                    let geomCount = doc.resolvedGeometry(for: entity)?.count ?? 0
                    if engine.simplifyComplexBlocks && geomCount > 50 {
                        if let wbb = entity.worldBoundingBox {
                            let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: transform)
                            let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: transform)
                            let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: transform)
                            let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: transform)
                            ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, 2.0)
                            ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), hc, 2.0)
                            ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), hc, 2.0)
                            ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), hc, 2.0)
                        }
                    } else {
                        _ = engine.cadBridge.vertexEditor.forEachWorldSegment(
                            handle: hover, in: ctx.geometry, maxSegments: 4096
                        ) { x1, y1, x2, y2 in
                            let s0 = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: transform)
                            let s1 = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: transform)
                            ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, 2.0)
                        }
                    }
                }
            }
            popBackgroundClip()
        }

        if target.hasMousePos, !engine.io.pointee.WantCaptureMouse {
            let mx = target.mouseX
            let my = target.mouseY
            if mx >= vp.x, mx <= vp.x + vp.w, my >= vp.y, my <= vp.y + vp.h {
                drawCrosshairArms(
                    center: ImVec2(x: mx, y: my),
                    drawList: igGetForegroundDrawList_ViewportPtr(nil))
            }
        }
    }

    /// Refresh an aux window's cached metrics.
    /// - Returns: False when minimized or unmeasurable (caller skips the frame).
    private func refreshAuxMetrics(_ aux: EngineManagedWindow) -> Bool {
        let windowFlags = SDL_GetWindowFlags(aux.handle)
        if (windowFlags & 0x0000_0000_0000_0040) != 0 {
            aux.isMinimized = true
            aux.inputQueue.removeAll()
            return false
        }
        aux.isMinimized = false

        var windowWidth: Int32 = 0
        var windowHeight: Int32 = 0
        var pixelWidth: Int32 = 0
        var pixelHeight: Int32 = 0
        guard SDL_GetWindowSize(aux.handle, &windowWidth, &windowHeight),
              SDL_GetWindowSizeInPixels(aux.handle, &pixelWidth, &pixelHeight),
              windowWidth > 0, windowHeight > 0, pixelWidth > 0, pixelHeight > 0
        else {
            return false
        }
        aux.width = windowWidth
        aux.height = windowHeight
        aux.pixelWidth = pixelWidth
        aux.pixelHeight = pixelHeight
        aux.scaleX = Float(pixelWidth) / Float(windowWidth)
        aux.scaleY = Float(pixelHeight) / Float(windowHeight)
        aux.dpiScale = SDL_GetWindowDisplayScale(aux.handle)
        return true
    }

    /// Render one auxiliary OS window with no hosted tab: metrics, input, an
    /// empty ImGui frame, and present. Float windows always host a tab, so
    /// this is only a safe fallback for a stray aux window.
    private func renderAuxWindow(_ aux: EngineManagedWindow, deltaSec: Double) {
        engine.activateImGuiContext(for: aux)
        engine.ui.frameRole = .floatWindow(hostedTabID: aux.hostedTabID)
        guard refreshAuxMetrics(aux) else { return }
        let windowWidth = aux.width
        let windowHeight = aux.height

        engine.io.pointee.DisplaySize = ImVec2(x: Float(windowWidth), y: Float(windowHeight))
        engine.io.pointee.DisplayFramebufferScale = ImVec2(x: aux.scaleX, y: aux.scaleY)
        engine.io.pointee.DeltaTime = Float(deltaSec)

        engine.ui.replayQueuedInput(for: aux, appFocused: engine.windowManager.focusedWindow != nil)

        ImGuiNewFrame()

        ImGuiRender()
        aux.wantCaptureMouse = engine.io.pointee.WantCaptureMouse
        aux.wantCaptureKeyboard = engine.io.pointee.WantCaptureKeyboard

        let imguiDrawDataReady = uploadImGuiDrawData()

        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            print("Failed to acquire GPU command buffer (aux window)")
            return
        }

        var swapchainTexture: OpaquePointer? = nil
        if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, aux.handle, &swapchainTexture, nil, nil) {
            print("Failed to acquire swapchain texture (aux window)")
            SDL_CancelGPUCommandBuffer(cmd)
            return
        }

        if let swapchainTexture = swapchainTexture {
            var colorTarget = SDL_GPUColorTargetInfo()
            colorTarget.texture = swapchainTexture
            colorTarget.mip_level = 0
            colorTarget.layer_or_depth_plane = 0
            colorTarget.clear_color = engine.ui.backgroundColor
            colorTarget.load_op = SDL_GPU_LOADOP_CLEAR
            colorTarget.store_op = SDL_GPU_STOREOP_STORE
            colorTarget.cycle = true

            if let renderPass = SDL_BeginGPURenderPass(cmd, &colorTarget, 1, nil) {
                if imguiDrawDataReady {
                    engine.ui.renderImGuiDrawData(cmd: cmd, renderPass: renderPass, renderer: self, fontTexture: engine.fontTexture)
                }
                SDL_EndGPURenderPass(renderPass)
            }
        }

        SDL_SubmitGPUCommandBuffer(cmd)
    }

    /// Upload the latest ImGui draw data to the shared GPU vertex/index buffers.
    /// Called once per window frame, immediately after `ImGuiRender` and before
    /// that window's render pass consumes the buffers.
    /// - Returns: Whether fresh draw data is ready to render.
    /// Growth policy for reusable ImGui transfer buffers. Returns the
    /// capacity to ensure: reuse when the existing buffer covers the need,
    /// else grow with headroom to avoid per-frame reallocations.
    static func grownImGuiTransferCapacity(neededBytes: Int, existingBytes: Int) -> Int? {
        guard neededBytes > 0 else { return nil }
        if existingBytes >= neededBytes { return existingBytes }
        return neededBytes + max(4096, neededBytes / 4)
    }

    /// Returns a transfer buffer with at least `bytes` capacity, growing
    /// (with headroom) only when the current one is too small. Buffers are
    /// never released per-frame; uploads already pass `cycle=true`, which
    /// is SDL's documented cross-frame reuse mechanism.
    private func ensuredImGuiTransferBuffer(
        bytes: Int,
        current: inout OpaquePointer?,
        capacity: inout Int
    ) -> OpaquePointer? {
        guard let want = Self.grownImGuiTransferCapacity(
            neededBytes: bytes, existingBytes: capacity)
        else { return nil }
        if current == nil || capacity < bytes {
            var info = SDL_GPUTransferBufferCreateInfo()
            info.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
            info.size = UInt32(want)
            if let created = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &info) {
                if let old = current {
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, old)
                }
                current = created
                capacity = want
            }
        }
        return current
    }

    private func uploadImGuiDrawData() -> Bool {
        guard let drawData = ImGuiGetDrawData() else { return false }
        var totalVtxCount = 0
        var totalIdxCount = 0
        for n in 0..<Int(drawData.pointee.CmdListsCount) {
            guard let cmdList = drawData.pointee.CmdLists.Data?[n] else { continue }
            totalVtxCount += Int(cmdList.pointee.VtxBuffer.Size)
            totalIdxCount += Int(cmdList.pointee.IdxBuffer.Size)
        }

        var imguiDrawDataReady = false
        if totalVtxCount > 0 && totalIdxCount > 0 {
            if imguiVertexBuffer == nil || imguiVertexCapacity < totalVtxCount {
                let newCapacity = totalVtxCount + 5000
                let size = UInt32(newCapacity * MemoryLayout<ImDrawVert>.stride)
                var createInfo = SDL_GPUBufferCreateInfo(
                    usage: SDL_GPU_BUFFERUSAGE_VERTEX, size: size, props: 0)
                if let newBuffer = SDL_CreateGPUBuffer(engine.gpuDevice, &createInfo) {
                    if let oldBuffer = imguiVertexBuffer {
                        SDL_ReleaseGPUBuffer(engine.gpuDevice, oldBuffer)
                    }
                    imguiVertexBuffer = newBuffer
                    imguiVertexCapacity = newCapacity
                } else {
                    print("Failed to grow ImGui GPU vertex buffer: \(String(cString: SDL_GetError()))")
                }
            }

            if imguiIndexBuffer == nil || imguiIndexCapacity < totalIdxCount {
                let newCapacity = totalIdxCount + 10000
                let size = UInt32(newCapacity * MemoryLayout<ImDrawIdx>.stride)
                var createInfo = SDL_GPUBufferCreateInfo(
                    usage: SDL_GPU_BUFFERUSAGE_INDEX, size: size, props: 0)
                if let newBuffer = SDL_CreateGPUBuffer(engine.gpuDevice, &createInfo) {
                    if let oldBuffer = imguiIndexBuffer {
                        SDL_ReleaseGPUBuffer(engine.gpuDevice, oldBuffer)
                    }
                    imguiIndexBuffer = newBuffer
                    imguiIndexCapacity = newCapacity
                } else {
                    print("Failed to grow ImGui GPU index buffer: \(String(cString: SDL_GetError()))")
                }
            }

            if imguiVertexCapacity >= totalVtxCount,
               imguiIndexCapacity >= totalIdxCount,
               let vertexBuffer = imguiVertexBuffer,
               let indexBuffer = imguiIndexBuffer
            {
                let vtxSizeInBytes = UInt32(totalVtxCount * MemoryLayout<ImDrawVert>.stride)
                let idxSizeInBytes = UInt32(totalIdxCount * MemoryLayout<ImDrawIdx>.stride)

                // Reusable transfer buffers: no per-frame create/release.
                // Map MUST use cycle=true: the previous frame's upload may
                // still be in flight, and overwriting referenced data without
                // cycling tears the UI every few frames.
                let vtxTransferBuf = ensuredImGuiTransferBuffer(
                    bytes: Int(vtxSizeInBytes),
                    current: &imguiVtxTransferBuffer,
                    capacity: &imguiVtxTransferCapacityBytes)
                let idxTransferBuf = ensuredImGuiTransferBuffer(
                    bytes: Int(idxSizeInBytes),
                    current: &imguiIdxTransferBuffer,
                    capacity: &imguiIdxTransferCapacityBytes)

                if let vtxTransferBuf,
                   let idxTransferBuf
                {
                    let vtxMapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, vtxTransferBuf, true)
                    let idxMapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, idxTransferBuf, true)

                    if let vtxMapped,
                       let idxMapped
                    {
                        var vtxOffset = 0
                        var idxOffset = 0
                        for n in 0..<Int(drawData.pointee.CmdListsCount) {
                            guard let cmdList = drawData.pointee.CmdLists.Data?[n] else { continue }
                            let vtxSize = Int(cmdList.pointee.VtxBuffer.Size) * MemoryLayout<ImDrawVert>.stride
                            let idxSize = Int(cmdList.pointee.IdxBuffer.Size) * MemoryLayout<ImDrawIdx>.stride

                            memcpy(vtxMapped.advanced(by: vtxOffset), cmdList.pointee.VtxBuffer.Data, vtxSize)
                            memcpy(idxMapped.advanced(by: idxOffset), cmdList.pointee.IdxBuffer.Data, idxSize)

                            vtxOffset += vtxSize
                            idxOffset += idxSize
                        }

                        SDL_UnmapGPUTransferBuffer(engine.gpuDevice, vtxTransferBuf)
                        SDL_UnmapGPUTransferBuffer(engine.gpuDevice, idxTransferBuf)

                        if let uploadCmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) {
                            if let copyPass = SDL_BeginGPUCopyPass(uploadCmd) {
                                var srcVtx = SDL_GPUTransferBufferLocation(
                                    transfer_buffer: vtxTransferBuf, offset: 0)
                                var dstVtx = SDL_GPUBufferRegion(
                                    buffer: vertexBuffer, offset: 0, size: vtxSizeInBytes)
                                SDL_UploadToGPUBuffer(copyPass, &srcVtx, &dstVtx, true)

                                var srcIdx = SDL_GPUTransferBufferLocation(
                                    transfer_buffer: idxTransferBuf, offset: 0)
                                var dstIdx = SDL_GPUBufferRegion(
                                    buffer: indexBuffer, offset: 0, size: idxSizeInBytes)
                                SDL_UploadToGPUBuffer(copyPass, &srcIdx, &dstIdx, true)

                                SDL_EndGPUCopyPass(copyPass)
                                imguiDrawDataReady = SDL_SubmitGPUCommandBuffer(uploadCmd)
                                if !imguiDrawDataReady {
                                    print("Failed to submit ImGui GPU upload: \(String(cString: SDL_GetError()))")
                                }
                            } else {
                                SDL_CancelGPUCommandBuffer(uploadCmd)
                            }
                        }
                    } else {
                        if vtxMapped != nil {
                            SDL_UnmapGPUTransferBuffer(engine.gpuDevice, vtxTransferBuf)
                        }
                        if idxMapped != nil {
                            SDL_UnmapGPUTransferBuffer(engine.gpuDevice, idxTransferBuf)
                        }
                    }
                }
            }
        }
        return imguiDrawDataReady
    }


    private func renderCadSelectionHighlight(cam: CameraTransform) {
        // AutoCAD selection highlight: selected entities are redrawn in gold.
        // Images and complex block references use one bounding frame each;
        // loose entities keep their geometry highlight (never per-entity boxes).
        // Grips are suppressed over GRIPOBJLIMIT; the highlight remains.
        let selColor = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let lineWidth: Float = 2.0
        let maxSegments = (_foregroundVertexLimit - _foregroundVertexEstimate) / 6
        var segmentsDrawn = 0

        let overGripLimit = engine.cadSelection.selectedHandles.count > engine.gripObjectMax

        for handle in engine.cadSelection.selectedHandles {
            guard let entity = engine.document.entity(for: handle),
                  let layer = engine.document.layer(for: entity.layerID), layer.isVisible
            else { continue }

            let geom = entity.localGeometry ?? engine.document.resolvedGeometry(for: entity)
            let isImage = geom?.contains(where: { if case .image = $0 { return true }; return false }) ?? false
            let isBlock = entity.blockID != nil
            let highlightStyle = CADSelectionDisplayPolicy.highlightStyle(isImage: isImage, isBlockReference: isBlock, primitiveCount: geom?.count ?? 0)

            if highlightStyle == .boundingFrame || highlightStyle == .geometry {
                let drawList = igGetBackgroundDrawList(nil)

                // For image entities or complex blocks, just draw the bounding box.

                if highlightStyle == .boundingFrame || segmentsDrawn >= maxSegments {
                    guard highlightStyle == .boundingFrame else { continue }
                    guard let wbb = entity.worldBoundingBox else { continue }
                    let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                    let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                    let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                    let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), selColor, lineWidth)
                    _foregroundVertexEstimate += 8
                } else {
                    // For simple block entities, redraw each geometry segment so the
                    // selection highlight matches the geometry shape (same as hover).
                    engine.cadBridge.vertexEditor.forEachWorldSegment(handle: handle, in: engine.geometryManager, maxSegments: max(0, maxSegments - segmentsDrawn)) { x1, y1, x2, y2 in
                        guard segmentsDrawn < maxSegments else { return }
                        let s0 = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: cam)
                        let s1 = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: cam)
                        ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, lineWidth)
                        segmentsDrawn += 1
                    }
                    _foregroundVertexEstimate += segmentsDrawn * 2
                }
            } else if overGripLimit, CADSelectionHighlightRenderer.frameRequired(handle: handle, document: engine.document) {
                // Legacy over-limit box path: AutoCAD suppresses grips but
                // keeps the geometry highlight, so this frame only draws if
                // a frame is still required (see frameRequired).
                guard let wbb = entity.worldBoundingBox else { continue }
                let drawList = igGetBackgroundDrawList(nil)
                let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), selColor, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), selColor, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), selColor, lineWidth)
                _foregroundVertexEstimate += 8
            }
        }
    }

    /// AutoCAD-style hover highlight: draws the entity's actual geometry outline
    /// (polylines, line segments) when cursor is near, not the bounding box.
    private func renderCadHoverHighlight(cam: CameraTransform) {
        guard let hoverHandle = engine.interaction.hoveredEntityHandle else { return }
        guard !engine.cadSelection.selectedHandles.contains(hoverHandle) else { return }
        guard let entity = engine.document.entity(for: hoverHandle),
              let geometry = engine.document.resolvedGeometry(for: entity)
        else { return }

        // Image entities have no visible geometry segments in the GPU pipeline —
        // draw their bounding box instead of iterating (empty) world segments.
        if geometry.contains(where: { if case .image = $0 { return true }; return false }) {
            if let wbb = entity.worldBoundingBox {
                let hc = makeImCol32(r: 64, g: 224, b: 208, a: 180)
                let lineWidth: Float = 2.0
                let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                let drawList = igGetBackgroundDrawList(nil)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), hc, lineWidth)
                _foregroundVertexEstimate += 8
            }
            return
        }

        let hc = makeImCol32(r: 64, g: 224, b: 208, a: 180)
        let lineWidth: Float = 2.0

        // Massive blocks (loaded xrefs) highlight as a frame, not a segment walk.
        if geometry.count > 50 && (engine.simplifyComplexBlocks || geometry.count > CADBlockSpatialGrid.buildThreshold) {
            if let wbb = entity.worldBoundingBox {
                let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                let drawList = igGetBackgroundDrawList(nil)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), hc, lineWidth)
                ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), hc, lineWidth)
                _foregroundVertexEstimate += 8 // 4 lines = 8 vertices
            }
            return
        }

        guard let drawList = igGetBackgroundDrawList(nil) else { return }
        let remainingVertices = max(
            0,
            _foregroundVertexLimit - Int(drawList.pointee.VtxBuffer.Size))
        let maxSegments = min(4096, remainingVertices / 8)
        guard maxSegments > 0 else { return }

        let segmentsDrawn = engine.cadBridge.vertexEditor.forEachWorldSegment(
            handle: hoverHandle,
            in: engine.geometryManager,
            maxSegments: maxSegments
        ) { x1, y1, x2, y2 in
            let s0 = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: cam)
            let s1 = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, lineWidth)
        }
        _foregroundVertexEstimate += segmentsDrawn * 8
    }

    /// Renders a live preview of what the selection will look like after
    /// the rect select is finalized. Draws geometry outlines like hover,
    /// capped to stay under ImGui's 16-bit index limit (65535 vertices).
    private func renderRectSelectPreview(cam: CameraTransform) {
        guard engine.interaction.rectSelectActive else { return }
        let previewStyle: CADSelectionManager.RectSelectStyle = (engine.interaction.lastMouseX >= engine.interaction.rectSelectScreenStartX) ? .window : .crossing
        let previewMinX = min(engine.interaction.rectSelectStartX, engine.interaction.rectSelectCurrentX)
        let previewMaxX = max(engine.interaction.rectSelectStartX, engine.interaction.rectSelectCurrentX)
        let previewMinY = min(engine.interaction.rectSelectStartY, engine.interaction.rectSelectCurrentY)
        let previewMaxY = max(engine.interaction.rectSelectStartY, engine.interaction.rectSelectCurrentY)
        guard previewMaxX > previewMinX || previewMaxY > previewMinY else { return }
        let previewHandles = engine.interaction.rectPreviewHandles(
            minX: previewMinX, minY: previewMinY, maxX: previewMaxX, maxY: previewMaxY,
            revision: engine.document.renderRevision,
            compute: { engine.cadSelection.handlesInRect(worldX: previewMinX, worldY: previewMinY, worldW: previewMaxX - previewMinX, worldH: previewMaxY - previewMinY, document: engine.document, style: previewStyle) })
        guard !previewHandles.isEmpty else { return }
        guard !CADSelectionDisplayPolicy.previewSuppressed(previewCount: previewHandles.count, selectionPreviewLimit: engine.selectionPreviewLimit) else { return }


        let addColor = makeImCol32(r: 64, g: 180, b: 255, a: 180)
        let removeColor = makeImCol32(r: 255, g: 80, b: 80, a: 180)
        let lineWidth: Float = 1.5
        let baseMaxSegments = 8000  // 8000 segments × 2 verts = 16000 verts
        let budgetMaxSegments = (_foregroundVertexLimit - _foregroundVertexEstimate) / 6
        let maxSegments = min(baseMaxSegments, max(0, budgetMaxSegments))
        var segmentsDrawn = 0

        let toAdd = previewHandles.subtracting(engine.cadSelection.selectedHandles)
        let toRemove = engine.cadSelection.selectedHandles.subtracting(previewHandles)

        func drawGeometry(for handle: UUID, color: UInt32) {
            guard segmentsDrawn < maxSegments else { return }

            guard let entity = engine.document.entity(for: handle),
                  let geometry = engine.document.resolvedGeometry(for: entity)
            else { return }

            let drawList = igGetBackgroundDrawList(nil)
            // Massive blocks (loaded xrefs) highlight as a frame, not a segment walk.
        if geometry.count > 50 && (engine.simplifyComplexBlocks || geometry.count > CADBlockSpatialGrid.buildThreshold) {
                if let wbb = entity.worldBoundingBox {
                    let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                    let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                    let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                    let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), color, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), color, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), color, lineWidth)
                    segmentsDrawn += 4
                }
                return
            }

            engine.cadBridge.vertexEditor.forEachWorldSegment(handle: handle, in: engine.geometryManager) { x1, y1, x2, y2 in
                guard segmentsDrawn < maxSegments else { return }
                let s0 = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lineWidth)
                segmentsDrawn += 1
            }
        }

        for handle in toAdd {
            drawGeometry(for: handle, color: addColor)
        }
        for handle in toRemove {
            drawGeometry(for: handle, color: removeColor)
        }
        _foregroundVertexEstimate += segmentsDrawn * 2
    }

    private func renderCadGrips(cam: CameraTransform) {
        guard engine.cadSelection.hasSelection else { return }
        let drawList = igGetBackgroundDrawList(nil)
        let maxGripsToDraw = engine.gripMax
        var drawnGrips = 0

        for grip in engine._cachedCadGrips {
            if drawnGrips >= maxGripsToDraw { break }

            let screenPos: SDL_FPoint = engine.interaction.gripActive
                ? EngineCameraManager.worldToScreen(
                    worldX: grip.worldPos.x, worldY: grip.worldPos.y, cam: cam)
                : grip.screenPos

            let margin: Float = 10.0
            // Cull against the full window: screenPos is absolute even when a
            // split pane borrows smaller metrics.
            let fullW = ImGuiGetIO()?.pointee.DisplaySize.x ?? Float(engine.windowWidth)
            let fullH = ImGuiGetIO()?.pointee.DisplaySize.y ?? Float(engine.windowHeight)
            if screenPos.x < -margin || screenPos.x > fullW + margin
                || screenPos.y < -margin || screenPos.y > fullH + margin {
                continue
            }

            let isHovered: Bool
            if let hovered = engine.interaction.hoveredGrip,
               engine.interaction.hoveredGripHandle == grip.handle {
                isHovered = gripTypeMatches(hovered, grip.grip)
            } else {
                isHovered = false
            }

            if case .arraySpacing = grip.grip {
                drawArrayTriangleGrip(
                    grip: grip, screenPos: screenPos, hovered: isHovered,
                    drawList: drawList, filled: false)
                drawnGrips += 1
                continue
            }
            if case .arrayCount = grip.grip {
                drawArrayTriangleGrip(
                    grip: grip, screenPos: screenPos, hovered: isHovered,
                    drawList: drawList, filled: true)
                drawnGrips += 1
                continue
            }

            let fill: UInt32
            let half: Float
            switch grip.grip {
            case .corner:
                fill = isHovered ? makeImCol32(r: 80, g: 180, b: 255, a: 255) : makeImCol32(r: 0, g: 128, b: 255, a: 255)
                half = 4.0
            case .center, .arrayBase:
                fill = isHovered ? makeImCol32(r: 128, g: 255, b: 255, a: 255) : makeImCol32(r: 0, g: 255, b: 255, a: 255)
                half = 4.0
            case .rotation:
                fill = isHovered ? makeImCol32(r: 255, g: 128, b: 255, a: 255) : makeImCol32(r: 255, g: 0, b: 255, a: 255)
                half = 5.0
            case .vertex:
                fill = isHovered ? makeImCol32(r: 80, g: 180, b: 255, a: 255) : makeImCol32(r: 0, g: 100, b: 255, a: 255)
                half = 4.0
            case .midpoint:
                fill = isHovered ? makeImCol32(r: 128, g: 255, b: 180, a: 255) : makeImCol32(r: 0, g: 200, b: 140, a: 255)
                half = 3.0
            case .arraySpacing, .arrayCount:
                continue
            }

            let pMin = ImVec2(x: screenPos.x - half, y: screenPos.y - half)
            let pMax = ImVec2(x: screenPos.x + half, y: screenPos.y + half)
            ImDrawListAddRectFilled(drawList, pMin, pMax, fill, 0.0, 0)
            ImDrawListAddRect(
                drawList, pMin, pMax,
                makeImCol32(r: 255, g: 255, b: 255, a: 255), 0.0, 1.0, 0)
            drawnGrips += 1
        }
        _foregroundVertexEstimate += drawnGrips * 10
    }

    private func drawArrayTriangleGrip(
        grip: CADSelectionManager.CadGripInfo,
        screenPos: SDL_FPoint,
        hovered: Bool,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        filled: Bool
    ) {
        let rawDirection = grip.screenDirection ?? SDL_FPoint(x: 1, y: 0)
        let length = max(0.001, sqrt(Double(
            rawDirection.x * rawDirection.x + rawDirection.y * rawDirection.y)))
        let dx = Float(Double(rawDirection.x) / length)
        let dy = Float(Double(rawDirection.y) / length)
        let nx = -dy
        let ny = dx
        let tip = ImVec2(x: screenPos.x + dx * 7, y: screenPos.y + dy * 7)
        let baseX = screenPos.x - dx * 5
        let baseY = screenPos.y - dy * 5
        let a = ImVec2(x: baseX + nx * 5, y: baseY + ny * 5)
        let b = ImVec2(x: baseX - nx * 5, y: baseY - ny * 5)
        let color = hovered
            ? makeImCol32(r: 80, g: 180, b: 255, a: 255)
            : makeImCol32(r: 0, g: 128, b: 255, a: 255)
        let outline = makeImCol32(r: 255, g: 255, b: 255, a: 255)

        if filled {
            ImDrawListAddTriangleFilled(drawList, tip, a, b, color)
        } else {
            ImDrawListAddTriangleFilled(
                drawList, tip, a, b, makeImCol32(r: 0, g: 30, b: 50, a: 255))
        }
        ImDrawListAddLine(drawList, tip, a, outline, 1.0)
        ImDrawListAddLine(drawList, a, b, outline, 1.0)
        ImDrawListAddLine(drawList, b, tip, outline, 1.0)
    }

    private func gripTypeMatches(
        _ a: CADSelectionManager.GripType, _ b: CADSelectionManager.GripType
    ) -> Bool {
        switch (a, b) {
        case (.center, .center): return true
        case (.rotation, .rotation): return true
        case (.arrayBase, .arrayBase): return true
        case (.corner(let i), .corner(let j)): return i == j
        case (.vertex(let e1, let i1), .vertex(let e2, let i2)): return e1 == e2 && i1 == i2
        case (.midpoint(let e1, let a1, let b1), .midpoint(let e2, let a2, let b2)):
            return e1 == e2 && a1 == a2 && b1 == b2
        case (.arraySpacing(let a1), .arraySpacing(let a2)): return a1 == a2
        case (.arrayCount(let a1), .arrayCount(let a2)): return a1 == a2
        default: return false
        }
    }

    // MARK: - Crosshair Cursor (AutoCAD-style)

    /// Draw full-screen crosshair lines through the cursor position,
    /// mimicking AutoCAD's iconic crosshair cursor.
    /// Hidden during rect select (the selection rectangle replaces it)
    /// and during active drag / grip operations.
    /// Returns false when foreground draw list is approaching 16-bit index limit.
    private func _foregroundCanAdd(estimatedVerts: Int) -> Bool {
        guard _foregroundVertexEstimate + estimatedVerts < _foregroundVertexLimit else { return false }
        _foregroundVertexEstimate += estimatedVerts
        return true
    }

    private func renderCrosshairCursor(cam: CameraTransform, origin: (x: Float, y: Float) = (0, 0)) {
        let io = ImGuiGetIO()
        if let wantCapture = io?.pointee.WantCaptureMouse, wantCapture {
            return
        }
        guard !engine.interaction.dragActive && !engine.interaction.gripActive && !engine.interaction.panActive else { return }
        // Show crosshair during commands (MOVE, ROTATE, SCALE, feature commands) —
        // the user needs to see the cursor to pick points.

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        drawCrosshairArms(
            center: ImVec2(
                x: engine.interaction.lastMouseX + origin.x,
                y: engine.interaction.lastMouseY + origin.y),
            drawList: drawList)
    }

    /// The crosshair glyph at a screen point (shared by the primary cursor
    /// and the mirrored split-pane cursors).
    private func drawCrosshairArms(center: ImVec2, drawList: UnsafeMutablePointer<ImDrawList>?) {
        let crosshair = engine.ui.isViewportBackgroundLight ? (20, 38, 52, 120) : (255, 255, 255, 120)
        let col = makeImCol32(
            r: UInt8(crosshair.0),
            g: UInt8(crosshair.1),
            b: UInt8(crosshair.2),
            a: UInt8(crosshair.3))
        let cx = center.x
        let cy = center.y
        let armLen: Float = 56  // pixels from center in each direction
        let gap: Float = 0      // small gap around center so the intersection is visible

        // Rotate crosshair by SNAPANG if set
        let angleRad = Float(engine.snap.snapAngle * .pi / 180.0)
        let cosA = cos(angleRad)
        let sinA = sin(angleRad)

        // Arm end points in unrotated frame
        let up    = (dx: Float(0),  dy: Float(-armLen))
        let down  = (dx: Float(0),  dy: Float(armLen))
        let left  = (dx: Float(-armLen), dy: Float(0))
        let right = (dx: Float(armLen),  dy: Float(0))
        let upGap    = (dx: Float(0), dy: Float(-gap))
        let downGap  = (dx: Float(0), dy: Float(gap))
        let leftGap  = (dx: Float(-gap), dy: Float(0))
        let rightGap = (dx: Float(gap),  dy: Float(0))

        func rot(_ d: (dx: Float, dy: Float)) -> (Float, Float) {
            (cx + d.dx * cosA - d.dy * sinA, cy + d.dx * sinA + d.dy * cosA)
        }

        let (ux1, uy1) = rot(up);    let (ux2, uy2) = rot(upGap)
        let (dx1, dy1) = rot(downGap); let (dx2, dy2) = rot(down)
        let (lx1, ly1) = rot(left);  let (lx2, ly2) = rot(leftGap)
        let (rx1, ry1) = rot(rightGap); let (rx2, ry2) = rot(right)

        ImDrawListAddLine(drawList, ImVec2(x: ux1, y: uy1), ImVec2(x: ux2, y: uy2), col, 2.0)
        ImDrawListAddLine(drawList, ImVec2(x: dx1, y: dy1), ImVec2(x: dx2, y: dy2), col, 2.0)
        ImDrawListAddLine(drawList, ImVec2(x: lx1, y: ly1), ImVec2(x: lx2, y: ly2), col, 2.0)
        ImDrawListAddLine(drawList, ImVec2(x: rx1, y: ry1), ImVec2(x: rx2, y: ry2), col, 2.0)
        _foregroundVertexEstimate += 24  // 4 thick lines ≈ 6 verts each
    }

    /// Global cursor for split panes: the crosshair follows the physical
    /// mouse in whichever pane it hovers (focused or not — the OS cursor is
    /// hidden over the whole canvas), and mirrors at the same world point
    /// into every other pane sharing that tab + drawing view (same
    /// coordinate space). Display only; CAD input stays focused-pane-local.
    private func renderSplitCrosshairs(
        leaves: [(id: UUID, tabID: UUID?, rect: PaneRect)],
        focusedID: UUID,
        activeID: UUID?
    ) {
        let io = ImGuiGetIO()
        if let wantCapture = io?.pointee.WantCaptureMouse, wantCapture {
            return
        }
        guard !engine.interaction.dragActive && !engine.interaction.gripActive && !engine.interaction.panActive,
              let io else { return }
        let mouse = io.pointee.MousePos
        func containsMouse(_ rect: PaneRect) -> Bool {
            mouse.x >= rect.x && mouse.x < rect.x + rect.w
                && mouse.y >= rect.y && mouse.y < rect.y + rect.h
        }
        guard let hover = leaves.first(where: { containsMouse($0.rect) }),
              let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }

        /// The (tab, drawing view) coordinate space a leaf shows.
        func space(of leaf: (id: UUID, tabID: UUID?, rect: PaneRect)) -> (UUID, Int)? {
            guard let tabID = leaf.tabID,
                  let tab = engine.tabManager.tab(for: tabID) else { return nil }
            if leaf.id == focusedID && tabID == activeID {
                return (tabID, tab.activeViewIndex)
            }
            let entry = engine.paneViews.entry(leafID: leaf.id, tabID: tabID)
            let idx = min(
                max(entry?.viewIndex ?? tab.activeViewIndex, 0),
                max(tab.drawingViews.count - 1, 0))
            return (tabID, idx)
        }
        func transform(of leaf: (id: UUID, tabID: UUID?, rect: PaneRect)) -> CameraTransform? {
            let camera: EngineCameraManager?
            if leaf.id == focusedID && leaf.tabID == activeID {
                camera = engine.camera
            } else {
                camera = paneCtxs[leaf.id]?.camera
            }
            return camera?.transformForSubRect(
                originX: Double(leaf.rect.x), originY: Double(leaf.rect.y),
                width: Int32(leaf.rect.w), height: Int32(leaf.rect.h))
        }

        let hoverSpace = space(of: hover)
        let world: (Double, Double)? = transform(of: hover).map {
            EngineCameraManager.screenToWorld(screenX: mouse.x, screenY: mouse.y, cam: $0)
        }

        for leaf in leaves {
            let center: ImVec2?
            if leaf.id == hover.id {
                center = mouse
            } else if let world, let hoverSpace,
                      let leafSpace = space(of: leaf),
                      leafSpace.0 == hoverSpace.0 && leafSpace.1 == hoverSpace.1,
                      let t = transform(of: leaf) {
                let p = EngineCameraManager.worldToScreen(
                    worldX: world.0, worldY: world.1, cam: t)
                let inside = p.x >= leaf.rect.x && p.x < leaf.rect.x + leaf.rect.w
                    && p.y >= leaf.rect.y && p.y < leaf.rect.y + leaf.rect.h
                center = inside ? ImVec2(x: p.x, y: p.y) : nil
            } else {
                center = nil
            }
            guard let center else { continue }
            pushForegroundClip(leaf.rect)
            drawCrosshairArms(center: center, drawList: drawList)
            popForegroundClip()
        }
    }

    // MARK: - Grid

    /// Draw the background grid when `engine.snap.gridVisible` is true.
    /// Grid lines are drawn as thin lines via the ImGui foreground draw list,
    /// making them non-selectable (not part of the CAD vertex buffer or ID-buffer pick pass).
    /// The visual spacing adapts to the current zoom level so a consistent density
    /// of lines is visible at all zoom levels.
    private func renderGrid(
        cam: CameraTransform,
        viewportWidth: Float? = nil,
        viewportHeight: Float? = nil,
        cameraZoom: Double? = nil,
        viewport: (minX: Double, minY: Double, maxX: Double, maxY: Double)? = nil,
        useLightPalette: Bool? = nil
    ) {
        guard engine.snap.gridVisible else { return }

        let gridW = viewportWidth ?? Float(engine.windowWidth)
        let gridH = viewportHeight ?? Float(engine.windowHeight)
        let zoom = cameraZoom ?? engine.camera.zoom
        let spacing = engine.snap.effectiveGridSpacing(windowWidth: Int32(gridW), cameraZoom: zoom)
        let ox = engine.snap.gridOriginX
        let oy = engine.snap.gridOriginY

        let vp = viewport ?? engine.camera.worldViewportRect(
            windowWidth: Int32(gridW), windowHeight: Int32(gridH))
        // Expand viewport slightly so lines don't pop in/out at edges
        let margin = spacing
        let vpMinX = vp.minX - margin
        let vpMinY = vp.minY - margin
        let vpMaxX = vp.maxX + margin
        let vpMaxY = vp.maxY + margin

        let drawList = igGetBackgroundDrawList(nil)
        // Subtle gray, semi-transparent, selected from the effective viewport background.
        let gridCol = (useLightPalette ?? engine.ui.isViewportBackgroundLight)
            ? makeImCol32(r: 180, g: 180, b: 180, a: 60)
            : makeImCol32(r: 80, g: 80, b: 80, a: 50)
        let lineThickness: Float = 1.0

        // Helper: world coordinate to screen point
        func worldToScreen(_ wx: Double, _ wy: Double) -> SDL_FPoint {
            EngineCameraManager.worldToScreen(worldX: wx, worldY: wy, cam: cam)
        }

        // Determine first/last grid line indices
        let firstIX = Int(ceil((vpMinX - ox) / spacing))
        let lastIX  = Int(floor((vpMaxX - ox) / spacing))
        let firstIY = Int(ceil((vpMinY - oy) / spacing))
        let lastIY  = Int(floor((vpMaxY - oy) / spacing))

        // Cap grid lines to avoid overflowing ImGui's 16-bit foreground draw list.
        // 2 verts per thin line; safe upper bound leaves room for other overlays.
        let maxGridLines = (_foregroundVertexLimit - _foregroundVertexEstimate) / 2
        guard maxGridLines > 0 else { return }

        // Vertical grid lines
        var drawn = 0
        for i in firstIX...lastIX {
            if drawn >= maxGridLines { break }
            let worldX = ox + Double(i) * spacing
            let p1 = worldToScreen(worldX, vpMinY)
            let p2 = worldToScreen(worldX, vpMaxY)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), gridCol, lineThickness)
            drawn += 1
        }

        // Horizontal grid lines
        for i in firstIY...lastIY {
            if drawn >= maxGridLines { break }
            let worldY = oy + Double(i) * spacing
            let p1 = worldToScreen(vpMinX, worldY)
            let p2 = worldToScreen(vpMaxX, worldY)
            ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), gridCol, lineThickness)
            drawn += 1
        }
        _foregroundVertexEstimate += drawn * 2
    }

    // MARK: - Snap Indicator

    /// Draw a small green square at the snap point when the cursor is within
    /// snap threshold of an entity's anchor point during an active draw command.
    private func renderSnapIndicator(cam: CameraTransform) {
        guard let snap = engine.snap.currentSnapResult else { return }
        // Show snap indicator when any tool that uses snapping is active.
        let toolActive = engine.commandProcessor.activeFeatureCommand != nil
            || engine.commandProcessor.activeCommand != nil
            || engine.interaction.gripActive
            || engine.interaction.dragActive
        guard toolActive else { return }

        let drawList = igGetBackgroundDrawList(nil)
        let sp = EngineCameraManager.worldToScreen(worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)
        let size: Float = 6
        let half: Float = size / 2

        // Outer ring (9×9)
        let outerCol = makeImCol32(r: 0, g: 255, b: 128, a: 200)
        let outerHalf: Float = 2.5 + half
        ImDrawListAddRect(drawList,
            ImVec2(x: sp.x - outerHalf, y: sp.y - outerHalf),
            ImVec2(x: sp.x + outerHalf, y: sp.y + outerHalf),
            outerCol, 0.0, 1.5, 0)

        // Inner filled square (6×6)
        let fillCol = makeImCol32(r: 0, g: 255, b: 128, a: 180)
        ImDrawListAddRectFilled(drawList,
            ImVec2(x: sp.x - half, y: sp.y - half),
            ImVec2(x: sp.x + half, y: sp.y + half),
            fillCol, 0.0, 0)
        _foregroundVertexEstimate += 10  // 2 rects (outline + filled) ≈ 10 verts
    }

    // MARK: - Polar Tracking Overlay

    /// Renders a dashed line from the reference point to the polar-snapped cursor
    /// position, plus a tooltip showing distance and angle.
    /// Dashed-line helper. Draws alternating dash/gap segments from `a` to `b`.
    private func drawDashedLine(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        from a: ImVec2,
        to b: ImVec2,
        color: UInt32,
        thickness: Float
    ) {
        let dashLen: Float = 6
        let gapLen: Float = 4
        let totalLen = sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
        guard totalLen > 0.001 else { return }

        let ux = (b.x - a.x) / totalLen
        let uy = (b.y - a.y) / totalLen

        var t: Float = 0
        var draw = true

        while t < totalLen {
            let segLen = min(draw ? dashLen : gapLen, totalLen - t)
            if draw {
                ImDrawListAddLine(
                    drawList,
                    ImVec2(x: a.x + ux * t, y: a.y + uy * t),
                    ImVec2(x: a.x + ux * (t + segLen), y: a.y + uy * (t + segLen)),
                    color,
                    thickness
                )
            }
            t += segLen
            draw.toggle()
        }
    }

    private func renderPolarTracking(cam: CameraTransform) {
        guard engine.snap.polarTrackingEnabled || engine.snap.objectSnapTrackingEnabled || engine.snap.extensionSnapEnabled else { return }
        guard let polar = engine.snap.lastPolarResult else { return }

        let drawList = igGetBackgroundDrawList(nil)

        let angleRad = polar.angleDeg * .pi / 180.0
        let farWorld = 10000.0 / max(Double(cam.camZoom), 0.001)

        let p1 = Vector3(
            x: polar.reference.x - cos(angleRad) * farWorld,
            y: polar.reference.y - sin(angleRad) * farWorld,
            z: 0
        )

        let p2 = Vector3(
            x: polar.reference.x + cos(angleRad) * farWorld,
            y: polar.reference.y + sin(angleRad) * farWorld,
            z: 0
        )

        let startSp = EngineCameraManager.worldToScreen(
            worldX: p1.x,
            worldY: p1.y,
            cam: cam
        )

        let endSp = EngineCameraManager.worldToScreen(
            worldX: p2.x,
            worldY: p2.y,
            cam: cam
        )

        let snapSp = EngineCameraManager.worldToScreen(
            worldX: polar.worldPos.x,
            worldY: polar.worldPos.y,
            cam: cam
        )

        drawDashedLine(
            drawList: drawList,
            from: ImVec2(x: startSp.x, y: startSp.y),
            to: ImVec2(x: endSp.x, y: endSp.y),
            color: makeImCol32(r: 255, g: 200, b: 0, a: 180),
            thickness: 1.2
        )

        // Tooltip: distance + angle
        let tipText = String(format: "%.1f < %.0f°", polar.distance, polar.angleDeg)
        let tipCol = makeImCol32(r: 255, g: 220, b: 60, a: 255)
        let tipX = snapSp.x + 10
        let tipY = snapSp.y - 18
        ImDrawListAddText(drawList, ImVec2(x: tipX, y: tipY), tipCol, tipText, nil)
        _foregroundVertexEstimate += 4
    }

    // MARK: - OTRACK Overlay

    private func renderOTRACKOverlay(cam: CameraTransform) {
        guard engine.snap.objectSnapTrackingEnabled else { return }
        let points = engine.snap.snapTrackingEngine.trackingPoints
        guard !points.isEmpty else { return }

        let drawList = igGetBackgroundDrawList(nil)
        let plusCol = makeImCol32(r: 0, g: 255, b: 128, a: 220)
        let crossSize: Float = 5

        for tp in points {
            let sp = EngineCameraManager.worldToScreen(
                worldX: tp.worldPos.x, worldY: tp.worldPos.y, cam: cam)

            // `+` marker at tracking point.
            ImDrawListAddLine(drawList,
                ImVec2(x: sp.x - crossSize, y: sp.y),
                ImVec2(x: sp.x + crossSize, y: sp.y), plusCol, 1.5)
            ImDrawListAddLine(drawList,
                ImVec2(x: sp.x, y: sp.y - crossSize),
                ImVec2(x: sp.x, y: sp.y + crossSize), plusCol, 1.5)
            _foregroundVertexEstimate += 8
        }
    }

    // MARK: - Extension Snap Overlay

    /// Renders a dashed extension line from the entity endpoint along the
    /// extension direction when extension snapping is active and the cursor
    /// is on an extension snap.
    private func renderExtensionSnapOverlay(cam: CameraTransform) {
        guard engine.snap.extensionSnapEnabled else { return }
        guard let snap = engine.snap.currentSnapResult else { return }
        guard engine.snap.lastPolarResult == nil else { return }
        guard case .nearest = snap.anchor else { return }

        let isRealEntity = snap.entityHandle != SnapEngine.gridSnapSentinel
            && snap.entityHandle != PhrostEngine.drawingSnapSentinel
        guard isRealEntity else { return }
        guard let entity = engine.document.entity(for: snap.entityHandle) else { return }
        guard let geom = entity.localGeometry, !geom.isEmpty else { return }

        var hasExtensionSource = false
        for prim in geom {
            if case .line = prim { hasExtensionSource = true; break }
            if case .arc = prim { hasExtensionSource = true; break }
        }
        guard hasExtensionSource else { return }

        var nearestVertexDist = Double.greatestFiniteMagnitude
        var nearestVertexPos: Vector3? = nil
        for ap in entity.anchorPoints {
            if case .vertex(_, _) = ap {
                let wp = ap.worldPosition(transform: entity.transform)
                let d = wp.distance(to: snap.worldPos)
                if d < nearestVertexDist {
                    nearestVertexDist = d
                    nearestVertexPos = wp
                }
            }
        }

        if let vp = nearestVertexPos {
            // MUST use transformWorldToScreen and pass cam
            let vsp = EngineCameraManager.worldToScreen(worldX: vp.x, worldY: vp.y, cam: cam)
            let ssp = EngineCameraManager.worldToScreen(worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)
            let drawList = igGetBackgroundDrawList(nil)
            
            // Calculate Perceived Luminance for a subtle line
            let bg = engine.ui.backgroundColor
            let luminance = (0.299 * bg.r) + (0.587 * bg.g) + (0.114 * bg.b)
            let trackingAlpha: Float = 0.25
            let trackingColorVec = luminance < 0.5 
                ? ImVec4(x: 1.0, y: 1.0, z: 1.0, w: trackingAlpha)
                : ImVec4(x: 0.0, y: 0.0, z: 0.0, w: trackingAlpha)
            let trackingColorU32 = igGetColorU32_Vec4(trackingColorVec)

            // Use the new dashed line utility!
            var dx = ssp.x - vsp.x
            var dy = ssp.y - vsp.y
            let len = Float(sqrt(Double(dx * dx + dy * dy)))
            guard len > 0.001 else { return }

            dx /= len
            dy /= len

            let endSp = ImVec2(
                x: ssp.x + dx * 10000,
                y: ssp.y + dy * 10000
            )

            renderDashedLine(
                p1: ImVec2(x: vsp.x, y: vsp.y),
                p2: endSp,
                color: trackingColorU32,
                dashLength: 8.0,
                gapLength: 6.0,
                thickness: 1.0,
                drawList: drawList
            )
            _foregroundVertexEstimate += 2
        }
    }

    private func renderRectSelectBox(origin: (x: Float, y: Float) = (0, 0)) {
        guard engine.interaction.rectSelectActive else { return }
        let cam = engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let q1 = EngineCameraManager.worldToScreen(
            worldX: engine.interaction.rectSelectStartX, worldY: engine.interaction.rectSelectStartY, cam: cam)
        let q3 = EngineCameraManager.worldToScreen(
            worldX: engine.interaction.rectSelectCurrentX, worldY: engine.interaction.rectSelectCurrentY, cam: cam)
        let p1 = SDL_FPoint(x: q1.x + origin.x, y: q1.y + origin.y)
        let p3 = SDL_FPoint(x: q3.x + origin.x, y: q3.y + origin.y)
        let p2 = SDL_FPoint(x: p3.x, y: p1.y)
        let p4 = SDL_FPoint(x: p1.x, y: p3.y)
        let style: CADSelectionManager.RectSelectStyle =
            (engine.interaction.lastMouseX >= engine.interaction.rectSelectScreenStartX) ? .window : .crossing
        let hc: (UInt8, UInt8, UInt8, UInt8)
        switch engine.interaction.cadRectSelectMode {
        case .replace:
            hc = (style == .window) ? (0, 128, 255, 255) : (64, 180, 255, 255)
        case .add:
            hc = (style == .window) ? (0, 128, 255, 255) : (64, 180, 255, 255)
        case .subtract:
            hc = (255, 80, 80, 255)
        }
        let drawList = igGetBackgroundDrawList(nil)
        let col = makeImCol32(r: hc.0, g: hc.1, b: hc.2, a: hc.3)
        
        ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), col, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y), col, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: p3.x, y: p3.y), ImVec2(x: p4.x, y: p4.y), col, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: p4.x, y: p4.y), ImVec2(x: p1.x, y: p1.y), col, 1.0)
        _foregroundVertexEstimate += 8  // 4 thin lines ≈ 8 verts
    }

    // MARK: - Move Ghost Preview

    /// When MOVE command is active and a base point has been selected,
    /// renders an exact outline preview of the selected entities at the proposed
    /// destination.
    private func renderMoveGhostPreview(cam: CameraTransform) {
        guard engine.commandProcessor.activeCommand == "MOVE",
              let base = engine.commandProcessor.commandRefPoint,
              engine.cadSelection.hasSelection
        else { return }

        let ghostX = engine.commandProcessor._moveGhostWorldX
        let ghostY = engine.commandProcessor._moveGhostWorldY
        let dx = ghostX - base.0
        let dy = ghostY - base.1

        let _ = EngineCameraManager.worldToScreen(worldX: base.0, worldY: base.1, cam: cam)
        let _ = EngineCameraManager.worldToScreen(worldX: ghostX, worldY: ghostY, cam: cam)

        let drawList = igGetBackgroundDrawList(nil)
        let color = makeImCol32(r: 255, g: 200, b: 64, a: 190)
        let lineWidth: Float = 1.5
        var remainingSegments = 12000

        for handle in engine.cadSelection.selectedHandles {
            guard remainingSegments > 0 else { break }
            guard let entity = engine.document.entity(for: handle),
                  let geometry = engine.document.resolvedGeometry(for: entity)
            else { continue }

            renderMoveGhostGeometry(
                geometry,
                transform: entity.transform,
                dx: dx,
                dy: dy,
                cam: cam,
                drawList: drawList,
                color: color,
                lineWidth: lineWidth,
                remainingSegments: &remainingSegments)
        }
    }

    private func renderMoveGhostGeometry(
        _ geometry: [CADPrimitive],
        transform: Transform3D,
        dx: Double,
        dy: Double,
        cam: CameraTransform,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        color: UInt32,
        lineWidth: Float,
        remainingSegments: inout Int
    ) {
        for primitive in geometry {
            guard remainingSegments > 0 else { return }
            renderMoveGhostPrimitive(
                primitive,
                transform: transform,
                dx: dx,
                dy: dy,
                cam: cam,
                drawList: drawList,
                color: color,
                lineWidth: lineWidth,
                remainingSegments: &remainingSegments)
        }
    }

    private func renderMoveGhostPrimitive(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        dx: Double,
        dy: Double,
        cam: CameraTransform,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        color: UInt32,
        lineWidth: Float,
        remainingSegments: inout Int
    ) {
        func movedWorld(_ point: Vector3) -> Vector3 {
            let p = transform.transformPoint(point)
            return Vector3(x: p.x + dx, y: p.y + dy, z: p.z)
        }

        func drawPath(_ points: [Vector3], closed: Bool) {
            guard points.count >= 2, remainingSegments > 0 else { return }
            let count = closed ? points.count : points.count - 1
            guard count > 0 else { return }

            for i in 0..<count {
                guard remainingSegments > 0 else { return }
                let a = movedWorld(points[i])
                let b = movedWorld(points[(i + 1) % points.count])
                let s0 = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
                ImDrawListAddLine(
                    drawList,
                    ImVec2(x: s0.x, y: s0.y),
                    ImVec2(x: s1.x, y: s1.y),
                    color,
                    lineWidth)
                remainingSegments -= 1
            }
        }

        func circlePoints(center: Vector3, radius: Double, segments: Int = 64) -> [Vector3] {
            guard radius > 1e-12 else { return [] }
            return (0..<segments).map { i in
                let a = Double(i) * 2.0 * .pi / Double(segments)
                return Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)
            }
        }

        func arcPoints(center: Vector3, radius: Double, startAngle: Double, endAngle: Double, segments: Int = 32) -> [Vector3] {
            guard radius > 1e-12 else { return [] }
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * .pi }
            return (0...segments).map { i in
                let t = Double(i) / Double(segments)
                let a = startAngle + span * t
                return Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)
            }
        }

        func ellipsePoints(center: Vector3, majorAxis: Vector3, minorRatio: Double, segments: Int = 64) -> [Vector3] {
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            guard majorLen > 1e-12, minorLen > 1e-12 else { return [] }
            let rot = atan2(majorAxis.y, majorAxis.x)
            let c = cos(rot)
            let s = sin(rot)
            return (0..<segments).map { i in
                let t = Double(i) * 2.0 * .pi / Double(segments)
                let px = cos(t) * majorLen
                let py = sin(t) * minorLen
                return Vector3(
                    x: center.x + px * c - py * s,
                    y: center.y + px * s + py * c,
                    z: center.z)
            }
        }

        switch primitive {
        case .table: break
        case .point(let position, _):
            let p = movedWorld(position)
            let sp = EngineCameraManager.worldToScreen(worldX: p.x, worldY: p.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sp.x - 4, y: sp.y), ImVec2(x: sp.x + 4, y: sp.y), color, lineWidth)
            ImDrawListAddLine(drawList, ImVec2(x: sp.x, y: sp.y - 4), ImVec2(x: sp.x, y: sp.y + 4), color, lineWidth)
            remainingSegments -= 2

        case .line(let start, let end, _):
            drawPath([start, end], closed: false)

        case .rect(let origin, let size, _),
             .fillRect(let origin, let size, _):
            drawPath([
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ], closed: true)

        case .polygon(let points, _),
             .fillPolygon(let points, _):
            drawPath(points, closed: true)

        case .fillComplexPolygon(let outer, let holes, _),
             .gradient(let outer, let holes, _, _, _, _):
            drawPath(outer, closed: true)
            for hole in holes { drawPath(hole, closed: true) }

        case .polyline(let path, _):
            drawPath(path.tessellatedPoints(), closed: path.isClosed)

        case .circle(let center, let radius, _):
            drawPath(circlePoints(center: center, radius: radius), closed: true)

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            drawPath(arcPoints(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle), closed: false)

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            guard controlPoints.count >= 2 else { return }
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let pts = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: w,
                segmentsPerSpan: 12)
            drawPath(pts, closed: false)

        case .penStroke(let vertices, _, _):
            guard vertices.count >= 2 else { return }
            drawPath(vertices.map { $0.position }, closed: false)

        case .text(let position, let text, let height, let rotation, _, let alignH, let alignV, let mtextWidth, _):
            let bounds = CADEntity.estimateTextLocalBounds(
                text: text,
                height: height,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: mtextWidth)
            let c = cos(rotation)
            let s = sin(rotation)
            func textPoint(_ x: Double, _ y: Double) -> Vector3 {
                Vector3(
                    x: position.x + x * c - y * s,
                    y: position.y + x * s + y * c,
                    z: position.z)
            }
            drawPath([
                textPoint(bounds.minX, bounds.minY),
                textPoint(bounds.maxX, bounds.minY),
                textPoint(bounds.maxX, bounds.maxY),
                textPoint(bounds.minX, bounds.maxY),
            ], closed: true)

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            drawPath(ellipsePoints(center: center, majorAxis: majorAxis, minorRatio: minorRatio), closed: true)

        case .hatch(let boundary, _, _, _, _, _):
            drawPath(boundary, closed: true)
        case .hatchPath(let boundary, _, _, _, _, _, _):
            drawPath(boundary.tessellatedPoints(), closed: true)

        case .ray(let start, let direction, _):
            let end = Vector3(x: start.x + direction.x * 1000.0, y: start.y + direction.y * 1000.0, z: start.z + direction.z * 1000.0)
            drawPath([start, end], closed: false)

        case .xline(let point, let direction, _):
            let back = Vector3(x: point.x - direction.x * 1000.0, y: point.y - direction.y * 1000.0, z: point.z - direction.z * 1000.0)
            let end = Vector3(x: point.x + direction.x * 1000.0, y: point.y + direction.y * 1000.0, z: point.z + direction.z * 1000.0)
            drawPath([back, end], closed: false)

        case .image(let insertion, let uAxis, let vAxis, _, let clipBoundary, _):
            if let clipBoundary, clipBoundary.count >= 2 {
                drawPath(clipBoundary, closed: true)
            } else {
                drawPath([
                    insertion,
                    Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z),
                    Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z),
                    Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z),
                ], closed: true)
            }
        }
    }

    /// Dynamically renders the currently dragged entities on top of the CAD buffer.
    /// Because the entities are hidden in the shader (to avoid full scene rebuilds),
    /// we draw their exact current geometry using ImGui here.
    private func renderInteractivePreview(cam: CameraTransform) {
        let dragOrGrip = engine.interaction.dragActive || engine.interaction.gripActive
        guard dragOrGrip || !engine.interaction.pendingPreviewHandles.isEmpty else { return }

        let isLight = engine.ui.isViewportBackgroundLight
        let drawList = igGetBackgroundDrawList(nil)
        let lw: Float = 1.5
        
        let handlesToDraw = dragOrGrip ? engine.cadSelection.selectedHandles : engine.interaction.pendingPreviewHandles
        
        let isDragActive = engine.interaction.dragActive
        let isPendingBulkDrag = !engine.interaction.pendingPreviewHandles.isEmpty && engine.interaction.pendingPreviewIsBulkDrag && !(engine.interaction.dragActive || engine.interaction.gripActive)
        let applyDelta = isDragActive || isPendingBulkDrag
        let dragOffsetX = applyDelta ? engine.interaction.dragTotalWorldX : 0.0
        let dragOffsetY = applyDelta ? engine.interaction.dragTotalWorldY : 0.0

        for handle in handlesToDraw {
            let color: UInt32
            if let entity = engine.document.entity(for: handle),
               let layer = engine.document.layer(for: entity.layerID) {
                let rgba = layer.color.displayAdjusted(forLightBackground: isLight)
                color = makeImCol32(r: rgba.r, g: rgba.g, b: rgba.b, a: 255)
            } else {
                color = makeImCol32(r: 255, g: 255, b: 255, a: 255)
            }

            engine.cadBridge.vertexEditor.forEachWorldSegment(handle: handle, in: engine.geometryManager) { x1, y1, x2, y2 in
                let s0 = EngineCameraManager.worldToScreen(worldX: x1 + dragOffsetX, worldY: y1 + dragOffsetY, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: x2 + dragOffsetX, worldY: y2 + dragOffsetY, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lw)
            }

            if let entity = engine.document.entity(for: handle),
               entity.xdata["dxf.text"] != nil,
               let box = entity.worldBoundingBox {
                let p0 = EngineCameraManager.worldToScreen(worldX: box.min.x, worldY: box.min.y, cam: cam)
                let p1 = EngineCameraManager.worldToScreen(worldX: box.max.x, worldY: box.min.y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: box.max.x, worldY: box.max.y, cam: cam)
                let p3 = EngineCameraManager.worldToScreen(worldX: box.min.x, worldY: box.max.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p0.x, y: p0.y), ImVec2(x: p1.x, y: p1.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p3.x, y: p3.y), ImVec2(x: p0.x, y: p0.y), color, lw)
            }
        }
    }

    private func renderSprite(
        _ sprite: Sprite, deltaSec: Double, cam: CameraTransform,
        viewportWidth: Float? = nil, viewportHeight: Float? = nil,
        useLightPalette: Bool? = nil, cullOrigin: (x: Float, y: Float) = (0, 0)
    ) {
        if sprite.speed.0 != 0 || sprite.speed.1 != 0 {
            sprite.position.0 += sprite.speed.0 * deltaSec
            sprite.position.1 += sprite.speed.1 * deltaSec
        }

        // Viewport culling: skip sprites whose entire quad is off-screen.
        // Uses AABB of the 4 corners, not the center point — prevents large
        // images from disappearing when zoomed in (center off-screen but
        // part of the image still visible).
        let w = sprite.size.0 * sprite.scale.0
        let h = sprite.size.1 * sprite.scale.1
        let ar = sprite.rotate.2 * .pi / 180.0
        let s = sin(ar)
        let c = cos(ar)
        let hw = w / 2
        let hh = h / 2
        let px = sprite.position.0 + hw
        let py = sprite.position.1 + hh

        let p1: SDL_FPoint
        let p2: SDL_FPoint
        let p3: SDL_FPoint
        let p4: SDL_FPoint
        if let quad = sprite.worldQuad, quad.count == 4 {
            let base = sprite.worldQuadBasePosition ?? (sprite.position.0, sprite.position.1)
            let dx = sprite.position.0 - base.0
            let dy = sprite.position.1 - base.1
            p1 = EngineCameraManager.worldToScreen(worldX: quad[0].x + dx, worldY: quad[0].y + dy, cam: cam)
            p2 = EngineCameraManager.worldToScreen(worldX: quad[1].x + dx, worldY: quad[1].y + dy, cam: cam)
            p3 = EngineCameraManager.worldToScreen(worldX: quad[2].x + dx, worldY: quad[2].y + dy, cam: cam)
            p4 = EngineCameraManager.worldToScreen(worldX: quad[3].x + dx, worldY: quad[3].y + dy, cam: cam)
        } else {
            let topShift = sprite.shearX * h
            func transformedCorner(_ localX: Double, _ localY: Double) -> SDL_FPoint {
                let shiftedX = localX + (localY > 0 ? topShift : 0)
                return EngineCameraManager.worldToScreen(
                    worldX: px + shiftedX * c - localY * s,
                    worldY: py + shiftedX * s + localY * c,
                    cam: cam)
            }
            p1 = transformedCorner(-hw, -hh)
            p2 = transformedCorner(hw, -hh)
            p3 = transformedCorner(hw, hh)
            p4 = transformedCorner(-hw, hh)
        }

        // AABB culling: only skip if the entire quad is off-screen
        let margin: Float = 0
        let minX = min(p1.x, p2.x, p3.x, p4.x)
        let maxX = max(p1.x, p2.x, p3.x, p4.x)
        let minY = min(p1.y, p2.y, p3.y, p4.y)
        let maxY = max(p1.y, p2.y, p3.y, p4.y)
        let cullW = viewportWidth ?? Float(engine.windowWidth)
        let cullH = viewportHeight ?? Float(engine.windowHeight)
        if maxX < cullOrigin.x - margin || minX > cullOrigin.x + cullW + margin
            || maxY < cullOrigin.y - margin || minY > cullOrigin.y + cullH + margin {
            return
        }

        let isLight = useLightPalette ?? engine.ui.isViewportBackgroundLight
        let drawList = igGetBackgroundDrawList(nil)
        let spriteColor = isLight ? sprite.adjustedColorLight : sprite.adjustedColorDark
        let col = makeImCol32(r: spriteColor.0, g: spriteColor.1, b: spriteColor.2, a: spriteColor.3)

        let ip1 = ImVec2(x: p1.x, y: p1.y)
        let ip2 = ImVec2(x: p2.x, y: p2.y)
        let ip3 = ImVec2(x: p3.x, y: p3.y)
        let ip4 = ImVec2(x: p4.x, y: p4.y)

        // CAD TTF glyphs are ImGui texture quads, while the rest of the drawing
        // is transformed by the CAD GPU pipeline. On some Windows/D3D12 setups
        // the textured path can appear a few pixels behind during rapid pans.
        // A replacement outline is rendered in the CAD GPU path while panning,
        // so suppress the lagging ImGui texture quad entirely.
        if sprite.useBoundsWhilePanning
            && _panProxyActiveThisFrame
        {
            return
        }

        let clipOffset: (Double, Double)
        if let base = sprite.clipBasePosition {
            clipOffset = (sprite.position.0 - base.0, sprite.position.1 - base.1)
        } else {
            clipOffset = (0, 0)
        }
        let clipScreen = sprite.clipPolygon?.map {
            EngineCameraManager.worldToScreen(
                worldX: $0.x + clipOffset.0,
                worldY: $0.y + clipOffset.1,
                cam: cam)
        }
        let clippedTriangles: [CADRenderClipper.TexturedTriangle]?
        if let clipScreen, clipScreen.count >= 3 {
            clippedTriangles = CADRenderClipper.texturedTriangles(
                quad: [p1, p2, p3, p4],
                polygon: clipScreen,
                inverted: sprite.clipInverted)
        } else {
            clippedTriangles = nil
        }

        if let tex = sprite.texture {
            let texRefPtr = ImTextureRef_ImTextureRef_TextureID(UInt64(UInt(bitPattern: tex)))
            defer { ImTextureRef_destroy(texRefPtr) }
            let texRef = texRefPtr!.pointee

            if let clippedTriangles {
                for triangle in clippedTriangles {
                    let a = ImVec2(x: triangle.a.point.x, y: triangle.a.point.y)
                    let b = ImVec2(x: triangle.b.point.x, y: triangle.b.point.y)
                    let c = ImVec2(x: triangle.c.point.x, y: triangle.c.point.y)
                    let auv = ImVec2(x: triangle.a.uv.x, y: triangle.a.uv.y)
                    let buv = ImVec2(x: triangle.b.uv.x, y: triangle.b.uv.y)
                    let cuv = ImVec2(x: triangle.c.uv.x, y: triangle.c.uv.y)
                    ImDrawListAddImageQuad(
                        drawList, texRef,
                        a, b, c, c,
                        auv, buv, cuv, cuv,
                        col)
                }
            } else {
                ImDrawListAddImageQuad(
                    drawList,
                    texRef,
                    ip1, ip2, ip3, ip4,
                    ImVec2(x: 0, y: 0), ImVec2(x: 1, y: 0), ImVec2(x: 1, y: 1), ImVec2(x: 0, y: 1),
                    col
                )
            }
        } else if let clippedTriangles {
            for triangle in clippedTriangles {
                ImDrawListAddTriangleFilled(
                    drawList,
                    ImVec2(x: triangle.a.point.x, y: triangle.a.point.y),
                    ImVec2(x: triangle.b.point.x, y: triangle.b.point.y),
                    ImVec2(x: triangle.c.point.x, y: triangle.c.point.y),
                    col)
            }
        } else {
            ImDrawListAddQuadFilled(drawList, ip1, ip2, ip3, ip4, col)
        }
    }

    private func renderObjectPickerPopup() {
        guard engine.interaction.popupNeedsOpen || (!engine.interaction.popupHitList.isEmpty) else { return }

        if engine.interaction.popupNeedsOpen {
            engine.interaction.popupNeedsOpen = false
            let displayW = engine.io.pointee.DisplaySize.x
            let displayH = engine.io.pointee.DisplaySize.y
            let estW: Float = 220
            let estH: Float = Float(engine.interaction.popupHitList.count) * ImGuiGetTextLineHeightWithSpacing() + 50
            var px = engine.interaction.popupScreenX + 12
            var py = engine.interaction.popupScreenY + 8
            let pivotX: Float = 0
            var pivotY: Float = 0
            if px + estW > displayW {
                px = engine.interaction.popupScreenX - estW - 8
                if px < 4 { px = 4 }
            }
            if py + estH > displayH {
                py = engine.interaction.popupScreenY - estH - 8
                pivotY = 1
                if py < 4 { py = 4 }
            }
            ImGuiSetNextWindowPos(
                ImVec2(x: px, y: py),
                Int32(ImGuiCond_Appearing.rawValue), ImVec2(x: pivotX, y: pivotY))
            ImGuiOpenPopup("##ObjectPicker", Int32(ImGuiPopupFlags_None.rawValue))
        }

        let popupFlags = Int32(
            ImGuiWindowFlags_NoTitleBar.rawValue | ImGuiWindowFlags_NoResize.rawValue
                | ImGuiWindowFlags_NoMove.rawValue | ImGuiWindowFlags_NoSavedSettings.rawValue
                | ImGuiWindowFlags_AlwaysAutoResize.rawValue
                | ImGuiWindowFlags_NoFocusOnAppearing.rawValue)
        if ImGuiBeginPopup("##ObjectPicker", popupFlags) {
            let shiftHeld = engine.io.pointee.KeyShift
            let ctrlHeld = engine.io.pointee.KeyCtrl
            ImGuiTextV("\(engine.interaction.popupHitList.count) overlapping objects:")
            igSeparator()
            var popupHitIndex: Int32 = 0
            for hit in engine.interaction.popupHitList {
                popupHitIndex &+= 1
                let isSelected = engine.cadSelection.isSelected(hit.handle)
                var label = hit.label
                if isSelected { label += " [x]" }
                if ImGuiSelectable(
                    label, isSelected,
                    Int32(ImGuiSelectableFlags_None.rawValue),
                    ImVec2(x: 0, y: 0))
                {
                    if ctrlHeld {
                        engine.cadSelection.toggleSelect(hit.handle)
                    } else if shiftHeld {
                        engine.cadSelection.removeFromSelection(hit.handle)
                    } else {
                        engine.cadSelection.addToSelection(hit.handle)
                    }
                    ImGuiCloseCurrentPopup()
                    engine.interaction.popupHitList.removeAll()
                }

                // "Edit Block" option for block reference entities
                if let entity = engine.document.entity(for: hit.handle),
                   let blockID = entity.blockID {
                    ImGuiSameLine(0, 4)
                    ImGuiPushID(popupHitIndex)
                    if igSmallButton("Edit Block") {
                        engine.tabManager.enterBlockEditor(blockID: blockID)
                        engine.cadSelection.clearSelection()
                        ImGuiCloseCurrentPopup()
                        engine.interaction.popupHitList.removeAll()
                    }
                    ImGuiPopID()
                }
            }
            ImGuiEndPopup()
        } else {
            engine.interaction.popupHitList.removeAll()
        }
    }

}