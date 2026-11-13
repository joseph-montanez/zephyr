import Foundation
import SwiftSDL
import ImGui

// =========================================================================
// MARK: - EngineRenderer + Vertex Upload
//
// CAD vertex buffer construction and GPU upload pipeline. Handles:
//   - Gathering tessellation inputs from the geometry manager
//   - Sync vertex buffer rebuild (cold start, drag)
//   - Async vertex buffer rebuild (pan, zoom, edit)
//   - GPU buffer creation, upload, and swap
//   - Render cache metadata (viewport region, zoom, mutation gen)
//
// Separated from the main render loop for clarity — the upload pipeline
// is ~200 lines of state management and async coordination.
// =========================================================================

extension EngineRenderer {

    // MARK: - Gather (main actor)

    /// Copies the grid-query result into value-type `TessInput` structs so the
    /// tessellator can run off the main actor without touching live primitives.
    /// The source geometry manager and display palette are explicit so
    /// secondary (unfocused-window) contexts can gather without touching the
    /// primary pipeline's stores.
    internal func gatherTessInputs(
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        from geometryManager: GeometryManager,
        into ctx: WindowRenderContext,
        useLightDisplayPalette: Bool,
        viewportBackground: (UInt8, UInt8, UInt8, UInt8)
    ) -> [TessInput] {
        var inputs: [TessInput] = []

        func displayColor(for primitive: RenderPrimitive) -> (UInt8, UInt8, UInt8, UInt8) {
            if primitive.usesViewportBackgroundColor {
                return viewportBackground
            }
            if !geometryManager.autoContrastTrueColor && primitive.isTrueColor {
                return primitive.color
            }
            return useLightDisplayPalette
                ? primitive.adjustedColorLight
                : primitive.adjustedColorDark
        }

        func adjustedGradient(_ gradient: RenderPrimitive.GradientData?) -> RenderPrimitive.GradientData? {
            guard let gradient else { return nil }
            if !geometryManager.autoContrastTrueColor {
                return gradient
            }
            let color1 = ColorRGBA(
                r: gradient.color1.0, g: gradient.color1.1,
                b: gradient.color1.2, a: gradient.color1.3
            ).displayAdjusted(forLightBackground: useLightDisplayPalette)
            let color2 = ColorRGBA(
                r: gradient.color2.0, g: gradient.color2.1,
                b: gradient.color2.2, a: gradient.color2.3
            ).displayAdjusted(forLightBackground: useLightDisplayPalette)
            return RenderPrimitive.GradientData(
                color1: (color1.r, color1.g, color1.b, color1.a),
                color2: (color2.r, color2.g, color2.b, color2.a),
                angleCos: gradient.angleCos,
                angleSin: gradient.angleSin,
                minX: gradient.minX,
                minY: gradient.minY,
                diag: gradient.diag)
        }

        if let indices = geometryManager.visiblePrimitiveIndices(
            inWorldRect: region.minX, minY: region.minY,
            maxX: region.maxX, maxY: region.maxY)
        {
            ctx.cachedUsingGrid = true
            inputs.reserveCapacity(indices.count)

            for idx in indices {
                guard let p = geometryManager.getPrimitive(at: idx) else { continue }
                inputs.append(TessInput(
                    type: p.type,
                    points: p.points,
                    rects: p.rects,
                    corners: p.corners,
                    color: displayColor(for: p),
                    lineWeight: p.lineWeight,
                    geomWidth: p.geomWidth,
                    segmentLineWeights: p.segmentLineWeights,
                    entityIndex: p.entityIndex,
                    isHatchLine: p.isHatchLine,
                    hatchSpacing: p.hatchSpacing,
                    isPanProxy: p.isPanProxy,
                    gradientData: adjustedGradient(p.gradientData),
                    pointStyle: geometryManager.pointDisplayMode,
                    pointSize: geometryManager.pointDisplaySize
                ))
            }
        } else {
            ctx.cachedUsingGrid = false
            let primitives = geometryManager.getPrimitivesForRendering()
            inputs.reserveCapacity(primitives.count)

            for p in primitives {
                inputs.append(TessInput(
                    type: p.type,
                    points: p.points,
                    rects: p.rects,
                    corners: p.corners,
                    color: displayColor(for: p),
                    lineWeight: p.lineWeight,
                    geomWidth: p.geomWidth,
                    segmentLineWeights: p.segmentLineWeights,
                    entityIndex: p.entityIndex,
                    isHatchLine: p.isHatchLine,
                    hatchSpacing: p.hatchSpacing,
                    isPanProxy: p.isPanProxy,
                    gradientData: adjustedGradient(p.gradientData),
                    pointStyle: geometryManager.pointDisplayMode,
                    pointSize: geometryManager.pointDisplaySize
                ))
            }
        }

        return inputs
    }



    // MARK: - GPU Upload / Swap (main actor, double-buffered)

    /// Creates new GPU buffers from a `VertexBuildResult`, uploads them, then
    /// releases the old buffers and swaps in the new. Cache metadata is written
    /// at swap time so the cache always describes the live buffer.
    ///
    /// Acquires a command buffer for a render pass, with device-loss backoff:
    /// after a streak of failures the GPU is assumed removed and further
    /// submission stops (one clear message instead of an endless error wall
    /// every frame). Callers treat nil as "skip this frame".
    internal func acquireRenderCommandBuffer(tag: String) -> OpaquePointer? {
        if engine.gpuDeviceLost { return nil }
        guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
            engine._gpuAcquireFailStreak += 1
            if engine._gpuAcquireFailStreak >= 5 {
                if !engine.gpuDeviceLost {
                    engine.gpuDeviceLost = true
                    print("[GPU] Device lost: the GPU stopped responding (likely an oversized or invalid command). Rendering is paused; save your work and restart. (\(tag))")
                }
            } else {
                print("Failed to acquire GPU command buffer (\(tag))")
            }
            return nil
        }
        engine._gpuAcquireFailStreak = 0
        return cmd
    }

    /// Called from both the sync `rebuildCadVertexBuffer()` and the async
    /// `applyPendingVertexBuildIfReady()` paths.
    /// Creates GPU buffers from a `VertexBuildResult`, uploads them chunk by
    /// chunk, then releases the old buffers and swaps in the new set. Cache
    /// metadata is written at swap time so the cache always describes the
    /// live buffers. Returns false when nothing was applied (upload refused
    /// or a chunk failed); the previous buffer stays live then.
    @discardableResult
    internal func applyVertexBuild(_ result: VertexBuildResult, paletteGen: Int, ctx: WindowRenderContext) -> Bool {
        let vertices = result.vertices

        // --- Build NEW GPU buffers into locals, one chunk at a time ---
        // Copies are submitted WITH fences and transfer buffers stay alive
        // until their fence completes: releasing (and potentially reusing)
        // transfer memory while an earlier copy is still in flight tears
        // vertex data across chunks — triangles whose corners came from
        // different chunks drew as map-spanning streaks on huge drawings.
        var newChunks: [WindowRenderContext.VertexGPUChunk] = []
        // Diagnostic override (ZEPHYR_CHUNK_VERTS): force a chunk size to
        // A/B multi-buffer draw behavior against the default 4M-vert chunks.
        let chunkCap: Int = {
            if let raw = ProcessInfo.processInfo.environment["ZEPHYR_CHUNK_VERTS"],
               let parsed = Int(raw), parsed > 0 {
                return parsed
            }
            return CADVertexBufferBuilder.maxVertsPerChunk
        }()
        var pendingFences: [OpaquePointer?] = []
        var pendingTransfers: [OpaquePointer] = []
        func drainPendingCopies() {
            if !pendingFences.isEmpty {
                var fences = pendingFences
                _ = SDL_WaitForGPUFences(engine.gpuDevice, true, &fences, UInt32(fences.count))
                for fence in fences { SDL_ReleaseGPUFence(engine.gpuDevice, fence) }
                pendingFences.removeAll()
            }
            for tb in pendingTransfers {
                SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, tb)
            }
            pendingTransfers.removeAll()
        }
        if !vertices.isEmpty {
            let groups = CADVertexBufferBuilder.chunkBatches(result.batches, maxVertsPerChunk: chunkCap)
            var globalOffset = 0
            var failed = false
            for group in groups {
                let count = group.reduce(0) { $0 + Int($1.vertexCount) }
                guard count > 0,
                      let uploadBytes = CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: count)
                else {
                    let approxMB = Double(count * MemoryLayout<CADVertex>.stride) / 1_048_576.0
                    print("[CADVertex] Upload refused: chunk of \(count) verts (~\(String(format: "%.0f", approxMB)) MB) exceeds the single-buffer budget; keeping the previous buffer.")
                    failed = true
                    break
                }
                let sizeInBytes = UInt32(uploadBytes)
                var bufferCreateInfo = SDL_GPUBufferCreateInfo(
                    usage: SDL_GPU_BUFFERUSAGE_VERTEX, size: sizeInBytes, props: 0)
                guard let vb = SDL_CreateGPUBuffer(engine.gpuDevice, &bufferCreateInfo) else {
                    print("Failed to create CAD GPU vertex buffer: \(String(cString: SDL_GetError()))")
                    failed = true
                    break
                }

                var transferInfo = SDL_GPUTransferBufferCreateInfo()
                transferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
                transferInfo.size = sizeInBytes
                guard let transferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &transferInfo) else {
                    print("Failed to create CAD GPU transfer buffer: \(String(cString: SDL_GetError()))")
                    SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                    failed = true
                    break
                }

                guard let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, transferBuf, false) else {
                    print("Failed to map CAD GPU transfer buffer: \(String(cString: SDL_GetError()))")
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                    SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                    failed = true
                    break
                }
                vertices.withUnsafeBytes { ptr in
                    let src = ptr.baseAddress!.advanced(by: globalOffset * MemoryLayout<CADVertex>.stride)
                    memcpy(mapped, src, Int(sizeInBytes))
                }
                SDL_UnmapGPUTransferBuffer(engine.gpuDevice, transferBuf)

                guard let cmd = acquireRenderCommandBuffer(tag: "CAD upload") else {
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                    SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                    failed = true
                    break
                }

                let copyPass = SDL_BeginGPUCopyPass(cmd)
                guard let cp = copyPass else {
                    print("Failed to begin copy pass for CAD buffer upload")
                    SDL_CancelGPUCommandBuffer(cmd)
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                    SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                    failed = true
                    break
                }

                var sourceLocation = SDL_GPUTransferBufferLocation(transfer_buffer: transferBuf, offset: 0)
                var destLocation = SDL_GPUBufferRegion(buffer: vb, offset: 0, size: sizeInBytes)
                SDL_UploadToGPUBuffer(cp, &sourceLocation, &destLocation, false)

                SDL_EndGPUCopyPass(cp)

                guard let fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) else {
                    print("Failed to submit command buffer for CAD buffer upload")
                    SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                    SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                    failed = true
                    break
                }
                pendingFences.append(fence)
                pendingTransfers.append(transferBuf)
                newChunks.append(WindowRenderContext.VertexGPUChunk(
                    buffer: vb, vertexCount: count, batches: group))
                globalOffset += count
            }
            if failed {
                drainPendingCopies()
                for chunk in newChunks {
                    if let buf = chunk.buffer {
                        SDL_ReleaseGPUBuffer(engine.gpuDevice, buf)
                    }
                }
                return false
            }
            drainPendingCopies()
            if ProcessInfo.processInfo.environment["ZEPHYR_VERIFY_UPLOAD"] == "1" {
                verifyUploadedChunks(newChunks, source: vertices)
            }
        }

        // --- Swap: release old, assign new (atomic with metadata write) ---
        for chunk in ctx.vertexChunks {
            if let buf = chunk.buffer {
                SDL_ReleaseGPUBuffer(engine.gpuDevice, buf)
            }
        }

        ctx.vertexChunks = newChunks

        // --- Write cache metadata at swap time (atomic with buffer replacement) ---
        ctx.cachedViewportMinX = result.regionMinX
        ctx.cachedViewportMaxX = result.regionMaxX
        ctx.cachedViewportMinY = result.regionMinY
        ctx.cachedViewportMaxY = result.regionMaxY
        ctx.bufferedZoom = result.builtZoom
        ctx.lastCameraZoom = result.builtZoom
        ctx.cachedMutationGen = result.mutationGen
        ctx.cachedPaletteGen = paletteGen
        ctx.lastHatchVerts = result.hatchVerts
        ctx.lastVertexCapped = result.capped
        return true
    }

    /// Diagnostic (ZEPHYR_VERIFY_UPLOAD=1): downloads each just-uploaded
    /// chunk buffer and byte-compares it against the CPU source slice.
    /// Splits upload corruption from draw-side corruption conclusively.
    private func verifyUploadedChunks(
        _ chunks: [WindowRenderContext.VertexGPUChunk],
        source: [CADVertex]
    ) {
        let stride = MemoryLayout<CADVertex>.stride
        var globalStart = 0
        for (ci, chunk) in chunks.enumerated() {
            defer { globalStart += chunk.vertexCount }
            guard let buf = chunk.buffer, chunk.vertexCount > 0 else { continue }
            let bytes = chunk.vertexCount * stride
            var info = SDL_GPUTransferBufferCreateInfo()
            info.usage = SDL_GPUTransferBufferUsage(rawValue: 1)
            info.size = UInt32(bytes)
            guard let tb = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &info) else {
                print("[VerifyUpload] chunk \(ci): transfer buffer creation failed")
                continue
            }
            defer { SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, tb) }
            guard let cmd = acquireRenderCommandBuffer(tag: "verify download"),
                  let cp = SDL_BeginGPUCopyPass(cmd)
            else {
                print("[VerifyUpload] chunk \(ci): no command buffer")
                continue
            }
            var src = SDL_GPUBufferRegion(buffer: buf, offset: 0, size: UInt32(bytes))
            var dst = SDL_GPUTransferBufferLocation(transfer_buffer: tb, offset: 0)
            SDL_DownloadFromGPUBuffer(cp, &src, &dst)
            SDL_EndGPUCopyPass(cp)
            guard let fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) else {
                print("[VerifyUpload] chunk \(ci): submit failed")
                continue
            }
            var fences: [OpaquePointer?] = [fence]
            _ = SDL_WaitForGPUFences(engine.gpuDevice, true, &fences, 1)
            SDL_ReleaseGPUFence(engine.gpuDevice, fence)
            guard let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, tb, false) else {
                print("[VerifyUpload] chunk \(ci): map failed")
                continue
            }
            var firstBadVertex = -1
            source.withUnsafeBytes { raw in
                let srcBase = raw.baseAddress!.advanced(by: globalStart * stride)
                if memcmp(mapped, srcBase, bytes) != 0 {
                    let got = UnsafeRawBufferPointer(start: mapped, count: bytes)
                    let want = UnsafeRawBufferPointer(start: srcBase, count: bytes)
                    var byte = 0
                    while byte < bytes, got[byte] == want[byte] { byte += 1 }
                    firstBadVertex = byte / stride
                }
            }
            if firstBadVertex < 0 {
                print("[VerifyUpload] chunk \(ci): OK (\(chunk.vertexCount) verts, globalStart \(globalStart))")
            } else {
                let gi = globalStart + firstBadVertex
                var gotV = CADVertex(x: 0, y: 0, r: 0, g: 0, b: 0, a: 0)
                _ = withUnsafeMutableBytes(of: &gotV) { dst in
                    memcpy(dst.baseAddress!, mapped.advanced(by: firstBadVertex * stride), stride)
                }
                let wantV = source[gi]
                print("[VerifyUpload] chunk \(ci): MISMATCH at global vertex \(gi): got (\(gotV.x), \(gotV.y)) want (\(wantV.x), \(wantV.y))")
            }
            SDL_UnmapGPUTransferBuffer(engine.gpuDevice, tb)
        }
    }

    // MARK: - Async Launch / Apply (main actor)

    /// Launches an async vertex-buffer build if the current cache is stale and
    /// no in-flight build already satisfies the current viewport + zoom +
    /// mutation. Dedup prevents 60 Hz thrashing: if the in-flight build targets
    /// the same region, zoom band, and mutationGen, we just wait for it rather
    /// than relaunching.
    internal func launchAsyncVertexBuildIfNeeded(
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
        let vp = camera.worldViewportRect(windowWidth: viewportWidth, windowHeight: viewportHeight)
        let marginX = (vp.maxX - vp.minX) * cadCullMargin
        let marginY = (vp.maxY - vp.minY) * cadCullMargin
        let region = (
            minX: vp.minX - marginX,
            minY: vp.minY - marginY,
            maxX: vp.maxX + marginX,
            maxY: vp.maxY + marginY
        )
        let zoom = camera.zoom
        let lineZoom = zoom * Double(pixelScale)
        let mutationGen = geometry.mutationGeneration

        // Coalesce: while a build for the current mutation/palette is in
        // flight and its region still covers the viewport, let it land
        // instead of cancelling every frame — a cancel storm means no build
        // ever completes during a continuous pan/zoom. Zoom drift is settled
        // at apply time, which relaunches when the landed widths are stale.
        if let inFlightRegion = ctx.vbInFlightRegion,
           ctx.vbInFlightToken != nil,
           ctx.vbInFlightMutationGen == mutationGen,
           ctx.vbInFlightPaletteGen == paletteGen
        {
            let vpInsideInFlight =
                vp.minX >= inFlightRegion.minX && vp.maxX <= inFlightRegion.maxX &&
                vp.minY >= inFlightRegion.minY && vp.maxY <= inFlightRegion.maxY
            if vpInsideInFlight {
                return  // Already computing what we need; wait for it to land
            }
        }

        // Cancel a stale in-flight build and launch fresh, rate-limited:
        // relaunches during a continuous pan/zoom are capped at one per
        // 100 ms so the main thread is not re-gathering every frame. The
        // current buffer keeps displaying in between.
        if ctx.vbTask != nil {
            let now = SDL_GetTicks()
            guard now &- ctx.vbLastLaunchTicks >= 100 else { return }
        }
        ctx.vbLastLaunchTicks = SDL_GetTicks()
        engine._statAsyncLaunches += 1
        ctx.vbTask?.cancel()

        ctx.vbToken += 1
        let token = ctx.vbToken

        let inputs = gatherTessInputs(
            region: region, from: geometry, into: ctx,
            useLightDisplayPalette: useLightDisplayPalette,
            viewportBackground: viewportBackground)

        ctx.vbInFlightToken = token
        ctx.vbInFlightRegion = region
        ctx.vbInFlightZoom = lineZoom
        ctx.vbInFlightMutationGen = mutationGen
        ctx.vbInFlightPaletteGen = paletteGen

        let capturedZoom = zoom
        let capturedPixelScale = pixelScale
        let capturedAA = antiAliasLines
        let capturedHairlineQuads = usesTriangleHairlines
        let capturedMutationGen = mutationGen

        ctx.vbTask = Task.detached { [builder = ctx.vbBuilder] in
            await builder.build(
                inputs: inputs,
                token: token,
                cameraZoom: capturedZoom,
                pixelScale: capturedPixelScale,
                antiAliasLines: capturedAA,
                hairlineQuads: capturedHairlineQuads,
                region: region,
                mutationGen: capturedMutationGen
            )
        }
    }

    /// Called every frame. If a pending build matches the current in-flight
    /// token, applies it (GPU upload + swap). Also clears the in-flight marker
    /// so a new build can be launched.
    internal func applyPendingVertexBuildIfReady(ctx: WindowRenderContext, currentLineZoom: Double) {
        guard let wantToken = ctx.vbInFlightToken else { return }
        guard let result = ctx.vbBuilder.takePending(forToken: wantToken) else { return }

        if !Self.isLineWidthZoomStable(currentLineZoom, result.builtZoom) {
            // Zoom moved on while the build was in flight: keep displaying
            // the current buffer (geometry is still current; only line
            // widths are stale) and let the next frame launch a fresh async
            // build. Must NOT poison cachedMutationGen here — that forces a
            // full synchronous rebuild on the main thread.
            ctx.vbInFlightToken = nil
            ctx.vbTask = nil
            ctx.vbInFlightRegion = nil
            return
        }

        let paletteGen = ctx.vbInFlightPaletteGen
        if applyVertexBuild(result, paletteGen: paletteGen, ctx: ctx) {
            engine._statAsyncApplied += 1
        }

        ctx.vbInFlightToken = nil
        ctx.vbTask = nil
        ctx.vbInFlightRegion = nil
    }

    /// One-line GPU-load snapshot for the frame-timing window: active-tab
    /// vertex/batch counts, sprite count, and rebuild activity since the
    /// last window. Printed beside `[FrameTiming]`; counters reset here.
    internal func perfStatsLine() -> String {
        let actx = engine.tabManager.activeTab.map { tabCtx(for: $0.id) } ?? primaryCtx
        let totalVerts = actx.vertexChunks.reduce(0) { $0 + $1.vertexCount }
        let totalBatches = actx.vertexChunks.reduce(0) { $0 + $1.batches.count }
        var lineVerts = 0
        var otherVerts = 0
        for chunk in actx.vertexChunks {
            for batch in chunk.batches {
                if batch.pipelineType == .line { lineVerts += Int(batch.vertexCount) }
                else { otherVerts += Int(batch.vertexCount) }
            }
        }
        let census = actx.bridge.lastContentCensus
        let line =
            "[PerfStats] verts:\(totalVerts) batches:\(totalBatches) chunks:\(actx.vertexChunks.count)" +
            " sprites:\(actx.sprites.spriteCount)" +
            " lineVerts:\(lineVerts) triVerts:\(otherVerts) hatchVerts:\(actx.lastHatchVerts)" +
            " capped:\(actx.lastVertexCapped ? 1 : 0)" +
            " census:b\(census.blockInserts)t\(census.textEntities)h\(census.hatchEntities)d\(census.dashedEntities)" +
            " syncRebuild:\(engine._statSyncRebuilds)" +
            " asyncLaunch:\(engine._statAsyncLaunches)" +
            " asyncApplied:\(engine._statAsyncApplied)" +
            " regen:\(engine._statRegensLaunched)" +
            " unsupported:\(actx.bridge.curveUnsupportedCount)"
        engine._statSyncRebuilds = 0
        engine._statAsyncLaunches = 0
        engine._statAsyncApplied = 0
        engine._statRegensLaunched = 0
        return line
    }

    // MARK: - Dashed Line Rendering

    /// Draws a dashed line using ImGui's draw list.
    ///
    /// - Parameters:
    ///   - p1: Start point (screen coordinates).
    ///   - p2: End point (screen coordinates).
    ///   - color: 32-bit packed color (e.g., from `igGetColorU32_Vec4`).
    ///   - dashLength: Length of the visible dash in pixels.
    ///   - gapLength: Length of the invisible gap in pixels.
    ///   - thickness: Line thickness.
    ///   - drawList: The ImGui draw list target.
    internal func renderDashedLine(
        p1: ImVec2, p2: ImVec2,
        color: UInt32,
        dashLength: Float = 6.0,
        gapLength: Float = 4.0,
        thickness: Float = 1.0,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        guard let drawList = drawList else { return }

        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let distance = Float(sqrt(Double(dx * dx + dy * dy)))

        guard distance > 0 else { return }

        let dirX = dx / distance
        let dirY = dy / distance

        var currentDist: Float = 0
        var isDrawing = true

        while currentDist < distance {
            let step = isDrawing ? dashLength : gapLength
            let nextDist = min(currentDist + step, distance)

            if isDrawing {
                let startPoint = ImVec2(x: p1.x + dirX * currentDist, y: p1.y + dirY * currentDist)
                let endPoint = ImVec2(x: p1.x + dirX * nextDist, y: p1.y + dirY * nextDist)
                ImDrawList_AddLine(drawList, startPoint, endPoint, color, thickness)
            }

            currentDist = nextDist
            isDrawing.toggle()
        }
    }

    /// Renders the dynamic dashed tracking lines for Polar and OTRACK features.
    /// These are subtle, background-adaptive dashed lines that connect the
    /// reference point / tracking origin to the current cursor position.
    internal func renderTrackingOverlays(
        drawList: UnsafeMutablePointer<ImDrawList>?, cam: CameraTransform
    ) {
        guard let drawList = drawList else { return }

        // 1. Calculate Perceived Luminance (ITU-R BT.601) from background color
        let bg = engine.ui.backgroundColor
        let luminance = (0.299 * bg.r) + (0.587 * bg.g) + (0.114 * bg.b)

        // 2. Choose a subtle contrasting overlay (25% opacity)
        let trackingAlpha: Float = 0.25
        let trackingColorVec = luminance < 0.5
            ? ImVec4(x: 1.0, y: 1.0, z: 1.0, w: trackingAlpha)
            : ImVec4(x: 0.0, y: 0.0, z: 0.0, w: trackingAlpha)

        let trackingColorU32 = igGetColorU32_Vec4(trackingColorVec)

        // 3. Render Polar Tracking Line (if active)
        if let polar = engine.snap.lastPolarResult {
            let screenRef = engine.camera.transformWorldToScreen(
                worldX: polar.reference.x, worldY: polar.reference.y, cam: cam)
            let screenCursor = engine.camera.transformWorldToScreen(
                worldX: polar.worldPos.x, worldY: polar.worldPos.y, cam: cam)

            let dx = screenCursor.x - screenRef.x
            let dy = screenCursor.y - screenRef.y
            let dist = Float(sqrt(Double(dx * dx + dy * dy)))
            if dist > 0 {
                let p2X = screenRef.x + (dx / dist) * 10000.0
                let p2Y = screenRef.y + (dy / dist) * 10000.0

                renderDashedLine(
                    p1: ImVec2(x: screenRef.x, y: screenRef.y),
                    p2: ImVec2(x: p2X, y: p2Y),
                    color: trackingColorU32,
                    dashLength: 8.0, gapLength: 6.0, thickness: 1.0,
                    drawList: drawList
                )
            }
        }

        // 4. Render OTRACK Alignment Lines
        if let snap = engine.snap.currentSnapResult,
           engine.snap.snapTrackingEngine.trackingPoints.contains(where: { $0.entityHandle == snap.entityHandle }) {

            if let originPoint = engine.snap.snapTrackingEngine.trackingPoints.first(where: { $0.entityHandle == snap.entityHandle }) {
                let screenOrigin = engine.camera.transformWorldToScreen(
                    worldX: originPoint.worldPos.x, worldY: originPoint.worldPos.y, cam: cam)
                let screenSnap = engine.camera.transformWorldToScreen(
                    worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)

                let dx = screenSnap.x - screenOrigin.x
                let dy = screenSnap.y - screenOrigin.y
                let dist = Float(sqrt(Double(dx * dx + dy * dy)))
                if dist > 0 {
                    let p2X = screenOrigin.x + (dx / dist) * 10000.0
                    let p2Y = screenOrigin.y + (dy / dist) * 10000.0

                    renderDashedLine(
                        p1: ImVec2(x: screenOrigin.x, y: screenOrigin.y),
                        p2: ImVec2(x: p2X, y: p2Y),
                        color: trackingColorU32,
                        dashLength: 8.0, gapLength: 6.0, thickness: 1.0,
                        drawList: drawList
                    )
                }
            }
        }

        // 5. Render the green `+` markers for acquired OTRACK points
        let markerColor = igGetColorU32_Vec4(ImVec4(x: 0.0, y: 1.0, z: 0.0, w: 0.8))
        for tp in engine.snap.snapTrackingEngine.trackingPoints {
            let screenPos = engine.camera.transformWorldToScreen(
                worldX: tp.worldPos.x, worldY: tp.worldPos.y, cam: cam)
            let size: Float = 4.0

            ImDrawList_AddLine(drawList,
                ImVec2(x: screenPos.x - size, y: screenPos.y),
                ImVec2(x: screenPos.x + size, y: screenPos.y), markerColor, 1.5)
            ImDrawList_AddLine(drawList,
                ImVec2(x: screenPos.x, y: screenPos.y - size),
                ImVec2(x: screenPos.x, y: screenPos.y + size), markerColor, 1.5)
        }

        // 6. Render pending distance entry tooltip (direct distance during MOVE)
        if !engine.commandProcessor.pendingDistanceBuffer.isEmpty,
           engine.commandProcessor.commandRefPoint != nil,
           engine.commandProcessor.activeCommand == "MOVE" {
            let ghostX = engine.commandProcessor._moveGhostWorldX
            let ghostY = engine.commandProcessor._moveGhostWorldY
            let screenPos = engine.camera.transformWorldToScreen(worldX: ghostX, worldY: ghostY, cam: cam)
            let distText = engine.commandProcessor.pendingDistanceBuffer
            let tipCol = igGetColorU32_Vec4(ImVec4(x: 1.0, y: 0.84, z: 0.0, w: 1.0))
            let tipX = screenPos.x + 14
            let tipY = screenPos.y - 28
            ImDrawListAddText(drawList, ImVec2(x: tipX, y: tipY), tipCol, distText, nil)
        }
    }
}
