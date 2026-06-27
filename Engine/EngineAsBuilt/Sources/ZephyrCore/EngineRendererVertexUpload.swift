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
    internal func gatherTessInputs(
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    ) -> [TessInput] {
        var inputs: [TessInput] = []
        let useLightDisplayPalette = !engine.ui.isDarkTheme

        if let indices = engine.geometryManager.visiblePrimitiveIndices(
            inWorldRect: region.minX, minY: region.minY,
            maxX: region.maxX, maxY: region.maxY)
        {
            engine._cachedUsingGrid = true
            inputs.reserveCapacity(indices.count)

            for idx in indices {
                guard let p = engine.geometryManager.getPrimitive(at: idx) else { continue }
                inputs.append(TessInput(
                    type: p.type,
                    points: p.points,
                    rects: p.rects,
                    corners: p.corners,
                    color: useLightDisplayPalette ? p.adjustedColorLight : p.adjustedColorDark,
                    lineWeight: p.lineWeight,
                    geomWidth: p.geomWidth,
                    entityIndex: p.entityIndex,
                    isHatchLine: p.isHatchLine,
                    hatchSpacing: p.hatchSpacing,
                    isPanProxy: p.isPanProxy,
                    gradientData: p.gradientData
                ))
            }
        } else {
            engine._cachedUsingGrid = false
            let primitives = engine.geometryManager.getPrimitivesForRendering()
            inputs.reserveCapacity(primitives.count)

            for p in primitives {
                inputs.append(TessInput(
                    type: p.type,
                    points: p.points,
                    rects: p.rects,
                    corners: p.corners,
                    color: useLightDisplayPalette ? p.adjustedColorLight : p.adjustedColorDark,
                    lineWeight: p.lineWeight,
                    geomWidth: p.geomWidth,
                    entityIndex: p.entityIndex,
                    isHatchLine: p.isHatchLine,
                    hatchSpacing: p.hatchSpacing,
                    isPanProxy: p.isPanProxy,
                    gradientData: p.gradientData
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
    /// Called from both the sync `rebuildCadVertexBuffer()` and the async
    /// `applyPendingVertexBuildIfReady()` paths.
    internal func applyVertexBuild(_ result: VertexBuildResult, paletteGen: Int) {
        let vertices = result.vertices

        // --- Build NEW GPU buffers into locals ---
        var newVertexBuffer: OpaquePointer? = nil

        if !vertices.isEmpty {
            let sizeInBytes = UInt32(vertices.count * MemoryLayout<CADVertex>.stride)
            var bufferCreateInfo = SDL_GPUBufferCreateInfo(
                usage: SDL_GPU_BUFFERUSAGE_VERTEX, size: sizeInBytes, props: 0)
            newVertexBuffer = SDL_CreateGPUBuffer(engine.gpuDevice, &bufferCreateInfo)
            guard let vb = newVertexBuffer else {
                print("Failed to create CAD GPU vertex buffer: \(String(cString: SDL_GetError()))")
                return
            }

            var transferInfo = SDL_GPUTransferBufferCreateInfo()
            transferInfo.usage = SDL_GPUTransferBufferUsage(rawValue: 0)
            transferInfo.size = sizeInBytes
            guard let transferBuf = SDL_CreateGPUTransferBuffer(engine.gpuDevice, &transferInfo) else {
                print("Failed to create CAD GPU transfer buffer: \(String(cString: SDL_GetError()))")
                SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                return
            }

            guard let mapped = SDL_MapGPUTransferBuffer(engine.gpuDevice, transferBuf, false) else {
                print("Failed to map CAD GPU transfer buffer: \(String(cString: SDL_GetError()))")
                SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                return
            }
            _ = vertices.withUnsafeBytes { ptr in
                memcpy(mapped, ptr.baseAddress!, Int(sizeInBytes))
            }
            SDL_UnmapGPUTransferBuffer(engine.gpuDevice, transferBuf)

            guard let cmd = SDL_AcquireGPUCommandBuffer(engine.gpuDevice) else {
                print("Failed to acquire command buffer for CAD upload")
                SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                return
            }

            let copyPass = SDL_BeginGPUCopyPass(cmd)
            guard let cp = copyPass else {
                print("Failed to begin copy pass for CAD buffer upload")
                SDL_CancelGPUCommandBuffer(cmd)
                SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
                SDL_ReleaseGPUBuffer(engine.gpuDevice, vb)
                return
            }

            var sourceLocation = SDL_GPUTransferBufferLocation(transfer_buffer: transferBuf, offset: 0)
            var destLocation = SDL_GPUBufferRegion(buffer: vb, offset: 0, size: sizeInBytes)
            SDL_UploadToGPUBuffer(cp, &sourceLocation, &destLocation, false)

            SDL_EndGPUCopyPass(cp)

            if !SDL_SubmitGPUCommandBuffer(cmd) {
                print("Failed to submit command buffer for CAD buffer upload")
            }
            SDL_ReleaseGPUTransferBuffer(engine.gpuDevice, transferBuf)
        }

        // --- Swap: release old, assign new (atomic with metadata write) ---
        if let oldBuf = cadVertexBuffer {
            SDL_ReleaseGPUBuffer(engine.gpuDevice, oldBuf)
        }

        cadVertexBuffer = newVertexBuffer

        if newVertexBuffer != nil {
            cadVertexCount = vertices.count
            cadDrawBatches = result.batches
        } else {
            cadVertexCount = 0
            cadDrawBatches.removeAll()
        }

        // --- Write cache metadata at swap time (atomic with buffer replacement) ---
        _cachedViewportMinX = result.regionMinX
        _cachedViewportMaxX = result.regionMaxX
        _cachedViewportMinY = result.regionMinY
        _cachedViewportMaxY = result.regionMaxY
        _bufferedZoom = result.builtZoom
        engine._lastCameraZoom = result.builtZoom
        engine._cachedMutationGen = result.mutationGen
        engine._cachedDisplayPaletteGen = paletteGen
    }

    // MARK: - Async Launch / Apply (main actor)

    /// Launches an async vertex-buffer build if the current cache is stale and
    /// no in-flight build already satisfies the current viewport + zoom +
    /// mutation. Dedup prevents 60 Hz thrashing: if the in-flight build targets
    /// the same region, zoom band, and mutationGen, we just wait for it rather
    /// than relaunching.
    internal func launchAsyncVertexBuildIfNeeded() {
        let vp = engine.camera.worldViewportRect(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let marginX = (vp.maxX - vp.minX) * cadCullMargin
        let marginY = (vp.maxY - vp.minY) * cadCullMargin
        let region = (
            minX: vp.minX - marginX,
            minY: vp.minY - marginY,
            maxX: vp.maxX + marginX,
            maxY: vp.maxY + marginY
        )
        let zoom = engine.camera.zoom
        let mutationGen = engine.geometryManager.mutationGeneration
        let paletteGen = engine.ui.displayPaletteGeneration

        // Dedup: is the in-flight build already going to satisfy the current desire?
        if let inFlightRegion = _vbInFlightRegion,
           _vbInFlightToken != nil
        {
            let vpInsideInFlight =
                vp.minX >= inFlightRegion.minX && vp.maxX <= inFlightRegion.maxX &&
                vp.minY >= inFlightRegion.minY && vp.maxY <= inFlightRegion.maxY

            let zoomStable: Bool
            if _vbInFlightZoom > 0 {
                let ratio = zoom / _vbInFlightZoom
                zoomStable = ratio > 0.8 && ratio < 1.25
            } else {
                zoomStable = false
            }
            if vpInsideInFlight && zoomStable
                && _vbInFlightMutationGen == mutationGen
                && _vbInFlightPaletteGen == paletteGen
            {
                return  // Already computing exactly what we need
            }
        }

        // Cancel stale in-flight build and launch fresh.
        _vbBuildTask?.cancel()

        _vbBuildToken += 1
        let token = _vbBuildToken

        let inputs = gatherTessInputs(region: region)

        _vbInFlightToken = token
        _vbInFlightRegion = region
        _vbInFlightZoom = zoom
        _vbInFlightMutationGen = mutationGen
        _vbInFlightPaletteGen = paletteGen

        let capturedZoom = zoom
        let capturedAA = antiAliasLines
        let capturedMutationGen = mutationGen

        _vbBuildTask = Task.detached { [vbBuilder] in
            await vbBuilder.build(
                inputs: inputs,
                token: token,
                cameraZoom: capturedZoom,
                antiAliasLines: capturedAA,
                region: region,
                mutationGen: capturedMutationGen
            )
        }
    }

    /// Called every frame. If a pending build matches the current in-flight
    /// token, applies it (GPU upload + swap). Also clears the in-flight marker
    /// so a new build can be launched.
    internal func applyPendingVertexBuildIfReady() {
        guard let wantToken = _vbInFlightToken else { return }
        guard let result = vbBuilder.takePending(forToken: wantToken) else { return }

        let paletteGen = _vbInFlightPaletteGen
        applyVertexBuild(result, paletteGen: paletteGen)

        _vbInFlightToken = nil
        _vbBuildTask = nil
        _vbInFlightRegion = nil
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
        drawList: UnsafeMutablePointer<ImDrawList>? = igGetWindowDrawList()
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
    }
}
