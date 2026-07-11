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

    // MARK: CAD GPU Buffer
    internal var cadVertexBuffer: OpaquePointer?
    internal var cadVertexCount: Int = 0
    internal var cadDrawBatches: [CADDrawBatch] = []

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


    internal var usesTriangleHairlines: Bool { true }

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
            if let buf = cadVertexBuffer {
                SDL_ReleaseGPUBuffer(engine.gpuDevice, buf)
                cadVertexBuffer = nil
            }
            cadVertexCount = 0
            cadDrawBatches.removeAll()
            engine._lastCameraZoom = -1.0
            engine._cachedMutationGen = -1  // force cold-start sync rebuild next frame
            engine._cachedDisplayPaletteGen = -1
        }
    }

    /// Last color set via SDL_SetRenderDrawColor. Tracked to skip redundant calls.
    internal var _lastDrawColor: UInt32 = 0xFFFF_FFFF  // sentinel: never matches

    /// The **buffered (over-scanned) world region** the CAD vertex buffer was last built for.
    /// The render cache is a hit as long as the current viewport stays inside this region —
    /// vertices are world-space, so panning within it is a pure camera-matrix change and needs
    /// no rebuild. Written by `rebuildCadVertexBuffer()`.
    internal var _cachedViewportMinX: Double = 0
    internal var _cachedViewportMinY: Double = 0
    internal var _cachedViewportMaxX: Double = 0
    internal var _cachedViewportMaxY: Double = 0
    /// Zoom at which the buffered region was built. Screen-constant primitives (point quads,
    /// thick/AA line widths) are sized for this zoom, so a large zoom change forces a rebuild.
    internal var _bufferedZoom: Double = -1.0
    /// Overscan added on each side when building the CAD vertex buffer, as a fraction of the
    /// viewport. Pans that keep the viewport inside this margin reuse the buffer (no CPU
    /// re-tessellation). 0.5 ⇒ buffered region ≈ 2× the viewport per axis. Tune upward for
    /// fewer rebuilds at the cost of a larger buffer.
    internal var cadCullMargin: Double = 0.5

    // MARK: - Async Vertex-Buffer Build State (mirrors _regeneration* pattern)

    /// Builder that owns the pure tessellator + lock-guarded pending slot.
    internal let vbBuilder = CADVertexBufferBuilder()

    /// Monotonic token; incremented on each async launch.
    internal var _vbBuildToken: Int = 0
    /// Token of the build currently computing (nil = none in flight).
    internal var _vbInFlightToken: Int? = nil
    /// Background task for the in-flight build.
    internal var _vbBuildTask: Task<Void, Never>? = nil

    /// Descriptor the in-flight build targets — used for dedup to avoid 60 Hz thrashing.
    internal var _vbInFlightRegion: (minX: Double, minY: Double, maxX: Double, maxY: Double)? = nil
    internal var _vbInFlightZoom: Double = -1.0
    internal var _vbInFlightMutationGen: Int = -1
    internal var _vbInFlightPaletteGen: Int = -1

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

    public init(engine: PhrostEngine) {
        self.engine = engine
    }



    // MARK: - Rendering

    internal func rebuildCadVertexBuffer() {
        // Cancel any in-flight async build — this sync rebuild supersedes it.
        _vbBuildTask?.cancel()
        _vbBuildTask = nil
        _vbInFlightToken = nil
        _vbInFlightRegion = nil
        vbBuilder.cancelPending()

        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let marginX = (vp.maxX - vp.minX) * cadCullMargin
        let marginY = (vp.maxY - vp.minY) * cadCullMargin
        let cullMinX = vp.minX - marginX, cullMaxX = vp.maxX + marginX
        let cullMinY = vp.minY - marginY, cullMaxY = vp.maxY + marginY

        let region = (minX: cullMinX, minY: cullMinY, maxX: cullMaxX, maxY: cullMaxY)
        let inputs = gatherTessInputs(region: region)
        let paletteGen = engine.ui.displayPaletteGeneration

        // Let tessellate handle empty inputs cleanly — returns empty VertexBuildResult
        // so applyVertexBuild writes metadata atomically and cache hits next frame.
        guard let result = CADVertexBufferBuilder.tessellate(
            inputs,
            cameraZoom: engine.camera.zoom,
            pixelScale: lineWidthPixelScale,
            antiAliasLines: antiAliasLines,
            hairlineQuads: usesTriangleHairlines,
            region: region,
            mutationGen: engine.geometryManager.mutationGeneration
        ) else {
            return  // cancelled
        }

        applyVertexBuild(result, paletteGen: paletteGen)
    }

    private func makeImCol32(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt32 {
        return (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r)
    }

    internal func render(deltaSec: Double) {
        SDL_GetWindowSize(engine.window, &engine.windowWidth, &engine.windowHeight)
        SDL_GetWindowSizeInPixels(engine.window, &engine.pixelWidth, &engine.pixelHeight)
        let newScaleX = (engine.windowWidth > 0) ? Float(engine.pixelWidth) / Float(engine.windowWidth) : 1.0
        let newScaleY = (engine.windowHeight > 0) ? Float(engine.pixelHeight) / Float(engine.windowHeight) : 1.0

        // print("newScaleX: \(newScaleX), newScaleY: \(newScaleY), engine.scaleX: \(engine.scaleX), engine.scaleY: \(engine.scaleY) engine.windowWidth: \(engine.windowWidth), engine.windowHeight: \(engine.windowHeight), engine.pixelWidth: \(engine.pixelWidth), engine.pixelHeight: \(engine.pixelHeight)")

        if newScaleX != engine.scaleX || newScaleY != engine.scaleY {
            engine.camera.renderGeneration &+= 1
        }
        engine.scaleX = newScaleX
        engine.scaleY = newScaleY

        let newDpiScale = SDL_GetWindowDisplayScale(engine.window)
        engine.updateScale(dpiScale: newDpiScale, fbScale: newScaleX)

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

        let t0 = SDL_GetTicks()
        let activeDoc = engine.tabManager.activeDocument

        // Fold in-tab edits into the regeneration generation so they supersede any in-flight
        // task exactly the way a tab switch does. needsRegeneration is the "needs regen" trigger for
        // edits/undo; tab switches bump the generation directly (see onActiveTabChanged).
        if activeDoc.needsRegeneration {
            activeDoc.needsRegeneration = false
            engine._regenerationGeneration &+= 1
        }

        let wantGen = engine._regenerationGeneration

        // Launch (or relaunch) a background regeneration for the current generation when the
        // displayed geometry is stale and no task is already computing THIS generation.
        // The snapshot is a value-typed copy, so the detached task never touches the live doc.
        if wantGen != engine._appliedGeneration && engine._regenerationInFlight != wantGen {
            print("[Loop] regen needed for generation \(wantGen), launching task")
            engine._regenerationTask?.cancel()
            let docSnapshot = activeDoc.snapshot()
            engine._regenerationInFlight = wantGen
            let inBlockEditor = engine.tabManager.activeTab?.editingBlockID != nil
            let simplify = inBlockEditor ? false : engine.simplifyComplexBlocks
            let tessDiv = engine.splineTessellationDivisor
            engine._regenerationTask = Task.detached { [weak self] in
                guard let self else { return }
                await engine.cadBridge.regenerate(
                    fromSnapshot: docSnapshot,
                    generation: wantGen,
                    simplifyComplexBlocks: simplify,
                    into: engine.geometryManager,
                    splineTessellationDivisor: tessDiv
                )
            }
        }

        // Apply results only if they match the generation we currently want to show. Results
        // from a superseded tab/edit are dropped here and never reach the screen — this is the
        // fix for the tab-switch race on large files.
        let pendingApplied = engine.cadBridge.applyPendingIfNeeded(
            forGeneration: wantGen, into: engine.geometryManager, engine: engine)

        if pendingApplied {
            engine._appliedGeneration = wantGen
            engine._regenerationInFlight = nil
            engine._regenerationTask = nil
            engine.interaction.pendingPreviewHandles.removeAll()
            // Rebuild entity spatial grid after geometry has been regenerated, if needed.
            if !activeDoc.entityGridBuilt {
                activeDoc.rebuildEntityGrid()
            }
        }

        // Render cache: vertices are world-space and the camera matrix is re-uploaded every
        // frame (see PushGPUVertexUniformData in the draw pass below), so PAN/ROTATE never
        // require a rebuild. Rebuild only when the viewport leaves the over-scanned buffered
        // region, when zoom changes enough to break screen-constant primitive sizing, or when
        // geometry actually mutates.
        let mutationGen = engine.geometryManager.mutationGeneration
        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)

        let insideBuffer =
            vp.minX >= _cachedViewportMinX && vp.maxX <= _cachedViewportMaxX &&
            vp.minY >= _cachedViewportMinY && vp.maxY <= _cachedViewportMaxY
        let zoomStable = isLineWidthZoomStable(currentLineWidthZoom, _bufferedZoom)

        // FIX: Removed `&& cadVertexBuffer != nil` — empty spaces cache via engine._cachedMutationGen
        let renderCacheHit = !pendingApplied && !engine.interaction.dragActive && !engine.interaction.gripActive
            && insideBuffer
            && zoomStable
            && engine._cachedMutationGen == mutationGen
            && engine._cachedDisplayPaletteGen == engine.ui.displayPaletteGeneration

        // --- Vertex buffer routing (§4): sync for cold-start/drag, async for pan/zoom ---
        // applyPendingVertexBuildIfReady() acquires+submits its own command buffer,
        // so it MUST execute before the main render pass acquires its command buffer
        // (SDL_AcquireGPUCommandBuffer below).
        if engine._cachedMutationGen == -1 {
            rebuildCadVertexBuffer()            // cold start: sync
        } else if !renderCacheHit && !(engine.interaction.dragActive || engine.interaction.gripActive) {
            launchAsyncVertexBuildIfNeeded()    // pan/zoom/edit: async launch
        }
        applyPendingVertexBuildIfReady()        // always: apply ready results
        // NOTE: engine._cachedMutationGen is now written at swap time inside applyVertexBuild,
        // not here.
        let t1 = SDL_GetTicks()

        let spritesToRender = engine.spriteManager.getSpritesForRendering()
        var transform = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)

        engine.io.pointee.DisplaySize = ImVec2(x: Float(engine.windowWidth), y: Float(engine.windowHeight))
        engine.io.pointee.DisplayFramebufferScale = ImVec2(x: engine.scaleX, y: engine.scaleY)
        engine.io.pointee.DeltaTime = Float(deltaSec)

        // Apply any deferred UI scale rebuild before NewFrame locks the font atlas.
        engine.applyPendingUiScaleRebuild()

        ImGuiNewFrame()

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

        // 1. Draw active command / interaction overlays on ImGui foreground draw list
        _foregroundVertexEstimate = 0
        // Only recompute grips when camera, selection, grip drag, or document
        // regeneration (e.g. layer visibility) changes.
        if engine.interaction.cachedGripGeneration != engine.camera.renderGeneration
            || engine._cachedSelectionGen != engine.cadSelection._selectionGeneration
            || engine._cachedApplyGen != engine._appliedGeneration
            || engine.interaction.gripActive
            || engine.interaction.dragActive
        {
            // Respect gripObjectMax: if too many entities are selected, suppress
            // all grips and show only selection outlines.
            let gripHandles: Set<UUID>
            if engine.cadSelection.selectedHandles.count > engine.gripObjectMax {
                gripHandles = []
            } else {
                gripHandles = engine.cadSelection.selectedHandles
            }
            engine._cachedCadGrips = CADGripSystem.getAllGrips(
                document: engine.document, cam: transform,
                simplifyComplexBlocks: true,
                selectedHandles: gripHandles)
            engine.interaction.cachedGripGeneration = engine.camera.renderGeneration
            engine._cachedSelectionGen = engine.cadSelection._selectionGeneration
            engine._cachedApplyGen = engine._appliedGeneration
        }
        renderCrosshairCursor(cam: transform)
        renderGrid(cam: transform)
        renderSnapIndicator(cam: transform)
        
        // --> Call the new subtle, background-adaptive tracking lines <--
        let drawList = igGetBackgroundDrawList(nil)
        renderTrackingOverlays(drawList: drawList, cam: transform)

        renderCadSelectionHighlight(cam: transform)
        renderCadHoverHighlight(cam: transform)
        renderRectSelectPreview(cam: transform)
        renderCadGrips(cam: transform)
        renderRectSelectBox()
        renderMoveGhostPreview(cam: transform)
        renderInteractivePreview(cam: transform)

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

        // 2. ImGui user panels/callbacks. Some controls (notably radial Pan)
        // mutate the camera here, so sprite transforms must be calculated after it.
        if let callback = engine.imguiFrameCallback { callback() } else { ImGuiShowDemoWindow(nil) }

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

        for sprite in spritesToRender {
            guard backgroundVertexEstimate < backgroundVertexLimit else { break }
            if hiddenImageSpriteIDs.contains(sprite.id) { continue }
            renderSprite(sprite, deltaSec: deltaSec, cam: transform)
            backgroundVertexEstimate += 4
        }
        
        // 3. Feature commands UI
        engine.commandProcessor.activeFeatureCommand?.renderImGui(engine: engine)
        
        renderObjectPickerPopup()
        ImGuiRender()

        guard let drawData = ImGuiGetDrawData() else { return }
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

                var vtxTransferInfo = SDL_GPUTransferBufferCreateInfo()
                vtxTransferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
                vtxTransferInfo.size = vtxSizeInBytes
                let vtxTransferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &vtxTransferInfo)

                var idxTransferInfo = SDL_GPUTransferBufferCreateInfo()
                idxTransferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
                idxTransferInfo.size = idxSizeInBytes
                let idxTransferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &idxTransferInfo)

                if let vtxTransferBuf,
                   let idxTransferBuf
                {
                    let vtxMapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, vtxTransferBuf, false)
                    let idxMapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, idxTransferBuf, false)

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

                if let vtxTransferBuf {
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, vtxTransferBuf)
                }
                if let idxTransferBuf {
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, idxTransferBuf)
                }
            }
        }

        // --- Phase 2: GPU ID-buffer pick pass ---
        if let pickX = _pendingPickScreenX, let pickY = _pendingPickScreenY,
           let pickTex = pickTexture, cadIDPipeline != nil, cadVertexBuffer != nil,
           cadVertexCount > 0
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

                    var vertexBinding = SDL_GPUBufferBinding(buffer: cadVertexBuffer!, offset: 0)
                    SDL_BindGPUVertexBuffers(pickPass, 0, &vertexBinding, 1)

                    // Upload pick matrix (9×9 viewport centered on cursor)
                    var pickMatrix = engine.camera.computePickMatrix(cursorScreenX: pickX, cursorScreenY: pickY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                    SDL_PushGPUVertexUniformData(pickCmd, 0, &pickMatrix, UInt32(pickMatrix.count * 4))

                    // Draw all batches with appropriate ID pipeline per primitive type
                    var lastBoundType: CADPipelineType? = nil
                    for batch in cadDrawBatches {
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
        if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, engine.window, &swapchainTexture, nil, nil) {
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
                if let vertexBuf = cadVertexBuffer, cadVertexCount > 0 {
                    var lastBoundPipeline: CADPipelineType? = nil
                    var vertexBinding = SDL_GPUBufferBinding(buffer: vertexBuf, offset: 0)
                    SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

                    let cameraMatrix = engine.camera.computeMatrix(windowW: Double(engine.windowWidth), windowH: Double(engine.windowHeight))
                    
                    var uniformData = CameraUniformData()
                    uniformData.m00 = cameraMatrix[0]; uniformData.m01 = cameraMatrix[1]; uniformData.m02 = cameraMatrix[2]; uniformData.m03 = cameraMatrix[3]
                    uniformData.m10 = cameraMatrix[4]; uniformData.m11 = cameraMatrix[5]; uniformData.m12 = cameraMatrix[6]; uniformData.m13 = cameraMatrix[7]
                    uniformData.m20 = cameraMatrix[8]; uniformData.m21 = cameraMatrix[9]; uniformData.m22 = cameraMatrix[10]; uniformData.m23 = cameraMatrix[11]
                    uniformData.m30 = cameraMatrix[12]; uniformData.m31 = cameraMatrix[13]; uniformData.m32 = cameraMatrix[14]; uniformData.m33 = cameraMatrix[15]
                    
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
                    
                    SDL_PushGPUVertexUniformData(cmd, 0, &uniformData, UInt32(MemoryLayout<CameraUniformData>.size))

                    let isPanning = _panProxyActiveThisFrame
                    for batch in cadDrawBatches {
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

    private func renderCadSelectionHighlight(cam: CameraTransform) {
        // Selection highlight: for image entities and block references, redraw
        // geometry outlines in a bright highlight colour so the selected state
        // is visually distinct from both unselected geometry and the hover state.
        // Falls back to a bounding box for entities with many primitives.
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

            if isImage || isBlock {
                let drawList = igGetBackgroundDrawList(nil)

                // For image entities or complex blocks, just draw the bounding box.
                let primitiveCount = geom?.count ?? 0
                if isImage || primitiveCount > 50 || segmentsDrawn >= maxSegments {
                    guard let wbb = entity.worldBoundingBox else { continue }
                    let s0 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                    let s1 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                    let s2 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                    let s3 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), selColor, lineWidth)
                    ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), selColor, lineWidth)
                    _foregroundVertexEstimate += 8
                } else {
                    // For simple block entities, redraw each geometry segment so the
                    // selection highlight matches the geometry shape (same as hover).
                    engine.cadBridge.vertexEditor.forEachWorldSegment(handle: handle, in: engine.geometryManager) { x1, y1, x2, y2 in
                        guard segmentsDrawn < maxSegments else { return }
                        let s0 = engine.camera.transformWorldToScreen(worldX: x1, worldY: y1, cam: cam)
                        let s1 = engine.camera.transformWorldToScreen(worldX: x2, worldY: y2, cam: cam)
                        ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), selColor, lineWidth)
                        segmentsDrawn += 1
                    }
                    _foregroundVertexEstimate += segmentsDrawn * 2
                }
            } else if overGripLimit {
                // When selection exceeds gripObjectMax, grips are suppressed.
                // Draw gold bounding boxes for non-image, non-block entities
                // so users can still see what is selected.
                guard let wbb = entity.worldBoundingBox else { continue }
                let drawList = igGetBackgroundDrawList(nil)
                let s0 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
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
                let s0 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
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

        if engine.simplifyComplexBlocks && geometry.count > 50 {
            if let wbb = entity.worldBoundingBox {
                let s0 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                let s2 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                let s3 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
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
            let s0 = engine.camera.transformWorldToScreen(worldX: x1, worldY: y1, cam: cam)
            let s1 = engine.camera.transformWorldToScreen(worldX: x2, worldY: y2, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), hc, lineWidth)
        }
        _foregroundVertexEstimate += segmentsDrawn * 8
    }

    /// Renders a live preview of what the selection will look like after
    /// the rect select is finalized. Draws geometry outlines like hover,
    /// capped to stay under ImGui's 16-bit index limit (65535 vertices).
    private func renderRectSelectPreview(cam: CameraTransform) {
        guard engine.interaction.rectSelectActive, !engine.interaction.rectSelectPreviewHandles.isEmpty else { return }

        let addColor = makeImCol32(r: 64, g: 180, b: 255, a: 180)
        let removeColor = makeImCol32(r: 255, g: 80, b: 80, a: 180)
        let lineWidth: Float = 1.5
        let baseMaxSegments = 8000  // 8000 segments × 2 verts = 16000 verts
        let budgetMaxSegments = (_foregroundVertexLimit - _foregroundVertexEstimate) / 6
        let maxSegments = min(baseMaxSegments, max(0, budgetMaxSegments))
        var segmentsDrawn = 0

        let toAdd = engine.interaction.rectSelectPreviewHandles.subtracting(engine.cadSelection.selectedHandles)
        let toRemove = engine.cadSelection.selectedHandles.subtracting(engine.interaction.rectSelectPreviewHandles)

        func drawGeometry(for handle: UUID, color: UInt32) {
            guard segmentsDrawn < maxSegments else { return }

            guard let entity = engine.document.entity(for: handle),
                  let geometry = engine.document.resolvedGeometry(for: entity)
            else { return }

            let drawList = igGetBackgroundDrawList(nil)
            if engine.simplifyComplexBlocks && geometry.count > 50 {
                if let wbb = entity.worldBoundingBox {
                    let s0 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
                    let s1 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
                    let s2 = engine.camera.transformWorldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
                    let s3 = engine.camera.transformWorldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
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
                let s0 = engine.camera.transformWorldToScreen(worldX: x1, worldY: y1, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: x2, worldY: y2, cam: cam)
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

        // 1. Cap grips to prevent ImGui 16-bit index crash.
        // 65535 limit / ~12 vertices per grip = max ~5400 grips.
        // Cap at the configured limit (default 1000) to leave room for other
        // ImGui draw-list primitives (crosshairs, rect-select previews, etc.).
        let maxGripsToDraw = engine.gripMax
        var drawnGrips = 0

        for grip in engine._cachedCadGrips {
            if drawnGrips >= maxGripsToDraw { break }

            // During active drag, compute screen position from the incrementally
            // transformed world position rather than using a stale cached screenPos.
            let screenPos: SDL_FPoint = engine.interaction.gripActive
                ? engine.camera.transformWorldToScreen(worldX: grip.worldPos.x, worldY: grip.worldPos.y, cam: cam)
                : grip.screenPos

            // 2. Viewport culling: Don't push vertices for grips outside the screen
            let margin: Float = 10.0
            if screenPos.x < -margin || screenPos.x > Float(engine.windowWidth) + margin ||
               screenPos.y < -margin || screenPos.y > Float(engine.windowHeight) + margin {
                continue
            }

            let isHovered: Bool
            if let hg = engine.interaction.hoveredGrip, engine.interaction.hoveredGripHandle == grip.handle {
                isHovered = gripTypeMatches(hg, grip.grip)
            } else {
                isHovered = false
            }

            let fill: UInt32
            let half: Float
            switch grip.grip {
            case .corner:
                fill = isHovered ? makeImCol32(r: 80, g: 180, b: 255, a: 255) : makeImCol32(r: 0, g: 128, b: 255, a: 255)
                half = 4.0
            case .center:
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
            }
            
            let pMin = ImVec2(x: screenPos.x - half, y: screenPos.y - half)
            let pMax = ImVec2(x: screenPos.x + half, y: screenPos.y + half)

            ImDrawListAddRectFilled(drawList, pMin, pMax, fill, 0.0, 0)
            ImDrawListAddRect(drawList, pMin, pMax, makeImCol32(r: 255, g: 255, b: 255, a: 255), 0.0, 1.0, 0)
            
            drawnGrips += 1
        }
        _foregroundVertexEstimate += drawnGrips * 10  // filled rect + outline ≈ 10 verts
    }

    private func gripTypeMatches(
        _ a: CADSelectionManager.GripType, _ b: CADSelectionManager.GripType
    ) -> Bool {
        switch (a, b) {
        case (.center, .center): return true
        case (.rotation, .rotation): return true
        case (.corner(let i), .corner(let j)): return i == j
        case (.vertex(let e1, let i1), .vertex(let e2, let i2)): return e1 == e2 && i1 == i2
        case (.midpoint(let e1, let a1, let b1), .midpoint(let e2, let a2, let b2)):
            return e1 == e2 && a1 == a2 && b1 == b2
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

    private func renderCrosshairCursor(cam: CameraTransform) {
        let io = ImGuiGetIO()
        if let wantCapture = io?.pointee.WantCaptureMouse, wantCapture {
            return
        }
        guard !engine.interaction.dragActive && !engine.interaction.gripActive && !engine.interaction.panActive else { return }
        // Show crosshair during commands (MOVE, ROTATE, SCALE, feature commands) —
        // the user needs to see the cursor to pick points.

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let crosshair = engine.ui.isDarkTheme ? (255, 255, 255, 120) : (20, 38, 52, 120)
        let col = makeImCol32(
            r: UInt8(crosshair.0),
            g: UInt8(crosshair.1),
            b: UInt8(crosshair.2),
            a: UInt8(crosshair.3))
        let cx = engine.interaction.lastMouseX
        let cy = engine.interaction.lastMouseY
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

    // MARK: - Grid

    /// Draw the background grid when `engine.snap.gridVisible` is true.
    /// Grid lines are drawn as thin lines via the ImGui foreground draw list,
    /// making them non-selectable (not part of the CAD vertex buffer or ID-buffer pick pass).
    /// The visual spacing adapts to the current zoom level so a consistent density
    /// of lines is visible at all zoom levels.
    private func renderGrid(cam: CameraTransform) {
        guard engine.snap.gridVisible else { return }

        let spacing = engine.snap.effectiveGridSpacing(windowWidth: engine.windowWidth, cameraZoom: engine.camera.zoom)
        let ox = engine.snap.gridOriginX
        let oy = engine.snap.gridOriginY

        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        // Expand viewport slightly so lines don't pop in/out at edges
        let margin = spacing
        let vpMinX = vp.minX - margin
        let vpMinY = vp.minY - margin
        let vpMaxX = vp.maxX + margin
        let vpMaxY = vp.maxY + margin

        let drawList = igGetBackgroundDrawList(nil)
        // Subtle gray, semi-transparent. Slightly brighter on dark theme for contrast.
        let gridCol = engine.ui.isDarkTheme
            ? makeImCol32(r: 80, g: 80, b: 80, a: 50)
            : makeImCol32(r: 180, g: 180, b: 180, a: 60)
        let lineThickness: Float = 1.0

        // Helper: world coordinate to screen point
        func worldToScreen(_ wx: Double, _ wy: Double) -> SDL_FPoint {
            engine.camera.transformWorldToScreen(worldX: wx, worldY: wy, cam: cam)
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
        let sp = engine.camera.transformWorldToScreen(worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)
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

        let startSp = engine.camera.transformWorldToScreen(
            worldX: p1.x,
            worldY: p1.y,
            cam: cam
        )

        let endSp = engine.camera.transformWorldToScreen(
            worldX: p2.x,
            worldY: p2.y,
            cam: cam
        )

        let snapSp = engine.camera.transformWorldToScreen(
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
            let sp = engine.camera.transformWorldToScreen(
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
            let vsp = engine.camera.transformWorldToScreen(worldX: vp.x, worldY: vp.y, cam: cam)
            let ssp = engine.camera.transformWorldToScreen(worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)
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

    private func renderRectSelectBox() {
        guard engine.interaction.rectSelectActive else { return }
        let cam = engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let p1 = engine.camera.transformWorldToScreen(
            worldX: engine.interaction.rectSelectStartX, worldY: engine.interaction.rectSelectStartY, cam: cam)
        let p3 = engine.camera.transformWorldToScreen(
            worldX: engine.interaction.rectSelectCurrentX, worldY: engine.interaction.rectSelectCurrentY, cam: cam)
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

        let _ = engine.camera.transformWorldToScreen(worldX: base.0, worldY: base.1, cam: cam)
        let _ = engine.camera.transformWorldToScreen(worldX: ghostX, worldY: ghostY, cam: cam)

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
                let s0 = engine.camera.transformWorldToScreen(worldX: a.x, worldY: a.y, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: b.x, worldY: b.y, cam: cam)
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
            let sp = engine.camera.transformWorldToScreen(worldX: p.x, worldY: p.y, cam: cam)
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

        let isLight = !engine.ui.isDarkTheme
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
                let s0 = engine.camera.transformWorldToScreen(worldX: x1 + dragOffsetX, worldY: y1 + dragOffsetY, cam: cam)
                let s1 = engine.camera.transformWorldToScreen(worldX: x2 + dragOffsetX, worldY: y2 + dragOffsetY, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lw)
            }

            if let entity = engine.document.entity(for: handle),
               entity.xdata["dxf.text"] != nil,
               let box = entity.worldBoundingBox {
                let p0 = engine.camera.transformWorldToScreen(worldX: box.min.x, worldY: box.min.y, cam: cam)
                let p1 = engine.camera.transformWorldToScreen(worldX: box.max.x, worldY: box.min.y, cam: cam)
                let p2 = engine.camera.transformWorldToScreen(worldX: box.max.x, worldY: box.max.y, cam: cam)
                let p3 = engine.camera.transformWorldToScreen(worldX: box.min.x, worldY: box.max.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p0.x, y: p0.y), ImVec2(x: p1.x, y: p1.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y), color, lw)
                ImDrawListAddLine(drawList, ImVec2(x: p3.x, y: p3.y), ImVec2(x: p0.x, y: p0.y), color, lw)
            }
        }
    }

    private func renderSprite(_ sprite: Sprite, deltaSec: Double, cam: CameraTransform) {
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

        let p1 = engine.camera.transformWorldToScreen(worldX: px + (-hw * c - -hh * s), worldY: py + (-hw * s + -hh * c), cam: cam)
        let p2 = engine.camera.transformWorldToScreen(worldX: px + (hw * c - -hh * s), worldY: py + (hw * s + -hh * c), cam: cam)
        let p3 = engine.camera.transformWorldToScreen(worldX: px + (hw * c - hh * s), worldY: py + (hw * s + hh * c), cam: cam)
        let p4 = engine.camera.transformWorldToScreen(worldX: px + (-hw * c - hh * s), worldY: py + (-hw * s + hh * c), cam: cam)

        // AABB culling: only skip if the entire quad is off-screen
        let margin: Float = 0
        let minX = min(p1.x, p2.x, p3.x, p4.x)
        let maxX = max(p1.x, p2.x, p3.x, p4.x)
        let minY = min(p1.y, p2.y, p3.y, p4.y)
        let maxY = max(p1.y, p2.y, p3.y, p4.y)
        if maxX < -margin || minX > Float(engine.windowWidth) + margin
            || maxY < -margin || minY > Float(engine.windowHeight) + margin {
            return
        }

        let isLight = !engine.ui.isDarkTheme
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

        if let tex = sprite.texture {
            let texRefPtr = ImTextureRef_ImTextureRef_TextureID(UInt64(UInt(bitPattern: tex)))
            defer { ImTextureRef_destroy(texRefPtr) }
            let texRef = texRefPtr!.pointee

            ImDrawListAddImageQuad(
                drawList,
                texRef,
                ip1, ip2, ip3, ip4,
                ImVec2(x: 0, y: 0), ImVec2(x: 1, y: 0), ImVec2(x: 1, y: 1), ImVec2(x: 0, y: 1),
                col
            )
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